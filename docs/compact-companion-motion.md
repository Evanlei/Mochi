# Compact companion and motion

The selected design is **B — composer first** from the [design studies](../design/prototypes/compact-ui/index.html). The native SwiftUI implementation calls the real existing models; the HTML study remains a simulated design reference.

## UI and interaction choices

- A 300 × 150-point idle card keeps the prompt and presets close. Discovery modes live in a native popover instead of a permanent row. The extra click buys desktop space; the current mode stays visible.
- Results/search expand to 300 × 340. Song rows show title/artist and one overflow button; feedback/refinement actions live inside it. A confirmed track plays by clicking its title. Unknown musical measurements are omitted, never invented. The batch mode appears in the footer only if the next-request choice differs; a small Last.fm attribution remains visible.
- Native Liquid Glass (`glassEffect(.regular, in: .rect(cornerRadius: 22))`) replaces the forced-light blur, sage wash and white outline. One material surface is used; the composer has a shallow inset instead of another glass layer. System foreground colors adapt to appearance. Reduce Transparency uses an opaque window-background color.
- Search, favorite artists, New listening request and Play matches live in the header's listening-options popover. Persistent playback-success and feedback-success banners are suppressed. Explicit error fields retain playback/partial-match/refinement failures and failed feedback; progress and Cancel remain visible.
- Favorite artists still save immediately. Familiar/Discover require a favorite, and controls remain locked during pending work. Closing the mode popover returns focus to the composer.
- Utility selections dismiss their popover without a close animation before changing the focused input, avoiding late restoration of a retired composer when opening artist editing or search.
- Cancel keeps the draft, stops pending discovery, and rejects late responses through the existing generation guard. Canceling refinement preserves the current songs. New request remains a separate reset action.

## Motion review

| Before | After | Why |
| --- | --- | --- |
| Abrupt panel appearance/disappearance | 120 ms entry and 80 ms exit fades | Clear, quick presentation without delaying input |
| A separate 180 ms window resize while SwiftUI used the new height | Immediate native bounds update | Avoid cropping/reflowing new content through an independently moving window; glass owns the material appearance |
| No expression for the current request | Curious draft pose, thinking request pose, happy playback-start squish | Communicate activity through the character as well as visible status text |
| Restarting a reaction could snap to its first frame | Activity weights retarget from their current values over 220 ms | Cancel/retry and rapid edits preserve continuity |
| Uniform control feedback | Small spring press/release on presets and Send | Give tactile feedback while Return still submits directly |

**Verdict: Approve the implementation checks.** Motion is bounded, interruptions and stale close completion are tested, and Reduce Motion is respected. Native bounds now update directly; the double animation of content and window has been removed. AppKit's default window animation and extra shadow are disabled to avoid competing with the native glass surface. The mascot's existing Canvas renderer remains at 30 fps; no animation framework or dependency was added.

The idle jump, hover/wave, drag/stretch, music dance and sleeping z's are preserved. Thinking and curiosity yield to held/sleeping poses. An active greeting releases into the activity expression rather than ending with a pose snap. Repeated typing within a nonempty draft does not retrigger a greeting. Hidden characters stop animating. Reduce Motion keeps static activity expressions and skips window movement/fades; Reduce Transparency uses the existing solid material.

The 800 ms playback reaction is character expression rather than blocking UI motion. The discovery spinner/status and Cancel remain usable throughout. Dance rhythm is decorative and is not inferred from the song's tempo.

## Guidance used

The bundled Emil Kowalski Motion and Review Animations skills informed the timing, interruption, small press transforms and accessibility review. The catalog's Apple HIG and SwiftUI Design entries are pointers to upstream packages, not full installed workflows; they were not treated as complete local skills. Native decisions were checked against [Apple's motion guidance](https://developer.apple.com/design/human-interface-guidelines/motion), [Liquid Glass custom-view guidance](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views), and [AppKit animation completion behavior](https://developer.apple.com/documentation/appkit/nsanimationcontext/completionhandler).

## Verification

- `bash scripts/test-companion.sh /private/tmp/mochi-glass-preview`: actual native accessibility actions, typing/Return/Escape, header/song overflow popovers, dropdown choices/gating, conditional applied-mode labels, saved mode, result expansion, artist editing/focus, feedback and refinement, close/reopen during a fade, Cancel and late-response rejection. Providers/playback use mocks.
- `bash scripts/test-discovery.sh`: provider contracts and playback/feedback behavior, including visible partial-playback notices, feedback errors and clearing errors on retry.
- Pose checks: interruption continuity, thinking/happy expressions, held/sleep priority and static reduced-motion poses. Native face and result snapshots are rendered and visually inspected.
- Liquid Glass depends on window-server compositing; `cacheDisplay` exports omit its background/foreground effects. Diagnostic layout captures use flat backdrops and must not be presented as faithful Liquid Glass screenshots. Native accessibility checks verify the actual controls; the app is also built/run through Xcode. Discovery-model checks ensure partial playback and feedback failures stay visible while success banners remain quiet.
- `xcodebuild -project Mochi/Mochi.xcodeproj -scheme Mochi -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/mochi-glass-build CODE_SIGNING_ALLOWED=NO build`.

These checks validate UI contracts, state wiring and construction. They do not replace judging timing in the running app, live ranking evaluation, or real Spotify-account playback validation.
