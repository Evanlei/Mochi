# Mochi

A native macOS menu-bar music companion, built with Swift and SwiftUI. Mochi is being developed to turn natural-language listening requests into personalized recommendations, with Spotify providing playback.

The native shell and Spotify authorization flow are implemented. Recommendation retrieval, ranking, and playback integration are still planned.

## Current functionality

- Menu-bar panel with a music-request text field.
- Submission by button or Return, including validation for blank and whitespace-only requests.
- Spotify Authorization Code with PKCE, using the system browser and a local callback listener.
- Callback state validation, cancellation, timeout, and connection-status messages.
- HTTPS token exchange, access-token refresh, and secure token storage in macOS Keychain.
- Restoration of a saved connection when the panel opens after relaunch.
- Local disconnect that removes Mochi's saved tokens.

**Find Music currently displays your submitted request. It does not recommend tracks or start playback yet.** Automated authentication checks pass using simulated Spotify responses; live login with a Spotify account still needs manual verification.

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

3. Set your app's Client ID in [SpotifyConfiguration.swift](Mochi/Mochi/SpotifyConfiguration.swift). The Client ID is public; PKCE does not require a client secret.
4. Run one copy of Mochi, open the panel, and click **Connect Spotify**.
5. Sign in and approve the requested playback permissions on Spotify's page.
6. Return to Mochi and wait for **Spotify connected.**

The listener binds only to `127.0.0.1`, on your own computer. If port 8888 is occupied, close another copy of Mochi or the application using that port and retry. Login times out after three minutes; **Cancel** stops it sooner.

**Disconnect** deletes locally stored tokens. To revoke Spotify's permission grant as well, remove Mochi from the connected-apps page in your Spotify account.

For the code walkthrough, security model, refresh behavior, and official references, see [Spotify authentication](docs/spotify-auth.md).

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

## Project layout

```text
Mochi/
  Mochi.xcodeproj/        Native macOS project
  Mochi/                 SwiftUI interface and Spotify authentication
Tests/AuthChecks.swift   Authentication checks
scripts/test-auth.sh     Compiles and runs the checks
docs/spotify-auth.md     Authentication walkthrough
backend/                 Reserved for the planned Python service
```

`SpotifyAuthModel` coordinates authentication independently of the view. The app owns this model, so dismissing the menu-bar panel does not cancel login. Tokens stay in Keychain; temporary verifier and state values stay in memory for the login attempt.

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

Next milestones are live Spotify authentication verification, track search and resolution, playback control, and communication with the Python backend.
