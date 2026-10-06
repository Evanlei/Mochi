# Mochi

A native macOS music companion, built with Swift and SwiftUI. A small floating Mochi collects listening requests, while the menu-bar panel controls Spotify playback. Mochi is being developed to turn those requests into personalized recommendations.

The floating companion, listening-request card, Spotify authorization, Now Playing display, and basic playback controls are implemented. Recommendation retrieval and ranking are still planned.

## Current functionality

- A draggable sage Mochi character, matching the supplied SVG artwork.
- Click Mochi to open or close a compact listening-request card.
- Focus, Unwind, and Surprise me choices, plus a text input with Send and Return submission.
- Local follow-up prompts and a summary of your preferences, retained while the app runs.
- Saved desktop position and visibility, plus Show/Hide Mochi and Quit in the menu-bar panel.
- Spotify Authorization Code with PKCE, using the system browser and a local callback listener.
- Callback state validation, cancellation, timeout, and connection-status messages.
- HTTPS token exchange, access-token refresh, and secure token storage in macOS Keychain.
- Restoration of a saved connection when the panel opens after relaunch.
- Local disconnect that removes Mochi's saved tokens.
- Now Playing with the song, artist, playing/paused status, and Spotify device.
- Play/pause, previous, next, and manual Refresh controls.
- Refresh when the panel opens or connects, and after a playback command.
- Clear messages for unavailable players, restricted controls, connection failures, and rate limits.

**The companion currently collects preferences with simple local prompts. It does not use an AI service, recommend tracks, or start playback from those requests yet.** Live Spotify login, connection restoration, and playback controls have been manually confirmed. Automated authentication and playback checks use simulated Spotify responses.

## Requirements

- macOS 26 or later.
- Xcode with the macOS SDK and Swift toolchain. The project has been built with Swift 6.4.
- Spotify Premium and a registered Spotify developer app for live authentication.

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

Mochi gently bobs and blinks, with no ground shadow, and makes a small hop when the pointer enters its area. Animation pauses when hidden or dragged, and turns off when macOS Reduce Motion is enabled. The compact 300 × 180-point card uses a soft sage, translucent, blurred background; Reduce Transparency gives it a solid background.

- **Drag** the character to move it. Its position is saved between launches.
- **Click** the character to open or close the card. Dragging does not also open it.
- Choose **Focus**, **Unwind**, or **Surprise me**, or type your own mood, artist, or song. Click the arrow or press **Return** to submit.
- Mochi asks for another preference after the first submission. These are fixed local prompts, ready for a future discovery service.
- Click the reset arrow to start a **new listening request**.
- Press **Escape**, click the close button, or click outside the card to dismiss it. Closing retains your draft and preferences during this app session.
- Use **Hide Mochi / Show Mochi** in the menu-bar panel. Hiding also closes the card; visibility is remembered after quitting.

The companion stays above ordinary windows and joins desktop Spaces. Its card opens above the character when space permits, below it near the top edge, and stays within the display's usable area. If a remembered display is disconnected, Mochi moves back onto an available display. Spotify controls remain in the menu bar.

Your listening preferences are currently kept in memory and cleared when the app quits. Only the character's position and visibility are saved in local app preferences.

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

Run this in a logged-in macOS desktop session. The checks briefly show native test windows and verify screen-edge placement, multiple/removed displays, accessible click toggling, keyboard focus, typing, Return submission, Escape dismissal, and position/visibility restoration. They use a unique temporary preferences domain and remove it afterward; they do not use Spotify credentials or modify real playback.

To also render the actual SwiftUI card and character for inspection:

```bash
bash scripts/test-companion.sh /private/tmp/MochiCompanionPreview
```

## Project layout

```text
Mochi/
  Mochi.xcodeproj/        Native macOS project
  Mochi/                 SwiftUI interface, desktop windows, authentication and playback
Tests/                   Authentication, playback and companion checks
scripts/                 Compile and run the checks
docs/spotify-auth.md     Authentication walkthrough
backend/                 Reserved for the planned Python service
design/                  Supplied mascot and companion UI SVG references
```

`SpotifyAuthModel` coordinates authentication independently of the view. The app owns this model, so dismissing the menu-bar panel does not cancel login. Tokens stay in Keychain; temporary verifier and state values stay in memory for the login attempt.

`SpotifyPlaybackClient.swift` contains the playback requests and the types used to read Spotify's responses. `SpotifyPlaybackModel` manages the displayed state, busy/error status, and control sequencing. `NowPlayingView` displays that state and calls the model when you click a button. The app owns both models, keeping authentication and playback separate from the interface.

The smaller authentication helpers are grouped by their role:

- `SpotifyAuthorization.swift`: app configuration, login preparation, authorization URL, and PKCE.
- `SpotifyCallbackListener.swift`: receive and validate the browser callback.
- `SpotifyAuthTypes.swift`: saved-token data and authentication errors.
- `SpotifyTokenClient.swift`: exchange the authorization code and refresh tokens.
- `SpotifyTokenStore.swift`: save and load tokens in Keychain.
- `SpotifyAuthModel.swift`: coordinate the connection and expose its status to the UI.

Combined files use `MARK` sections for navigation in Xcode and VS Code. Swift types can share a file; they still have separate jobs.

`MochiCompanionController.swift` owns the native desktop panels, click/drag handling, screen placement, and saved visibility. `MochiCompanionView.swift` contains the card, its local request state, and vector drawing of the supplied character. The application delegate starts the companion at launch; it does not depend on opening the music menu first.

## Planned recommendation architecture

```text
Natural-language request
  → intent representation
  → semantic candidate retrieval
  → personalized ranking
  → Spotify track resolution
  → playback
```

Mochi will own retrieval and ranking, rather than asking an LLM to invent a track list. The planned backend uses Python and FastAPI, with a transparent heuristic ranking baseline before introducing a learned model. Feedback collection and evaluation will guide later improvements.

Next milestones are track search and resolution, conversational discovery, and communication with the Python backend.
