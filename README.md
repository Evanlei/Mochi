# Mochi

<img src="design/mochi-app-icon.png" alt="Mochi: a sage blob with oval eyes and a tiny smile on warm cream" width="112" height="112">

A personal desktop DJ, built with Swift and SwiftUI. Describe a session to floating Mochi; the local Python backend discovers Last.fm candidates and ranks them to your taste, while Spotify handles playback.

The native companion, live discovery integration, independent ranking, conservative Spotify resolution, partial queue playback, and local taste memory are implemented. Live Last.fm source checks and a real discovery/ranking request have passed; real-account recommendation playback remains to be checked.

## Current functionality

- A draggable sage Mochi character, matching the supplied SVG artwork.
- Click Mochi to open or close a compact listening-request card.
- Optional favorite-artist setup with Last.fm autocomplete, up to three removable choices, and a heart button to edit them later.
- Familiar / Balanced / Discover choices adjust artist pools and ranking, remember your preference, and preserve the original mode for **More like this**.
- Focus, Unwind, and Surprise me choices, plus a text input with Send and Return submission.
- Listening text sent asynchronously to a local FastAPI backend, with validation and confirmation.
- Two-pass ranking checks song tags for promising preliminary matches, then reranks with the new information; at most 12 recordings get detail lookups.
- Loading, reset/cancellation, and retry messages; confirmed requests retained while the app runs.
- **More like this** in each live song's `…` menu, keeping the original request and excluding the previous batch.
- Song and artist searches in the companion card, with up to five matching tracks and click-to-play results.
- Loading, cancellation, empty-result, unavailable-track, and connection/error states for search.
- Saved desktop position and visibility, plus Show/Hide Mochi and Quit in the menu-bar panel.
- Spotify Authorization Code with PKCE, using the system browser and a local callback listener.
- Callback state validation, cancellation, timeout, and connection-status messages.
- HTTPS token exchange, access-token refresh, and secure token storage in macOS Keychain.
- Restoration of a saved connection at app launch, even before the menu-bar panel opens.
- Local disconnect that removes Mochi's saved tokens.
- Optional Spotify desktop controls with no Web API login, plus validated track-link playback.
- **Find on Spotify** in recommendation menus for users outside the API beta.
- Now Playing with the song, artist, playing/paused status, and Spotify device.
- Play/pause, previous, next, and manual Refresh controls.
- Refresh when the panel opens or connects, and after a playback command.
- Clear messages for unavailable players, restricted controls, connection failures, and rate limits.

**Mood requests now discover live Last.fm candidates, rank independent tags/descriptions, and return up to five canonical recordings. API-connected users get conservative Spotify version matching: Web API mode starts the ranked subset, and desktop mode starts the first confirmed match. Users without API login can hand off to public Spotify search and play a copied track link locally. Likes/dislikes persist in SQLite and affect later requests. Unknown BPM, vocals, or energy never satisfy strict requirements.** ReccoBeats BPM enrichment is experimental and off by default; reliable vocal/energy measurements are not yet available. Fictional music remains only in explicitly selected development mode. Live Spotify login and original controls were previously confirmed; new recommendation playback is covered by mock integration tests pending a live account check.

See [music discovery, setup, tradeoffs and verification](docs/music-discovery.md). The first release is a private hobby beta. Desktop controls avoid the Web API allowlist for playback; automatic API matching remains limited. Public distribution still requires resolving provider permissions. See [local playback setup and limits](docs/local-spotify-playback.md).

## Requirements

- macOS 26 or later.
- Xcode with the macOS SDK and Swift toolchain. The project has been built with Swift 6.4.
- The Spotify Mac desktop app for local controls; macOS Automation permission is requested when you enable them.
- Spotify Premium and a registered developer app only for optional Web API matching/playback.
- Python 3.12 or later and [uv](https://docs.astral.sh/uv/) for the local listening-request backend.
- A [Last.fm API key](https://www.last.fm/api/account/create) for live discovery, kept only in backend configuration.

Most source editing can be done in VS Code. Xcode provides the native project, build tools, signing, and debugger.

## Run Mochi

1. Open `Mochi/Mochi.xcodeproj` in Xcode.
2. Select the **Mochi** scheme and **My Mac** destination.
3. Build and run with **Command-R**.
4. Click the music-note icon in the macOS menu bar to open the panel.
5. Mochi appears near the bottom-right of your desktop on first launch. Click the character to open the listening-request card. If you previously hid it, click **Show Mochi** in the menu-bar panel.
6. Choose one to three favorite artists, or **Skip for now**. Start the local backend below first. Type a full artist name and press **Return** or **Add**, or click an autocomplete result. An exact match saves as a removable chip; partial names require choosing a result. Spotify login is not needed. Click the heart later to edit your choices.

You can also build from the repository root:

```bash
xcodebuild -project Mochi/Mochi.xcodeproj \
  -scheme Mochi \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  build
```

The resulting app is `build/Build/Products/Debug/Mochi.app`. Build output is ignored by Git.

## Run the local backend

Copy `backend/.env.example` to `backend/.env` from the repository root, then fill in `LASTFM_API_KEY` locally. Keep it out of chat and Git. No key is needed for the explicit fictional demo (`MOCHI_CATALOG_MODE=sample`). In a separate VS Code terminal:

```bash
cd backend
uv sync --extra semantic
uv run --extra semantic python ../scripts/prepare-intent-model.py
uv run --extra semantic fastapi dev main.py
```

The preparation command downloads a pinned public model once (about 67 MB of model weights) into an ignored local folder. On subsequent starts, only run `uv run --extra semantic fastapi dev main.py`. Leave the terminal running while using listening requests. **Control-C** stops it. Saving Python changes reloads the development server. It listens on your computer at `127.0.0.1:8000`; no AWS service is needed. For the deterministic rules alone, use `uv run fastapi dev main.py`; missing model files or packages also fall back to those rules.

Open [the API testing page](http://127.0.0.1:8000/docs) or [the health check](http://127.0.0.1:8000/health). Then run Mochi, connect Spotify, click the character, and try **jazz piano**, **indie rock**, or **mellow acoustic guitar**. The expanded card shows source links, available musical features, play buttons and likes/dislikes. Missing musical features stay unknown. Strict requests such as **no vocals** currently return empty live selections rather than guessed results. In fictional demo mode, try **calm piano without vocals 80–100 BPM** to exercise numeric filtering. **Calm and energetic** asks for clarification.

If the server is stopped, Mochi keeps your text and asks you to start the backend and retry. Send is disabled during a pending request; the reset button cancels it. Spotify search and playback use their existing direct Spotify connection independently.

Artist setup also needs this server for Last.fm lookup. After starting it, press **Return** or **Add** to retry the artist name already in the field; you do not need to retype it.

See [the backend walkthrough](docs/backend.md) for the request flow, code roles, API contract, and current limits.

See [request understanding and evaluation](docs/intent-understanding.md) for the rule/model combination and its measured results.

See [sample song selection](docs/song-selection.md) for the explicitly fictional fixture mode, and [live discovery](docs/music-discovery.md) for the current flow.

## Connect Spotify

1. Create an app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard), selecting Web API if asked.
2. Register this exact redirect URI:

   ```text
   http://127.0.0.1:8888/callback
   ```

3. Set your app's Client ID in [SpotifyAuthorization.swift](Mochi/Mochi/SpotifyAuthorization.swift) under **App configuration**. The Client ID is public; PKCE does not require a client secret.
4. Run one copy of Mochi, open the panel, and click **Connect Spotify**.
5. Sign in and approve the requested playback permissions on Spotify's page.
6. Return to Mochi and wait for **Spotify connected.**

The listener binds only to `127.0.0.1`, on your own computer. If port 8888 is occupied, close another copy of Mochi or the application using that port and retry. Login times out after three minutes; **Cancel** stops it sooner.

**Disconnect** deletes locally stored tokens. To revoke Spotify's permission grant as well, remove Mochi from the connected-apps page in your Spotify account.

For the code walkthrough, security model, refresh behavior, and official references, see [Spotify authentication](docs/spotify-auth.md).

## Now Playing and controls

For the optional **Web API** route:

1. Connect Spotify API in Mochi.
2. Open Spotify on your preferred device and start a song.
3. Open Mochi's menu-bar panel. Click the circular-arrow **Refresh** button if needed.
4. Use **Previous**, **Play/Pause**, or **Next**. Mochi targets the device shown in the panel and reads the updated playback state after Spotify accepts the command.

Web API mode takes a snapshot when the panel opens, after a control action, or when you click Refresh. Desktop mode also checks every five seconds without requesting API tokens. If you change tracks or devices elsewhere, click Refresh before using the controls. Spotify may take a moment to reflect a command; Refresh can fetch a newer result.

Controls are disabled while a request is running, when Spotify reports restrictions, or when there is no usable playback state. A failed refresh marks the displayed information as old and disables controls until a successful refresh. If Spotify limits requests, wait for the indicated delay before refreshing.

The playback client gets its access token from the existing authentication model. Expired tokens refresh automatically; an explicit token rejection triggers one refresh and retry. Uncertain failures such as a timeout do not repeat a skip command.

## Floating Mochi

The accepted **B — composer first** layout uses a 300 × 150-point translucent sage card. The current discovery mode opens a small dropdown, leaving room for the prompt and presets. Results and Spotify search expand to 300 × 340 points; favorite-artist editing uses 300 × 320 points and shrinks after three choices. Reduce Transparency supplies a solid background.

Mochi breathes, blinks, glances around and occasionally jumps while idle, with no ground shadow. Hovering gives a squishy greeting and hand wave; dragging stretches the body and releasing it gives a settling bounce. A draft gives Mochi a curious expression, an active discovery/search request gives it a thinking pose, and playback starting triggers a brief happy squish. Reactions blend from their current state rather than restarting on every keystroke. The panel fades in/out quickly, expands smoothly into results, and its primary buttons have subtle press feedback.

While music is playing, Mochi dances to its own steady rhythm; this is not measured song BPM. Desktop mode refreshes playback every five seconds while the menu is closed. After 90 seconds without interaction, Mochi sleeps with closed eyes, slow breathing and floating z’s; hovering wakes it. An open card keeps it awake. Animation pauses when hidden. Reduce Motion uses static character expressions and immediate panel geometry changes. See [motion choices and validation](docs/compact-companion-motion.md).

- **Drag** the character to move it. Its position is saved between launches.
- **Click** the character to open or close the card. Dragging does not also open it.
- Use the **heart** to add/remove favorite artists. One is enough; choices save immediately on this Mac. Adding an artist triggers Mochi's squishy greeting. The setup card shrinks after three choices.
- Open the **discovery-mode dropdown** and choose **Familiar** to lean toward saved artists, **Balanced** for the existing mix of candidate sources, or **Discover** to lean toward artists outside your favorites. Familiar/Discover need a saved artist. The choice applies to the next request; existing results keep a label showing their original mode. These are preferences, not fixed ratios or a guarantee that you have/haven't heard a recording.
- Choose **Focus**, **Unwind**, or **Surprise me**, or type your own mood, artist, or song. Click the arrow or press **Return** to submit.
- Mood submissions show live matches, a setup/constraint message, or a clarification question. Each submission is analyzed independently; answer a question with a complete revised request.
- Use thumbs up/down to save taste feedback. Right-click the reset arrow and choose **Forget taste memory** to delete it. **Play matches** retries matching after connecting Spotify.
- Choose **More like this** from a recommended song's `…` menu to discover another batch for the same session.
- Use **Cancel** while a request is pending to keep your draft and reject late responses. Refinement cancellation also retains the existing songs.
- Click the reset arrow to start a **new listening request**.
- Press **Escape**, click the close button, or click outside the card to dismiss it. Closing retains your draft and preferences during this app session.
- Use **Hide Mochi / Show Mochi** in the menu-bar panel. Hiding also closes the card; visibility is remembered after quitting.

The companion stays above ordinary windows and joins desktop Spaces. Its card opens above the character when space permits, below it near the top edge, and stays within the display's usable area. If a remembered display is disconnected, Mochi moves back onto an available display. Spotify controls remain in the menu bar.

The visible request summary lasts for the app session. Explicit feedback and recommendation contexts persist in the local backend's SQLite taste store; disposable provider metadata has a separate bounded cache. Favorite artists, setup completion, character position and visibility stay in local app preferences. New listening requests include your favorite artist names; they guide Last.fm candidate pools and receive a small ranking preference. **Surprise me** starts from those artists when set. **Forget taste memory** clears backend feedback/context and then native artist choices. This version has one feedback profile per local backend; native choices are per app installation.

## Find more songs like a recommendation

1. Send a listening request such as **jazz piano** and wait for live recommendations.
2. Click the **`…` menu** beside a song, then **More like this**.
3. Mochi finds similar candidates, ranks them against that original request and your saved taste, and starts the confident Spotify matches if connected.

The selected song and immediately previous batch are excluded. Strict BPM/vocal/energy requirements stay in place; missing measurements still cannot satisfy them. Your current composer draft is preserved. If discovery fails or no new candidates meet the request, the existing songs remain available. This action does not save a like; use thumbs up/down for that. Reset or disconnect cancels pending work. Fictional sample rows do not offer this action.

## Find and play a song

1. Connect Spotify from the menu-bar panel, and open Spotify on your preferred device. Start a song there once if Spotify has no active player.
2. Click Mochi, then the **magnifying glass** in its card.
3. Choose **Songs** and enter a title, or choose **Artists** and enter an artist's name to find matching tracks.
4. Press **Return** or click the search button. Mochi searches once per submission, not on every keystroke.
5. Click a result to play that track. The small external-link button opens its Spotify page.
6. Use the speech-bubble button to return to your listening request.

Search mode expands the same translucent card to 300 × 340 points, with a scrollable result list. Returning to the listening request restores its 300 × 180-point size and retains your preferences. Closing the card retains search results during the session. Disconnecting clears account results and cancels pending work.

Mochi uses Spotify's [catalog search](https://developer.spotify.com/documentation/web-api/reference/search) with five results and the connected user's market. Artist mode searches tracks with Spotify's `artist:` filter. You choose the result; Mochi does not assume the first match is correct. Tracks explicitly marked unavailable are disabled. Spotify may omit optional metadata, which Mochi tolerates.

In Web API mode, choosing a track reads the active playback device, then sends its URI to Spotify's [Start/Resume Playback endpoint](https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback). Web API playback requires Premium and the existing `user-modify-playback-state` permission; no extra login scopes were added. Desktop mode sends a confirmed URI directly to the installed app instead. Search and menu controls share playback sequencing. Mochi refreshes Now Playing after Spotify accepts the track; if confirmation fails, it reports that the command was accepted but its result could not be refreshed. It does not automatically repeat uncertain playback failures.

## App icon

Mochi's app icon uses the sage character on a warm cream rounded square. The editable source is [mochi-app-icon-concept.svg](design/mochi-app-icon-concept.svg); [mochi-app-icon.png](design/mochi-app-icon.png) is the 1024-pixel export used above.

Xcode's `Assets.xcassets/AppIcon.appiconset` contains the macOS icon sizes, including Retina versions. Both Debug and Release builds use this asset. You can inspect it by opening **Assets → AppIcon** in Xcode, and see the built app's icon in Finder. Mochi runs as a menu-bar app, so it does not appear in the Dock; the music-note menu-bar button opens playback controls.

## Authentication checks

From the repository root:

```bash
bash scripts/test-auth.sh
```

The checks cover a PKCE reference vector, random verifier generation, authorization parameters, callback validation, real loopback requests, timeout/cancellation, simulated token exchange and refresh, and the app's connection lifecycle. They do not log in to Spotify or use real Spotify credentials.

To also check Keychain save, load, update, and deletion:

```bash
bash scripts/test-auth.sh --keychain
```

The Keychain check creates a uniquely named item containing fake tokens and deletes it afterward. Keep port 8888 free while running the checks.

## Local Spotify desktop playback

Open Spotify and start a song, then click **Use desktop controls** in Mochi's menu. Allow the macOS Automation request. Now Playing, play/pause and skips work without Spotify API login. Desktop mode refreshes every five seconds and keeps Mochi's dancing current.

For recommendations, open a song's **… → Find on Spotify**, choose the recording and copy its track link. Paste that into the menu's **Spotify track link** field and click **Play link**. Automatic catalog matching still requires optional API access. Desktop mode plays one track at a time; it cannot create a queue or read your top artists.

See [the flow, implementation and live-check steps](docs/local-spotify-playback.md). The new desktop route has mock integration/UI coverage and builds successfully; real Automation permission and playback remain to be checked on your Mac.

```bash
bash scripts/test-local-playback.sh
```

## Playback checks

```bash
bash scripts/test-playback.sh
```

These checks cover playback decoding, all four control requests, device targeting, restricted actions, missing playback, token refresh/retry, rate limits, serialized controls, and ignoring responses after disconnect. They use fake tokens and intercepted network responses; they do not change real Spotify playback. Live playback should also be checked from the running app.

## Companion checks

```bash
bash scripts/test-companion.sh
```

Run this in a logged-in macOS desktop session. The checks briefly show native test windows and verify placement, accessible click toggling, keyboard focus, typing, Return submission, Escape dismissal, and position/visibility restoration. They also exercise search-card expansion, launch-time connection restoration, keyboard search, and result-click playback using fake Spotify responses. They use a unique temporary preferences domain and remove it afterward; they do not use Spotify credentials or modify real playback.

To also render the actual SwiftUI card and character for inspection:

```bash
bash scripts/test-companion.sh /private/tmp/MochiCompanionPreview
```

## Search checks

```bash
bash scripts/test-search.sh
```

These checks cover song/artist query encoding, optional metadata, unavailable tracks, duplicate and invalid results, token refresh/retry, cancellation, stale responses, rate limits, selected-track request bodies, current-device targeting, serialized playback, and disconnect behavior. All requests are intercepted and use fake tokens.

## Backend checks

After `uv sync` in `backend/`, run from the repository root:

```bash
bash scripts/test-backend.sh
```

These check Python input validation, vocals/energy parsing and the response contract, Swift request encoding and response decoding, unavailable servers, timeouts, invalid responses, duplicate submission, failure/retry, and reset while a response is pending. Requests are simulated by default. With the development server running, add `--live` to also verify a real Swift-to-Python request.

For fast checks while working on Python, without starting the backend or compiling Swift:

```bash
bash scripts/test-backend.sh --python-only
```

The Python tests check vocal and energy preferences, explicit BPM values/ranges, scoped negation, word boundaries, conflicts, unspecified preferences, uppercase input, combined requests, trimming, Unicode, input limits, malformed JSON, model failure, catalog validation, selection constraints, ranking, cached embeddings, and the documented response format. They use deterministic or injected model outputs, so they require no model download. Failures identify the test and example that failed.

With the semantic extra installed and model prepared, also compare actual model inference on the held-out requests:

```bash
bash scripts/test-backend.sh --semantic
```

This requires at least 85% exact agreement on the small authored intent set and improvement over the rules-only baseline. It also verifies four sample-track retrieval smoke cases with outbound sockets blocked; these are acceptance checks, not a general recommendation accuracy measurement. The intent evaluation report and remaining misses are recorded in [the walkthrough](docs/intent-understanding.md).

The native companion checks use a simulated backend by default. To run the existing fixture-based `--live`/`--live-backend` bridge checks, start the server with `MOCHI_CATALOG_MODE=sample`; they expect the fictional catalog. Real discovery has separate provider and recording-resolution checks.

## Discovery checks

```bash
bash scripts/test-discovery.sh
backend/.venv/bin/python scripts/validate-discovery.py --output docs/provider-validation.json
backend/.venv/bin/python scripts/evaluate-discovery.py
```

The native checks use mock responses to verify artist/version/ISRC matching, partial playback, nullable features, cancellation, feedback, reconnect and similar-song requests. Provider checks make read-only live requests; Last.fm needs your key. To check the real listening-request → More like this API flow without changing your taste profile or Spotify playback:

```bash
backend/.venv/bin/python scripts/verify-similar-discovery.py
```

To verify live artist autocomplete and favorite-based discovery with disposable storage:

```bash
backend/.venv/bin/python scripts/verify-artist-discovery.py --artist Drake --artist 'Frank Ocean'
```

The [artist setup probe](docs/artist-setup-validation.json) returned five recordings from those seed artists in 7.4 seconds, with no warnings, and rejected unknown BPM under strict filtering. Native checks cover skip/edit, saved choices, autocomplete cancellation, actual Add/Remove/Done buttons and card resizing. Relevance still needs listening and user feedback.

The [two-pass ranking probe](docs/two-pass-ranking-validation.json) checked The Weeknd across **Surprise me**, **Relaxing music**, and **Something more energetic** on October 13. Each returned five songs in 6.7–7.5 seconds, used 12 tag lookups, and prioritized candidates beyond the old first-12 cutoff. Unknown BPM still failed strict filtering. These are source/contract checks; the song choices have not been graded for relevance. Reranking considers the full remaining pool, so some final songs can still lack detailed song tags.

To verify live discovery modes without changing your profile or playback:

```bash
backend/.venv/bin/python scripts/verify-discovery-modes.py --artist 'The Weeknd'
```

The [October 15 mode probe](docs/discovery-modes-validation.json) returned five favorite-artist tracks in Familiar/Balanced and five outside-favorite tracks in Discover for **Surprise me**, in 6.3–8.6 seconds. All modes used 12 tag lookups; strict unknown BPM was rejected and **More like this** recovered its original mode. Counts reflect this small source/contract check, not guaranteed ratios or graded recommendation quality. Native checks cover real mode buttons, persistence, pending-request locks and the applied-mode label. The Xcode build passes.

The ranking evaluation defaults to clearly labeled fictional fixtures; [the discovery guide](docs/music-discovery.md) explains how to capture and manually judge real Last.fm candidates. Recorded smoke results are not a broad coverage or recommendation-accuracy claim.

## Project layout

```text
Mochi/
  Mochi.xcodeproj/        Native macOS project
  Mochi/                 SwiftUI interface, desktop windows, authentication and playback
Tests/                   Authentication, playback, search, backend and companion checks
scripts/                 Compile and run the checks
docs/spotify-auth.md     Authentication walkthrough
backend/                 Local FastAPI service and locked Python dependencies
design/                  Mascot, UI references, app icon source and previews
```

`SpotifyAuthModel` coordinates authentication independently of the view. The app owns this model, so dismissing the menu-bar panel does not cancel login. Tokens stay in Keychain; temporary verifier and state values stay in memory for the login attempt.

`SpotifyPlaybackClient.swift` contains the playback requests and the types used to read Spotify's responses. `SpotifyPlaybackModel` manages the displayed state, busy/error status, and control sequencing. `NowPlayingView` displays that state and calls the model when you click a button. The app owns both models, keeping authentication and playback separate from the interface.

`SpotifySearchClient.swift` searches the catalog and decodes track results. `SpotifySearchModel.swift` owns query/result state, cancellation, and selection, while obtaining tokens through the authentication model and starting tracks through the shared playback model. `MochiAppDelegate` owns authentication and playback for the whole app session and restores the connection at launch.

The smaller authentication helpers are grouped by their role:

- `SpotifyAuthorization.swift`: app configuration, login preparation, authorization URL, and PKCE.
- `SpotifyCallbackListener.swift`: receive and validate the browser callback.
- `SpotifyAuthTypes.swift`: saved-token data and authentication errors.
- `SpotifyTokenClient.swift`: exchange the authorization code and refresh tokens.
- `SpotifyTokenStore.swift`: save and load tokens in Keychain.
- `SpotifyAuthModel.swift`: coordinate the connection and expose its status to the UI.

Combined files use `MARK` sections for navigation in Xcode and VS Code. Swift types can share a file; they still have separate jobs.

`MochiCompanionController.swift` owns the native desktop panels, click/drag handling, screen placement, and saved visibility. `MochiCompanionView.swift` contains the card, request state, and vector drawing of the supplied character. `MochiArtistPreferences.swift` owns the compact editor, saved artist choices and debounced autocomplete. `MochiBackendClient.swift` sends listening/similar-song requests, artist searches and first-party feedback to Python. `backend/main.py` defines the health, discovery, artist-search and taste routes. Time-based poses reshape the body and animate the eyes, mouth, and hand independently; interaction state selects the greeting, held, and release reactions. The application delegate starts the companion at launch; it does not depend on opening the music menu first.

## Recommendation architecture

```text
Natural-language request
  → intent representation
  → Last.fm discovery + independent text matching
  → personalized ranking
  → Spotify track resolution
  → playback
```

Mochi owns relevance ranking over independent discovery candidates. The current heuristic combines text similarity, explicit likes/dislikes, artist affinity and repetition penalties. A trained ranking model remains a later experiment once enough first-party feedback exists to compare it with this baseline.

Live source and similar-song API checks now pass with the configured Last.fm key. Next are manual ranking judgments and a real-account recommendation-playback check. See [SPEC.md](SPEC.md) and [music discovery](docs/music-discovery.md) for implementation boundaries and remaining work.
