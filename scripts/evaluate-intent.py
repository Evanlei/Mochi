"""Compare the frozen original parser, improved rules and local semantic matching."""

import argparse
import hashlib
import json
import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
from intent import interpret_request
from semantic import EnergyMatcher, MODEL_NAME, MODEL_REVISION


def original_parser(prompt):
    text = prompt.lower()
    vocals = False if "no vocals" in text else True if "with vocals" in text else None
    energy = "low" if "relaxing" in text else "high" if "energetic" in text else None
    return {"vocals": vocals, "energy": energy}


def evaluate(parser, cases):
    exact, fields, mistakes, latencies = 0, {"vocals": 0, "energy": 0}, [], []
    for case in cases:
        before = time.perf_counter()
        result = parser(case["prompt"])
        latencies.append((time.perf_counter() - before) * 1000)
        expected = {key: case[key] for key in fields}
        if result == expected:
            exact += 1
        else:
            mistakes.append({"category": case["category"], "prompt": case["prompt"],
                             "expected": expected, "actual": result})
        for key in fields:
            fields[key] += result[key] == expected[key]
    return {"requests": len(cases), "exact_matches": exact,
            "exact_accuracy": exact / len(cases),
            "field_accuracy": {key: count / len(cases) for key, count in fields.items()},
            "median_ms": statistics.median(latencies), "mistakes": mistakes}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--split", choices=["development", "test", "all"], default="test")
    parser.add_argument("--semantic", action="store_true")
    parser.add_argument("--check", action="store_true", help="Require improvement over rules and at least 85 percent exact agreement")
    parser.add_argument("--minimum-similarity", type=float, default=0.65)
    parser.add_argument("--minimum-margin", type=float, default=0.02)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    fixture = ROOT / "Tests/fixtures/intent-evaluation.json"
    cases = json.loads(fixture.read_text())["cases"]
    selected = [case for case in cases if args.split == "all" or case["split"] == args.split]
    engines = {"original": original_parser,
               "rules": lambda prompt: interpret_request(prompt, use_semantic=False).values()}
    report = {"split": args.split, "fixture_sha256": hashlib.sha256(fixture.read_bytes()).hexdigest()}
    if args.semantic:
        before = time.perf_counter()
        matcher = EnergyMatcher(minimum_similarity=args.minimum_similarity, minimum_margin=args.minimum_margin)
        report["model"] = {"name": MODEL_NAME, "revision": MODEL_REVISION,
                           "minimum_similarity": args.minimum_similarity, "minimum_margin": args.minimum_margin,
                           "load_seconds": time.perf_counter() - before}
        engines["hybrid"] = lambda prompt: interpret_request(prompt, matcher=matcher).values()
    report["engines"] = {name: evaluate(engine, selected) for name, engine in engines.items()}
    for name, result in report["engines"].items():
        print(f"{name}: {result['exact_matches']}/{result['requests']} exact; median {result['median_ms']:.2f} ms")
        for mistake in result["mistakes"]:
            print(f"  {mistake['prompt']!r}: {mistake['actual']} (expected {mistake['expected']})")
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    if args.check:
        if "hybrid" not in report["engines"]:
            parser.error("--check requires --semantic")
        hybrid, rules = report["engines"]["hybrid"], report["engines"]["rules"]
        if hybrid["exact_matches"] <= rules["exact_matches"] or hybrid["exact_accuracy"] < 0.85:
            raise SystemExit("Intent evaluation did not meet the recorded quality gate")


if __name__ == "__main__":
    main()
