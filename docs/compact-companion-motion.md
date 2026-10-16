# Compact companion and motion

The selected design is **B — composer first** from the [design studies](../design/prototypes/compact-ui/index.html). The native SwiftUI implementation calls the real existing models; the HTML study remains a simulated design reference.

## UI and interaction choices

- A 300 × 150-point idle card keeps the prompt and presets close. Discovery modes live in a native popover instead of a permanent row. The extra click buys desktop space; the current mode stays visible.
- Results/search expand to 300 × 340. The batch's applied mode remains separate from the next-request choice. Song rows use separators, readable artist/title hierarchy and labeled feedback/options controls. Unknown musical measurements are omitted, never invented.
- Favorite artists still save immediately. Familiar/Discover require a favorite, and controls remain locked during pending work. Closing the mode popover returns focus to the composer.
- Cancel keeps the draft, stops pending discovery, and rejects late responses through the existing generation guard. Canceling refinement preserves the current songs. New request remains a separate reset action.

## Motion review

| Before | After | Why |
| --- | --- | --- |
| Abrupt panel appearance/disappearance | 160 ms entry and 100 ms exit fades | Clear, quick presentation without delaying input |
| Instant native card size changes | 180 ms AppKit resize with ease-out; immediate reposition when changing screen side | Keep the real window aligned with its content without crossing the character |
| No expression for the current request | Curious draft pose, thinking request pose, happy playback-start squish | Communicate activity through the character as well as visible status text |
| Restarting a reaction could snap to its first frame | Activity weights retarget from their current values over 220 ms | Cancel/retry and rapid edits preserve continuity |
| Uniform control feedback | Small spring press/release on presets and Send | Give tactile feedback while Return still submits directly |

**Verdict: Approve the implementation checks.** Motion is bounded, interruptions and stale close completion are tested, and Reduce Motion is respected. Native window resizing is an intentional exception to the web guidance to animate only transforms/opacity: the small borderless window must physically match the new content size. It uses AppKit's animator for a short transition rather than a continuous layout loop. The mascot's existing Canvas renderer remains at 30 fps; no animation framework or dependency was added.

The idle jump, hover/wave, drag/stretch, music dance and sleeping z's are preserved. Thinking and curiosity yield to held/sleeping poses. An active greeting releases into the activity expression rather than ending with a pose snap. Repeated typing within a nonempty draft does not retrigger a greeting. Hidden characters stop animating. Reduce Motion keeps static activity expressions and skips window movement/fades; Reduce Transparency uses the existing solid material.

The 800 ms playback reaction is character expression rather than blocking UI motion. The discovery spinner/status and Cancel remain usable throughout. Dance rhythm is decorative and is not inferred from the song's tempo.

## Guidance used

The bundled Emil Kowalski Motion and Review Animations skills informed the timing, interruption, small press transforms and accessibility review. The catalog's Apple HIG and SwiftUI Design entries are pointers to upstream packages, not full installed workflows; they were not treated as complete local skills. Native decisions were checked against [Apple's motion guidance](https://developer.apple.com/design/human-interface-guidelines/motion) and [AppKit animation completion behavior](https://developer.apple.com/documentation/appkit/nsanimationcontext/completionhandler).

## Verification

- `bash scripts/test-companion.sh /private/tmp/mochi-compact-native-preview`: actual native accessibility actions, typing/Return/Escape, dropdown choices/gating, saved mode, result expansion, artist editing, feedback and refinement, close/reopen during a fade, Cancel and late-response rejection. Providers/playback use mocks.
- Pose checks: interruption continuity, thinking/happy expressions, held/sleep priority and static reduced-motion poses. Native face and result snapshots are rendered and visually inspected.
- `xcodebuild -project Mochi/Mochi.xcodeproj -scheme Mochi -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/mochi-compact-build CODE_SIGNING_ALLOWED=NO build`.

These checks validate UI contracts, state wiring and construction. They do not replace judging timing in the running app, live ranking evaluation, or real Spotify-account playback validation.
