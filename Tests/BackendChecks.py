import sys
import unittest
from unittest.mock import patch
import json
from pathlib import Path

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from intent import interpret_request
from semantic import EnergyMatcher
from main import app
from selection import SongSelector
from catalog import load_catalog


class IntentChecks(unittest.TestCase):
    def test_vocals_energy_and_unspecified_preferences(self):
        cases = (
            ("music for studying", None, None),
            ("no vocals", False, None),
            ("music with vocals", True, None),
            ("relaxing music", None, "low"),
            ("energetic music", None, "high"),
            ("relaxing music, no vocals", False, "low"),
            ("energetic pop with vocals", True, "high"),
            ("RELAXING MUSIC, NO VOCALS", False, "low"),
            ("ENERGETIC MUSIC WITH VOCALS", True, "high"),
            ("夜の piano 🎵", None, None),
        )
        for prompt, vocals, energy in cases:
            with self.subTest(prompt=prompt):
                self.assertEqual(interpret_request(prompt, use_semantic=False).values(), {"vocals": vocals, "energy": energy})

    def test_word_boundaries_negation_and_conflicts(self):
        cases = (
            ("energetically is a word", None, None, False),
            ("a vocalist biography", None, None, False),
            ("not energetic", None, None, True),
            ("I don't want upbeat songs", None, None, True),
            ("not without vocals", True, None, False),
            ("no vocals and upbeat music", False, "high", False),
            ("nothing intense, just mellow", None, "low", False),
            ("calm and energetic", None, None, True),
            ("instrumental with singing", None, None, True),
            ("either vocals or instrumental is fine", None, None, False),
            ("any instrumental music", False, None, False),
            ("I don’t mind vocals", None, None, False),
        )
        for prompt, vocals, energy, clarify in cases:
            with self.subTest(prompt=prompt):
                result = interpret_request(prompt, use_semantic=False)
                self.assertEqual(result.values(), {"vocals": vocals, "energy": energy})
                self.assertEqual(result.clarification is not None, clarify)

    def test_held_out_explicit_constraints(self):
        fixture = Path(__file__).parent / "fixtures/intent-evaluation.json"
        for case in json.loads(fixture.read_text())["cases"]:
            if case["split"] != "test" or case["category"] == "semantic":
                continue
            with self.subTest(prompt=case["prompt"]):
                expected = {key: case[key] for key in ("vocals", "energy")}
                self.assertEqual(interpret_request(case["prompt"], use_semantic=False).values(), expected)


class SemanticChecks(unittest.TestCase):
    def test_explicit_constraints_override_model(self):
        class Matcher:
            calls = []
            def predict(self, prompt):
                self.calls.append(prompt)
                return "high"
        matcher = Matcher()
        result = interpret_request("calm music without vocals", matcher=matcher)
        self.assertEqual(result.values(), {"vocals": False, "energy": "low"})
        result = interpret_request("not energetic", matcher=matcher)
        self.assertIsNone(result.energy)
        self.assertIsNotNone(result.clarification)
        self.assertEqual(matcher.calls, [])
        result = interpret_request("give me a boost without lyrics", matcher=matcher)
        self.assertEqual(result.values(), {"vocals": False, "energy": "high"})
        self.assertNotIn("lyrics", matcher.calls[0])

    def test_missing_and_failed_model_preserve_constraints(self):
        with patch("semantic.get_matcher", return_value=None):
            self.assertEqual(interpret_request("songs without lyrics").values(), {"vocals": False, "energy": None})
        class BrokenMatcher:
            def predict(self, prompt):
                raise RuntimeError("model failure")
        result = interpret_request("help me unwind, no vocals", matcher=BrokenMatcher())
        self.assertEqual(result.values(), {"vocals": False, "energy": None})

    def test_uncertain_model_scores_abstain(self):
        matcher = EnergyMatcher.__new__(EnergyMatcher)
        matcher.minimum_similarity, matcher.minimum_margin = 0.65, 0.02
        for scores, expected in (({"low": 0.8, "high": 0.7, "unspecified": 0.6}, "low"),
                                 ({"low": 0.6, "high": 0.5, "unspecified": 0.4}, None),
                                 ({"low": 0.8, "high": 0.79, "unspecified": 0.6}, None),
                                 ({"low": 0.7, "high": 0.6, "unspecified": 0.8}, None)):
            with self.subTest(scores=scores):
                matcher.scores = lambda prompt: scores
                self.assertEqual(matcher.predict("test prompt"), expected)


class BackendChecks(unittest.TestCase):
    def setUp(self):
        # Requests stay inside the test process; no running server is needed.
        self.enterContext(patch("main.interpret_request", side_effect=lambda prompt: interpret_request(prompt, use_semantic=False)))
        selector = SongSelector(load_catalog())
        self.enterContext(patch("main.get_selector", return_value=selector))
        self.enterContext(patch("selection.get_matcher", return_value=None))
        self.client = self.enterContext(TestClient(app))

    def test_health(self):
        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"status": "ok"})

    def test_trimmed_unicode_response(self):
        text = "夜の piano 🎵"
        response = self.client.post("/listening-request", json={"prompt": f"  {text}  "})
        self.assertEqual(response.status_code, 200)
        result = response.json()
        self.assertEqual(result["received_prompt"], text)
        self.assertEqual(result["intent"], {"vocals": None, "energy": None, "bpm_min": None, "bpm_max": None})
        self.assertIsNone(result["clarification"])
        self.assertEqual(result["selection"]["catalog_kind"], "fictional_sample")

    def test_vocals_and_energy_in_api_response(self):
        for prompt, vocals, energy in (("relaxing music, no vocals", False, "low"),
                                      ("energetic pop with vocals", True, "high"),
                                      ("relaxing music", None, "low"),
                                      ("energetic music", None, "high"),
                                      ("NO VOCALS", False, None),
                                      ("ENERGETIC MUSIC WITH VOCALS", True, "high"),
                                      ("music for studying", None, None)):
            with self.subTest(prompt=prompt):
                response = self.client.post("/listening-request", json={"prompt": prompt})
                self.assertEqual(response.status_code, 200)
                result = response.json()
                self.assertEqual(result["received_prompt"], prompt)
                self.assertEqual(result["intent"], {"vocals": vocals, "energy": energy, "bpm_min": None, "bpm_max": None})
                self.assertIsNone(result["clarification"])
                for track in result["selection"]["tracks"]:
                    if vocals is not None:
                        self.assertEqual(track["vocals"], vocals)
                    if energy is not None:
                        self.assertEqual(track["energy"], energy)

    def test_conflicting_request_returns_clarification(self):
        response = self.client.post("/listening-request", json={"prompt": "instrumental with singing, calm and upbeat"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["intent"], {"vocals": None, "energy": None, "bpm_min": None, "bpm_max": None})
        self.assertIn("vocals or instrumental", response.json()["clarification"])
        self.assertIn("energy level", response.json()["clarification"])
        self.assertEqual(response.json()["selection"]["tracks"], [])

    def test_catalog_selection_and_bpm_in_response(self):
        result = self.client.post("/listening-request", json={"prompt": "calm piano without vocals, 80-100 BPM"}).json()
        self.assertEqual((result["intent"]["bpm_min"], result["intent"]["bpm_max"]), (80, 100))
        self.assertIn(result["selection"]["tracks"][0]["id"], {"sample-paper-lantern", "sample-moonlit-keys"})
        self.assertLessEqual(len(result["selection"]["tracks"]), 5)
        for track in result["selection"]["tracks"]:
            self.assertFalse(track["vocals"])
            self.assertEqual(track["energy"], "low")
            self.assertTrue(80 <= track["bpm"] <= 100)
        empty = self.client.post("/listening-request", json={"prompt": "no vocals 300 BPM"}).json()["selection"]
        self.assertEqual(empty["tracks"], [])
        self.assertIn("No sample tracks", empty["message"])

    def test_invalid_catalog_returns_actionable_server_error(self):
        with patch("main.get_selector", side_effect=ValueError("bad catalog")):
            response = self.client.post("/listening-request", json={"prompt": "piano"})
        self.assertEqual(response.status_code, 503)
        self.assertIn("Sample catalog unavailable", response.json()["detail"])

    def test_invalid_input_is_rejected(self):
        for body in ({}, {"prompt": None}, {"prompt": 42}, {"prompt": ""},
                     {"prompt": " \t\n "}, {"prompt": "x" * 501}):
            with self.subTest(body=body):
                response = self.client.post("/listening-request", json=body)
                self.assertEqual(response.status_code, 422)

    def test_maximum_length_is_accepted(self):
        response = self.client.post("/listening-request", json={"prompt": "x" * 500})
        self.assertEqual(response.status_code, 200)

    def test_malformed_json_is_rejected(self):
        response = self.client.post("/listening-request", content="not json",
                                    headers={"Content-Type": "application/json"})
        self.assertEqual(response.status_code, 422)

    def test_response_contract_is_documented(self):
        schema = self.client.get("/openapi.json").json()
        response = schema["paths"]["/listening-request"]["post"]["responses"]["200"]["content"]["application/json"]["schema"]
        self.assertEqual(response["$ref"], "#/components/schemas/ListeningResponse")
        intent = schema["components"]["schemas"]["ListeningIntent"]
        self.assertEqual(set(intent["required"]), {"vocals", "energy"})
        self.assertIn("selection", schema["components"]["schemas"]["ListeningResponse"]["required"])
        self.assertIn("tracks", schema["components"]["schemas"]["SongSelection"]["properties"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
