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
from recommendations import RecommendationService
from settings import Settings
from intent import interpret_request, IntentResult
from selection import SongSelector
from unittest.mock import patch
from fastapi.testclient import TestClient
from main import app
import uuid

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
        self.reply({"content": [self.recco_row(trackTitle=None), self.recco_row(artists=[{"name": None}])]})
        self.assertIsNone((await ReccoBeats(self.http).enrich(track())).bpm)

    async def test_reissues_share_isrc_but_different_recordings_do_not(self):
        self.reply({"content": [self.recco_row(isrc="TEST12345678", durationMs=200000),
            self.recco_row(id="15c8ca63-5895-4572-84eb-a7040bc08c4d", isrc="TEST12345678", durationMs=200005)]})
        self.reply({"tempo": 90})
        self.assertEqual((await ReccoBeats(self.http).enrich(track())).bpm, 90)
        self.reply({"content": [self.recco_row(isrc="TEST12345678", durationMs=200000),
            self.recco_row(id="15c8ca63-5895-4572-84eb-a7040bc08c4d", isrc="OTHER1234567", durationMs=200000)]})
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

    async def test_live_service_ranks_saves_context_and_uses_favorites(self):
        methods = []
        async def handle(request):
            method = request.url.params.get("method")
            methods.append(method)
            if method == "track.getTopTags":
                tags = ["jazz", "piano"] if request.url.params["track"] == "Fixture Piano" else ["jazz", "saxophone"]
                return httpx.Response(200, json={"toptags": {"tag": [{"name": tag} for tag in tags]}}, headers={"Cache-Control": "max-age=100"})
            rows = [{"name": "Fixture Sax", "artist": "Other Artist"}, {"name": "Fixture Piano", "artist": "Fixture Artist"}]
            key = "similartracks" if method == "track.getSimilar" else "tracks"
            return httpx.Response(200, json={key: {"track": rows}}, headers={"Cache-Control": "max-age=100"})
        client = httpx.AsyncClient(transport=httpx.MockTransport(handle))
        service = RecommendationService(Settings(lastfm_key="fixture", data_directory=Path(self.directory)/"service"), client=client)
        self.addAsyncCleanup(service.close)
        service.http.interval = 0
        with patch("selection.get_matcher", return_value=None):
            selection = await service.recommend("jazz piano", interpret_request("jazz piano", use_semantic=False))
            self.assertEqual(selection.catalog_kind, "lastfm_live")
            self.assertEqual(selection.tracks[0].title, "Fixture Piano")
            self.assertIsNotNone(selection.request_id)
            self.assertTrue(all(row.vocals is None and row.energy is None for row in selection.tracks))
            import uuid
            service.taste.feedback(str(uuid.uuid4()), selection.request_id, selection.tracks[0].id, "like")
            second = await service.recommend("jazz piano", IntentResult())
            self.assertIn("track.getSimilar", methods)
            self.assertGreater(second.tracks[0].score, selection.tracks[0].score)
            strict = await service.recommend("jazz piano 80-100 BPM", IntentResult(bpm_min=80, bpm_max=100))
            self.assertEqual(strict.tracks, [])
            vocals = await service.recommend("jazz piano no vocals", IntentResult(vocals=False))
            self.assertEqual(vocals.tracks, [])
            for prompt in ("jazz piano low energy", "jazz piano high–energy"):
                strict_energy = await service.recommend(prompt, interpret_request(prompt, use_semantic=False))
                self.assertEqual(strict_energy.tracks, [])

    async def test_quick_choice_aliases_work_without_a_semantic_model(self):
        async def handle(request):
            if request.url.params["method"] == "track.getTopTags":
                return httpx.Response(200, json={"toptags": {"tag": [{"name": "study"}, {"name": "chillout"}, {"name": "pop"}]}})
            return httpx.Response(200, json={"tracks": {"track": [{"name": "Fixture Session", "artist": "Fixture Artist"}]}})
        service = RecommendationService(Settings(lastfm_key="fixture", data_directory=Path(self.directory)/"choices"),
                                        client=httpx.AsyncClient(transport=httpx.MockTransport(handle)))
        self.addAsyncCleanup(service.close)
        service.http.interval = 0
        with patch("selection.get_matcher", return_value=None):
            for prompt in ("Focus", "Unwind", "Surprise me"):
                self.assertTrue((await service.recommend(prompt, IntentResult())).tracks, prompt)

    async def test_live_setup_and_malformed_provider_are_actionable(self):
        client = httpx.AsyncClient(transport=httpx.MockTransport(lambda request: httpx.Response(200, json={"tracks": None})))
        service = RecommendationService(Settings(lastfm_key="", data_directory=Path(self.directory)/"setup"), client=client)
        self.addAsyncCleanup(service.close)
        self.assertIn("LASTFM_API_KEY", (await service.recommend("jazz", IntentResult())).message)
        self.reply({"tracks": None})
        with self.assertRaises(ProviderError): await self.lastfm.top_tracks("jazz")


class LiveRankingChecks(unittest.TestCase):
    def test_missing_features_and_dislike_cannot_be_overridden(self):
        tracks = [track(), track("Known Piano", bpm=90, vocals=False, energy="low")]
        taste = {"tracks": {tracks[1].id: -1}, "artists": {}, "recent": []}
        for intent in [IntentResult(vocals=False), IntentResult(energy="low", energy_locked=True), IntentResult(bpm_min=80, bpm_max=100)]:
            self.assertEqual(SongSelector(tracks).select("piano", intent, use_semantic=False, taste=taste).tracks, [])

    def test_personalization_is_bounded_and_repeated_like_is_not_amplified(self):
        a, b = track("A Piano"), track("B Piano", artist="Other Artist")
        taste = {"tracks": {b.id: 1}, "artists": {}, "recent": []}
        selector = SongSelector([a, b])
        baseline = selector.select("piano", IntentResult(), use_semantic=False)
        personal = selector.select("piano", IntentResult(), use_semantic=False, taste=taste)
        self.assertEqual(personal.tracks[0].id, b.id)
        taste["recent"] = [b.id] * 100
        replay = selector.select("piano", IntentResult(), use_semantic=False, taste=taste)
        self.assertAlmostEqual(next(t.score for t in personal.tracks if t.id == b.id) - next(t.score for t in replay.tracks if t.id == b.id), 0.15)


class DiscoveryAPIChecks(unittest.TestCase):
    def setUp(self):
        directory = self.enterContext(tempfile.TemporaryDirectory())
        self.enterContext(patch("main.Settings.from_environment", return_value=Settings(lastfm_key="", data_directory=Path(directory))))
        self.enterContext(patch("main.interpret_request", side_effect=lambda prompt: interpret_request(prompt, use_semantic=False)))
        self.client = self.enterContext(TestClient(app))

    def test_live_missing_key_is_not_a_fictional_fallback(self):
        result = self.client.post("/listening-request", json={"prompt": "piano"}).json()
        self.assertEqual(result["selection"]["catalog_kind"], "lastfm_live")
        self.assertEqual(result["selection"]["tracks"], [])
        self.assertIn("LASTFM_API_KEY", result["selection"]["message"])

    def test_feedback_requires_context_is_idempotent_and_can_be_erased(self):
        request_id = str(uuid.uuid4())
        self.client.app.state.recommendations.taste.save_request(request_id, "piano", [track()])
        body = {"event_id": str(uuid.uuid4()), "request_id": request_id, "track_id": track().id, "event": "like"}
        self.assertEqual(self.client.post("/feedback", json=body).status_code, 200)
        self.assertEqual(self.client.post("/feedback", json=body).status_code, 200)
        self.assertEqual(self.client.post("/feedback", json={**body, "event": "dislike"}).status_code, 422)
        self.assertEqual(self.client.post("/feedback", json={**body, "event_id": str(uuid.uuid4()), "track_id": "unknown"}).status_code, 422)
        self.assertEqual(self.client.post("/feedback", json={**body, "spotify_payload": {}}).status_code, 422)
        self.assertEqual(self.client.post("/feedback", json={**body, "event": "skip"}).status_code, 422)
        self.assertEqual(self.client.delete("/taste").json(), {"status": "ok"})
        self.assertEqual(self.client.app.state.recommendations.taste.snapshot()["tracks"], {})


if __name__ == "__main__": unittest.main()
