"""Deterministic adapter/storage checks: fictional fixtures, no external requests."""

import asyncio
import json
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import httpx
from discovery import discover, discovery_tags
from music import CatalogTrack, DiscoveryMode, identity_key, artist_key
from providers import LastFM, ProviderError, ProviderHTTP, ReccoBeats, cache_lifetime
from storage import ProviderCache, TasteStore
from recommendations import RecommendationService
from settings import Settings
from intent import interpret_request, IntentResult
from selection import SongSelector
from unittest.mock import AsyncMock, patch
from fastapi.testclient import TestClient
from main import app
from selection import SongSelection
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
        with self.assertRaises(LookupError): taste.recommendation_context("request")
        taste.clear(); self.assertEqual(taste.snapshot()["tracks"], {})

    def test_similar_context_survives_restart_without_provider_metadata(self):
        path = Path(self.directory) / "context.sqlite3"
        taste = TasteStore(path)
        taste.save_request("request", "gentle piano 80-100 BPM", [track()])
        taste.close()
        taste = TasteStore(path); self.addCleanup(taste.close)
        prompt, identifiers = taste.recommendation_context("request")
        self.assertEqual(prompt, "gentle piano 80-100 BPM")
        self.assertIn(track().id, identifiers)
        self.assertNotIn(track().title.encode(), path.read_bytes())
        taste.clear()
        with self.assertRaises(LookupError): taste.recommendation_context("request")

    def test_legacy_database_upgrade_preserves_feedback_and_defaults_to_balanced(self):
        import sqlite3
        path = Path(self.directory) / "legacy.sqlite3"
        candidate = track()
        with sqlite3.connect(path) as legacy:
            legacy.execute("CREATE TABLE requests (id TEXT PRIMARY KEY, prompt TEXT NOT NULL, tracks TEXT NOT NULL, created REAL NOT NULL)")
            legacy.execute("INSERT INTO requests VALUES (?,?,?,?)", ("old", "piano", json.dumps({candidate.id: artist_key(candidate.artist)}), self.now[0]))
        taste = TasteStore(path, clock=lambda: self.now[0])
        taste.feedback("like", "old", candidate.id, "like")
        self.assertEqual(taste.recommendation_options("old"), {"mode": DiscoveryMode.BALANCED, "favorite_artist_keys": ()})
        taste.save_request("new", "piano", [candidate], mode=DiscoveryMode.DISCOVER, favorite_artists=[artist_key(candidate.artist)])
        taste.close()
        taste = TasteStore(path, clock=lambda: self.now[0]); self.addCleanup(taste.close)
        self.assertEqual(taste.snapshot()["tracks"][candidate.id], 1)
        self.assertEqual(taste.recommendation_options("new"), {"mode": DiscoveryMode.DISCOVER, "favorite_artist_keys": (artist_key(candidate.artist),)})
        self.assertEqual(taste.recommendation_context("old")[0], "piano")
        self.assertNotIn(candidate.artist.encode(), path.read_bytes())
        self.now[0] += 31 * 86400
        with self.assertRaises(LookupError): taste.recommendation_options("new")


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

    async def test_artist_search_similarity_and_top_tracks(self):
        self.reply({"results": {"artistmatches": {"artist": [
            {"name": " Fixture Artist "}, {"name": "fixture artist"},
            {"name": None}, {"name": "bad\nname"}, {"name": "音楽"}]}}},
            headers={"Cache-Control": "max-age=100"})
        self.assertEqual(await self.lastfm.search_artists("Fixture"), ["Fixture Artist", "音楽"])
        self.assertEqual(await self.lastfm.search_artists("Fixture"), ["Fixture Artist", "音楽"])
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.requests[0].url.params["limit"], "5")
        self.reply({"similarartists": {"artist": [{"name": "Fixture Artist"}, {"name": "Related Artist"}]}})
        self.assertEqual(await self.lastfm.similar_artists("Fixture Artist"), ["Related Artist"])
        self.reply({"toptracks": {"track": [
            {"name": "Fixture Hit", "artist": {"name": "Fixture Artist"}},
            {"name": "Wrong", "artist": {"name": "Other Artist"}}]}})
        result = await self.lastfm.artist_tracks("Fixture Artist")
        self.assertEqual([row.title for row in result], ["Fixture Hit"])
        self.assertIsNone(result[0].bpm)
        self.assertIsNone(result[0].vocals)
        self.assertEqual(self.requests[-1].url.params["autocorrect"], "0")
        self.assertEqual(result[0].tags, ())
        self.reply({"results": {"artistmatches": []}})
        with self.assertRaises(ProviderError): await self.lastfm.search_artists("broken")

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

    async def test_favorite_artist_pools_are_balanced_bounded_and_not_fake_tags(self):
        provider = AsyncMock()
        provider.artist_tracks.side_effect = lambda name, **kw: [track(f"Hit {i}", name) for i in range(10)]
        provider.similar_artists.return_value = ["Related Artist", "Other Neighbor", "Fixture Artist"]
        provider.top_tracks.side_effect = lambda tag, **kw: [track(f"{tag} {i}", "Session Artist") for i in range(15)]
        result, warnings = await discover("piano jazz", provider, artists=["Fixture Artist", "Second Favorite", "Third Favorite"])
        self.assertEqual(warnings, [])
        self.assertEqual(len(result), 65)
        self.assertEqual(len(result), len({row.id for row in result}))
        self.assertEqual({row.artist for row in result[:7]},
            {"Fixture Artist", "Second Favorite", "Third Favorite", "Session Artist", "Related Artist", "Other Neighbor"})
        provider.similar_artists.assert_any_await("Fixture Artist", limit=3)
        # Partial failure does not replace favorites with invented recordings.
        provider.artist_tracks.side_effect = ProviderError("Artist unavailable")
        result, warnings = await discover("piano", provider, artists=["Fixture Artist"])
        self.assertTrue(result); self.assertTrue(warnings)

    async def test_modes_change_favorite_and_related_pools_within_the_same_cap(self):
        for mode, direct_limit, neighbors in [(DiscoveryMode.FAMILIAR, 20, 1),
                                               (DiscoveryMode.BALANCED, 10, 2),
                                               (DiscoveryMode.DISCOVER, 5, 3)]:
            with self.subTest(mode=mode):
                provider = AsyncMock()
                provider.artist_tracks.side_effect = lambda name, limit: [track(f"Hit {i}", name) for i in range(limit)]
                provider.similar_artists.return_value = ["Neighbor A", "Neighbor B", "Neighbor C"]
                provider.top_tracks.side_effect = lambda tag, limit: [track(f"{tag} {i}", "Session Artist") for i in range(limit)]
                rows, warnings = await discover("piano jazz", provider, artists=["Fixture Artist"], mode=mode)
                self.assertEqual(warnings, [])
                provider.artist_tracks.assert_any_await("Fixture Artist", limit=direct_limit)
                self.assertEqual(len({row.artist for row in rows if row.artist.startswith("Neighbor")}), neighbors)
                self.assertLessEqual(len(rows), 65)
                self.assertEqual(len({row.id for row in rows}), len(rows))
                self.assertTrue(all(row.bpm is None and row.vocals is None and row.energy is None for row in rows))
        # Explicit song neighborhoods retain their recording seed in every mode.
        provider = AsyncMock(); provider.similar.return_value = [track("Similar")]
        rows, _ = await discover("piano", provider, seed=track(), mode=DiscoveryMode.DISCOVER)
        provider.similar.assert_awaited_once_with(track(), limit=50)
        provider.artist_tracks.assert_not_awaited()

    async def test_artist_acquisition_timeout_keeps_finished_pools_and_cancellation_propagates(self):
        provider = AsyncMock()
        provider.artist_tracks.return_value = [track()]
        async def slow(*args, **kwargs):
            await asyncio.sleep(10)
        provider.top_tracks.side_effect = slow
        real_timeout = asyncio.timeout
        with patch("discovery.asyncio.timeout", side_effect=lambda seconds: real_timeout(0.02)):
            result, warnings = await discover("piano", provider, artists=["Fixture Artist"])
        self.assertEqual(result, [track()]); self.assertTrue(warnings)
        pending = asyncio.create_task(discover("piano", provider, artists=["Fixture Artist"]))
        await asyncio.sleep(0.01); pending.cancel()
        with self.assertRaises(asyncio.CancelledError): await pending

    async def test_live_artist_profile_surprise_and_strict_filters(self):
        seen = []
        async def handle(request):
            method = request.url.params["method"]; seen.append(method)
            if method == "artist.getTopTracks":
                value = {"toptracks": {"track": [{"name": "Favorite Hit", "artist": {"name": "Fixture Artist"}}]}}
            elif method == "artist.getSimilar":
                value = {"similarartists": {"artist": []}}
            elif method == "track.getTopTags":
                value = {"toptags": {"tag": [{"name": "piano"}]}}
            else: value = {"tracks": {"track": []}}
            return httpx.Response(200, json=value)
        service = RecommendationService(Settings(lastfm_key="fixture", data_directory=Path(self.directory)/"artists"),
            client=httpx.AsyncClient(transport=httpx.MockTransport(handle)))
        self.addAsyncCleanup(service.close); service.http.interval = 0
        with patch("selection.get_matcher", return_value=None):
            result = await service.recommend("Surprise me", IntentResult(), artists=["Fixture Artist"])
            self.assertEqual([row.title for row in result.tracks], ["Favorite Hit"])
            self.assertEqual(result.method, "none")
            self.assertIn("artist.getTopTracks", seen)
            self.assertNotIn("tag.getTopTracks", seen)
            service.taste.feedback(str(uuid.uuid4()), result.request_id, result.tracks[0].id, "dislike")
            excluded = await service.recommend("Surprise me", IntentResult(), artists=["Fixture Artist"])
            self.assertEqual(excluded.tracks, [])
            strict = await service.recommend("piano 80-100 BPM", IntentResult(bpm_min=80, bpm_max=100), artists=["Fixture Artist"])
            self.assertEqual(strict.tracks, [])
            unrelated = await service.recommend("metal", IntentResult(), artists=["Fixture Artist"])
            self.assertEqual(unrelated.tracks, [])

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

    async def test_explicit_seed_uses_similar_pool_and_excludes_previous_batch_and_dislikes(self):
        seed, previous, disliked = track(), track("Previous Piano"), track("Disliked Piano")
        seen = []
        async def handle(request):
            seen.append(dict(request.url.params))
            if request.url.params["method"] == "track.getTopTags":
                return httpx.Response(200, json={"toptags": {"tag": [{"name": "piano"}]}})
            rows = [{"name": title, "artist": "Fixture Artist"} for title in
                (seed.title, previous.title, "New Piano", "New Piano", disliked.title)]
            return httpx.Response(200, json={"similartracks": {"track": rows}})
        service = RecommendationService(Settings(lastfm_key="fixture", data_directory=Path(self.directory)/"similar"),
            client=httpx.AsyncClient(transport=httpx.MockTransport(handle)))
        self.addAsyncCleanup(service.close); service.http.interval = 0
        request_id = str(uuid.uuid4())
        service.taste.save_request(request_id, "piano", [seed, previous, disliked])
        service.taste.feedback(str(uuid.uuid4()), request_id, disliked.id, "dislike")
        prompt, verified, excluded = service.similar_context(request_id, seed.id, seed.title, seed.artist)
        self.assertEqual(service.cache.connection.execute("SELECT COUNT(*) FROM responses").fetchone()[0], 0)
        with self.assertRaises(ValueError): service.similar_context(request_id, seed.id, "Spoofed Piano", seed.artist)
        with patch("selection.get_matcher", return_value=None):
            result = await service.recommend(prompt, IntentResult(), seed=verified, exclude=excluded)
            self.assertEqual([row.title for row in result.tracks], ["New Piano"])
            self.assertNotEqual(result.request_id, request_id)
            self.assertEqual(seen[0]["method"], "track.getSimilar")
            self.assertEqual(seen[0]["track"], seed.title)
            self.assertEqual(seen[0]["limit"], "50")
            self.assertNotIn("tag.getTopTracks", [row["method"] for row in seen])
            strict = await service.recommend(prompt, IntentResult(bpm_min=80, bpm_max=100), seed=verified, exclude=excluded)
            self.assertEqual(strict.tracks, [])

    async def test_similar_failures_do_not_fall_back_to_unrelated_songs(self):
        self.replies.append(httpx.Response(503))
        candidates, warnings = await discover("piano", self.lastfm, seed=track())
        self.assertEqual(candidates, [])
        self.assertTrue(warnings)
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.requests[0].url.params["method"], "track.getSimilar")

    async def test_cancelled_similar_request_releases_service_lock(self):
        async def slow(request):
            await asyncio.sleep(10)
            return httpx.Response(200, json={})
        service = RecommendationService(Settings(lastfm_key="fixture", data_directory=Path(self.directory)/"cancel-similar"),
            client=httpx.AsyncClient(transport=httpx.MockTransport(slow)))
        self.addAsyncCleanup(service.close)
        task = asyncio.create_task(service.recommend("piano", IntentResult(), seed=track()))
        await asyncio.sleep(0.01); task.cancel()
        with self.assertRaises(asyncio.CancelledError): await task
        self.assertFalse(service.request_lock.locked())


class LookupRankingChecks(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        directory = self.enterContext(tempfile.TemporaryDirectory())
        def unexpected(request):
            raise AssertionError("Unexpected external provider request")
        self.service = RecommendationService(Settings(lastfm_key="fixture", data_directory=Path(directory)),
            client=httpx.AsyncClient(transport=httpx.MockTransport(unexpected)))
        self.addAsyncCleanup(self.service.close)
        self.enterContext(patch("selection.get_matcher", return_value=None))
        self.rows = [track(f"Candidate {index}").model_copy(update={
            "description": "Popular tracks on Last.fm.", "tags": ()}) for index in range(24)]
        self.discovery = self.enterContext(patch("recommendations.discover", new_callable=AsyncMock,
            return_value=(self.rows, [])))
        self.service.lastfm.tags = AsyncMock(side_effect=lambda row: row)

    def looked_up(self):
        return [call.args[0].id for call in self.service.lastfm.tags.await_args_list]

    async def test_late_promising_tracks_get_tags_and_changed_text_is_reranked(self):
        for index in (20, 21):
            self.rows[index] = self.rows[index].model_copy(update={"description": "Community tags: piano", "tags": ("piano",)})
        class Encoder:
            catalog_calls = 0
            def embed_tracks(self, texts):
                self.catalog_calls += 1
                return [[1, 0] if "piano" in text else [0, 1] for text in texts]
            def embed_query(self, text): return [1, 0]
        encoder = Encoder()
        self.service.lastfm.tags.side_effect = lambda row: row.model_copy(update={
            "description": "Community tags: " + ("piano" if row.id == self.rows[21].id else "metal"),
            "tags": ("piano",) if row.id == self.rows[21].id else ("metal",)})
        with patch("selection.get_matcher", return_value=encoder):
            result = await self.service.recommend("piano", IntentResult())
            self.assertEqual(set(self.looked_up()[:2]), {self.rows[20].id, self.rows[21].id})
            self.assertEqual(len(self.looked_up()), 12)
            self.assertEqual(len(set(self.looked_up())), 12)
            self.assertEqual([row.id for row in result.tracks], [self.rows[21].id])
            self.assertEqual(result.method, "semantic")
            self.assertEqual(encoder.catalog_calls, 2, "Changed tags reused stale embeddings")
            _, saved = self.service.taste.recommendation_context(result.request_id)
            self.assertEqual(set(saved), {self.rows[21].id}, "Preliminary results entered recommendation context")
            self.service.lastfm.tags.reset_mock()
            await self.service.recommend("piano", IntentResult())
            self.assertEqual(encoder.catalog_calls, 2, "Unchanged catalogs did not reuse embeddings")

    async def test_no_initial_matches_still_leaves_room_for_discovery(self):
        self.service.lastfm.tags.side_effect = lambda row: row.model_copy(update={
            "description": "Community tags: piano", "tags": ("piano",)})
        result = await self.service.recommend("piano", IntentResult())
        self.assertEqual(self.looked_up(), [row.id for row in self.rows[:12]])
        self.assertEqual(len(result.tracks), 5)
        self.assertEqual(result.method, "lexical")

    async def test_unknown_features_can_be_checked_but_never_satisfy_final_constraints(self):
        self.rows[20] = self.rows[20].model_copy(update={"description": "Community tags: piano", "tags": ("piano",)})
        for prompt, intent in [("piano 80-100 BPM", IntentResult(bpm_min=80, bpm_max=100)),
                               ("piano no vocals", IntentResult(vocals=False)),
                               ("piano high energy", IntentResult(energy="high", energy_locked=True))]:
            with self.subTest(prompt=prompt):
                self.service.lastfm.tags.reset_mock()
                result = await self.service.recommend(prompt, intent)
                self.assertEqual(self.looked_up()[0], self.rows[20].id)
                self.assertEqual(len(self.looked_up()), 12)
                self.assertEqual(result.tracks, [])
                self.assertIsNone(result.request_id)

    async def test_verified_tempo_after_lookup_can_qualify_a_late_candidate(self):
        self.rows[20] = self.rows[20].model_copy(update={"description": "Community tags: piano", "tags": ("piano",)})
        self.service.settings = replace(self.service.settings, reccobeats_enabled=True)
        self.service.recco.enrich = AsyncMock(side_effect=lambda row: row.model_copy(update={"bpm": 90.0})
            if row.id == self.rows[20].id else row)
        result = await self.service.recommend("piano 80-100 BPM", IntentResult(bpm_min=80, bpm_max=100))
        self.assertEqual(self.looked_up()[0], self.rows[20].id)
        self.assertEqual(self.service.recco.enrich.await_count, 12)
        self.assertEqual([row.id for row in result.tracks], [self.rows[20].id])
        self.assertEqual(result.tracks[0].bpm, 90)

    async def test_disliked_and_previous_tracks_do_not_consume_lookups(self):
        self.service.taste.save_request("old", "piano", [self.rows[20]])
        self.service.taste.feedback("dislike", "old", self.rows[20].id, "dislike")
        self.service.lastfm.tags.side_effect = lambda row: row.model_copy(update={"description": "piano"})
        result = await self.service.recommend("piano", IntentResult(), exclude=[self.rows[0].id])
        rejected = {self.rows[0].id, self.rows[20].id}
        self.assertFalse(rejected.intersection(self.looked_up()))
        self.assertFalse(rejected.intersection(row.id for row in result.tracks))
        self.assertEqual(len(self.looked_up()), 12)

    async def test_mode_is_returned_saved_and_needs_explicit_favorites(self):
        for mode in (DiscoveryMode.FAMILIAR, DiscoveryMode.DISCOVER):
            with self.subTest(mode=mode):
                missing = await self.service.recommend("piano", IntentResult(), mode=mode)
                self.assertEqual(missing.tracks, [])
                self.assertIn("favorite artist", missing.message)
                self.discovery.assert_not_awaited()
        for mode in DiscoveryMode:
            with self.subTest(mode=mode):
                result = await self.service.recommend("Surprise me", IntentResult(), artists=["Fixture Artist"], mode=mode)
                self.assertEqual(result.discovery_mode, mode)
                self.assertTrue(result.tracks)
                self.assertEqual(self.service.taste.recommendation_options(result.request_id), {
                    "mode": mode, "favorite_artist_keys": (artist_key("Fixture Artist"),)})
                strict = await self.service.recommend("piano 80-100 BPM", IntentResult(bpm_min=80, bpm_max=100),
                    artists=["Fixture Artist"], mode=mode)
                self.assertEqual(strict.tracks, [])
                self.assertEqual(strict.discovery_mode, mode)

    async def test_provider_errors_keep_candidates_and_warning_without_extra_lookups(self):
        self.rows[20] = self.rows[20].model_copy(update={"description": "Community tags: piano", "tags": ("piano",)})
        self.service.lastfm.tags.side_effect = ProviderError("Tags unavailable")
        result = await self.service.recommend("piano", IntentResult())
        self.assertEqual(self.looked_up()[0], self.rows[20].id)
        self.assertEqual(len(self.looked_up()), 12)
        self.assertEqual([row.id for row in result.tracks], [self.rows[20].id])
        self.assertEqual(result.warnings, ["Tags unavailable"])

    async def test_lookup_timeout_preserves_completed_metadata(self):
        async def enrich(row):
            if row.id != self.rows[0].id: await asyncio.sleep(10)
            return row.model_copy(update={"description": "Community tags: piano", "tags": ("piano",)})
        self.service.lastfm.tags.side_effect = enrich
        real_timeout = asyncio.timeout
        with patch("recommendations.asyncio.timeout", side_effect=lambda seconds: real_timeout(0.05)):
            result = await self.service.recommend("piano", IntentResult())
        self.assertEqual([row.id for row in result.tracks], [self.rows[0].id])
        self.assertEqual(result.tracks[0].tags, ("piano",))
        self.assertTrue(result.warnings)
        self.assertFalse(self.service.request_lock.locked())

    async def test_cancellation_during_lookup_does_not_save_a_preliminary_request(self):
        started = asyncio.Event()
        async def slow(row):
            started.set()
            await asyncio.sleep(10)
        self.service.lastfm.tags.side_effect = slow
        pending = asyncio.create_task(self.service.recommend("piano", IntentResult()))
        await asyncio.wait_for(started.wait(), 1)
        pending.cancel()
        with self.assertRaises(asyncio.CancelledError): await pending
        self.assertFalse(self.service.request_lock.locked())
        self.assertEqual(self.service.taste.connection.execute("SELECT COUNT(*) FROM requests").fetchone()[0], 0)
        self.service.lastfm.tags.side_effect = lambda row: row.model_copy(update={"description": "piano"})
        self.assertTrue((await self.service.recommend("piano", IntentResult())).tracks)


class LiveRankingChecks(unittest.TestCase):
    def test_modes_prefer_favorites_or_other_artists_after_relevance_and_strict_filters(self):
        favorite, neighbor = track("Favorite"), track("Neighbor", "Neighbor Artist")
        taste = {"tracks": {}, "artists": {}, "recent": [], "favorite_artists": {artist_key(favorite.artist)}}
        for mode in DiscoveryMode:
            with self.subTest(mode=mode):
                taste["discovery_mode"] = mode
                selected = SongSelector([neighbor, favorite]).select("piano", IntentResult(), use_semantic=False, taste=taste)
                self.assertEqual(selected.tracks[0].id, neighbor.id if mode == DiscoveryMode.DISCOVER else favorite.id)
                self.assertEqual(SongSelector([favorite, neighbor]).select("piano", IntentResult(bpm_min=80), use_semantic=False, taste=taste).tracks, [])
                taste["tracks"] = {favorite.id: -1}
                self.assertEqual([row.id for row in SongSelector([favorite, neighbor]).select("piano", IntentResult(), use_semantic=False, taste=taste).tracks], [neighbor.id])
                taste["tracks"] = {}
                irrelevant = favorite.model_copy(update={"description": "metal", "tags": ("metal",)})
                self.assertEqual([row.id for row in SongSelector([irrelevant, neighbor]).select("piano", IntentResult(), use_semantic=False, taste=taste).tracks], [neighbor.id])

    def test_broad_artist_request_uses_taste_and_preserves_popularity_order(self):
        top, second, neighbor = track("Most Popular"), track("Second Most Popular"), track("Neighbor", "Related Artist")
        taste = {"tracks": {}, "artists": {}, "recent": [], "favorite_artists": {artist_key(top.artist)}}
        selection = SongSelector([top, neighbor, second]).select("Surprise me", IntentResult(), taste=taste, allow_unmatched=True)
        self.assertEqual([row.id for row in selection.tracks], [top.id, second.id, neighbor.id])
        self.assertEqual(selection.method, "none")
        strict = SongSelector([top]).select("Surprise me", IntentResult(bpm_min=80), taste=taste, allow_unmatched=True)
        self.assertEqual(strict.tracks, [])

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

    def test_artist_search_and_explicit_profile_contract(self):
        service = self.client.app.state.recommendations
        self.assertEqual(self.client.post("/artist-search", json={"query": "Piano"}).status_code, 503)
        with patch.object(service.lastfm, "search_artists", new_callable=AsyncMock, return_value=["音楽", "Fixture Artist"]) as search:
            result = self.client.post("/artist-search", json={"query": "  音楽  "})
            self.assertEqual(result.json(), {"query": "音楽", "artists": ["音楽", "Fixture Artist"]})
            search.assert_awaited_once_with("音楽")
        for query in (" ", "x" * 101, "bad\nname", 123):
            self.assertEqual(self.client.post("/artist-search", json={"query": query}).status_code, 422)
        with patch.object(service, "recommend", new_callable=AsyncMock,
                          return_value=SongSelection(catalog_kind="lastfm_live", method="none", tracks=[])) as recommend:
            result = self.client.post("/listening-request", json={"prompt": "piano", "favorite_artists": [" 音楽 ", "Fixture Artist"]})
            self.assertEqual(result.status_code, 200)
            self.assertEqual(recommend.call_args.kwargs["artists"], ["音楽", "Fixture Artist"])
            for names in ([""], ["bad\nname"], ["same", "SAME"], [1], ["a", "b", "c", "d"]):
                self.assertEqual(self.client.post("/listening-request", json={"prompt": "piano", "favorite_artists": names}).status_code, 422)
            self.assertEqual(self.client.post("/listening-request", json={"prompt": "piano", "spotify_payload": {}}).status_code, 422)
            self.assertEqual(recommend.call_count, 1)

    def test_mode_validation_default_and_propagation(self):
        service = self.client.app.state.recommendations
        async def result(prompt, intent, **options):
            return SongSelection(catalog_kind="lastfm_live", method="none", tracks=[], discovery_mode=options["mode"])
        with patch.object(service, "recommend", new_callable=AsyncMock, side_effect=result) as recommend:
            for mode in DiscoveryMode:
                response = self.client.post("/listening-request", json={"prompt": "piano",
                    "favorite_artists": ["Fixture Artist"], "discovery_mode": mode.value})
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.json()["selection"]["discovery_mode"], mode.value)
                self.assertEqual(recommend.call_args.kwargs["mode"], mode)
            self.client.post("/listening-request", json={"prompt": "piano"})
            self.assertEqual(recommend.call_args.kwargs["mode"], DiscoveryMode.BALANCED)
            for invalid in ("unknown", "Familiar", "", None, 123, True):
                self.assertEqual(self.client.post("/listening-request", json={"prompt": "piano", "discovery_mode": invalid}).status_code, 422)
            self.assertEqual(recommend.call_count, 4)

    def test_similar_uses_original_mode_and_favorite_keys_instead_of_client_overrides(self):
        service = self.client.app.state.recommendations
        candidate, request_id = track(), str(uuid.uuid4())
        key = artist_key(candidate.artist)
        service.taste.save_request(request_id, "piano", [candidate], mode=DiscoveryMode.FAMILIAR, favorite_artists=[key])
        body = {"request_id": request_id, "track_id": candidate.id, "title": candidate.title, "artist": candidate.artist}
        with patch.object(service, "recommend", new_callable=AsyncMock,
            return_value=SongSelection(catalog_kind="lastfm_live", method="none", tracks=[], discovery_mode=DiscoveryMode.FAMILIAR)) as recommend:
            response = self.client.post("/more-like-this", json=body)
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json()["selection"]["discovery_mode"], "familiar")
            self.assertEqual(recommend.call_args.kwargs["mode"], DiscoveryMode.FAMILIAR)
            self.assertEqual(recommend.call_args.kwargs["favorite_artist_keys"], (key,))
            self.assertEqual(self.client.post("/more-like-this", json={**body, "discovery_mode": "discover"}).status_code, 422)
            self.assertEqual(recommend.call_count, 1)

    def test_fictional_mode_does_not_claim_to_apply_live_familiarity(self):
        self.client.app.state.settings = replace(self.client.app.state.settings, mode="sample")
        with patch("selection.get_matcher", return_value=None):
            response = self.client.post("/listening-request", json={"prompt": "piano", "discovery_mode": "familiar"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["selection"]["discovery_mode"], "balanced")
        self.assertIn("live recommendations", response.json()["selection"]["warnings"][0])

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

    def test_similar_route_recovers_original_constraints_and_validates_identity(self):
        service = self.client.app.state.recommendations
        candidate, request_id = track(), str(uuid.uuid4())
        prompt = "piano no vocals 80-100 BPM"
        service.taste.save_request(request_id, prompt, [candidate])
        body = {"request_id": request_id, "track_id": candidate.id, "title": candidate.title, "artist": candidate.artist}
        with patch.object(service, "recommend", new_callable=AsyncMock,
                          return_value=SongSelection(catalog_kind="lastfm_live", method="none", tracks=[])) as recommend:
            response = self.client.post("/more-like-this", json=body)
            self.assertEqual(response.status_code, 200)
            result = response.json()
            self.assertEqual(result["received_prompt"], prompt)
            self.assertEqual(result["intent"]["vocals"], False)
            self.assertEqual(result["intent"]["bpm_min"], 80)
            self.assertEqual(result["intent"]["bpm_max"], 100)
            self.assertEqual(recommend.call_args.kwargs["seed"].id, candidate.id)
            self.assertIn(candidate.id, recommend.call_args.kwargs["exclude"])
            for changes in ({"title": "Wrong title"}, {"artist": "Wrong artist"}, {"track_id": "sample-fixture"},
                            {"prompt": "drop requirements"}, {"spotify_payload": {}}, {"bpm": 90}):
                self.assertEqual(self.client.post("/more-like-this", json={**body, **changes}).status_code, 422)
            self.assertEqual(recommend.call_count, 1)
        self.client.delete("/taste")
        self.assertEqual(self.client.post("/more-like-this", json=body).status_code, 409)

    def test_similar_route_is_unavailable_in_fictional_mode(self):
        from dataclasses import replace
        self.client.app.state.settings = replace(self.client.app.state.settings, mode="sample")
        response = self.client.post("/more-like-this", json={"request_id": str(uuid.uuid4()),
            "track_id": track().id, "title": track().title, "artist": track().artist})
        self.assertEqual(response.status_code, 409)


if __name__ == "__main__": unittest.main()
