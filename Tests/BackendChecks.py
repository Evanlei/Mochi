import sys
from pathlib import Path

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from main import app

with TestClient(app) as client:
    assert client.get("/health").json() == {"status": "ok"}
    text = "夜の piano 🎵"
    response = client.post("/listening-request", json={"prompt": f"  {text}  "})
    assert response.status_code == 200
    assert response.json() == {"received_prompt": text, "intent": {"vocals": None}}
    for prompt, vocals in (("relaxing music, no vocals", False),
                          ("pop music with vocals", True),
                          ("relaxing music", None), ("NO VOCALS", False)):
        response = client.post("/listening-request", json={"prompt": prompt})
        assert response.status_code == 200
        assert response.json() == {"received_prompt": prompt, "intent": {"vocals": vocals}}
    for body in ({}, {"prompt": None}, {"prompt": 42}, {"prompt": ""},
                 {"prompt": " \t\n "}, {"prompt": "x" * 501}):
        assert client.post("/listening-request", json=body).status_code == 422
    assert client.post("/listening-request", json={"prompt": "x" * 500}).status_code == 200
    assert client.post("/listening-request", content="not json", headers={"Content-Type": "application/json"}).status_code == 422
    schema = client.get("/openapi.json").json()
    assert "ListeningResponse" in schema["components"]["schemas"]
print("PASS: Python health, response contract, vocals rules, trimming, Unicode, limits, and invalid requests")
