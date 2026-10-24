# Project: Mochi UI and Micro-Interactions Overhaul

## Architecture
Mochi is a macOS desktop companion and menu-bar music controller built with SwiftUI and AppKit.
The architecture comprises four core presentation layers:
1. **Menu-Bar Popover Player (`NowPlayingView.swift`, `ContentView.swift`)**:
   - Anchored to macOS status bar (`MenuBarExtra`).
   - Presents current playback artwork, track title, artist, album, playback device badge, tactile transport controls, and settings popovers.
   - Decodes Spotify playback state via `SpotifyPlaybackClient` and triggers commands via `SpotifyPlaybackModel`.
2. **Floating Desktop Companion Card (`MochiCompanionView.swift`, `MochiCompanionController.swift`)**:
   - Borderless, floating AppKit panel (`CompanionPanel`) with Liquid Glass material (`glassEffect(.regular)`).
   - Houses discovery mode dropdown, preset prompt chips, composer query field, recommendations list, Up Next queue, and overflow actions.
3. **Mascot Dynamics & Character Canvas (`MochiCompanionView.swift`)**:
   - Pure SwiftUI Canvas rendering (`MochiMascotArtwork`) with dynamic mathematical transforms (`MochiMascotPose`).
   - Multi-state animations: idle breathing/hop, curious typing, thinking discovery, celebration impulse, music playback dance, inactivity sleep/wake, drag/squash.
   - Comprehensive accessibility hooks: `accessibilityReduceMotion` (static expressive poses, 1Hz timeline throttling) and `accessibilityReduceTransparency` (solid window background material).
4. **Shared Preferences & State Models**:
   - `MochiArtistPreferences.swift`: Favorite artist chips and onboarding.
   - `MochiRequestModel`: Continuous listening session state, discovery requests, queue refill.
   - `SpotifyAuthModel`: Web API connection lifecycle and tokens.

---

## Feature Inventory
Every requirement and discovered feature is enumerated below and mapped to a specific milestone.

| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| F1 | Menu-Bar Artwork Treatment | Elevated artwork styling with multi-layer drop shadow, 11pt continuous corner radius, subtle stroke border, and polished placeholder | M1 | ORIGINAL_REQUEST §R2 |
| F2 | Menu-Bar Typography & Hierarchy | Prominent track title (14.5pt semibold), artist name (12pt medium), and album name (11pt tertiary) with refined optical spacing | M1 | ORIGINAL_REQUEST §R2 |
| F3 | Playback Device Badge | Native macOS status capsule with device icon, colored playback state indicator dot, and device name | M1 | ORIGINAL_REQUEST §R2 |
| F4 | Tactile Transport Controls | Expanded hit targets (≥40-44pt), active press spring scaling/opacity (`TransportButtonStyle`), and hover highlights | M1 | ORIGINAL_REQUEST §R2 |
| F5 | Settings & Connection Popover Polish | macOS menu-style row hover highlights, grouped sections ("Playback", "Connection"), and polished iconography | M1 | ORIGINAL_REQUEST §R2 |
| F6 | Preset Prompt Chips Elevation | Elegant frosted pill backgrounds (`Capsule`), subtle stroke border, and refined secondary typography for "Focus", "Unwind", "Surprise me" | M2 | ORIGINAL_REQUEST §R1 |
| F7 | Composer Field Depth & Hierarchy | Enhanced field container depth, subtle surface opacity/border, clear focus glow, and polished placeholder contrast | M2 | ORIGINAL_REQUEST §R1 |
| F8 | Recommendation List & Row Redesign | Refined typography hierarchy, subtle hover states, rounded row clipping, tag-like badges (BPM/vocals), and modern separators | M2 | ORIGINAL_REQUEST §R1 |
| F9 | Up Next Queue Active Playback & Refill | Hero card container for currently playing track, active play/waveform indicator, and distinct animated refill status badge | M2 | ORIGINAL_REQUEST §R1 |
| F10 | Overflow Menus & Artist Onboarding | Native macOS styling for track action popovers, session history, and favorite artist chips | M2 | ORIGINAL_REQUEST §R1 |
| F11 | Mascot Pose Transitions & Smoothing | Smooth transitions across idle, curious typing, thinking discovery, celebration impulse, music playback dance, and sleep/wake | M3 | ORIGINAL_REQUEST §R3 |
| F12 | Spring Micro-Interactions | Delightful spring compression and tactile feedback on buttons, chips, and interactive controls (`MochiPressStyle`) | M3 | ORIGINAL_REQUEST §R3 |
| F13 | Accessibility Reduce Motion Support | Zero continuous oscillations/sways, calm static emotional poses, 1Hz timeline throttling, and instant transitions when Reduce Motion is on | M3 | ORIGINAL_REQUEST §R3, §Rubric |
| F14 | Accessibility Reduce Transparency Support | Seamless fallback from Liquid Glass blur to solid macOS window background material (`Color(nsColor: .windowBackgroundColor)`) with outline | M3 | ORIGINAL_REQUEST §R3, §Rubric |
| F15 | Regression Prevention & Key Contracts | Preserve Return/Escape keyboard shortcuts, all 17 accessibility identifiers, and AppKit accessibility labels | M4 | ORIGINAL_REQUEST §R4 |
| F16 | Automated Suite Verification | 100% pass rate on `bash scripts/test-companion.sh` and zero errors on `xcodebuild` | M4 | ORIGINAL_REQUEST §Acceptance |
| F17 | E2E Test Suite (Tiers 1-4) | Comprehensive opaque-box test suite verifying all features in isolation, boundary cases, combinations, and real-world workflows | E2E Track | ORIGINAL_REQUEST §Acceptance |
| F18 | Adversarial Coverage Hardening (Tier 5) | White-box stress testing, corner cases, rapid typing/cancellation, and extreme window placements | M4 | Project Pattern |

---

## Milestones

| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Menu-Bar Player & Transport Polish | F1, F2, F3, F4, F5 in `NowPlayingView.swift`, `ContentView.swift`, and `SpotifyPlaybackClient.swift` | none | DONE |
| M2 | Desktop Companion Card Elevation | F6, F7, F8, F9, F10 in `MochiCompanionView.swift` and `MochiArtistPreferences.swift` | none | PLANNED |
| M3 | Mascot Dynamics & Micro-Interactions | F11, F12, F13, F14 in `MochiCompanionView.swift` (`MochiMascotView`, `MochiMascotPose`, `MochiPressStyle`) | M2 | PLANNED |
| E2E | Opaque-Box E2E Testing Track | F17: Test harness, Tiers 1-4 test suites across all features, publishing `TEST_READY.md` | none (Parallel Track) | IN_PROGRESS |
| M4 | Final Integration & Verification | F15, F16, F18: 100% E2E test pass, adversarial hardening (Tier 5), forensic audit, victory claim | M1, M2, M3, E2E | PLANNED |

---

## Interface Contracts

### 1. `NowPlayingView.swift` ↔ `SpotifyPlaybackModel.swift` / `SpotifyPlaybackClient.swift`
- `SpotifyPlaybackAlbum`: May optionally decode `name: String? = nil` to display album title. Must not break existing decoders. (Implemented & verified).
- `LocalSpotifyClient`: Must maintain exact 5 Apple Event properties query (`pPlS`, `pnam`, `pArt`, `ID  `, `aUrl`). (Maintained & verified).
- Transport Actions: Buttons must retain exact `.accessibilityLabel` values (`"Previous track"`, `"Play"`, `"Pause"`, `"Next track"`). (Verified).
- Root Container: Must retain `.accessibilityIdentifier("mochiMenuPlayer")`. (Verified).

### 2. `MochiCompanionView.swift` ↔ `Tests/CompanionChecks.swift` & `Tests/UpNextChecks.swift`
- Panel Dimensions: Fixed sizes `300x150` (idle), `300x340` (search/selection/up-next), `300x320` (artist onboarding), `300x210` (3 artists settled).
- Accessibility Identifiers: All 17 identifiers must be strictly preserved:
  `mochiComposer`, `mochiReply`, `mochiDiscoveryPicker`, `mochiDiscoveryMode-balanced`, `mochiDiscoveryMode-familiar`, `mochiDiscoveryMode-discover`, `mochiAppliedDiscoveryMode`, `mochiSimilarSeed`, `mochiSampleCatalog`, `mochiSelectedTrack-<id>`, `mochiSongOptions-<id>`, `mochiDiscoverySource`, `mochiContinuousStatus`, `mochiUpNext`, `mochiQueueCurrent-<id>`, `mochiQueueSong-<id>`, `mochiQueueStatus`.
- Accessibility Labels: Exact strings queried by AppKit tests (`"Close Mochi"`, `"Listening options"`, `"Search Spotify"`, `"Send listening request"`, `"Options for ..."`, `"Show Up Next"`, `"Show recommendations"`, `"Stop continuous listening"`).
- Keyboard: Return submits composer/search, Escape closes modals/popovers hierarchically.

### 3. Mascot Dynamic Poses & Accessibility
- `MochiMascotPose.at(time, ...)`: Must compute smooth kinematics while returning exact static poses when `animate: false` (`tilt == 0`, `waves == 0`, `lift == 0`).
- Priority Order: Held/drag (`isHeld`) > Sleeping (`isSleeping`) > Music Playing (`isMusicPlaying`) > In-flight Thinking (`isThinking`) > Curious Typing (`isCurious`) > Idle Breathing.
- `accessibilityReduceTransparency`: Falls back to `Color(nsColor: .windowBackgroundColor)` + 0.5pt stroke.

---

## Code Layout & Write Ownership

| Target File | Exclusive Owner | Purpose |
|---|---|---|
| `Mochi/Mochi/NowPlayingView.swift` | Milestone 1 Worker | Menu-bar player presentation, artwork, typography, transport (COMPLETED) |
| `Mochi/Mochi/ContentView.swift` | Milestone 1 Worker | Menu-bar popover container, settings rows, session row (COMPLETED) |
| `Mochi/Mochi/SpotifyPlaybackClient.swift` | Milestone 1 Worker | Optional album name decoding (COMPLETED) |
| `Mochi/Mochi/MochiArtistPreferences.swift` | Milestone 2 Worker | Favorite artist onboarding chips & styling |
| `Mochi/Mochi/MochiCompanionView.swift` | Milestone 2 Worker (Card UI), then Milestone 3 Worker (Mascot & Spring) | Companion card, queue, recommendation rows, mascot canvas & motion |
| `Tests/E2E/` or `scripts/e2e/` | E2E Testing Track | Independent opaque-box test suites (Tiers 1-4) |
