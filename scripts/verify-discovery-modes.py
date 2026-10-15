#!/usr/bin/env python3
"""Live mode/source checks with disposable storage; no saved taste or playback changes."""

import argparse
import json
import sys
import tempfile
import time
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from fastapi.testclient import TestClient
from main import app, ListeningRequest
from music import DiscoveryMode, normalized
from settings import Settings


def run(artists, output):
    profile = ListeningRequest(prompt="Surprise me", favorite_artists=artists)
    if not profile.favorite_artists:
        raise SystemExit("Choose one to three favorite artists.")
    settings = Settings.from_environment()
    if not settings.lastfm_key:
        raise SystemExit("Configure LASTFM_API_KEY in backend/.env first.")
    cases, familiar = [], None
    keys = {normalized(name) for name in profile.favorite_artists}
    with tempfile.TemporaryDirectory(prefix="mochi-modes-probe-") as directory:
        settings = replace(settings, mode="live", data_directory=Path(directory), reccobeats_enabled=False)
        with patch.object(Settings, "from_environment", return_value=settings), TestClient(app) as client:
            service = app.state.recommendations
            original_tags = service.lastfm.tags
            for mode in DiscoveryMode:
                checked = []
                async def tags(row):
                    checked.append(row.id)
                    return await original_tags(row)
                started = time.monotonic()
                with patch.object(service.lastfm, "tags", side_effect=tags):
                    response = client.post("/listening-request", json={"prompt": profile.prompt,
                        "favorite_artists": profile.favorite_artists, "discovery_mode": mode.value})
                assert response.status_code == 200, "Mode discovery failed."
                selection = response.json()["selection"]
                rows = selection["tracks"]
                assert selection["discovery_mode"] == mode.value, "Requested mode was not applied."
                assert 0 < len(rows) <= 5 and len({row["id"] for row in rows}) == len(rows), "No valid live results."
                assert len(checked) <= 12 and len(set(checked)) == len(checked), "Lookup budget failed."
                favorite_count = sum(normalized(row["artist"]) in keys for row in rows)
                cases.append({"mode": mode.value, "elapsed_ms": round((time.monotonic() - started) * 1000),
                    "returned_tracks": len(rows), "favorite_artist_tracks": favorite_count,
                    "outside_favorite_artists": len(rows) - favorite_count,
                    "tag_lookup_count": len(checked), "warnings": selection["warnings"]})
                if mode == DiscoveryMode.FAMILIAR:
                    familiar = selection
            strict = client.post("/listening-request", json={"prompt": "80-100 BPM",
                "favorite_artists": profile.favorite_artists, "discovery_mode": "discover"})
            assert strict.status_code == 200 and not strict.json()["selection"]["tracks"], "Unknown BPM qualified."
            seed = familiar["tracks"][0]
            similar = client.post("/more-like-this", json={"request_id": familiar["request_id"],
                "track_id": seed["id"], "title": seed["title"], "artist": seed["artist"]})
            assert similar.status_code == 200 and similar.json()["selection"]["discovery_mode"] == "familiar", "Original mode was lost."
    checked_at = datetime.now(timezone.utc)
    report = {"checked_at": checked_at.isoformat(),
        "checked_local_at": checked_at.astimezone(ZoneInfo("America/New_York")).isoformat(),
        "live": True, "probe_artists": profile.favorite_artists, "cases": cases,
        "unknown_bpm_rejected": True, "similar_restored_original_mode": True,
        "note": "Source/contract probe with disposable storage. Mix counts are observations, not guaranteed quotas or relevance grades. Outside favorites does not mean unheard. Spotify playback and personal preferences were unchanged."}
    encoded = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    assert len(encoded.encode()) < 16_384, "Probe report exceeded its bound."
    if output: Path(output).write_text(encoded)
    print(encoded, end="")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artist", action="append", required=True, help="One to three manually chosen artists")
    parser.add_argument("--output")
    arguments = parser.parse_args()
    run(arguments.artist, arguments.output)
