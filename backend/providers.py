"""Read-only provider adapters. Never log requests containing an API key."""

import asyncio
import hashlib
import json
import math
import re
import time
from email.utils import parsedate_to_datetime
from urllib.parse import urlparse

import httpx

from music import CatalogTrack, identity_key, normalized


class ProviderError(Exception):
    def __init__(self, message, *, retry_after=None):
        super().__init__(message)
        self.retry_after = retry_after


def cache_lifetime(headers, *, now=None):
    """No freshness headers means no reuse; no-store/no-cache always win."""
    now = time.time() if now is None else now
    control = headers.get("cache-control", "").lower()
    if any(word in control for word in ("no-store", "no-cache", "private")):
        return 0
    age = max(0, float(headers.get("age", "0"))) if re.fullmatch(r"\d+(?:\.\d+)?", headers.get("age", "0")) else 0
    match = re.search(r'(?:^|,)\s*max-age\s*=\s*"?(\d+)', control)
    if match:
        return max(0, min(86400, int(match[1]) - age))
    try:
        return max(0, min(86400, parsedate_to_datetime(headers["expires"]).timestamp() - now))
    except (KeyError, TypeError, ValueError, OverflowError):
        return 0


class ProviderHTTP:
    def __init__(self, client, cache, *, interval=0.3):
        self.client, self.cache = client, cache
        self.interval, self.next_request = interval, 0
        self.lock = asyncio.Lock()
        self.cooldowns = {}

    async def get(self, provider, base, params, *, missing_ok=False):
        # Include a digest of credentials in cache identity, never the key itself.
        key = provider + ":" + hashlib.sha256(json.dumps([base, sorted(params.items())]).encode()).hexdigest()
        cached = self.cache.get(key)
        if cached is not None:
            return cached, key, self.cache.remaining(key)
        async with self.lock:
            now = time.monotonic()
            remaining = self.cooldowns.get(provider, 0) - now
            if remaining > 0:
                raise ProviderError(f"{provider} asked Mochi to wait before retrying.", retry_after=remaining)
            await asyncio.sleep(max(0, self.next_request - now))
            self.next_request = time.monotonic() + self.interval
        try:
            async with self.client.stream("GET", base, params=params, timeout=4, follow_redirects=False) as response:
                if response.status_code == 429:
                    raw = response.headers.get("retry-after", "60")
                    try:
                        delay = float(raw)
                    except ValueError:
                        try: delay = parsedate_to_datetime(raw).timestamp() - time.time()
                        except (ValueError, TypeError): delay = 60
                    delay = min(86400, max(1, delay)) if math.isfinite(delay) else 60
                    self.cooldowns[provider] = time.monotonic() + delay
                    raise ProviderError(f"{provider} is limiting requests. Try again later.", retry_after=delay)
                if missing_ok and response.status_code == 404:
                    return {}, key, 0
                if response.status_code != 200:
                    raise ProviderError(f"{provider} request failed (HTTP {response.status_code}).")
                body = bytearray()
                async for chunk in response.aiter_bytes():
                    body.extend(chunk)
                    if len(body) > 1_000_000:
                        raise ProviderError(f"{provider} returned an oversized response.")
                value = json.loads(body)
                if not isinstance(value, dict):
                    raise ValueError("Expected object")
                ttl = cache_lifetime(response.headers)
                self.cache.put(key, value, ttl)
                return value, key, ttl
        except (httpx.HTTPError, ValueError, UnicodeError):
            raise ProviderError(f"Couldn't read {provider}. Try again.") from None


def entries(value):
    if isinstance(value, dict):
        return [value]
    return value if isinstance(value, list) else []


def lastfm_url(value):
    if not isinstance(value, str):
        return None
    parsed = urlparse(value)
    if parsed.hostname not in {"www.last.fm", "last.fm"} or parsed.scheme not in {"http", "https"}:
        return None
    return parsed._replace(scheme="https").geturl()


class LastFM:
    def __init__(self, http, api_key):
        self.http, self.api_key = http, api_key

    async def request(self, method, **params):
        if not self.api_key:
            raise ProviderError("Add LASTFM_API_KEY to backend/.env, then restart the backend.")
        value, key, ttl = await self.http.get("Last.fm", "https://ws.audioscrobbler.com/2.0/",
            {"method": method, "api_key": self.api_key, "format": "json", **params})
        if "error" in value:
            if str(value["error"]) == "29":
                self.http.cooldowns["Last.fm"] = time.monotonic() + 60
            message = "Last.fm rejected the API key. Check backend/.env." if str(value["error"]) in {"4", "10", "26"} else "Last.fm couldn't complete discovery. Try again later."
            raise ProviderError(message)
        return value, ttl

    async def top_tracks(self, tag, *, limit=25):
        value, ttl = await self.request("tag.getTopTracks", tag=tag, limit=limit)
        return self.parse_tracks(value.get("tracks", {}).get("track", []), (tag,), ttl)

    async def similar(self, track, *, limit=15):
        value, ttl = await self.request("track.getSimilar", track=track.title, artist=track.artist, autocorrect=0, limit=limit)
        return self.parse_tracks(value.get("similartracks", {}).get("track", []), (), ttl)

    def parse_tracks(self, rows, tags, ttl):
        result = []
        for row in entries(rows):
            if not isinstance(row, dict): continue
            title, artist = row.get("name"), row.get("artist", {})
            artist = artist.get("name") if isinstance(artist, dict) else artist
            if not isinstance(title, str) or not isinstance(artist, str) or not title.strip() or not artist.strip(): continue
            identifier = "lastfm-" + identity_key(title, artist)
            try:
                track = CatalogTrack(id=identifier, title=title, artist=artist,
                    tags=tags, description="Community tags: " + ", ".join(tags) if tags else "Related listening patterns on Last.fm.",
                    mbid=row.get("mbid") or None, source_url=lastfm_url(row.get("url")))
            except ValueError:
                continue
            # Persist canonical metadata only for the lifetime allowed by its response.
            self.http.cache.put("track:" + identifier, track.model_dump(mode="json"), ttl)
            result.append(track)
        return result

    async def tags(self, track):
        value, ttl = await self.request("track.getTopTags", track=track.title, artist=track.artist, autocorrect=0)
        tags = []
        for row in entries(value.get("toptags", {}).get("tag", [])):
            if isinstance(row, dict) and isinstance(row.get("name"), str):
                tag = row["name"].strip().lower()
                if 0 < len(tag) <= 60 and tag not in tags:
                    tags.append(tag)
        # A candidate pool label describes that pool, not necessarily this recording.
        if not tags: return track
        updated = track.model_copy(update={"tags": tuple(tags[:12]), "description": "Community tags: " + ", ".join(tags[:12])})
        self.http.cache.put("track:" + track.id, updated.model_dump(mode="json"), ttl)
        return updated


class ReccoBeats:
    """Opt-in tempo lookup. Spotify-derived names are identity checks only.

    No returned names, popularity, or descriptions enter the semantic model.
    Instrumentalness is not promoted into a reliable vocals boolean.
    """
    def __init__(self, http):
        self.http = http

    async def enrich(self, track):
        if len(track.title) < 3 or len(track.artist) < 3:
            return track
        value, _, _ = await self.http.get("ReccoBeats", "https://api.reccobeats.com/v1/track/search",
            {"searchText": track.title, "artist": track.artist, "size": 5})
        matches = [row for row in entries(value.get("content", [])) if isinstance(row, dict)
            and normalized(row.get("trackTitle", "")) == normalized(track.title)
            and any(isinstance(artist, dict) and normalized(artist.get("name", "")) == normalized(track.artist)
                    for artist in entries(row.get("artists", [])))]
        # Ambiguity is safer than applying a cover/remix's tempo to this recording.
        ids = {row.get("id") for row in matches}
        if len(ids) != 1:
            return track
        features = await self.features(matches[0])
        if not features:
            return track
        # Preserve the independently sourced title/artist/description verbatim.
        return track.model_copy(update={"bpm": features["bpm"], "feature_source": "reccobeats",
            "feature_recording_id": features["feature_recording_id"], "feature_spotify_id": features["spotify_id"]})

    async def features_by_spotify_id(self, spotify_id):
        if not re.fullmatch(r"[A-Za-z0-9]{22}", spotify_id):
            raise ValueError("Invalid Spotify recording ID")
        value, _, _ = await self.http.get("ReccoBeats", "https://api.reccobeats.com/v1/track", {"ids": spotify_id})
        rows = entries(value.get("content", []))
        row = next((row for row in rows if isinstance(row, dict) and row.get("href") == f"https://open.spotify.com/track/{spotify_id}"), None)
        if not row: return None
        return await self.features(row)

    async def features(self, row):
        identifier = row.get("id", "")
        if not isinstance(identifier, str) or not re.fullmatch(r"[0-9a-fA-F-]{36}", identifier): return None
        value, _, _ = await self.http.get("ReccoBeats", f"https://api.reccobeats.com/v1/track/{identifier}/audio-features", {}, missing_ok=True)
        tempo = value.get("tempo")
        if isinstance(tempo, bool) or not isinstance(tempo, (int, float)) or not math.isfinite(tempo) or not 20 <= tempo <= 400:
            return None
        return {"bpm": float(tempo), "feature_recording_id": identifier,
                "spotify_id": row.get("href", "").rsplit("/", 1)[-1]}
