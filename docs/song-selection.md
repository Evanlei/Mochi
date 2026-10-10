# Sample song selection

This walkthrough describes the explicitly fictional development mode (`MOCHI_CATALOG_MODE=sample`). The default live path is documented in [music discovery](music-discovery.md).

Mochi now connects a listening request to a catalog: interpret preferences, filter requirements, compare the full sentence with descriptions, rank, and show up to five candidates in the native card.

This milestone uses 16 **fictional sample tracks**, authored in `backend/data/sample-catalog.json`. Titles, artists, descriptions, and BPM/energy/vocal metadata are illustrative development data. They are not real recordings, measured audio features, or Spotify metadata. The card labels them as fictional, provides no play button, and never sends their IDs to Spotify. The next dataset must be independently licensed and researched before replacement.

## Follow one request

For `relaxing piano music, no vocals`:

1. Swift sends the text to `POST /listening-request`.
2. `interpret_request()` produces `vocals=False` and explicit `energy="low"`. It also preserves that energy was explicitly requested internally.
3. `SongSelector` removes vocal and high-energy entries. Unspecified preferences do not filter anything.
4. The full sentence is compared with descriptions of eligible tracks. This preserves the piano detail, which the two coarse preference fields cannot represent.
5. Similarity orders the candidates. The real local model smoke check puts **Quiet Window**, a fictional gentle piano entry, first for this request.
6. The API returns the intent, optional clarification, and typed selection. Swift displays the list with title, artist, energy, vocals, and known BPM.

A clarification prevents selection until a complete revised request is submitted. Impossible requirements produce an empty list without widening the filters. Each request is independent; the session's earlier displayed text is not merged into the backend request.

## Catalog fields

| Field | Meaning |
| --- | --- |
| `id` | Stable `sample-…` identifier; unique within the catalog |
| `title`, `artist` | Identity of the fictional entry |
| `description` | Instruments, style, mood, and activity context |
| `vocals` | Whether the entry includes singing |
| `energy` | Low or high; separate from tempo |
| `bpm` | Beats per minute, or `null` when unspecified/no steady pulse |

Pydantic validates the schema and rejects malformed fields or duplicate IDs. The catalog is read once per process. Restart the backend after editing the JSON so the catalog and embeddings are rebuilt. Missing/invalid catalog data returns HTTP 503 with an actionable diagnostic; it does not serve silently corrupted entries.

## Requirements and preferences

**Hard requirements** remove entries before ranking: explicit vocals, explicitly stated positive energy, and supported numeric BPM bounds. For example, `no vocals 80–100 BPM` excludes tracks with singing, outside that range, or with unknown BPM.

**Soft preferences** affect order: an inferred energy preference adds `0.08` to the matching entry's similarity score. It does not remove other energies. This protects against an uncertain interpretation excluding a relevant track. Instrument and genre wording currently influences text similarity; it is not a separate hard constraint, so `piano only` or `no guitar` is not guaranteed. More structured constraints need future parser work.

The score is:

```text
text similarity + 0.08 if the track matches inferred energy
```

Explicit energy already filters tracks, so it does not receive the bonus. Scores are not probabilities or estimates of user satisfaction. Ties are broken by stable track ID. There is no learned ranking, listening-history personalization, or feedback storage yet.

## BPM behavior

Supported English forms include `90 BPM`, `90.5 BPM`, `80-100 BPM`, `80–100 BPM`, `80 to 100 BPM`, and `between 80 and 100 beats per minute`. Bounds are inclusive. A single value is exact, with no hidden tolerance. Multiple values/ranges are intersected; a contradictory intersection asks for clarification.

Values must be 20–400 for this prototype's metadata schema. Exclusions, approximate values, one-sided wording such as `under 100 BPM`, invalid ranges, and a BPM request without numbers ask for a value or range instead. Relaxing, fast, or energetic wording does not silently invent BPM bounds. A slow entry can still have high energy, demonstrated by the fictional **Rough Edges** at 90 BPM.

## Why this matching design

The semantic path reuses the same prepared local BGE model through FastEmbed. Query and passage embedding APIs are used for the request and catalog respectively. Normalized vectors are compared by dot product (cosine similarity). Corpus vectors are computed once per model/selector instance; request vectors are computed for each submission. Locks protect initialization and shared model inference. Initialization and inference remain local, with no serving-time download or prompt sent to a model service.

For a 16-entry catalog, scanning every vector is simpler than maintaining an index. Retrieval costs approximately O(N × D), where N is the entry count and D the vector dimension, plus sorting O(N log N). A larger real catalog will justify measuring FAISS or another index. [Sentence Transformers' semantic search guide](https://sbert.net/examples/sentence_transformer/applications/semantic-search/README.html) describes the query/corpus embedding approach; [FastEmbed's API](https://github.com/qdrant/fastembed/blob/main/fastembed/text/text_embedding.py) exposes query and passage embedding calls.

When local inference is unavailable or fails, the code uses a deterministic word-matching baseline: token sets weighted by how uncommon each word is in the catalog, compared with cosine similarity. That fallback lacks synonym understanding and complex negation. If an explicit requirement leaves eligible entries but the words offer no preference among them, it can still return eligible entries in stable order. Without any requirement or overlapping words, it returns no matches.

The semantic path uses a provisional similarity floor of 0.45. It is an engineering baseline, not a calibrated confidence threshold. General music wording can make unrelated descriptions look similar, and a tiny catalog often has no genuinely suitable track. This implementation demonstrates filtering/retrieval integration rather than production recommendation quality. Broader relevance labels and a comparison against the lexical baseline are needed before making accuracy claims or tuning a learned ranker.

## UI and failure behavior

The sage card remains 300 × 180 points while idle, waiting, asking a question, or displaying no results. It expands to 300 × 340 points when sample rows arrive; results scroll. Switching to Spotify search and back retains the sample selection. New submissions clear old rows, failures keep the draft for retry, and reset cancels pending work and returns to the compact card. Late responses cannot restore an obsolete selection. The native controller clamps the expanded panel to the screen and preserves composer focus when resizing.

Spotify search/playback remains its separate existing flow. The fictional sample IDs are never playable Spotify URIs.

## Verification

```bash
bash scripts/test-backend.sh --python-only
bash scripts/test-backend.sh --semantic
bash scripts/test-companion.sh
```

With the backend running, `bash scripts/test-backend.sh --live` and `bash scripts/test-companion.sh --live-backend` exercise the actual HTTP connection.

Automated checks cover catalog validation/provenance, numeric tempo, unknown BPM, impossible/conflicting requirements, hard-filter precedence over high similarity, soft inferred energy, full-request instrument matching, stable ordering/top-five limits, concurrent vector caching, model failure fallback, typed JSON, Swift decoding, result reset/failure state, native accessible rows, keyboard submission, panel sizes/placement, and search/back retention. Four authored real-model smoke cases exercise piano, guitar, jazz, and electronic retrieval with outbound socket connections blocked. These are acceptance checks, not held-out recommendation accuracy. The prior 21/24 intent result still passes and measures a different task.

## Next milestone

Research an independently licensed real-track catalog with usable descriptions/features and identity metadata. Evaluate retrieval on broader independently labeled requests, then implement Spotify resolution using reliable title/artist/version/ISRC matching. Personalization and learned ranking follow once relevant feedback exists.
