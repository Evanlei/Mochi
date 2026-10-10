# Music discovery and taste memory

Mochi is a personal desktop DJ: describe a session, discover real recordings, rank them independently, and play confident Spotify matches. Last.fm supplies candidates; Spotify supplies deterministic catalog matching and playback. This version runs locally with FastAPI, SQLite, Swift and SwiftUI. It needs no AWS service.

## Setup

From the repository root:

```bash
cp backend/.env.example backend/.env
```

Request a free hobby API key from [Last.fm's API account page](https://www.last.fm/api/account/create), then put it in the local `.env` file:

```dotenv
LASTFM_API_KEY=your_key_here
MOCHI_CATALOG_MODE=live
MOCHI_RECCOBEATS_ENABLED=false
```

Do not paste the key into chat or put it in Swift. `.env` and `.data` are ignored by Git. Environment variables take priority over `.env`. Restart the server after changing configuration:

```bash
cd backend
uv sync --extra semantic
uv run --extra semantic python ../scripts/prepare-intent-model.py
uv run --extra semantic fastapi dev main.py
```

Model preparation is needed only once. Without the optional model, ranking falls back to lexical similarity. With no Last.fm key, the server returns an actionable setup message and an empty live selection; it never substitutes fictional songs. Start Spotify on the desired device, connect Mochi, and try `jazz piano`, `indie rock`, or `mellow acoustic guitar`.

For the explicit fictional offline demo, set `MOCHI_CATALOG_MODE=sample` and restart. Those rows are labeled and cannot trigger Spotify playback. The older [sample selection walkthrough](song-selection.md) explains this fixture mode.

## The flow

```text
Your request
  → POST /listening-request
  → explicit constraints + optional local semantic interpretation
  → up to two Last.fm tag pools + similar tracks from an available favorite
  → deduplicate canonical artist/title identities
  → independent tags/descriptions + optional verified tempo lookup
  → strict requirements, relevance ranking, taste adjustments
  → at most five canonical recordings
  → Swift checks Spotify artist/title/version and available recording identifiers
  → play the confirmed recordings in ranked order
  → explicit feedback influences later requests
```

The initial tag vocabulary is small and inspectable in `backend/discovery.py`. It recognizes genres, instruments and several session cues. Unknown prompts ask for a genre or instrument instead of inventing a meaning. “Surprise me” uses pop and indie pools. The broad catalog remains discoverable beyond cached songs, but this is not exhaustive Spotify coverage. Tag-top-track pools favor familiar recordings and can miss niche or very recent music.

Each request acquires at most 65 candidates and enriches details for at most 12, interleaving the two tag pools. HTTP calls have four-second timeouts, discovery has a 20-second budget, and provider rate-limit cooldowns are shared. Failures can produce partial results with warnings. One local discovery request runs at a time. Ranking runs outside the API event loop. Candidate embeddings are retained only in a small in-memory LRU of eight catalogs; no vectors are stored on disk.

## What the ranking knows

The existing local text model ranks independently sourced Last.fm descriptions and tags. Missing model files or inference failure select lexical matching. Similarity scores are ranking values, not probabilities. Weak matches can produce an empty selection.

Musical measurements remain nullable. A Last.fm community tag is a retrieval hint, not proof of BPM, vocal absence, or measured energy. Unknown values fail strict requirements. Mochi never widens a requested BPM range.

For live music, subjective mood words such as “relaxing” influence retrieval and text relevance. An explicit `low energy` or `high energy` requirement demands verified energy. Vocal requests such as `no vocals` remain strict. This version does not provide reliable vocal/energy measurements, so those strict requests currently produce empty results. That limitation is visible rather than guessed away.

ReccoBeats tempo enrichment is experimental and off by default. Its returned title, artist, ISRC and duration are used only to establish recording identity. The adapter promotes only a finite tempo in the supported 20–400 BPM range, with provider and recording provenance. Independently claimed analytical metrics stay separate from its Spotify-derived basic metadata. Instrumentalness is not converted into a vocals boolean. Names, popularity and Spotify responses never enter the semantic model. See [ReccoBeats's source and reliability terms](https://reccobeats.com/docs/documentation/terms-of-service).

## Spotify resolution and playback

Swift searches by ISRC when available, otherwise by title and artist. It requires near-exact normalized artist/title matches, compatible version markers, playability, and a duration within two seconds when provided. A known ISRC must agree. Multiple eligible recordings are rejected unless they share a known ISRC; equivalent releases use a stable choice. Covers, live versions and remixes are not silently substituted. This conservative approach sacrifices coverage to avoid wrong recordings.

Mochi starts one to five confirmed URIs through Spotify's [Start/Resume Playback endpoint](https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback), preserving ranking and dropping duplicate URIs. The shared playback model reads the active device and serializes commands with menu controls. Premium and a usable player are required. Zero confident matches show a message; partial matches report how many started. An accepted command whose refresh fails is reported separately, and an uncertain playback failure is not automatically retried.

The matching phase budgets 25 seconds, with each search capped at 15 seconds and the remaining budget. An explicit 401 gets one token refresh/retry. Reset or disconnect cancels work and invalidates late results. Playback acceptance is an acknowledgment, not proof of listening. “Play matches” lets a user connect Spotify after obtaining recommendations, or explicitly retry. Row play buttons replay already-resolved recordings.

## Taste memory

The card includes like/dislike controls. A dislike excludes that canonical recording from later recommendations. A like contributes +0.12, artist affinity contributes at most ±0.08, and recent selections/replays contribute a repetition penalty capped at 0.15. These transparent heuristics precede any trained ranking model. Repeating a like does not multiply its score.

`backend/.data/taste.sqlite3` stores Mochi's own prompt, request identifier, opaque canonical track/artist keys, event identifier, event type and timestamp. Recommendation contexts expire after 30 days; feedback retains the latest 10,000 events. A “select” means Mochi accepted a playback command for its first selection; it does not imply every queued track was heard. Choosing the same track again in the session records “replay”. Likes/dislikes are explicit. Spotify history, skips and completed-listen inference are not collected.

Remembered favorites can seed Last.fm similar-track discovery while their canonical metadata remains available in the fresh provider cache. When that metadata expires, the recording/artist preference keys still influence new candidates, but the similar-track seed is unavailable until rediscovered. This avoids keeping provider descriptions indefinitely in the taste database.

Taste belongs to the local backend profile on this Mac; this is not a hosted, multi-account service. Reset clears the current card/session while preserving feedback. Right-click the reset arrow and choose **Forget taste memory** to delete stored contexts and feedback. The provider cache is independent and replaceable.

## API additions

`POST /listening-request` retains `received_prompt`, `intent`, `clarification`, and `selection`. Live selections use `catalog_kind: lastfm_live`, nullable track `bpm`, `vocals`, and `energy`, a source URL, optional feature provenance/identity, warnings, and a UUID `request_id` for nonempty results. Fictional selections use `fictional_sample`.

`POST /feedback` accepts exactly:

```json
{
  "event_id": "d52160cc-2687-4fab-8a4b-c8d22e98209a",
  "request_id": "039926ce-22e7-4557-9e91-970026b4305f",
  "track_id": "the-canonical-id-returned-in-that-request",
  "event": "like"
}
```

Allowed events: `like`, `dislike`, `select`, `replay`. The recording must belong to that recent request. Event identifiers are idempotent, and reused identifiers with different contents are rejected. `DELETE /taste` clears this profile. These are loopback development endpoints; do not expose this unauthenticated service publicly.

## Storage and release boundaries

Provider responses and derived canonical metadata share a 40 MB SQLite cache, bounded by physical database pages. Expired and least recently used entries are removed. HTTP `Cache-Control`, `Age` and `Expires` govern reuse, capped at one day; absent freshness headers, `no-cache`, `private`, or `no-store` mean no reuse. API keys appear only in outbound HTTPS parameters and hashed cache identities, never in logs or API responses. The bounded evaluation capture adds at most 2 MB; in-memory candidate data is also bounded. Avoid accumulating additional exported provider snapshots.

[Last.fm's terms](https://www.last.fm/api/tos) impose a 100 MB storage allowance, caching requirements, noncommercial default use and prior approval for public-facing use. This implementation remains a private hobby/testing project until those permissions are resolved. Links attribute Last.fm in the native result card. Spotify is used for deterministic matching and playback, consistent with its [developer policy](https://developer.spotify.com/policy); Spotify content is not ingested into Mochi's ML model. The beta remains limited by [Spotify development-mode quotas](https://developer.spotify.com/documentation/web-api/concepts/quota-modes), currently five authenticated users.

## Verification and source evidence

```bash
bash scripts/test-backend.sh --semantic
bash scripts/test-discovery.sh
bash scripts/test-search.sh
bash scripts/test-playback.sh
bash scripts/test-companion.sh /private/tmp/MochiDiscoveryPreview
backend/.venv/bin/python scripts/validate-discovery.py --output docs/provider-validation.json
```

Deterministic checks cover provider errors, invalid/oversized responses, missing features, strict filtering, deduplication, physical cache limits/expiry, rate-limit cooldowns, persistence, feedback context/idempotency/deletion, nullable Swift decoding, independent Spotify resolution, partial playback, cancellation and stale responses. Native UI checks render the existing compact card and check accessible feedback controls. Tests use fictional fixtures and fake tokens; they do not alter real Spotify playback.

The committed [source probe](provider-validation.json) tested three recordings on October 10, 2026. ReccoBeats produced a matching estimated tempo for **Blinding Lights** (171.001 BPM); **Manchild** and **River Flows in You** had ambiguous recordings and remained unknown. Responses took roughly 1.7–2.8 seconds per lookup. Last.fm was blocked by the missing key. These are access/availability smoke cases, not measured overall coverage or manual tempo-accuracy results. Last.fm live discovery and real-account recommendation playback still require validation.

To compare rankings, start with the [authored fixture report](discovery-evaluation.json):

```bash
backend/.venv/bin/python scripts/evaluate-discovery.py
```

Its four manually graded fictional-description cases isolate ranking logic. The acquisition order is an authored stand-in, not actual Last.fm ordering; its improved NDCG is not a live recommendation-quality claim. Once a key is configured:

```bash
backend/.venv/bin/python scripts/evaluate-discovery.py --capture
```

This replaces one bounded snapshot at `backend/.data/discovery-evaluation.json`, without modifying your taste profile. Manually assign every candidate a relevance grade (0 irrelevant, 1 weak, 2 useful, 3 strong), then compare actual acquisition order with Mochi:

```bash
backend/.venv/bin/python scripts/evaluate-discovery.py \
  --input backend/.data/discovery-evaluation.json --semantic
```

Measure Spotify resolver precision separately. Before inviting testers, validate Last.fm responses, manually review song/version matches and tempo estimates, and listen to the resulting sessions. Larger discovery pools, reliable musical measurements, cloud profiles, skip inference, learned ranking and broader distribution remain future work.
