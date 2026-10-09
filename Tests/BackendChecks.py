import sys
import unittest
from pathlib import Path

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from intent import parse_intent
from main import app


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
                self.assertEqual(parse_intent(prompt), {"vocals": vocals, "energy": energy})


class BackendChecks(unittest.TestCase):
    def setUp(self):
        # Requests stay inside the test process; no running server is needed.
        self.client = self.enterContext(TestClient(app))

    def test_health(self):
        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"status": "ok"})

    def test_trimmed_unicode_response(self):
        text = "夜の piano 🎵"
        response = self.client.post("/listening-request", json={"prompt": f"  {text}  "})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"received_prompt": text, "intent": {"vocals": None, "energy": None}})

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
                self.assertEqual(response.json(), {"received_prompt": prompt, "intent": {"vocals": vocals, "energy": energy}})

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
