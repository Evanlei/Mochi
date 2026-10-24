# Private beta verification — October 23, 2026

Target: macOS 26+, Apple Silicon. This report distinguishes a reproducible build
and deterministic checks from live recommendation quality and actual playback.

## Passed

| Check | Result |
|---|---|
| `bash scripts/check.sh --ui` | Exit 0: backend, native contracts, auth, playback, local playback, search, discovery, session, engine, companion, Up Next, settings and Debug app build. |
| Python suites in that run | 17 backend/intent checks, 11 selection checks (one real-model case intentionally skipped), 46 discovery checks. The separate prepared-model run covered the skipped case. |
| Prepared-model selection checks | All 11 checks passed with the real local model and outbound sockets blocked. |
| Held-out intent evaluation | Hybrid 21/24 exact matches; rules 18/24. This is a small authored set, not a general quality estimate. |
| Real bundled engine fixture smoke | Starts without Python on PATH or any provider key; five fictional tracks with **semantic** ranking. The package refuses a silent lexical fallback. |
| Signed sandbox controller | Real child starts, reports model/configuration status, and exits with its owning controller. Foreign services and external engines are never terminated. |
| Frozen engine live Last.fm probe | Five real candidates, semantic ranking, 8.49 seconds, no warnings, disposable storage. BPM/vocals/energy remained unknown. No Spotify data entered this request. |
| Packaged native app | Opened, restored the saved Spotify connection, and displayed correct external-engine and model status in native Settings. |
| Packaging | Release app and `Mochi-private-beta-arm64.zip` built; deep/strict signature verification passed. App approximately 227 MB, archive 128 MB. Python license, dependency notices/inventory and tester guide are included. No `.env`, personal SQLite database or provider cache is bundled. |
| Native presentation | Companion, artwork fallback, artist editor, Up Next light/dark and settings rendered and inspected. Native panel checks cover keyboard input, cancellation, resizing, menu controls and old-batch feedback. |

## Live check findings

Submitting **relaxing pop** through the packaged app returned real Last.fm picks
using the saved artist preferences. Matching completed, but an overlapping
background Now Playing read initially caused the automatic start to return
“Playback is busy.” This race was fixed: starts and queue appends wait for a
passive read, while actual playback mutations remain serialized. A bounded wait
retains cancellation, reset, route and account checks; uncertain writes are never
retried.

After that fix, playback, local-playback and continuous-session regressions passed
again, including a new delayed-read/start/queue/disconnect case, and the Release
app/archive were rebuilt. The retry correctly reported no active Spotify player.
Spotify was then opened and a candidate start was accepted, but the expected
recording was not consistently confirmed by the desktop player. The managed
session stopped instead of extending an unconfirmed session. **Actual playback
and continuous queue behavior remain unverified on this account.** An ambiguous
Starboy match also retained the explicit Find on Spotify fallback; no uncertain
recording was forced through the matcher.

The broad discovery probe is an access/runtime check. It does not establish that
the five picks are relaxing or that they match a listener's taste. Human relevance
judgments, long listening sessions, real Automation permission flows and testing
on another Mac remain necessary before inviting testers to rely on the app.

## Distribution gates

This artifact is an ad-hoc signed development beta. It has not been notarized or
tested as a quarantined download on a clean recipient Mac. The GitHub workflow
has been committed but has not run remotely. No release was uploaded or published.

API matching and queues remain subject to Spotify's development allowlist;
desktop controls do not broaden API access. Public distribution also needs the
provider review and signing work described in [the tester guide](PRIVATE_BETA.md).

The generated runtime reports are `build/beta/bundle-validation.json` and
`build/beta/live-engine-validation.json`. Build/test logs and native previews
were retained under `/private/tmp` for this verification session; they contain
fixture data and credential-free summaries. Keys and tokens were never printed.
