# Mochi

<img src="design/mochi-app-icon.png" alt="Mochi: a sage blob with oval eyes and a tiny smile on warm cream" width="112" height="112">

A native macOS music companion, built with Swift and SwiftUI. A small floating Mochi collects listening requests, while the menu-bar panel controls Spotify playback. Mochi is being developed to turn those requests into personalized recommendations.

The floating companion, listening-request card, local Python backend connection, Spotify authorization, catalog search, selected-track playback, Now Playing display, and basic playback controls are implemented. Recommendation retrieval and ranking are still planned.

## Current functionality

- A draggable sage Mochi character, matching the supplied SVG artwork.
- Click Mochi to open or close a compact listening-request card.
- Focus, Unwind, and Surprise me choices, plus a text input with Send and Return submission.
- Listening text sent asynchronously to a local FastAPI backend, with validation and confirmation.
- Loading, reset/cancellation, and retry messages; confirmed requests retained while the app runs.
- Song and artist searches in the companion card, with up to five matching tracks and click-to-play results.
- Loading, cancellation, empty-result, unavailable-track, and connection/error states for search.
- Saved desktop position and visibility, plus Show/Hide Mochi and Quit in the menu-bar panel.
- Spotify Authorization Code with PKCE, using the system browser and a local callback listener.
- Callback state validation, cancellation, timeout, and connection-status messages.
- HTTPS token exchange, access-token refresh, and secure token storage in macOS Keychain.
- Restoration of a saved connection at app launch, even before the menu-bar panel opens.
- Local disconnect that removes Mochi's saved tokens.
- Now Playing with the song, artist, playing/paused status, and Spotify device.
- Play/pause, previous, next, and manual Refresh controls.
- Refresh when the panel opens or connects, and after a playback command.
- Clear messages for unavailable players, restricted controls, connection failures, and rate limits.

**Mood requests now reach the local Python backend, which validates and echoes the text and detects an explicit vocal preference. They do not generate recommendations or start playback yet. Search mode separately finds specific songs or tracks by an artist and plays a result you choose.** Live Spotify login, connection restoration, and the original playback controls have been manually confirmed. Search and selected-track playback are covered by simulated API and native UI checks; a live account check is still needed.

## Requirements

- macOS 26 or later.
- Xcode with the macOS SDK and Swift toolchain. The project has been built with Swift 6.4.
- Spotify Premium and a registered Spotify developer app for live authentication.
- Python 3.12 or later and [uv](https://docs.astral.sh/uv/) for the local listening-request backend.

Most source editing can be done in VS Code. Xcode provides the native project, build tools, signing, and debugger.

## Run Mochi

1. Open `Mochi/Mochi.xcodeproj` in Xcode.
2. Select the **Mochi** scheme and **My Mac** destination.
3. Build and run with **Command-R**.
4. Click the music-note icon in the macOS menu bar to open the panel.
5. Mochi appears near the bottom-right of your desktop on first launch. Click the character to open the listening-request card. If you previously hid it, click **Show Mochi** in the menu-bar panel.

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

In a separate VS Code terminal, from the repository root:

```bash
cd backend
uv sync
uv run fastapi dev main.py
```

Leave the terminal running while using listening requests. **Control-C** stops it. Saving Python changes reloads the development server. It listens on your computer at `127.0.0.1:8000`; no AWS service is needed.

Open [the API testing page](http://127.0.0.1:8000/docs) or [the health check](http://127.0.0.1:8000/health). Then run Mochi, click the character, and send a mood request or choose Focus, Unwind, or Surprise me. The card shows a loading indicator, followed by **Request received. Recommendations are coming next.** The summary contains the text Python confirmed.

If the server is stopped, Mochi keeps your text and asks you to start the backend and retry. Send is disabled during a pending request; the reset button cancels it. Spotify search and playback use their existing direct Spotify connection independently.

See [the backend walkthrough](docs/backend.md) for the request flow, code roles, API contract, and current limits.

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

1. Connect Spotify in Mochi.
2. Open Spotify on your preferred device and start a song.
3. Open Mochi's menu-bar panel. Click the circular-arrow **Refresh** button if needed.
4. Use **Previous**, **Play/Pause**, or **Next**. Mochi targets the device shown in the panel and reads the updated playback state after Spotify accepts the command.

Mochi takes a snapshot when the panel opens, after a control action, or when you click Refresh. It does not continuously poll Spotify. If you change tracks or devices elsewhere, click Refresh before using the controls. Spotify may take a moment to reflect a command; Refresh can fetch a newer result.

Controls are disabled while a request is running, when Spotify reports restrictions, or when there is no usable playback state. A failed refresh marks the displayed information as old and disables controls until a successful refresh. If Spotify limits requests, wait for the indicated delay before refreshing.

The playback client gets its access token from the existing authentication model. Expired tokens refresh automatically; an explicit token rejection triggers one refresh and retry. Uncertain failures such as a timeout do not repeat a skip command.

## Floating Mochi

Mochi breathes with a gentle change in body shape, blinks, and glances around, with no ground shadow. About every 26 seconds while idle, it crouches, jumps with smiling eyes, and makes a squishy landing. Hovering or dragging restarts that idle wait. Hovering triggers an exaggerated cartoon squash-and-stretch greeting, smiling eyes, and a hand wave. Holding or dragging stretches its body with a surprised face; releasing it triggers a soft settling bounce. While Spotify’s last known playback state is playing, Mochi dances with big side-to-side leans, rhythmic squash-and-stretch bounces, alternating hand swings, and happy eyes instead of idle jumps. The dance uses its own steady rhythm. This follows the existing control/Refresh results, including while the menu is closed; it does not poll Spotify in the background. After 90 seconds without interaction, Mochi gradually falls asleep with closed eyes, slower breathing, and floating z’s; the dance and idle jumps stop. Hovering wakes it with a stretch and blink before its greeting. Mochi stays awake while its card is open. Animation pauses when hidden; macOS Reduce Motion uses static awake/asleep poses and static z’s. The compact 300 × 180-point card uses a soft sage, translucent, blurred background; Reduce Transparency gives it a solid background.

- **Drag** the character to move it. Its position is saved between launches.
- **Click** the character to open or close the card. Dragging does not also open it.
- Choose **Focus**, **Unwind**, or **Surprise me**, or type your own mood, artist, or song. Click the arrow or press **Return** to submit.
- Mochi asks for another preference after the first submission. These are fixed local prompts, ready for a future discovery service.
- Click the reset arrow to start a **new listening request**.
- Press **Escape**, click the close button, or click outside the card to dismiss it. Closing retains your draft and preferences during this app session.
- Use **Hide Mochi / Show Mochi** in the menu-bar panel. Hiding also closes the card; visibility is remembered after quitting.

The companion stays above ordinary windows and joins desktop Spaces. Its card opens above the character when space permits, below it near the top edge, and stays within the display's usable area. If a remembered display is disconnected, Mochi moves back onto an available display. Spotify controls remain in the menu bar.

Your listening preferences are currently kept in memory and cleared when the app quits. Only the character's position and visibility are saved in local app preferences.

## Find and play a song

1. Connect Spotify from the menu-bar panel, and open Spotify on your preferred device. Start a song there once if Spotify has no active player.
2. Click Mochi, then the **magnifying glass** in its card.
3. Choose **Songs** and enter a title, or choose **Artists** and enter an artist's name to find matching tracks.
4. Press **Return** or click the search button. Mochi searches once per submission, not on every keystroke.
5. Click a result to play that track. The small external-link button opens its Spotify page.
6. Use the speech-bubble button to return to your listening request.

Search mode expands the same translucent card to 300 × 340 points, with a scrollable result list. Returning to the listening request restores its 300 × 180-point size and retains your preferences. Closing the card retains search results during the session. Disconnecting clears account results and cancels pending work.

Mochi uses Spotify's [catalog search](https://developer.spotify.com/documentation/web-api/reference/search) with five results and the connected user's market. Artist mode searches tracks with Spotify's `artist:` filter. You choose the result; Mochi does not assume the first match is correct. Tracks explicitly marked unavailable are disabled. Spotify may omit optional metadata, which Mochi tolerates.

Choosing a track reads the active playback device, then sends its URI to Spotify's [Start/Resume Playback endpoint](https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback). This requires Premium and the existing `user-modify-playback-state` permission; no extra login scopes were added. Search and menu controls share playback sequencing. Mochi refreshes Now Playing after Spotify accepts the track; if confirmation fails, it reports that the command was accepted but its result could not be refreshed. It does not automatically repeat uncertain playback failures.

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

The Python tests check vocal and energy preferences, unspecified preferences, uppercase input, combined requests, trimming, Unicode, input limits, malformed JSON, and the documented response format. Failures identify the test and example that failed.

The native companion checks use a simulated backend by default. With the development server running, `bash scripts/test-companion.sh --live-backend` exercises Return submission through the real backend and confirms the response appears in the card.

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

`MochiCompanionController.swift` owns the native desktop panels, click/drag handling, screen placement, and saved visibility. `MochiCompanionView.swift` contains the card, request state, and vector drawing of the supplied character. `MochiBackendClient.swift` sends listening text to Python and reads its confirmation. `backend/main.py` defines the health and listening-request routes. Time-based poses reshape the body and animate the eyes, mouth, and hand independently; interaction state selects the greeting, held, and release reactions. The application delegate starts the companion at launch; it does not depend on opening the music menu first.

## Planned recommendation architecture

```text
Natural-language request
  → intent representation
  → semantic candidate retrieval
  → personalized ranking
  → Spotify track resolution
  → playback
```

Mochi will own retrieval and ranking, rather than asking an LLM to invent a track list. The initial Python/FastAPI connection is implemented; recommendation logic will begin with a transparent heuristic ranking baseline before introducing a learned model. Feedback collection and evaluation will guide later improvements.

Next is the Python backend and its API contract with the native client. Semantic retrieval, personalized ranking, and confidence-based resolution of independently recommended tracks remain planned.
