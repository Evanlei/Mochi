# Request understanding

The first parser checked four literal phrases. It was useful for establishing the API connection, but missed synonyms, treated `not energetic` as high energy, and picked the first result when preferences conflicted.

The replacement combines explicit constraints with a small local text model. It still produces vocal and energy preferences; song retrieval and ranking remain the next stage.

## How it works

1. Normalize case, Unicode punctuation, and dashes.
2. Recognize explicit vocal preferences such as instrumental, wordless, singing, and lyrics. Match whole words, handle nearby negation, and leave conflicting or explicitly indifferent preferences unset.
3. Recognize explicit energy preferences such as calm, mellow, soothing, upbeat, and high energy. An exclusion such as `not energetic` does not imply its exact opposite: energy stays unspecified and the response asks for clarification. Contradictory positive preferences also produce a question.
4. For requests without an explicit energy constraint, remove vocal-specific wording and use a local embedding model. It converts the remaining sentence into numbers, then compares those numbers with reference descriptions of low, high, and unspecified energy.
5. Accept a model-derived preference only when the best category is low/high, similarity is at least 0.65, and its margin over the next category is at least 0.02. Similarity is a matching score, not a calibrated probability.
6. Return the confirmed text, intent, and optional clarification. The compact card displays labels such as **Low energy · Instrumental**, or a question for conflicts.

The model cannot override explicit constraints. Failure to load or run it leaves the deterministic rules available. The model initializes once per process; inference and tokenization are serialized within that instance. FastAPI's synchronous route runs in its worker pool so inference does not block its event loop.

## Model and setup

The semantic extra uses [FastEmbed](https://github.com/qdrant/fastembed) with the English [BGE small model](https://huggingface.co/BAAI/bge-small-en-v1.5). FastEmbed serves the quantized ONNX export on CPU without adding PyTorch. The model card identifies the MIT license; the ONNX export comes from [Qdrant's model repository](https://huggingface.co/Qdrant/bge-small-en-v1.5-onnx-Q).

The export is pinned to revision `aa8f8b060edb00e03bfdd08813a2949946c8ba55`. Preparation downloads model/tokenizer files and records their SHA-256 checksums. Serving verifies those files and loads them from the local directory. It does not download a model during a listening request. Model files are ignored by Git. No Spotify data is used for fitting, training, or reference examples, and no listening text is sent to a model service.

From the repository root, first-time setup:

```bash
cd backend
uv sync --extra semantic
uv run --extra semantic python ../scripts/prepare-intent-model.py
uv run --extra semantic fastapi dev main.py
```

The model is already prepared in this workspace. Future starts need only the last command. A missing semantic extra or model falls back to rules; restart the backend after preparing a previously missing model.

## Measured comparison

`Tests/fixtures/intent-evaluation.json` contains 48 hand-authored English requests: 24 development examples and 24 separate test examples. Reference descriptions and thresholds were selected using the development examples. The test split was then evaluated without changing thresholds to fix its misses.

Exact agreement requires both vocals and energy to match the expected values, including expected unknown values.

| Approach | Exact agreement on 24 test requests |
| --- | --- |
| Frozen original four-phrase parser | 6/24 (25%) |
| Improved explicit rules | 18/24 (75%) |
| Improved rules plus local semantic matching | 21/24 (87.5%) |

The [recorded report](intent-evaluation.json) includes per-field agreement, runtime measurements, model revision, fixture checksum, and every miss. Median hybrid parsing time on this machine was approximately 3 ms after initialization; this is parser time, not end-to-end app latency.

The three remaining test misses were abstentions on `fire me up`, `take it easy`, and `keep me alert` requests. Their expected energy preference was not selected. This small authored set establishes a reproducible baseline; 87.5% is not a claim about general language understanding or user satisfaction. Broader, independently labeled requests are needed for later evaluation.

## Checks

Fast deterministic checks, with no server or model needed:

```bash
bash scripts/test-backend.sh --python-only
```

Model evaluation plus Swift checks, after preparing the semantic extra:

```bash
bash scripts/test-backend.sh --semantic
```

The semantic check requires at least 85% exact agreement and improvement over rules on the fixed test set. To inspect the recorded comparison:

```bash
backend/.venv/bin/python scripts/evaluate-intent.py --split test --semantic
```

Unit checks cover negation, word boundaries, conflicts, indifference, model precedence, weak-score abstention, missing/broken model fallback, API validation, response documentation, Swift decoding, and displayed clarification. The native checks also exercise real requests in a signed sandboxed test app. Local model initialization and inference were additionally verified with outbound socket connections blocked.

## Current limits

This is an English-focused baseline with two coarse energy choices. Complex negation, quoted statements, implicit preferences, changing one's mind across messages, medium energy, and multilingual understanding need further work. Each API call analyzes that submitted text; it does not merge earlier requests or answers. When the card asks a question, submit a complete revised request. It does not generate songs or control playback from a mood request yet.
