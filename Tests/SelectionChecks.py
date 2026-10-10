"""Selection behavior checks; optional real-model smoke cases use no network."""

import concurrent.futures
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from catalog import SampleCatalog, SampleTrack, load_catalog
from intent import IntentResult, interpret_request
from selection import SongSelector

SEMANTIC = "--semantic" in sys.argv
if SEMANTIC:
    sys.argv.remove("--semantic")


def track(identifier, description, *, vocals=False, energy="low", bpm=90):
    return SampleTrack(id=f"sample-{identifier}", title=identifier, artist="Example",
                       description=description, vocals=vocals, energy=energy, bpm=bpm)


class CatalogChecks(unittest.TestCase):
    def test_catalog_provenance_and_metadata_are_validated(self):
        tracks = load_catalog()
        self.assertEqual(len(tracks), 16)
        catalog = json.loads((Path(__file__).parents[1] / "backend/data/sample-catalog.json").read_text())
        self.assertEqual(catalog["kind"], "fictional_sample")
        self.assertIn("not real recordings", catalog["provenance"])
        for changes in ({"bpm": 0}, {"energy": "medium"}, {"vocals": "false"}, {"description": " "}, {"id": "spotify-id"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                SampleTrack.model_validate({**tracks[0].model_dump(), **changes})
        catalog["tracks"].append(catalog["tracks"][0])
        with self.assertRaises(ValueError):
            SampleCatalog.model_validate_json(json.dumps(catalog))

    def test_numeric_tempo_and_ambiguous_tempo(self):
        for prompt, expected in (("90 BPM", (90, 90)), ("80–100 bpm", (80, 100)),
                                 ("between 80 and 100 beats per minute", (80, 100)),
                                 ("90.5 BPM", (90.5, 90.5)), ("90-110 BPM and 95-105 BPM", (95, 105)),
                                 ("relaxing instrumental music", (None, None))):
            with self.subTest(prompt=prompt):
                intent = interpret_request(prompt, use_semantic=False)
                self.assertEqual((intent.bpm_min, intent.bpm_max), expected)
                self.assertIsNone(intent.clarification)
        for prompt in ("0 BPM", "-90 BPM", "500 BPM", "110-80 BPM", "90 BPM and 120 BPM", "no 90 BPM",
                       "under 100 BPM", "roughly 90 BPM", "less than or equal to 100 BPM", "80-100-120 BPM", "some BPM"):
            with self.subTest(prompt=prompt):
                intent = interpret_request(prompt, use_semantic=False)
                self.assertIsNotNone(intent.clarification)
                self.assertIsNone(intent.bpm_min)


class SelectionChecks(unittest.TestCase):
    def test_original_request_preserves_instrument_details(self):
        selector = SongSelector(load_catalog())
        for prompt, expected in (("relaxing piano music, no vocals", "sample-quiet-window"),
                                 ("gentle acoustic guitar without lyrics", "sample-amber-strings")):
            result = selector.select(prompt, interpret_request(prompt, use_semantic=False), use_semantic=False)
            self.assertEqual(result.tracks[0].id, expected)
            self.assertTrue(all(not entry.vocals and entry.energy == "low" for entry in result.tracks))

    def test_hard_constraints_override_high_similarity_and_unknown_bpm(self):
        tracks = [track("wrong-vocals", "piano", vocals=True), track("wrong-energy", "piano", energy="high"),
                  track("unknown-bpm", "piano", bpm=None), track("wrong-bpm", "piano", bpm=120),
                  track("correct", "piano", bpm=90)]
        class Encoder:
            def embed_tracks(self, texts): return [[1, 0]] * 4 + [[0.8, 0.2]]
            def embed_query(self, text): return [1, 0]
        intent = interpret_request("calm piano without vocals, 80-100 BPM", use_semantic=False)
        result = SongSelector(tracks).select("piano", intent, encoder=Encoder())
        self.assertEqual([entry.id for entry in result.tracks], ["sample-correct"])

    def test_inferred_energy_is_soft_and_explicit_energy_is_hard(self):
        class Encoder:
            def embed_tracks(self, texts): return [[0.6, 0.8], [1, 0]]
            def embed_query(self, text): return [1, 0]
        selector = SongSelector([track("gentle", "quiet", energy="low"), track("relevant", "piano", energy="high")])
        soft = selector.select("piano", IntentResult(energy="low"), encoder=Encoder())
        self.assertEqual(soft.tracks[0].id, "sample-relevant")
        hard = selector.select("piano", IntentResult(energy="low", energy_locked=True), encoder=Encoder())
        self.assertEqual([entry.id for entry in hard.tracks], ["sample-gentle"])

    def test_clarification_empty_results_and_stable_top_five(self):
        selector = SongSelector([track(str(index), "piano") for index in range(8)])
        first = selector.select("piano", IntentResult(), use_semantic=False)
        second = selector.select("piano", IntentResult(), use_semantic=False)
        self.assertEqual(first, second)
        self.assertEqual(len(first.tracks), 5)
        self.assertEqual([entry.id for entry in first.tracks], [f"sample-{index}" for index in range(5)])
        for intent in (IntentResult(clarification="Which energy?"), IntentResult(bpm_min=200, bpm_max=200)):
            result = selector.select("piano", intent, use_semantic=False)
            self.assertEqual(result.tracks, [])
            self.assertIsNotNone(result.message)
        self.assertEqual(selector.select("unrelated aardvark", IntentResult(), use_semantic=False).tracks, [])
        self.assertEqual(SongSelector([]).select("piano", IntentResult(), use_semantic=False).tracks, [])

    def test_absent_broken_and_invalid_models_fall_back(self):
        selector = SongSelector([track("piano", "gentle piano"), track("guitar", "acoustic guitar")])
        class Broken:
            def embed_tracks(self, texts): raise RuntimeError("broken")
        class Invalid:
            def embed_tracks(self, texts): return [[float("nan"), 0]] * 2
        for encoder in (None, Broken(), Invalid()):
            with self.subTest(encoder=encoder), patch("selection.get_matcher", return_value=None):
                result = selector.select("piano", IntentResult(vocals=False), encoder=encoder)
                self.assertEqual(result.method, "lexical")
                self.assertEqual(result.tracks[0].id, "sample-piano")

    def test_catalog_embeddings_are_cached_across_concurrent_queries(self):
        class Encoder:
            catalog_calls = 0
            def embed_tracks(self, texts):
                self.catalog_calls += 1
                return [[1, 0], [0, 1]]
            def embed_query(self, text): return [1, 0] if text == "piano" else [0, 1]
        encoder = Encoder()
        selector = SongSelector([track("piano", "piano"), track("guitar", "guitar")])
        prompts = ["piano", "guitar"] * 5
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda prompt: selector.select(prompt, IntentResult(), encoder=encoder), prompts))
        self.assertEqual(encoder.catalog_calls, 1)
        self.assertEqual([result.tracks[0].id for result in results], [f"sample-{prompt}" for prompt in prompts])

    def test_weak_semantic_match_returns_empty_instead_of_filling_results(self):
        class Encoder:
            def embed_tracks(self, texts): return [[1, 0]]
            def embed_query(self, text): return [0, 1]
        result = SongSelector([track("piano", "piano")]).select("unrelated text", IntentResult(), encoder=Encoder())
        self.assertEqual(result.method, "semantic")
        self.assertEqual(result.tracks, [])
        self.assertIn("No close matches", result.message)


@unittest.skipUnless(SEMANTIC, "Use --semantic for the prepared local model")
class RealModelChecks(unittest.TestCase):
    def test_native_model_retrieves_sample_tracks_without_network(self):
        selector = SongSelector(load_catalog())
        # These authored smoke cases are acceptance checks, not held-out accuracy.
        cases = (("relaxing piano music, no vocals", "sample-quiet-window"),
                 ("gentle acoustic guitar without lyrics", "sample-amber-strings"),
                 ("mellow instrumental jazz", "sample-velvet-room"),
                 ("energetic electronic workout music without vocals", "sample-neon-run"))
        with patch("socket.socket.connect", side_effect=AssertionError("Unexpected network access")):
            for prompt, expected in cases:
                with self.subTest(prompt=prompt):
                    intent = interpret_request(prompt)
                    result = selector.select(prompt, intent)
                    self.assertEqual(result.method, "semantic")
                    self.assertEqual(result.tracks[0].id, expected)
                    self.assertTrue(all(not entry.vocals for entry in result.tracks))


if __name__ == "__main__":
    unittest.main(verbosity=2)
