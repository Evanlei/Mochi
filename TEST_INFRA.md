# Mochi Opaque-Box E2E Test Infrastructure Specification

## 1. Overview and Architecture

The Mochi Opaque-Box End-to-End (E2E) Test Infrastructure provides automated, deterministic, and hermetic verification of the Mochi macOS desktop companion and menu-bar music controller. 

The test harness exercises the application strictly as an opaque black box from the perspective of an external user or macOS system service:
- **UI & Accessibility Inspection**: Interacts with the interface via native AppKit accessibility selectors (`accessibilityPerformPress()`, `accessibilityChildren`, `accessibilityIdentifier`, and `accessibilityLabel`).
- **Display & Panel Geometry**: Verifies multi-monitor display placement, screen clamping, auto-repositioning above/below companion cards, and drag dynamics.
- **Isolated Network Emulation**: Intercepts Spotify Web API requests via ephemeral `URLProtocol` (`SpotifyMockProtocol` / `SpotifyMockServer`), requiring zero network connectivity and zero live Spotify credentials.
- **AppleScript / Local Player Mocking**: Injects a deterministic `LocalPlayerFixture` conforming to `LocalSpotifyControlling` to verify desktop player Apple Events without needing the Spotify desktop client running.
- **State & Preferences Hermeticity**: Sandboxes user preferences via unique ephemeral `UserDefaults` suites (`com.evan.Mochi.e2e.<uuid>`), guaranteeing zero state pollution across test runs.

---

## 2. Test Suite Hierarchy & Tiers

The test suite is structured into four distinct verification tiers:

```
Tests/E2E/
├── E2ESupport.swift                    # Shared fixtures, assertions, element locators, mock payloads
├── Tier1FeatureCoverageTests.swift     # ≥5 test cases per feature for F1 through F16 (80+ test cases)
├── Tier2BoundaryCornerTests.swift      # Boundary conditions: empty states, long text, nil artwork, errors
├── Tier3CombinationTests.swift         # Pairwise cross-feature interactions (continuous listening + transport, etc.)
└── Tier4RealWorldScenariosTests.swift  # Complete end-to-end user workflows
```

### Tier 1: Feature Coverage (F1 – F16)
Every feature specified in `PROJECT.md` is covered with at least 5 isolated, thorough test cases:
1. **F1: Menu-Bar Artwork Treatment**:
   - `F1.1`: Nil artwork URL renders paused placeholder ("music.note").
   - `F1.2`: Nil artwork URL renders playing placeholder ("waveform").
   - `F1.3`: Valid artwork URL layout inside 48x48 frame.
   - `F1.4`: 11pt continuous corner radius container clipping and subtle background stroke.
   - `F1.5`: Artwork accessibility hidden flag (`accessibilityHidden(true)`).
2. **F2: Menu-Bar Typography & Hierarchy**:
   - `F2.1`: Track title typography (15pt / semibold) and 2-line limit constraint.
   - `F2.2`: Artist subtitle typography (12pt / secondary) and 1-line truncation.
   - `F2.3`: Nil playback state fallback strings ("Nothing playing" / "Start a song in Spotify.").
   - `F2.4`: Extremely long track title line wrapping and containment.
   - `F2.5`: Podcast episode subtitle formatting ("<show.name>").
3. **F3: Playback Device Badge**:
   - `F3.1`: Active playback device capsule formatting ("Playing · <device.name>").
   - `F3.2`: Paused playback device capsule formatting ("Paused · <device.name>").
   - `F3.3`: Nil device name fallback ("Playing" / "Paused").
   - `F3.4`: Restricted device status indicator and action permission suppression.
   - `F3.5`: Omission of device capsule when playback state is empty.
4. **F4: Tactile Transport Controls**:
   - `F4.1`: Previous track button label ("Previous track") and hit target (≥40-44pt).
   - `F4.2`: Next track button label ("Next track") and hit target (≥40-44pt).
   - `F4.3`: Prominent play/pause circular hit target (≥44pt) and spring press styling.
   - `F4.4`: Dynamic icon switching between "play.fill" and "pause.fill" based on playback state.
   - `F4.5`: Disabled state propagation when playback cannot perform command.
5. **F5: Settings & Connection Popover Polish**:
   - `F5.1`: Settings button hit target and accessibility label ("Player settings").
   - `F5.2`: "Refresh playback" action row dispatch.
   - `F5.3`: "Connect Spotify API" display and state transition when disconnected.
   - `F5.4`: "Disconnect Spotify API" display and state transition when connected.
   - `F5.5`: Seamless toggle between "Use desktop controls" and "Use Web API controls".
6. **F6: Preset Prompt Chips Elevation**:
   - `F6.1`: "Focus" preset chip populates draft and submits query.
   - `F6.2`: "Unwind" preset chip selection and query submission.
   - `F6.3`: "Surprise me" preset chip selection and query submission.
   - `F6.4`: Pill / Capsule background container styling with subtle stroke border.
   - `F6.5`: Chip interactive disabling while query or playback is in flight.
7. **F7: Composer Field Depth & Hierarchy**:
   - `F7.1`: Accessibility identifier `mochiComposer` presence and accessibility tree binding.
   - `F7.2`: Draft text synchronization during keyboard typing.
   - `F7.3`: Return key submission trigger.
   - `F7.4`: Escape key dismissal of composer and search state.
   - `F7.5`: Dynamic placeholder contrast and prompt guidance.
8. **F8: Recommendation List & Row Redesign**:
   - `F8.1`: Accessibility identifier `mochiSelectedTrack-<id>` for recommended tracks.
   - `F8.2`: Track row activation triggers playback request for track URI.
   - `F8.3`: BPM tag-like badge rendering when track tempo metadata exists.
   - `F8.4`: Vocals / Instrumental badge rendering when metadata exists.
   - `F8.5`: Accessibility identifier `mochiSongOptions-<id>` for track action overflow.
9. **F9: Up Next Queue Active Playback & Refill**:
   - `F9.1`: Hero container for currently playing track with `mochiQueueCurrent-<id>`.
   - `F9.2`: Queued upcoming track rows with `mochiQueueSong-<id>`.
   - `F9.3`: Refill status badge indication ("Finding more music…").
   - `F9.4`: Queue status accessibility identifier `mochiQueueStatus`.
   - `F9.5`: Graceful empty queue view when no upcoming tracks remain.
10. **F10: Overflow Menus & Artist Onboarding**:
    - `F10.1`: Adding favorite artist updates `MochiArtistPreferences`.
    - `F10.2`: Removing favorite artist updates `MochiArtistPreferences`.
    - `F10.3`: Companion card dynamic height resizing (300x150 → 300x320 onboarding → 300x210 settled).
    - `F10.4`: Session history tracking and retention of recent prompts.
    - `F10.5`: Similar track seed action (`mochiSimilarSeed`) launches refined discovery.
11. **F11: Mascot Pose Transitions & Smoothing**:
    - `F11.1`: Idle pose breathing oscillation kinematics.
    - `F11.2`: Smooth transition from idle to curious typing pose without coordinate snapping.
    - `F11.3`: Interrupted pose retargeting from current position to thinking pose.
    - `F11.4`: Music playing dance pose (squash-and-stretch, happy eyes, tilt, smile depth).
    - `F11.5`: Idle sleep transition after inactivity threshold with closed eyes and sleep phase.
12. **F12: Spring Micro-Interactions**:
    - `F12.1`: `MochiPressStyle` scale compression (0.97) under active press.
    - `F12.2`: `MochiPressStyle` opacity shift (0.8) under active press.
    - `F12.3`: Unpressed state restoration to scale 1.0 and opacity 1.0.
    - `F12.4`: Spring animation curve configuration with damping fraction.
    - `F12.5`: Tactile feedback integration across chips, buttons, and action items.
13. **F13: Accessibility Reduce Motion Support**:
    - `F13.1`: Static mascot pose when Reduce Motion is active (tilt = 0, waves = 0, lift = 0).
    - `F13.2`: Elimination of continuous breathing oscillation under Reduce Motion.
    - `F13.3`: Calm static happy expression during music playback without dance sway.
    - `F13.4`: `MochiPressStyle` disables scale spring under Reduce Motion.
    - `F13.5`: TimelineView minimum interval throttled to 1Hz under Reduce Motion.
14. **F14: Accessibility Reduce Transparency Support**:
    - `F14.1`: Fallback to solid `Color(nsColor: .windowBackgroundColor)` under Reduce Transparency.
    - `F14.2`: 0.5pt subtle stroke border outline on solid container.
    - `F14.3`: Liquid Glass effect disabled under Reduce Transparency.
    - `F14.4`: Panel corner radius (22pt) preserved under Reduce Transparency.
    - `F14.5`: Contrast and legibility maintained in high-contrast solid mode.
15. **F15: Regression Prevention & Key Contracts**:
    - `F15.1`: Strict preservation of all 17 accessibility identifiers across views.
    - `F15.2`: Strict preservation of AppKit accessibility labels and actions.
    - `F15.3`: Return key submission behavior across search and composer.
    - `F15.4`: Escape key hierarchical dismissal behavior.
    - `F15.5`: Root menu player accessibility identifier `mochiMenuPlayer`.
16. **F16: Automated Suite Verification**:
    - `F16.1`: `bash scripts/test-companion.sh` passes with exit code 0.
    - `F16.2`: `bash scripts/test-up-next.sh` passes with exit code 0.
    - `F16.3`: `bash scripts/test-playback.sh` passes with exit code 0.
    - `F16.4`: `bash scripts/test-search.sh` passes with exit code 0.
    - `F16.5`: Complete `xcodebuild` clean build verification.

---

### Tier 2: Boundary & Corner Cases
Verifies resilience against extreme, malformed, or hostile inputs:
- **Empty States**:
  - Empty search / discovery catalog response.
  - Empty Up Next queue.
  - Zero favorite artists.
  - Empty composer text submission.
  - No active playback devices available (HTTP 404 / noDevice).
- **Text & Unicode Extremes**:
  - Track titles exceeding 500 characters.
  - Complex multilingual UTF-8 text (Japanese Kanji, Cyrillic, RTL Arabic, Math symbols).
  - Emoji strings in composer draft and track titles.
  - Special characters and XML/HTML escapes (`&`, `<`, `>`, quotes).
  - Rapid draft editing and immediate clearing.
- **Nil & Missing Media**:
  - Missing artwork URL (nil `artworkURL`).
  - Corrupted or unreachable image URLs.
  - Missing artist names and missing album metadata.
  - Unrecognized playback item types.
  - Missing device names.
- **Network & Error Recovery**:
  - HTTP 401 Unauthorized token expiration and refresh handling.
  - HTTP 429 Rate Limiting with `Retry-After` header.
  - HTTP 500 Internal Server Failure recovery.
  - Apple Event permission rejection in desktop player.
  - Abrupt network cancellation during search dispatch.
- **Rapid Command Bursts & Concurrency**:
  - Rapid double-click on transport buttons (play/pause toggle storm).
  - Rapid opening and closing of companion card panel.
  - Concurrent search dispatch while prior query is in-flight.
  - Dragging mascot beyond multi-screen coordinate boundaries (-10,000 to +10,000).

---

### Tier 3: Cross-Feature Combinations (Pairwise Interactions)
Verifies multi-system coherence and state synchronization across components:
1. **Continuous Listening + Menu-Bar Playback Control**: Toggling playback pause/play from the menu-bar popover updates continuous listening session state and Up Next queue playback indicator.
2. **Composer Search + Discovery Mode Switching**: Switching discovery mode (balanced → familiar → discover) while a query is typed correctly reapplies mode parameters without dropping the query.
3. **Reduce Motion + Mascot Drag & Squash**: Dragging the mascot panel under Reduce Motion updates placement and clamping without triggering spring oscillations.
4. **Reduce Transparency + Dynamic Appearance (Dark/Light Mode)**: Companion panel styling correctly switches between solid light and solid dark background colors without Liquid Glass artifacts.
5. **Artist Onboarding + Preset Prompt Dispatch**: Selecting favorite artist chips immediately settles card height and feeds artist preferences into the preset chips ("Focus", "Unwind").
6. **Desktop Player Fallback + Track Link Playback + Menu-Bar Artwork**: Pasting a Spotify track URI into desktop player fallback mode updates NowPlayingView artwork and device status badge.
7. **Queue Refill In-Flight + Manual Recommendation Selection**: User manually selecting a recommendation while automatic queue refill is active cleanly prioritizes the user's selection without corrupting queue order.
8. **Settings Popover Open + External Playback Event**: External playback changes (e.g. track finish or device change) update the background NowPlayingView without forcibly dismissing or breaking the active settings popover.

---

### Tier 4: Real-World Application Scenarios
Simulates realistic end-to-end user workflows:
1. **Scenario 1: First-Run Onboarding to Active Playback**:
   - Fresh launch with clean defaults suite.
   - Onboard 3 favorite artists via chips.
   - Card transitions from onboarding (320pt) to settled (210pt).
   - Click "Focus" preset prompt chip.
   - Inspect recommendation results.
   - Click recommended track to initiate playback.
   - Mascot transitions to celebration dance pose.
2. **Scenario 2: Menu-Bar Controller & Desktop Player Fallback**:
   - Launch app with Spotify Web API disconnected.
   - Open menu-bar popover player.
   - Click "Use desktop controls".
   - Open settings popover and enable "Play a Spotify link".
   - Paste track URI and trigger playback.
   - Verify transport controls (play, pause, next) function via desktop Apple Events.
   - Verify device badge displays Mac desktop playback status.
3. **Scenario 3: Continuous Listening & Queue Refill Session**:
   - Connect Spotify API and launch continuous listening session.
   - Open Up Next queue popover.
   - Verify hero current track and queued upcoming songs.
   - Simulate current track completion.
   - Verify queue advances and refills automatically ("Finding more music…").
   - Stop session via stop button and verify queue snapshot cleanup.
4. **Scenario 4: Accessibility Conformance Session**:
   - Enable system `accessibilityReduceMotion` and `accessibilityReduceTransparency`.
   - Verify companion window background uses solid material with stroke border.
   - Verify composer typing and discovery thinking use calm static poses.
   - Verify TimelineView throttles to 1Hz.
   - Verify press styles use instant opacity feedback rather than spring scaling.
5. **Scenario 5: Network Disruption & Automatic Error Recovery**:
   - Active playback and continuous listening running.
   - Simulate network failure (HTTP 500 / 429).
   - Verify non-intrusive error banner in menu player.
   - Restore network connectivity.
   - Click "Refresh playback" in settings.
   - Verify successful recovery of playback state and queue.

---

## 3. Test Runner & Execution Environment

### Standalone Runner Script
The standalone runner is located at `scripts/test-e2e.sh`. It compiles all E2E test files with `xcrun swiftc` into an isolated binary in a temporary sandbox, executes the tests, and reports individual test results, timing, and pass/fail counts:

```bash
bash scripts/test-e2e.sh
```

Supported options:
- `bash scripts/test-e2e.sh`: Run all tiers (Tier 1 through Tier 4).
- `bash scripts/test-e2e.sh --tier 1`: Run Tier 1 Feature Coverage tests only.
- `bash scripts/test-e2e.sh --tier 2`: Run Tier 2 Boundary & Corner Case tests only.
- `bash scripts/test-e2e.sh --tier 3`: Run Tier 3 Cross-Feature Combination tests only.
- `bash scripts/test-e2e.sh --tier 4`: Run Tier 4 Real-World Scenario tests only.

Exit Code: Returns `0` on 100% pass, non-zero on any failure.
