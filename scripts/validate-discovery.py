#!/usr/bin/env python3
"""Live, credential-safe source probe. Failures are report rows, never fabricated data."""

import argparse
import asyncio
import json
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import httpx
from music import CatalogTrack, identity_key
from providers import LastFM, ProviderHTTP, ProviderError, ReccoBeats
from settings import Settings
from storage import ProviderCache

CASES = (("mainstream", "Blinding Lights", "The Weeknd"),
         ("recent", "Manchild", "Sabrina Carpenter"),
         ("instrumental", "River Flows in You", "Yiruma"))


async def run(output):
    settings, rows = Settings.from_environment(), []
    with tempfile.TemporaryDirectory(prefix="mochi-provider-probe-") as directory:
        cache = ProviderCache(Path(directory) / "cache.sqlite3")
        async with httpx.AsyncClient(headers={"Accept": "application/json", "User-Agent": "Mochi/0.1 (noncommercial source validation)"}) as client:
            http = ProviderHTTP(client, cache, interval=1)
            lastfm, recco = LastFM(http, settings.lastfm_key), ReccoBeats(http)
            for category, title, artist in CASES:
                track = CatalogTrack(id="lastfm-" + identity_key(title, artist), title=title, artist=artist,
                                     description="Authored provider validation input.")
                for provider in ("Last.fm", "ReccoBeats"):
                    start = time.monotonic()
                    row = {"provider": provider, "category": category, "title": title, "artist": artist}
                    try:
                        if provider == "Last.fm":
                            result = await lastfm.tags(track)
                            pool = await lastfm.top_tracks("piano" if category == "instrumental" else "pop", limit=5)
                            similar = await lastfm.similar(track, limit=5)
                            row.update(status="ok", tags=list(result.tags), missing_features=["bpm", "vocals", "energy"])
                            row.update(tag_candidates=len(pool), similar_candidates=len(similar))
                        else:
                            result = await recco.enrich(track)
                            row.update(status="matched" if result.bpm else "missing_or_ambiguous", bpm=result.bpm,
                                recording_id=result.feature_recording_id, missing_features=(["bpm"] if result.bpm is None else []) + ["vocals", "energy"])
                    except ProviderError as error:
                        row.update(status="blocked" if provider == "Last.fm" and not settings.lastfm_key else "failed", reason=str(error))
                    row["elapsed_ms"] = round((time.monotonic() - start) * 1000)
                    rows.append(row)
        cache.close()
    report = {"checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "live": True,
              "note": "Three smoke cases measure access and feature availability, not overall catalog coverage or tempo accuracy.", "results": rows}
    encoded = json.dumps(report, indent=2)
    if output:
        Path(output).write_text(encoded + "\n")
    print(encoded)
    return 0 if any(row["status"] in {"ok", "matched"} for row in rows) else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output")
    sys.exit(asyncio.run(run(parser.parse_args().output)))
