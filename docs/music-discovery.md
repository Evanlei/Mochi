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

## More like this

Choose **More like this** in the `…` menu beside a live recommended song. The same menu keeps its **Open on Last.fm** link. The card stays 300 × 340 points and shows which song seeded the new batch.

```text
Selected recommendation + its request ID
  → POST /more-like-this
  → recover the original prompt from Mochi's saved context
  → verify the selected artist/title against the stored recording identity
  → Last.fm similar-track pool for that song
  → exclude the seed and immediately previous batch
  → original requirements + independent ranking + current taste memory
  → new recommendation context
  → existing Spotify resolution and partial queue playback
```

This action uses up to 50 candidates from Last.fm's [track.getSimilar endpoint](https://www.last.fm/api/show/track.getSimilar), with detail lookups for at most 12. It uses that selected song's neighborhood; it does not fall back to unrelated popular tag pools when the provider returns nothing or fails. Ranking still uses the original prompt. Strict requirements stay strict, so unknown BPM/vocals/energy can leave no eligible songs. It excludes the previous batch, not every song ever recommended; taste repetition penalties still apply.

Clicking **More like this** is a direction for this request, not an implicit like. Existing likes/dislikes influence ranking as before. A partially typed new prompt is preserved and does not change the similar-song request. Empty/error responses keep the existing rows and Spotify mappings available; successful results replace them and use the existing automatic playback path when connected. Reset/disconnect invalidates pending responses. After 30 days, or after **Forget taste memory**, the original context is unavailable and the app asks for a new listening request. Sample-mode rows cannot start this action.

The native client returns the original Last.fm title/artist from the selected row. The backend verifies their opaque canonical track/artist keys against its own stored context before using them as a discovery seed. This avoids depending on an expired provider cache or keeping provider names/descriptions indefinitely in the taste database. Spotify search metadata and musical measurements are not accepted in this request.

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

`POST /more-like-this` accepts exactly four fields from a previous live response: UUID `request_id`, canonical `track_id` (`lastfm-` plus 64 hexadecimal characters), `title` and `artist` (1–200 characters each). It returns the same listening-response shape with the original `received_prompt`, reinterpreted intent and a new selection/request ID when nonempty. A new prompt, Spotify payload or supplied musical measurement is rejected. Unknown/expired/cleared contexts and sample mode return 409; an unrecognized recording or mismatched artist/title returns 422. Provider failures/empty strict selections return 200 with an empty live selection and an explanation.

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

Provider responses and derived canonical metadata share a 40 MB SQLite cache, bounded by physical database pages. Expired and least recently used entries are removed. HTTP `Cache-Control`, `Age` and `Expires` govern reuse, capped at one day; absent freshness headers, `no-cache`, `private`, or `no-store` mean no reuse. API keys appear only in outbound HTTPS parameters and hashed cache identities, never in logs or API responses. The bounded evaluation capture adds at most 2 MB; in-memory candidate data is also bounded. The similar-song smoke check replaces one report capped at 16 KB. Avoid accumulating additional exported provider snapshots.

[Last.fm's terms](https://www.last.fm/api/tos) impose a 100 MB storage allowance, caching requirements, noncommercial default use and prior approval for public-facing use. This implementation remains a private hobby/testing project until those permissions are resolved. Links attribute Last.fm in the native result card. Spotify is used for deterministic matching and playback, consistent with its [developer policy](https://developer.spotify.com/policy); Spotify content is not ingested into Mochi's ML model. The beta remains limited by [Spotify development-mode quotas](https://developer.spotify.com/documentation/web-api/concepts/quota-modes), currently five authenticated users.

## Verification and source evidence

```bash
bash scripts/test-backend.sh --semantic
bash scripts/test-discovery.sh
bash scripts/test-search.sh
bash scripts/test-playback.sh
bash scripts/test-companion.sh /private/tmp/MochiDiscoveryPreview
backend/.venv/bin/python scripts/validate-discovery.py --output docs/provider-validation.json
backend/.venv/bin/python scripts/verify-similar-discovery.py --output docs/similar-discovery-validation.json
```

Deterministic checks cover provider errors, invalid/oversized responses, missing features, strict filtering, deduplication, physical cache limits/expiry, rate-limit cooldowns, persistence, feedback context/idempotency/deletion, nullable Swift decoding, independent Spotify resolution, partial playback, cancellation and stale responses. Similar-song checks cover original-context validation/expiry/deletion, spoofed names and extra fields, seed/previous-batch exclusion, strict unknown BPM, no unrelated fallback, preserved drafts/results and disconnect/reset during pending refinement. Native UI checks render the compact card, verify accessible song menus and display the selected seed. Tests use fictional fixtures and fake tokens; they do not alter real Spotify playback.

The committed [source probe](provider-validation.json) tested three recordings on October 10, 2026 using the locally configured key. Last.fm returned five tag-pool candidates and five similar tracks for each input. Track tags were available for **Blinding Lights** and **Manchild**; **River Flows in You** returned no track tags. ReccoBeats produced a matching estimated tempo for **Blinding Lights** (171.001 BPM); the other two inputs had ambiguous recordings and remained unknown. Combined Last.fm tag/pool/similar checks took roughly 2.1–2.8 seconds per input, and ReccoBeats lookups took roughly 2.0–3.8 seconds. These are access/availability smoke cases, not measured overall coverage or manual tempo-accuracy results.

A separate real request through `RecommendationService` for `jazz piano` returned five semantically ranked recordings in approximately 6.4 seconds with no provider warnings: Nuvole Bianche, Comptine d'un autre été, L'Après-midi, Gymnopédie No. 1, Feeling Good, and In A Sentimental Mood. Their BPM, vocals and energy remained unknown. This checks the live acquisition/ranking path, not the quality of a jazz-piano session. Real-account recommendation playback and manually judged live rankings remain pending.

The [similar-song API smoke report](similar-discovery-validation.json), recorded on October 12, 2026 UTC (October 11 locally), uses a temporary cache/profile and the real Last.fm key. An initial `jazz piano` request returned five songs in 6.4 seconds. Selecting **Nuvole Bianche — Ludovico Einaudi** returned five new semantically ranked candidates in 5.7 seconds, with no provider warnings. The API preserved the original prompt and excluded the previous batch. Musical measurements remained unknown. This verifies acquisition and the API contract; it does not assess recommendation quality or change Spotify playback.

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
