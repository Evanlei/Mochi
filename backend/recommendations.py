"""Live acquisition → independent text ranking → canonical recording response."""

import asyncio
import json
import re
import uuid
from collections import OrderedDict
from dataclasses import replace

import httpx
from starlette.concurrency import run_in_threadpool

from discovery import discover, discovery_tags
from music import CatalogTrack, artist_key, identity_key, normalized
from providers import LastFM, ProviderError, ProviderHTTP, ReccoBeats
from selection import SongSelection, SongSelector
from storage import ProviderCache, TasteStore


class RecommendationService:
    def __init__(self, settings, *, client=None):
        self.settings = settings
        self.cache = ProviderCache(settings.data_directory / "providers.sqlite3")
        self.taste = TasteStore(settings.data_directory / "taste.sqlite3")
        self.client = client or httpx.AsyncClient(headers={"Accept": "application/json", "User-Agent": "Mochi/0.1"})
        self.http = ProviderHTTP(self.client, self.cache, interval=0.4)
        self.lastfm, self.recco = LastFM(self.http, settings.lastfm_key), ReccoBeats(self.http)
        self.request_lock = asyncio.Lock()
        self.selectors = OrderedDict()

    async def close(self):
        await self.client.aclose()
        self.cache.close(); self.taste.close()

    def similar_context(self, request_id, track_id, title, artist):
        prompt, previous = self.taste.recommendation_context(request_id)
        if (track_id != "lastfm-" + identity_key(title, artist)
            or previous.get(track_id) != artist_key(artist)):
            raise ValueError("Choose a song from that recommendation.")
        # Names came from a prior independent Mochi recommendation. Verify them
        # against stored opaque keys; never accept Spotify metadata or features.
        seed = CatalogTrack(id=track_id, title=title, artist=artist, description="User-selected Last.fm discovery seed.")
        return prompt, seed, tuple(previous)

    async def recommend(self, prompt, intent, *, seed=None, exclude=(), artists=()):
        if intent.clarification:
            return SongSelection(catalog_kind="lastfm_live", method="none", tracks=[], message=intent.clarification)
        # This is a local single-user backend; bound concurrent provider work.
        if self.request_lock.locked():
            return SongSelection(catalog_kind="lastfm_live", method="none", tracks=[], message="Another discovery request is finishing. Try again shortly.")
        async with self.request_lock:
            return await self._recommend(prompt, intent, seed=seed, exclude=exclude, artists=artists)

    async def _recommend(self, prompt, intent, *, seed=None, exclude=(), artists=()):
        if not self.settings.lastfm_key:
            return SongSelection(catalog_kind="lastfm_live", method="none", tracks=[],
                message="Add LASTFM_API_KEY to backend/.env, then restart the backend.")
        taste = self.taste.snapshot()
        taste["favorite_artists"] = {artist_key(name) for name in artists}
        favorites = []
        for identifier in taste["favorites"]:
            cached = self.cache.get("track:" + identifier)
            if cached:
                favorites.append(CatalogTrack.model_validate_json(json.dumps(cached)))
        tracks, warnings = [], []
        try:
            async with asyncio.timeout(20):
                tracks, warnings = await discover(prompt, self.lastfm, favorites=favorites, seed=seed, artists=artists)
                tracks = [track for track in tracks if track.id not in exclude]
                # Interleave pool labels so one provider's first genre does not
                # consume every detail lookup. We enrich at most 12 recordings.
                ordered = list(range(len(tracks)))[:12]
                for index in ordered:
                    try: tracks[index] = await self.lastfm.tags(tracks[index])
                    except ProviderError as error: warnings.append(str(error))
                if self.settings.reccobeats_enabled:
                    for index in ordered:
                        try: tracks[index] = await self.recco.enrich(tracks[index])
                        except ProviderError as error:
                            warnings.append(str(error)); break
        except TimeoutError:
            warnings.append("Discovery reached its time limit; showing the candidates available so far.")
        if not tracks:
            return SongSelection(catalog_kind="lastfm_live", method="none", tracks=[],
                message=warnings[0] if warnings else ("No new similar songs found. Try another song." if seed is not None else
                    "No songs found. Try another genre."), warnings=list(dict.fromkeys(warnings)))
        # Mood adjectives remain subjective ranking cues. Only an explicit
        # 'low/high energy' requirement demands verified energy metadata.
        # Sample-mode behavior is unchanged.
        if not re.search(r"\b(?:low|high) energy\b", normalized(prompt)):
            intent = replace(intent, energy_locked=False)
        # A tiny in-memory LRU reuses embeddings only while the source text is
        # identical. At most eight bounded catalogs; never persist vectors.
        signature = tuple(track.model_dump_json() for track in tracks)
        if signature not in self.selectors:
            self.selectors[signature] = SongSelector(tracks)
        self.selectors.move_to_end(signature)
        while len(self.selectors) > 8:
            self.selectors.popitem(last=False)
        # Keep the complete request and add the inspected retrieval vocabulary:
        # e.g. "Focus" also means the "study" pool when lexical fallback runs.
        ranking_prompt = prompt + " " + " ".join(discovery_tags(prompt))
        broad_request = seed is None and bool(artists) and normalized(prompt) in {
            "surprise me", "anything", "any music", "music", "my favorites", "play my favorites"}
        selection = await run_in_threadpool(self.selectors[signature].select, ranking_prompt, intent,
                                           taste=taste, allow_unmatched=broad_request)
        selection.catalog_kind = "lastfm_live"
        selection.warnings = list(dict.fromkeys(warnings))
        if selection.tracks:
            selection.request_id = str(uuid.uuid4())
            self.taste.save_request(selection.request_id, prompt, selection.tracks)
        return selection
