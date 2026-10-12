# Local Spotify desktop controls

Mochi can control the installed Spotify Mac app without Spotify Web API login. Open Spotify and start a song, then choose **Use desktop controls** in Mochi's menu-bar panel. macOS may ask to let Mochi control Spotify. Grant that permission yourself. If denied, enable Spotify under **System Settings → Privacy & Security → Automation → Mochi**, then choose the action again.

Desktop mode supports Now Playing, play, pause, next, previous and starting one known track. Paste a canonical `https://open.spotify.com/track/...` link or `spotify:track:...` URI into **Spotify track link**, then click **Play link**. Album, playlist, episode and shortened links are rejected. Spotify must be running; Mochi does not launch it during background checks. Spotify's account, subscription, availability and playback restrictions still apply; local events do not promise unrestricted streaming or offline access.

## Recommendation flow without API login

```text
Session request → local FastAPI → Last.fm discovery → Mochi ranking
  → song's … menu → Find on Spotify → user chooses a recording
  → copy its track link → Mochi's Play link → local Spotify playback
```

The public search link is a handoff, not a verified catalog match or an automatic playback command. No scraping or simulated Spotify search clicks are introduced. This flow does not require the user to join Spotify's five-user development allowlist. Last.fm discovery still requires internet and the backend key, and its public-use requirements remain unresolved.

If an API beta user optionally connects **Spotify API**, the existing conservative search resolver remains available. It checks title, artist, version and available recording identifiers. In desktop mode only the first confirmed recommendation starts; other matched rows have individual play buttons. In Web API mode the existing ranked multi-track playback remains available. Change modes through **Choose Spotify controls**. Switching modes cancels recommendation/search work and clears its transient results so a late response cannot start a different route.

## Implementation

`LocalSpotifyClient` sends the fixed Apple Events published by Spotify's installed `Spotify.sdef`, using `NSAppleEventDescriptor`. This is the transport used by AppleScript and ScriptingBridge, with no generated script, shell process, arbitrary command evaluation or OAuth token. Only Spotify's bundle identifier is targeted. Track IDs must contain exactly 22 ASCII letters/digits and are sent as data parameters.

Permission is requested only by **Use desktop controls**. Restoring desktop mode and refreshing check existing permission with prompting disabled. Blocking event work runs away from the main actor; each event has a two-second reply timeout. Cancellation is checked before dispatch and stale responses are ignored. A command already dispatched cannot be recalled, so uncertain failures never automatically repeat a skip. Acknowledged controls whose refresh fails remain reported as accepted, with stale controls disabled until a successful read.

`SpotifyPlaybackModel` owns both transports' shared busy state and displayed snapshot. Only the chosen mode handles a command: there is no silent fallback to API playback. Desktop mode refreshes every five seconds while the app runs, skips overlapping requests, and updates the existing mascot playback subscription. The chosen mode persists in local preferences; permission remains managed by macOS. Current song/artist metadata stays in native display state and is not sent to the backend, used to infer favorite artists, or ingested into the semantic model.

The app retains App Sandbox and adds the Apple Events entitlement, an Automation usage description, and only Spotify's `com.spotify.playback` / `com.spotify.library` scripting access groups. These groups are declared by the installed Spotify 1.3.0.277 dictionary. Dispatch uses the running Spotify process address to avoid relaunching it during a quit race. No broad Apple Events temporary exception or Accessibility permission is needed by the production feature. The desktop device label identifies the app being controlled; the scripting interface does not identify the active audio output or promise remote-device routing.

## Verification and remaining checks

```bash
bash scripts/test-local-playback.sh
bash scripts/test-playback.sh
bash scripts/test-discovery.sh
bash scripts/test-companion.sh /private/tmp/MochiLocalPreview
```

Isolated checks cover link validation, exact event addresses/codes, playing/paused/stopped decoding, permission denial, timeouts, one-track limits, route persistence, late responses, no-token/no-HTTP controls, independent discovery and optional API resolution into desktop playback. Native accessibility tests activate the desktop action against a fake player and render the menu. Existing Web API control and search tests are retained. They do not control the real Spotify app or grant Automation permission.

The Xcode Debug build succeeds, and its signed entitlements and merged usage description were inspected. Real app permission, snapshot response, play/pause/skip and known-URI playback still need a user-assisted live check. Successful mock checks are not evidence of Free-account behavior, remote-device routing or compatibility with every future Spotify release. The installed dictionary has no search, top-artist history, catalog resolution or queue command. Favorite artist/genre setup is a separate next feature.

References: [Spotify on its original AppleScript interface](https://engineering.atspotify.com/2022/4/spotifys-player-api), [Apple Events usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription), [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events), [sandboxed scripting access groups](https://developer.apple.com/library/archive/qa/qa1888/_index.html), [Spotify API quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes), [Last.fm terms](https://www.last.fm/api/tos).
