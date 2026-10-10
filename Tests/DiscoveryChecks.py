"""Deterministic adapter/storage checks: fictional fixtures, no external requests."""

import asyncio
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import httpx
from discovery import discover, discovery_tags
from music import CatalogTrack, identity_key
from providers import LastFM, ProviderError, ProviderHTTP, ReccoBeats, cache_lifetime
from storage import ProviderCache, TasteStore

def track(title="Fixture Piano", artist="Fixture Artist", **kwargs):
    return CatalogTrack(id="lastfm-" + identity_key(title, artist), title=title, artist=artist,
                        description="Community tags: piano, ambient", tags=("piano", "ambient"), **kwargs)


class StorageChecks(unittest.TestCase):
    def setUp(self):
        self.directory = self.enterContext(tempfile.TemporaryDirectory())
        self.now = [1000]
        self.cache = ProviderCache(Path(self.directory) / "cache.sqlite3", max_bytes=32768, clock=lambda: self.now[0])
        self.addCleanup(self.cache.close)

    def test_cache_expiry_and_physical_size_limit(self):
        self.cache.put("a", {"hello": "world"}, 2)
        self.assertEqual(self.cache.get("a"), {"hello": "world"})
        self.now[0] += 3
        self.assertIsNone(self.cache.get("a"))
        self.cache.put("uncacheable", {}, 0)
        self.assertIsNone(self.cache.get("uncacheable"))
        for index in range(40): self.cache.put(str(index), {"body": "x" * 4000}, 60)
        self.assertLessEqual(self.cache.size_bytes(), 32768)
        self.assertIsNone(self.cache.get("0"))
        self.assertIsNotNone(self.cache.get("39"))

    def test_freshness_headers(self):
        for headers, expected in [({}, 0), ({"cache-control": "public, max-age=100", "age": "20"}, 80),
            ({"cache-control": "no-cache, max-age=100"}, 0), ({"cache-control": "no-store"}, 0),
            ({"cache-control": "private, max-age=100"}, 0), ({"expires": "Thu, 01 Jan 1970 00:18:20 GMT"}, 100),
            ({"expires": "invalid"}, 0)]:
            with self.subTest(headers=headers): self.assertEqual(cache_lifetime(headers, now=1000), expected)

    def test_taste_persistence_idempotency_context_and_clear(self):
        path = Path(self.directory) / "taste.sqlite3"
        taste = TasteStore(path, clock=lambda: self.now[0])
        candidate = track()
        taste.save_request("request", "my private study request", [candidate])
        taste.feedback("event", "request", candidate.id, "like")
        taste.feedback("event", "request", candidate.id, "like")
        with self.assertRaises(ValueError): taste.feedback("event", "request", candidate.id, "dislike")
        with self.assertRaises(ValueError): taste.feedback("bad", "request", "other", "like")
        taste.feedback("next", "request", candidate.id, "select")
        self.assertEqual(taste.snapshot()["tracks"][candidate.id], 1)
        self.assertEqual(taste.snapshot()["recent"], [candidate.id])
        taste.close()
        taste = TasteStore(path, clock=lambda: self.now[0]); self.addCleanup(taste.close)
        self.assertEqual(taste.snapshot()["favorites"], [candidate.id])
        taste.feedback("unlike", "request", candidate.id, "dislike")
        self.assertEqual(taste.snapshot()["tracks"][candidate.id], -1)
        self.assertEqual(taste.snapshot()["favorites"], [])
        self.assertNotIn(candidate.title.encode(), path.read_bytes())
        self.now[0] += 31 * 86400
        with self.assertRaises(ValueError): taste.feedback("old", "request", candidate.id, "like")
        taste.clear(); self.assertEqual(taste.snapshot()["tracks"], {})


class ProviderChecks(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = self.enterContext(tempfile.TemporaryDirectory())
        self.cache = ProviderCache(Path(self.directory) / "cache.sqlite3")
        self.addCleanup(self.cache.close)
        self.requests, self.replies = [], []
        async def handle(request):
            self.requests.append(request)
            reply = self.replies.pop(0)
            if isinstance(reply, Exception): raise reply
            return reply
        self.client = httpx.AsyncClient(transport=httpx.MockTransport(handle))
        self.addAsyncCleanup(self.client.aclose)
        self.http = ProviderHTTP(self.client, self.cache, interval=0)
        self.lastfm = LastFM(self.http, "fixture-key-never-log")

    def reply(self, value, **kwargs):
        self.replies.append(httpx.Response(200, json=value, **kwargs))

    async def test_lastfm_tracks_tags_and_cached_credentials(self):
        self.reply({"tracks": {"track": [{"name": "Fixture Piano", "artist": {"name": "Fixture Artist"},
            "mbid": "", "url": "http://www.last.fm/music/Fixture/_/Piano"}, {"name": "", "artist": {"name": "bad"}}]}},
            headers={"Cache-Control": "max-age=100"})
        result = await self.lastfm.top_tracks("piano")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].source_url, "https://www.last.fm/music/Fixture/_/Piano")
        self.assertIsNone(result[0].bpm); self.assertIsNone(result[0].vocals); self.assertIsNone(result[0].energy)
        self.assertEqual(self.requests[0].url.params["method"], "tag.getTopTracks")
        self.assertEqual(await self.lastfm.top_tracks("piano"), result)
        self.assertEqual(len(self.requests), 1)
        self.assertNotIn(b"fixture-key-never-log", (Path(self.directory) / "cache.sqlite3").read_bytes())
        self.reply({"toptags": {"tag": {"name": "Ambient", "count": 100}}})
        tagged = await self.lastfm.tags(result[0])
        self.assertEqual(tagged.tags, ("ambient",))
        self.assertIsNone(tagged.energy)

    async def test_errors_invalid_json_oversized_and_missing_key(self):
        with self.assertRaisesRegex(ProviderError, "LASTFM_API_KEY"):
            await LastFM(self.http, "").top_tracks("piano")
        self.assertEqual(self.requests, [])
        self.reply({"error": 10, "message": "secret may appear here"})
        with self.assertRaisesRegex(ProviderError, "rejected the API key"):
            await self.lastfm.top_tracks("piano")
        for response in [httpx.Response(503), httpx.Response(200, content=b"not json"),
                         httpx.Response(200, content=b"x" * 1_000_001)]:
            self.replies.append(response)
            with self.assertRaises(ProviderError): await self.lastfm.top_tracks("jazz")

    async def test_rate_limit_cooldown_prevents_repeat_requests(self):
        self.replies.append(httpx.Response(429, headers={"Retry-After": "10"}))
        with self.assertRaises(ProviderError): await self.lastfm.top_tracks("piano")
        with self.assertRaises(ProviderError): await self.lastfm.top_tracks("jazz")
        self.assertEqual(len(self.requests), 1)

    async def test_discovery_deduplicates_and_allows_partial_success(self):
        row = {"name": "Fixture Piano", "artist": "Fixture Artist"}
        self.reply({"tracks": {"track": [row, row]}})
        self.replies.append(httpx.Response(503))
        candidates, warnings = await discover("piano jazz", self.lastfm)
        self.assertEqual(len(candidates), 1); self.assertEqual(len(warnings), 1)
        self.assertEqual(discovery_tags("avoid metal, piano instead"), ["piano"])
        self.assertEqual(discovery_tags("qwerty"), [])
        self.assertEqual(discovery_tags("Surprise me"), ["pop", "indie"])

    def recco_row(self, **changes):
        return {"id": "25c8ca63-5895-4572-84eb-a7040bc08c4d", "trackTitle": "Fixture Piano",
                "artists": [{"name": "Fixture Artist"}], "href": "https://open.spotify.com/track/0000000000000000000001", **changes}

    async def test_recco_exact_identity_only_and_no_model_metadata_leak(self):
        self.reply({"content": [self.recco_row(trackTitle="Fixture Piano (Live)"), self.recco_row()]})
        self.reply({"tempo": 90.5, "instrumentalness": 0.99, "energy": 0.2})
        original = track()
        enriched = await ReccoBeats(self.http).enrich(original)
        self.assertEqual(enriched.bpm, 90.5)
        self.assertEqual(enriched.search_text, original.search_text)
        self.assertIsNone(enriched.vocals); self.assertIsNone(enriched.energy)
        self.assertEqual(self.requests[0].url.params["searchText"], original.title)
        self.assertEqual(self.requests[0].url.params["artist"], original.artist)
        self.assertEqual(self.requests[1].url.path, "/v1/track/25c8ca63-5895-4572-84eb-a7040bc08c4d/audio-features")

    async def test_recco_ambiguous_missing_and_invalid_features_stay_unknown(self):
        self.reply({"content": [self.recco_row(), self.recco_row(id="15c8ca63-5895-4572-84eb-a7040bc08c4d")]})
        self.assertIsNone((await ReccoBeats(self.http).enrich(track())).bpm)
        for tempo in (None, True, -1, float("inf"), "90"):
            self.reply({"content": [self.recco_row()]})
            self.replies.append(httpx.Response(200, content=json.dumps({"tempo": tempo}).encode()))
            self.assertIsNone((await ReccoBeats(self.http).enrich(track())).bpm)

    async def test_cancellation_propagates_without_caching(self):
        async def slow(request):
            await asyncio.sleep(10)
            return httpx.Response(200, json={})
        async with httpx.AsyncClient(transport=httpx.MockTransport(slow)) as client:
            http = ProviderHTTP(client, self.cache, interval=0)
            task = asyncio.create_task(LastFM(http, "key").top_tracks("piano"))
            await asyncio.sleep(0.01); task.cancel()
            with self.assertRaises(asyncio.CancelledError): await task
        self.assertEqual(self.cache.connection.execute("SELECT COUNT(*) FROM responses").fetchone()[0], 0)


if __name__ == "__main__": unittest.main()
