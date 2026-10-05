# Spotify connection walkthrough

Mochi uses OAuth Authorization Code with PKCE to obtain permission to read and control Spotify playback. PKCE protects the authorization-code exchange; it is one part of the complete connection flow.

## Try the connection

1. In the Spotify developer dashboard, register exactly `http://127.0.0.1:8888/callback` for the Client ID in `SpotifyConfiguration.swift`.
2. Open `Mochi/Mochi.xcodeproj` and run the Mochi scheme on My Mac. Run only one copy while connecting, since port 8888 is fixed.
3. Open the music-note menu-bar panel and click **Connect Spotify**.
4. Sign in and approve the permissions on Spotify's own page.
5. The browser will show that Spotify answered Mochi. Return to the panel and wait for **Spotify connected.** That status appears only after token exchange and Keychain storage succeed.
6. Quit and relaunch the app. Opening the panel restores the saved connection, refreshing the access token if necessary.

Declining access leaves Mochi disconnected. **Cancel** stops the pending login. A login times out after three minutes. **Disconnect** deletes Mochi's local saved tokens; it does not revoke the app's grant on Spotify. To revoke the grant remotely, remove Mochi from the connected-apps page of your Spotify account.

The music request button still displays the submitted prompt. Track search, recommendation and playback services are separate future work.

## What happens when you connect

1. `SpotifyLoginAttempt.prepare()` makes a random **verifier**, derives its SHA-256 **challenge**, generates a separate random **state**, and builds the authorization URL.
2. `SpotifyCallbackListener` starts a small HTTP listener bound only to IPv4 loopback (`127.0.0.1`) on port 8888. It waits until the port is ready before opening the browser. This avoids approving access before Mochi is ready to receive the answer.
3. The browser visits Spotify's HTTPS authorization endpoint. The URL contains the public Client ID, requested permissions, redirect URI, challenge and state. It contains no verifier or tokens.
4. You approve or decline on Spotify's page. Mochi never asks for or receives your Spotify password.
5. Spotify redirects the browser to Mochi's local callback address with an authorization code and state, or an error and state.
6. `SpotifyCallback` checks the HTTP method, callback path, absence of duplicate/ambiguous parameters, and matching state. An unrelated request or wrong state receives an error response without consuming the login attempt.
7. After a valid callback, the listener closes. `SpotifyTokenClient` submits the code and original verifier directly to Spotify's HTTPS token endpoint. It also sends the Client ID and exactly the same redirect URI; it sends no client secret.
8. Spotify hashes the submitted verifier and compares the result with the earlier challenge. It does not reverse a hash. If the exchange passes Spotify's checks, its response contains an access token, refresh token, expiry and permissions.
9. Mochi validates the response and saves the tokens in macOS Keychain. Only then does the UI say it is connected.

## Keep these values separate

| Value | Job | Where it goes |
| --- | --- | --- |
| Client ID | Identifies the app, not the user | Authorization URL and token requests; public |
| Verifier | Secret proof for this login attempt | Kept in memory until sent to the HTTPS token endpoint |
| Challenge | Fingerprint of the verifier | Authorization URL; not secret |
| State | Associates the callback with our login attempt | Authorization URL and callback, compared locally |
| Authorization code | Temporary ticket after approval | Browser callback, then HTTPS token exchange |
| Access token | Pass for approved API operations | Keychain, then future API Authorization headers |
| Refresh token | Obtains a replacement access token | Keychain and HTTPS token endpoint |

PKCE protects a stolen authorization code from being redeemed without the verifier. It does not protect an already-stolen access token. HTTPS protects the verifier and token exchange in transit; Keychain stores tokens outside the repository.

## State ownership and asynchronous code

`MochiApp` owns one `SpotifyAuthModel` through `@StateObject`. `ContentView` observes it with `@ObservedObject`. The model's `@Published` properties drive the status text, progress indicator and buttons. Closing the panel does not destroy the app-owned model or its login task.

`async`/`await` lets the code wait for the browser response or Spotify's network response without blocking the UI. The listener uses a checked continuation to turn connection callbacks into one awaited result. Every success, failure, timeout and cancellation resumes that result once and cleans up the listener and connections.

The model tracks an operation generation so an old cancelled operation cannot overwrite a newer login. It shares an in-flight refresh task so concurrent callers do not independently refresh the same credentials.

## Later API requests

Playback services will ask `SpotifyAuthModel.validAccessToken()` for a token. It reuses an access token when more than 60 seconds remain, otherwise refreshes it over HTTPS. If Spotify omits a replacement refresh token, Mochi keeps the previous one. If Spotify returns `invalid_grant`, Mochi deletes the saved tokens and asks you to reconnect. Temporary network failures do not erase saved credentials.

Spotify currently documents a six-month refresh-token lifetime from original authorization; refreshing does not reset that lifetime. The implementation handles invalidation through `invalid_grant`, rather than assuming refresh tokens last forever.

## Checks and limits

Run `bash scripts/test-auth.sh` for the RFC PKCE reference vector, verifier generation, URL parameters, callback validation, real loopback requests, timeout/cancellation, mocked token exchange/refresh, and full simulated login/restoration tests. `bash scripts/test-auth.sh --keychain` also checks a unique temporary Keychain entry using fake tokens and deletes it afterward.

The app builds and the automated checks pass. Live approval with your Spotify account is a manual verification step. The network entitlements permit outbound HTTPS and an inbound listener while preserving App Sandbox; the code binds the listener to loopback only.

## Official references

- [Spotify PKCE flow](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow)
- [Redirect URI requirements](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri)
- [Refreshing tokens](https://developer.spotify.com/documentation/web-api/tutorials/refreshing-tokens)
- [Refresh-token expiration](https://developer.spotify.com/blog/2026-06-18-refresh-token-expiration)
- [Playback permissions](https://developer.spotify.com/documentation/web-api/concepts/scopes)
