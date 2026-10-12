#!/usr/bin/env python3
"""Read-only live API smoke check, using a disposable taste profile and cache."""

import argparse
import json
import sys
import tempfile
import time
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from fastapi.testclient import TestClient
from main import app
from settings import Settings


def run(prompt, output):
    settings = Settings.from_environment()
    if not settings.lastfm_key:
        raise SystemExit("Configure LASTFM_API_KEY in backend/.env first.")
    with tempfile.TemporaryDirectory(prefix="mochi-similar-probe-") as directory:
        settings = replace(settings, mode="live", data_directory=Path(directory), reccobeats_enabled=False)
        with patch.object(Settings, "from_environment", return_value=settings), TestClient(app) as client:
            started = time.monotonic()
            initial = client.post("/listening-request", json={"prompt": prompt})
            initial_ms = round((time.monotonic() - started) * 1000)
            assert initial.status_code == 200, "Initial listening request failed."
            original = initial.json()["selection"]
            assert original["tracks"], "No initial songs: try a different genre or instrument."
            seed = original["tracks"][0]
            started = time.monotonic()
            response = client.post("/more-like-this", json={"request_id": original["request_id"],
                "track_id": seed["id"], "title": seed["title"], "artist": seed["artist"]})
            similar_ms = round((time.monotonic() - started) * 1000)
            assert response.status_code == 200, "Similar-song request failed."
            result = response.json()
            selection = result["selection"]
            previous = {track["id"] for track in original["tracks"]}
            assert result["received_prompt"] == prompt, "Original request was changed."
            assert selection["catalog_kind"] == "lastfm_live", "Unexpected catalog."
            assert selection["tracks"], "No similar songs met the request: try another seed."
            assert previous.isdisjoint(track["id"] for track in selection["tracks"]), "Previous batch repeated."
            assert len(selection["tracks"]) <= 5, "Response exceeded the native card limit."
            report = {"checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "live": True,
                "prompt": prompt, "seed": {"title": seed["title"], "artist": seed["artist"]},
                "initial_count": len(original["tracks"]), "initial_elapsed_ms": initial_ms,
                "similar_count": len(selection["tracks"]), "similar_elapsed_ms": similar_ms,
                "method": selection["method"], "warnings": selection.get("warnings", []),
                "previous_batch_excluded": True, "original_prompt_preserved": True,
                "tracks": [{key: track[key] for key in ("title", "artist", "bpm", "vocals", "energy")}
                           for track in selection["tracks"]],
                "note": "Live acquisition/API smoke check; not a ranking-quality or Spotify-playback evaluation."}
    encoded = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    if output:
        # Replace one small report; do not accumulate an unbounded provider export.
        assert len(encoded.encode()) < 16_384, "Smoke report exceeded its bound."
        Path(output).write_text(encoded)
    print(encoded, end="")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prompt", default="jazz piano")
    parser.add_argument("--output")
    args = parser.parse_args()
    run(args.prompt, args.output)
