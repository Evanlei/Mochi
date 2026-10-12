#!/usr/bin/env python3
"""Read-only source/API probe with disposable storage; no personal taste changes."""

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
from music import normalized
from settings import Settings


def run(artists, output):
    settings = Settings.from_environment()
    if not settings.lastfm_key:
        raise SystemExit("Configure LASTFM_API_KEY in backend/.env first.")
    with tempfile.TemporaryDirectory(prefix="mochi-artist-probe-") as directory:
        settings = replace(settings, mode="live", data_directory=Path(directory), reccobeats_enabled=False)
        with patch.object(Settings, "from_environment", return_value=settings), TestClient(app) as client:
            started = time.monotonic()
            search = client.post("/artist-search", json={"query": artists[0]})
            assert search.status_code == 200, "Artist autocomplete failed."
            names = search.json()["artists"]
            assert any(normalized(name) == normalized(artists[0]) for name in names), "Exact artist not found."
            search_ms = round((time.monotonic() - started) * 1000)
            started = time.monotonic()
            response = client.post("/listening-request", json={"prompt": "Surprise me", "favorite_artists": artists})
            assert response.status_code == 200, "Favorite-artist discovery failed."
            selection = response.json()["selection"]
            tracks = selection["tracks"]
            assert tracks and selection["catalog_kind"] == "lastfm_live", "No live artist-based songs."
            assert len(tracks) <= 5 and len({track["id"] for track in tracks}) == len(tracks), "Invalid result batch."
            favorite_count = sum(normalized(track["artist"]) in {normalized(name) for name in artists} for track in tracks)
            assert favorite_count, "No selected favorite artists appeared."
            discovery_ms = round((time.monotonic() - started) * 1000)
            strict = client.post("/listening-request", json={"prompt": "80-100 BPM", "favorite_artists": artists})
            assert strict.status_code == 200 and not strict.json()["selection"]["tracks"], "Unknown BPM qualified."
            report = {"checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "live": True, "probe_artists": artists, "autocomplete_count": len(names), "exact_artist_found": True,
                "autocomplete_elapsed_ms": search_ms, "discovery_elapsed_ms": discovery_ms,
                "returned_tracks": len(tracks), "favorite_artist_tracks": favorite_count,
                "ranking_method": selection["method"], "unknown_bpm_rejected": True,
                "warnings": selection.get("warnings", []),
                "note": "Source/API smoke check only; recommendation relevance and real Spotify playback need user judgment."}
    encoded = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    assert len(encoded.encode()) < 16_384, "Probe report exceeded its bound."
    if output: Path(output).write_text(encoded)
    print(encoded, end="")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artist", action="append", required=True, help="One to three independent, manually chosen probe artists")
    parser.add_argument("--output")
    arguments = parser.parse_args()
    if not 1 <= len(arguments.artist) <= 3: parser.error("Choose one to three artists")
    run(arguments.artist, arguments.output)
