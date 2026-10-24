# Mochi private beta

Mochi is a native desktop music companion for macOS 26 or newer. The supplied
archive targets the architecture in its filename; `arm64` is for Apple Silicon.
It includes the local music engine and semantic model. Python and Xcode are not
needed to run the bundled build.

## First launch

1. Copy `Mochi.app` to Applications and open it. The music-note menu opens the player;
   clicking the floating Mochi opens the request card.
2. Open the player's `…` menu, then **Setup & Settings**. The bundled engine starts
   automatically. If you already started a development backend, Mochi uses it and
   leaves that process under your control.
3. Add a Last.fm **API key** in settings. Get one at
   https://www.last.fm/api/account/create. The bundled app saves it in macOS Keychain.
   An external development backend continues to use its own `backend/.env`.
4. Install/open Spotify and choose **Use desktop controls** from the player's `…`
   menu. Approve macOS Automation access when requested.
5. For automatic matching and continuous queues, ask the app owner to add your
   Spotify account to the development app's allowlist, then connect the Spotify
   API. Spotify Premium is required. Desktop controls and copied track links work
   without this API login; discovery results offer **Find on Spotify**.
6. Pick one to three favorite artists or skip setup, then describe a listening
   session. **Picks** contains recommendations/actions; **Up Next** shows the current
   song and confirmed upcoming songs. Songs still being matched are omitted.

## Daily use

- Like/dislike, read **Why this song**, or choose **More like this** from a song's `…`
  menu, including the current and upcoming songs in Up Next. Feedback shapes future
  recommendations; it does not remove songs already accepted by Spotify.
- **Recent sessions** in the companion's listening-options menu reuses a request and
  discovery mode with your current favorite artists. Twelve requests are retained
  on this Mac. Repeating a request makes a fresh selection.
- Spotify pause is respected. **Stop continuous listening** stops future refills;
  accepted queued songs can keep playing. A different song/device in Spotify ends
  the managed session. Starting Mochi does not automatically resume old music.
- Artwork follows Now Playing. Missing artwork uses the music-note/waveform fallback.
- **Check / Start engine** retries setup; **Restart engine** restarts only the engine
  this app owns. Closing Mochi stops its child engine. An externally started service
  is never killed by Mochi.

## Data and troubleshooting

Keys/tokens are stored in Keychain. Favorite artists and recent requests use native
local preferences; feedback/context and provider caches use local SQLite in the
app's Application Support container. Provider caches are replaceable and bounded.
**Clear recent list** clears the native request list; **Forget taste memory** clears
backend feedback/context, favorite artists and recent requests after deletion succeeds.

Last.fm receives discovery lookups. Spotify receives matching/playback requests.
Spotify payloads do not reach the recommendation model. There is no cloud account
service, background telemetry or startup playback.

If discovery says no matches, try fewer strict requirements: unknown BPM/vocals/energy
cannot qualify. An uncertain recording can be retried by clicking its title in Picks;
use **Find on Spotify** when it still cannot be confirmed. API 403 usually means missing
allowlist/Premium access; 429 means wait before retrying. The engine detects an
unrecognized service on port 8000 instead of taking it over.

## Release status

This is an ad-hoc signed private development beta, not a notarized public download.
macOS may require the recipient to review its app-opening prompt. Do not disable
system security globally. For normal public downloads, the maintainer must sign
with Developer ID, notarize the app and resolve provider distribution requirements.

Spotify development mode allows five authenticated accounts:
https://developer.spotify.com/documentation/web-api/concepts/quota-modes

Last.fm's terms require written approval before public access to pages using its
web services; public distribution is a provider-review gate:
https://www.last.fm/api/tos

The build includes passing fixture-based engine, model, native UI and playback
checks. Real-account queue behavior and recommendation relevance require listening
tests. Report the prompt, control mode, expected behavior and visible error; keep
credentials out of reports.

## Reproduce from source

```bash
bash scripts/setup.sh
bash scripts/run-mochi.sh
# Run Mochi from Xcode with Command-R.
bash scripts/check.sh --ui
MOCHI_ENGINE_SANDBOX=1 bash scripts/test-engine.sh
backend/.venv/bin/python scripts/build-beta.py
```

The final archive, app, fixture validation report and dependency notices are under
`build/beta`. Packaging uses explicit model/fixture inputs and refuses `.env` or
SQLite files inside the app bundle.
