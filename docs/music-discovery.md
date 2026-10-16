# Music discovery and taste memory

Mochi is a personal desktop DJ: describe a session, discover real recordings, rank them independently, and play confident Spotify matches. Last.fm supplies candidates; Spotify supplies deterministic catalog matching and playback. This version runs locally with FastAPI, SQLite, Swift and SwiftUI. It needs no AWS service. Spotify API matching is optional: [desktop controls and a public search handoff](local-spotify-playback.md) support use without API login, with manual recording selection.

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

Model preparation is needed only once. Without the optional model, ranking falls back to lexical similarity. With no Last.fm key, the server returns an actionable setup message and an empty live selection; it never substitutes fictional songs. For automatic API matching, start Spotify on the desired device, connect Mochi, and try `jazz piano`, `indie rock`, or `mellow acoustic guitar`.

For the explicit fictional offline demo, set `MOCHI_CATALOG_MODE=sample` and restart. Those rows are labeled and cannot trigger Spotify playback. The older [sample selection walkthrough](song-selection.md) explains this fixture mode.

## The flow

```text
Your request
  → POST /listening-request
  → explicit constraints + optional local semantic interpretation
  → favorite-artist/related-artist pools + up to two session tags + a remembered recording seed
  → deduplicate canonical artist/title identities
  → exclude disliked/previous recordings, then rank available descriptions for lookup priority
  → song tags + optional verified tempo lookup for at most 12 prioritized recordings
  → rerank the remaining pool with strict requirements and taste adjustments
  → at most five canonical recordings
  → optional API login: Swift checks Spotify identity and recording identifiers
  → Web API ranked playback or one confirmed track through desktop controls
  → without API login: public search handoff and user-supplied track-link playback
  → explicit feedback influences later requests
```

The initial tag vocabulary is small and inspectable in `backend/discovery.py`. It recognizes genres, instruments and several session cues. With no artist setup or remembered recording, unknown prompts ask for a genre or instrument. “Surprise me” uses your chosen artist pools when set, or pop/indie otherwise. The broad catalog remains discoverable beyond cached songs, but this is not exhaustive Spotify coverage. Provider top-track pools can miss niche or very recent music.

Each request retains at most 65 candidates and enriches details for at most 12. Candidate pools get a turn in round-robin order before ranking. A preliminary ranking prioritizes up to five promising songs for lookup; the remaining lookup slots use acquisition order. An empty shortlist still checks candidates in acquisition order. Disliked recordings and the previous batch in **More like this** are removed before lookups.

The preliminary pass defers vocal/BPM/explicit-energy requirements so missing data does not prevent a candidate from being checked. It chooses lookup priority only; its results are never returned or saved as a recommendation context. After lookups, the final pass ranks the full remaining pool and applies the original strict requirements. Unknown measurements cannot qualify, tags never become guessed BPM/vocals/energy, and only the final selection enters taste context. Because all candidates remain in the final competition, reranking can introduce songs that have not received a detailed tag lookup.

HTTP calls have four-second timeouts, acquisition has a 12-second limit within discovery's 20-second acquisition/preliminary-ranking/enrichment budget, and provider rate-limit cooldowns are shared. Timeouts preserve acquired candidates and completed metadata; failures can produce partial results with warnings. One local discovery request runs at a time. Both ranking passes run outside the API event loop. The shared in-memory LRU holds at most eight catalogs, including preliminary and enriched versions. Changed source text gets fresh embeddings, while unchanged text reuses them; no vectors are stored on disk. The extra ranking pass adds inference work while keeping the provider lookup limit unchanged. Early scoring can bias which songs receive details, and sparse provider tags still limit relevance.

## Favorite-artist setup

On first opening, the compact card asks **Who do you like listening to?** One artist is enough, three are optional, and **Skip for now** remembers that choice. The header’s **… → Edit favorite artists** edits choices anytime. Artist autocomplete waits 350 ms after typing, searches Last.fm through the local backend, and returns at most five names. Query changes and closing the editor cancel work and invalidate late replies. Adding a choice triggers Mochi's existing squishy greeting; Reduce Motion remains supported. Chips can be removed; the editor shrinks once three artists are selected.

Press **Return** or the visible **Add** button to save a full artist name with an exact normalized autocomplete match. An early press waits for lookup; partial/ambiguous input keeps the results for explicit selection instead of accepting the first artist. The local backend must be running. If it is stopped, the editor preserves the name and shows restart/retry instructions; Return/Add retries unchanged input after starting the server. Native editing commits that write the same text do not clear existing results.

Native UserDefaults saves the chosen artist names, setup completion and discovery mode. No sign-in or cloud profile is needed. These explicit first-party choices are separate from backend SQLite feedback and replaceable provider metadata. Each new `POST /listening-request` may include `favorite_artists`, a validated list of up to three distinct names. Empty/duplicate/oversized names, control characters and extra Spotify payload fields are rejected. New-request reset retains choices. The app's **Forget taste memory** clears them after the backend acknowledges feedback/context deletion; `DELETE /taste` alone only clears backend storage.

`POST /artist-search` accepts `{"query":"Drake"}` and returns `{"query":"Drake","artists":["Drake"]}` (up to five results). It uses Last.fm's [artist.search](https://www.last.fm/api/show/artist.search); the API key remains in backend configuration. Missing configuration, provider errors and timeouts show messages; users can still skip setup.

In default Balanced discovery, each chosen artist contributes up to ten recordings from [artist.getTopTracks](https://www.last.fm/api/show/artist.getTopTracks), ordered by Last.fm popularity. The first two favorites can contribute up to two unique neighbors total through [artist.getSimilar](https://www.last.fm/api/show/artist.getSimilar); their top-track pools add discovery beyond the favorites. Unexpected artist corrections are rejected. No artist genre is promoted into a recording-level tag or measured feature. Up to two prompt-tag pools (15 tracks each when artists are set, 25 otherwise) and an available remembered liked recording complete acquisition.

Session requests still need text relevance before mode preferences (a 0.06 favorite-artist adjustment in Balanced); explicit dislikes and hard requirements take precedence. Broad artist-seeded requests such as **Surprise me** have no session description to compare, so they use taste adjustments and provider pool order with `method: "none"`, retaining all hard filters. This is an understandable heuristic baseline, not a trained taste network. **More like this** keeps its recording-specific seed and original context rather than switching to current onboarding artists. In fictional sample mode, artist setup does not alter the fixture selections.

Spotify supplies playback and optional deterministic recording matching. Artist setup does not import Spotify top artists or playlists; dropping a URL is not an implemented playlist ingestion path. Automatic Spotify matching and provider release requirements retain their existing limits.

## Familiar / Balanced / Discover

The compact card has three choices. Balanced is the default and retains the previous behavior. Familiar and Discover require at least one saved artist; the disabled controls explain that a favorite artist is needed. The native preference persists on this Mac, survives a new-request reset, and resets to Balanced when artists/taste are cleared. A choice applies to the next listening request. Existing results show their applied mode when it differs from the next-request choice, and controls are disabled while sending/starting playback/feedback. The Liquid Glass request card is 300 × 150 points; results/search remain 300 × 340.

| Mode | Tracks per saved artist | Related artists | Tracks per prompt tag with favorites | Ranking preference after relevance |
|---|---:|---:|---:|---|
| Familiar | 20 | 1 | 8 | +0.12 for saved artists |
| Balanced | 10 | 2 | 15 | +0.06 for saved artists |
| Discover | 5 | 3 | 15 | −0.06 for saved artists, +0.06 for other artists |

Related artists contribute up to ten tracks each. At most two favorites supply neighbor lists; interleaving these lists keeps a single seed from monopolizing the related slots. The same 65-candidate cap, 12 detail lookups, time budgets and strict requirements apply. Neither mode invents measurements, widens BPM, overrides dislikes nor guarantees ratios. Balanced can still return five tracks from favorites. Discover favors artists outside saved favorites; it cannot know everything the user has heard.

`POST /listening-request` accepts optional `discovery_mode` (`familiar`, `balanced`, `discover`) and the selection echoes the applied value. Familiar/Discover without favorites show an actionable empty result. Sample mode remains Balanced with a warning. Older native payloads/responses remain compatible with the default.

Successful contexts save the chosen mode and up to three hashed favorite-artist identities, alongside existing prompt and track/artist keys. An additive SQLite upgrade preserves prior contexts and feedback; older contexts default to Balanced. These options expire and clear with the request. **More like this** recovers the original mode and artist keys from the backend, uses the selected recording's neighborhood, and applies that mode during ranking. Editing the next-request choice or current favorite list does not rewrite the previous context.

Run `backend/.venv/bin/python scripts/verify-discovery-modes.py --artist 'The Weeknd'` for a live source/contract probe using disposable storage. The [October 15 report](discovery-modes-validation.json) observed 5/5 favorite-artist tracks for Familiar/Balanced and 0/5 for Discover on **Surprise me**, in 6.3–8.6 seconds with no warnings and 12 tag lookup attempts per mode. It also verified strict unknown BPM rejection and original-mode refinement. These observations are not relevance grades or fixed quotas; saved taste and Spotify playback were unchanged. Deterministic/native tests cover mode validation, pool bounds, relevance/strict-filter precedence, schema upgrade, context recovery, saved choice, in-flight capture and actual buttons/rendering.

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

Taste belongs to the local backend profile on this Mac; this is not a hosted, multi-account service. Reset clears the current card/session while preserving feedback. Open the header’s **… → Forget taste memory** to delete stored contexts and feedback. The provider cache is independent and replaceable.

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

Provider responses and derived canonical metadata share a 40 MB SQLite cache, bounded by physical database pages. Expired and least recently used entries are removed. HTTP `Cache-Control`, `Age` and `Expires` govern reuse, capped at one day; absent freshness headers, `no-cache`, `private`, or `no-store` mean no reuse. API keys appear only in outbound HTTPS parameters and hashed cache identities, never in logs or API responses. Native preferences retain at most three names of 200 Unicode scalars each, with no provider biographies/images or derived graph. The bounded evaluation capture adds at most 2 MB; in-memory candidate data is also bounded. The similar-song and artist probes each replace one report capped at 16 KB; the artist report retains counts/timings rather than returned recording metadata. Avoid accumulating additional exported provider snapshots.

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
backend/.venv/bin/python scripts/verify-artist-discovery.py --artist Drake --artist 'Frank Ocean'
```

The [artist setup source/API probe](artist-setup-validation.json) on October 12 found Drake in five autocomplete results in 265 ms. An artist-seeded **Surprise me** request returned five recordings from Drake/Frank Ocean in 7.4 seconds, with no warnings. A strict BPM request returned no recordings because tempo remained unknown. The probe used disposable cache/taste databases and did not change the app's choices or Spotify playback. Native checks cover persisted/removed choices, malformed replies, debounce cancellation and late-query responses; actual UI checks exercise Skip, typing, Add, Remove, Done and card resize. These are contract checks; relevance still needs user listening judgments.

The [October 13 two-pass probe](two-pass-ranking-validation.json) used The Weeknd and disposable cache/taste storage through FastAPI. Three session requests returned five songs each in 6.7–7.5 seconds with no warnings and exactly 12 tag lookup attempts. Preliminary ranking prioritized 1/4/4 candidates beyond the old first-12 cutoff for **Surprise me** / **Relaxing music** / **Something more energetic**. Five/two/two final songs respectively had received a song-tag lookup; the others still relied on available acquisition metadata. A strict 80–100 BPM request returned no songs. No musical measurements were invented, and preferences/playback were unchanged. This is an instrumented contract check, not a relevance score.

Deterministic two-pass checks verify late-candidate lookup, changed-text reranking and embedding reuse, empty-shortlist exploration, strict unknown-feature rejection, verified-tempo acceptance, dislike/previous-batch exclusions, bounded lookups, partial provider errors, timeouts and cancellation without saving preliminary context.

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

## Continuous sessions (October 16)

The five-song response is a bounded discovery batch. It no longer ends a listening session. API-connected requests start one confirmed recording, prime the real Spotify queue, and refill when at most two future songs remain. Queue writes never use the play endpoint to replace a song mid-session. They run sequentially with a fresh ownership/device check for each append. A playback read every 15 seconds (five for local controls) tracks movement through known session URIs. An immediate app-lifetime observer primes a newly started session, even with the menu closed.

`POST /continue-listening` takes a prior canonical `request_id`, `track_id`, Last.fm `title`/`artist`, and up to 500 `exclude_tracks` canonical IDs. The backend verifies the seed, recovers the saved original prompt, mode and favorite-artist hashes, and combines previous-batch exclusions with that list. Client prompt/mode/Spotify payload overrides are rejected. Discovery uses the seed's similar-track neighborhood, the existing bounded lookups and strict requirements, and current explicit taste. Broad artist-seeded sessions retain broad-request ranking when continued. It does not train on Spotify data.

The native session keeps recent canonical IDs and matched Spotify URIs separately, rolling at 500 each. Repeated IDs/URIs are not queued again within that window. Prior queue entries are pruned as playback advances. Newly discovered candidates replace the displayed batch, keeping the interface compact. Existing queued songs continue while the next batch is fetched; uncertain/unavailable recordings are omitted. If no new songs can be confirmed, refills end with a notice rather than looping or relaxing requirements.

Pause prevents refills and never resumes music on a timer. A foreign URI/device ends ownership after an initial 20-second state-propagation grace period; every queue write still requires an owned URI immediately. Stop, reset, new request, route change and disconnect cancel in-flight work. A timeout after a queue POST has an unknown outcome, so Mochi stops instead of repeating the append. Stopping refills does not remove tracks already accepted by Spotify, and the queue lasts in Spotify independently of Mochi. Restarting Mochi does not restore an old session automatically.

Local scripting still has no queue API. Optional API-connected desktop mode starts a URI locally, then uses the Web API queue only while the active Spotify player confirms a session URI. Desktop-only users retain public search/copy-link playback. Spotify's [queue API](https://developer.spotify.com/documentation/web-api/reference/add-to-queue) requires Premium and its existing playback scope; API beta/access limits still apply.

Unresolved rows are retryable: a direct click can use a second search form but still applies deterministic recording validation. Duplicate album/single editions with exact names and near-identical known durations can match when ISRCs do not conflict. Generic requests without musical measurements can accept a labeled remaster; version/measurement-bound requests cannot. Genuine market restrictions, alternate artists, live/remix editions, mismatched ISRCs and uncertain recordings remain rejected. Use Find on Spotify when a recording cannot be confirmed.

Run `bash scripts/test-session.sh` for queue ordering, continuation context/exclusions, pause, exhaustion, repeats, ownership changes, cancellation, uncertain acknowledgements and API-assisted desktop queuing. Run existing discovery/local/UI checks for the matching and menu regressions. These fixtures make no real-account playback claims.
