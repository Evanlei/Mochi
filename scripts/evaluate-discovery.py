#!/usr/bin/env python3
"""Compare Mochi with acquisition order on explicitly judged candidate snapshots.

Default inputs are fictional development fixtures, never live quality evidence.
--capture obtains a bounded Last.fm snapshot with empty grades for human review.
"""

import argparse
import asyncio
import json
import math
import sys
import tempfile
from dataclasses import replace
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
from intent import IntentResult
from music import CatalogTrack
from recommendations import RecommendationService
from selection import SongSelector
from settings import Settings
from discovery import discovery_tags


def ndcg(order, grades, k=5):
    def dcg(ids):
        return sum((2 ** grades[identifier] - 1) / math.log2(index + 2) for index, identifier in enumerate(ids[:k]))
    ideal = dcg(sorted(grades, key=grades.get, reverse=True))
    return dcg(order) / ideal if ideal else 0


def evaluate(data, semantic=False):
    results = []
    for case in data["cases"]:
        tracks = [CatalogTrack.model_validate(row) for row in case["candidates"]]
        ids = [row.id for row in tracks]
        grades = case["grades"]
        if set(ids) != set(grades) or any(type(value) is not int or not 0 <= value <= 3 for value in grades.values()):
            raise ValueError("Every candidate needs a human relevance grade from 0 to 3")
        # This benchmark isolates unconstrained relevance, separately from BPM
        # filtering and Spotify entity-resolution tests. No taste boosts apply.
        prompt = case["prompt"]
        if data["source"].startswith("lastfm_live"):
            prompt += " " + " ".join(discovery_tags(prompt))
        ranked = SongSelector(tracks).select(prompt, IntentResult(), use_semantic=semantic)
        results.append({"prompt": case["prompt"], "method": ranked.method,
            "acquisition_ndcg_at_5": round(ndcg(ids, grades), 4),
            "mochi_ndcg_at_5": round(ndcg([row.id for row in ranked.tracks], grades), 4)})
    return {"source": data["source"], "note": data.get("note"), "cases": results,
        "mean_acquisition_ndcg_at_5": round(sum(row["acquisition_ndcg_at_5"] for row in results) / len(results), 4),
        "mean_mochi_ndcg_at_5": round(sum(row["mochi_ndcg_at_5"] for row in results) / len(results), 4)}


async def capture(prompts, output):
    settings = Settings.from_environment()
    if not settings.lastfm_key:
        raise ValueError("Configure LASTFM_API_KEY before capturing live rankings")
    directory = tempfile.TemporaryDirectory(prefix="mochi-discovery-evaluation-")
    service = RecommendationService(replace(settings, data_directory=Path(directory.name)))
    cases = []
    try:
        for prompt in prompts[:5]:
            service.selectors.clear()
            await service.recommend(prompt, IntentResult())
            if not service.selectors:
                raise ValueError("No live candidates available; check the source validation report")
            selector = next(reversed(service.selectors.values()))
            cases.append({"prompt": prompt, "candidates": [row.model_dump(mode="json") for row in selector.tracks],
                "grades": {row.id: None for row in selector.tracks}})
    finally:
        await service.close()
        directory.cleanup()
    payload = json.dumps({"source": "lastfm_live_manually_judged_snapshot", "note": "Fill every grade: 0 irrelevant, 1 weak, 2 useful, 3 strong. Review before scoring.", "cases": cases}, indent=2)
    if len(payload.encode()) > 2_000_000:
        raise ValueError("Evaluation snapshot exceeds its 2 MB budget")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(payload + "\n")
    print(f"Saved ungraded live candidates to {output}. This is not an evaluation result yet.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=ROOT / "Tests/fixtures/discovery-evaluation.json")
    parser.add_argument("--semantic", action="store_true")
    parser.add_argument("--capture", action="store_true")
    parser.add_argument("--output", type=Path, help="Write a metrics report (capture always uses backend/.data/discovery-evaluation.json)")
    args = parser.parse_args()
    try:
        data = json.loads(args.input.read_text())
        if args.capture:
            asyncio.run(capture([row["prompt"] for row in data["cases"]], ROOT / "backend/.data/discovery-evaluation.json"))
        else:
            report = json.dumps(evaluate(data, args.semantic), indent=2)
            if args.output: args.output.write_text(report + "\n")
            print(report)
    except (ValueError, KeyError, OSError) as error:
        print(str(error), file=sys.stderr); sys.exit(1)
