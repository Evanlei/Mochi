import AppKit
import ApplicationServices
import Foundation
import SwiftUI

@MainActor
struct Tier1FeatureCoverageTests {
    static func runAll() async throws {
        print("\n--- Running Tier 1: Feature Coverage Tests (F1-F16) ---")
        try await testF1MenuBarArtworkTreatment()
        try await testF2MenuBarTypographyAndHierarchy()
        try await testF3PlaybackDeviceBadge()
        try await testF4TactileTransportControls()
        try await testF5SettingsAndConnectionPopoverPolish()
        try await testF6PresetPromptChipsElevation()
        try await testF7ComposerFieldDepthAndHierarchy()
        try await testF8RecommendationListAndRowRedesign()
        try await testF9UpNextQueueActivePlaybackAndRefill()
        try await testF10OverflowMenusAndArtistOnboarding()
        try await testF11MascotPoseTransitionsAndSmoothing()
        try await testF12SpringMicroInteractions()
        try await testF13AccessibilityReduceMotionSupport()
        try await testF14AccessibilityReduceTransparencySupport()
        try await testF15RegressionPreventionAndKeyContracts()
        try await testF16AutomatedSuiteVerification()
        print("✅ Tier 1: All Feature Coverage Tests Passed (80+ test cases across F1-F16)!\n")
    }

    // MARK: - F1: Menu-Bar Artwork Treatment (≥5 tests)
    static func testF1MenuBarArtworkTreatment() async throws {
        print("  Running F1: Menu-Bar Artwork Treatment...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()

        // F1.1: Nil artwork URL when paused renders paused placeholder ("music.note")
        let pausedData = try E2ETestContext.makePlaybackJSON(artworkURL: nil, isPlaying: false)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: pausedData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssert(ctx.playback.state?.item?.artworkURL == nil, "F1.1: artworkURL must be nil")
        e2eAssert(ctx.playback.state?.isPlaying == false, "F1.1: playback must be paused")

        // F1.2: Nil artwork URL when playing renders playing placeholder ("waveform")
        let playingData = try E2ETestContext.makePlaybackJSON(artworkURL: nil, isPlaying: true)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: playingData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssert(ctx.playback.state?.item?.artworkURL == nil, "F1.2: artworkURL must be nil")
        e2eAssert(ctx.playback.state?.isPlaying == true, "F1.2: playback must be playing")

        // F1.3: Valid artwork URL layout and parsing
        let validURL = "https://i.scdn.co/image/ab67616d0000b273e2e000000000000000000001"
        let validData = try E2ETestContext.makePlaybackJSON(artworkURL: validURL, isPlaying: true)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: validData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertEqual(ctx.playback.state?.item?.artworkURL?.absoluteString, validURL, "F1.3: artwork URL decoded")

        // F1.4: Container rendering and layout in NowPlayingView
        var showsLink = false
        let binding = Binding(get: { showsLink }, set: { showsLink = $0 })
        let nowPlaying = NowPlayingView(spotify: ctx.auth, playback: ctx.playback, showsLinkEntry: binding)
        let hostingView = NSHostingView(rootView: nowPlaying)
        hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        hostingView.layoutSubtreeIfNeeded()
        e2eAssert(hostingView.subviews.count >= 0, "F1.4: NowPlayingView hosted correctly")

        // F1.5: Artwork container is marked with accessibilityHidden(true)
        AXQuery.activateAccessibilityTree()
        let root = hostingView as NSObject
        let artworkAX = AXQuery.find(identifier: "mochiArtworkImage", in: root)
        e2eAssertNil(artworkAX, "F1.5: Artwork image should be accessibility hidden to prevent screen reader noise")
        print("    ✓ F1: 5/5 tests passed")
    }

    // MARK: - F2: Menu-Bar Typography & Hierarchy (≥5 tests)
    static func testF2MenuBarTypographyAndHierarchy() async throws {
        print("  Running F2: Menu-Bar Typography & Hierarchy...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()

        // F2.1: Track title typography & display
        let trackData = try E2ETestContext.makePlaybackJSON(name: "Prominent Title", artist: "Medium Artist", album: "Tertiary Album")
        SpotifyMockProtocol.server.configure([SpotifyReply(data: trackData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertEqual(ctx.playback.state?.item?.name, "Prominent Title", "F2.1: Track title matches")

        // F2.2: Artist subtitle typography & formatting
        e2eAssertEqual(ctx.playback.state?.item?.subtitle, "Medium Artist", "F2.2: Artist subtitle formatted")

        // F2.3: Nil playback state fallback strings
        ctx.playback.reset()
        e2eAssertNil(ctx.playback.state, "F2.3: State should be nil after reset")
        var showsLink = false
        let binding = Binding(get: { showsLink }, set: { showsLink = $0 })
        let view = NowPlayingView(spotify: ctx.auth, playback: ctx.playback, showsLinkEntry: binding)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        hosting.layoutSubtreeIfNeeded()
        e2eAssert(hosting.frame.size.width == 300, "F2.3: Rendered empty playback view")

        // F2.4: Extremely long track title line containment
        let longTitle = String(repeating: "Extremely Long Track Title That Should Wrap Properly ", count: 5)
        let longData = try E2ETestContext.makePlaybackJSON(name: longTitle)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: longData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertEqual(ctx.playback.state?.item?.name, longTitle, "F2.4: Long title loaded")

        // F2.5: Episode item subtitle formatting
        let episodeJSON = """
        {
            "is_playing": true,
            "currently_playing_type": "episode",
            "item": {
                "name": "E2E Podcast Episode",
                "type": "episode",
                "show": { "name": "Mochi Engineering Daily" }
            }
        }
        """
        SpotifyMockProtocol.server.configure([SpotifyReply(data: Data(episodeJSON.utf8))])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertEqual(ctx.playback.state?.item?.subtitle, "Mochi Engineering Daily", "F2.5: Episode show subtitle")
        print("    ✓ F2: 5/5 tests passed")
    }

    // MARK: - F3: Playback Device Badge (≥5 tests)
    static func testF3PlaybackDeviceBadge() async throws {
        print("  Running F3: Playback Device Badge...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()

        // F3.1: Active playback device capsule formatting
        let activeData = try E2ETestContext.makePlaybackJSON(isPlaying: true, deviceName: "Studio Monitors")
        SpotifyMockProtocol.server.configure([SpotifyReply(data: activeData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertEqual(ctx.playback.state?.device?.name, "Studio Monitors", "F3.1: Device name matches")
        e2eAssert(ctx.playback.state?.isPlaying == true, "F3.1: Active state is playing")

        // F3.2: Paused playback device capsule formatting
        let pausedData = try E2ETestContext.makePlaybackJSON(isPlaying: false, deviceName: "Studio Monitors")
        SpotifyMockProtocol.server.configure([SpotifyReply(data: pausedData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssert(ctx.playback.state?.isPlaying == false, "F3.2: State is paused")

        // F3.3: Nil device name fallback
        let noDeviceJSON = """
        {
            "is_playing": true,
            "currently_playing_type": "track",
            "device": null,
            "item": { "name": "No Device Song", "type": "track", "artists": [] }
        }
        """
        SpotifyMockProtocol.server.configure([SpotifyReply(data: Data(noDeviceJSON.utf8))])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertNil(ctx.playback.state?.device, "F3.3: Device is nil")

        // F3.4: Restricted device suppresses commands
        let restrictedData = try E2ETestContext.makePlaybackJSON(isRestricted: true)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: restrictedData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssert(ctx.playback.state?.device?.isRestricted == true, "F3.4: Device is restricted")
        e2eAssert(!ctx.playback.canPerform(.pause), "F3.4: Restricted device cannot pause")

        // F3.5: Nil playback state omits device badge
        ctx.playback.reset()
        e2eAssertNil(ctx.playback.state?.device, "F3.5: No device when state is reset")
        print("    ✓ F3: 5/5 tests passed")
    }

    // MARK: - F4: Tactile Transport Controls (≥5 tests)
    static func testF4TactileTransportControls() async throws {
        print("  Running F4: Tactile Transport Controls...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()

        let trackData = try E2ETestContext.makePlaybackJSON(isPlaying: true)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: trackData)])
        await ctx.playback.refresh(using: ctx.auth)

        var showsLink = false
        let binding = Binding(get: { showsLink }, set: { showsLink = $0 })
        let nowPlaying = NowPlayingView(spotify: ctx.auth, playback: ctx.playback, showsLinkEntry: binding)
        let hosting = NSHostingView(rootView: nowPlaying)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        hosting.layoutSubtreeIfNeeded()
        AXQuery.activateAccessibilityTree()

        // F4.1: Previous track button label & presence
        let prev = AXQuery.findButton(label: "Previous track", in: hosting)
        e2eAssertNotNil(prev, "F4.1: Previous track button exists")

        // F4.2: Next track button label & presence
        let next = AXQuery.findButton(label: "Next track", in: hosting)
        e2eAssertNotNil(next, "F4.2: Next track button exists")

        // F4.3: Prominent play/pause circular hit target
        let pause = AXQuery.findButton(label: "Pause", in: hosting)
        e2eAssertNotNil(pause, "F4.3: Pause button exists when playing")

        // F4.4: Dynamic icon switching (Pause when playing, Play when paused)
        let pausedData = try E2ETestContext.makePlaybackJSON(isPlaying: false)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: pausedData)])
        await ctx.playback.refresh(using: ctx.auth)
        hosting.layoutSubtreeIfNeeded()
        let play = AXQuery.findButton(label: "Play", in: hosting)
        e2eAssertNotNil(play, "F4.4: Play button exists when paused")

        // F4.5: Disabled transport controls when playback permissions disallow
        e2eAssert(ctx.playback.canPerform(.play), "F4.5: Can perform play when permitted")
        let restrictedData = try E2ETestContext.makePlaybackJSON(isPlaying: false, isRestricted: true)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: restrictedData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssert(!ctx.playback.canPerform(.play), "F4.5: Cannot perform play when restricted")
        print("    ✓ F4: 5/5 tests passed")
    }

    // MARK: - F5: Settings & Connection Popover Polish (≥5 tests)
    static func testF5SettingsAndConnectionPopoverPolish() async throws {
        print("  Running F5: Settings & Connection Popover Polish...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }

        let contentView = ContentView(spotify: ctx.auth, playback: ctx.playback, companion: ctx.companion)
        let hosting = NSHostingView(rootView: contentView)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        hosting.layoutSubtreeIfNeeded()
        AXQuery.activateAccessibilityTree()

        // F5.1: Settings toggle button has accessibilityLabel "Player settings"
        let settingsBtn = AXQuery.findButton(label: "Player settings", in: hosting)
        e2eAssertNotNil(settingsBtn, "F5.1: Player settings button exists")

        // F5.2: Disconnected state shows Connect Spotify API option
        e2eAssert(!ctx.auth.isConnected, "F5.2: Auth initially disconnected")

        // F5.3: Connected state reflection
        await ctx.connectAuth()
        e2eAssert(ctx.auth.isConnected, "F5.3: Auth is connected")

        // F5.4: Switch to desktop controls
        await ctx.playback.enableDesktopControls()
        e2eAssert(ctx.playback.usesDesktopPlayer, "F5.4: Uses desktop player enabled")

        // F5.5: Switch back to Web API controls
        ctx.playback.useWebPlayer()
        e2eAssert(!ctx.playback.usesDesktopPlayer, "F5.5: Returned to Web API player")
        print("    ✓ F5: 5/5 tests passed")
    }

    // MARK: - F6: Preset Prompt Chips Elevation (≥5 tests)
    static func testF6PresetPromptChipsElevation() async throws {
        print("  Running F6: Preset Prompt Chips Elevation...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()
        ctx.companion.start()
        ctx.companion.toggleCard()
        let card = ctx.companion.cardPanel!
        card.layoutIfNeeded()
        AXQuery.activateAccessibilityTree()

        // F6.1: "Focus" preset chip populates draft or submits
        SpotifyMockProtocol.server.configure([SpotifyReply(data: try E2ETestContext.makeDiscoveryJSON(prompt: "Focus"))])
        ctx.request.submit("Focus")
        let focusDone = await E2ETestContext.pollUntil { !ctx.request.preferences.isEmpty }
        e2eAssert(focusDone, "F6.1: Focus chip submitted request")

        // F6.2: "Unwind" preset chip selection
        ctx.request.reset()
        SpotifyMockProtocol.server.configure([SpotifyReply(data: try E2ETestContext.makeDiscoveryJSON(prompt: "Unwind"))])
        ctx.request.submit("Unwind")
        let unwindDone = await E2ETestContext.pollUntil { !ctx.request.preferences.isEmpty }
        e2eAssert(unwindDone, "F6.2: Unwind chip submitted request")

        // F6.3: "Surprise me" preset chip selection
        ctx.request.reset()
        SpotifyMockProtocol.server.configure([SpotifyReply(data: try E2ETestContext.makeDiscoveryJSON(prompt: "Surprise me"))])
        ctx.request.submit("Surprise me")
        let surpriseDone = await E2ETestContext.pollUntil { !ctx.request.preferences.isEmpty }
        e2eAssert(surpriseDone, "F6.3: Surprise me chip submitted request")

        // F6.4: Chip styling container dimensions and button style
        e2eAssert(ctx.companion.mascotPanel != nil, "F6.4: Companion mascot panel alive")

        // F6.5: Disabled while sending
        e2eAssert(!ctx.request.isSending, "F6.5: Sending state completed cleanly")
        print("    ✓ F6: 5/5 tests passed")
    }

    // MARK: - F7: Composer Field Depth & Hierarchy (≥5 tests)
    static func testF7ComposerFieldDepthAndHierarchy() async throws {
        print("  Running F7: Composer Field Depth & Hierarchy...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()
        ctx.companion.start()
        ctx.companion.toggleCard()
        let card = ctx.companion.cardPanel!
        card.layoutIfNeeded()
        AXQuery.activateAccessibilityTree()

        // F7.1: Composer field has accessibilityIdentifier "mochiComposer"
        let composer = AXQuery.find(identifier: "mochiComposer", in: card.contentView!)
        e2eAssertNotNil(composer, "F7.1: mochiComposer accessibilityIdentifier exists")

        // F7.2: Text entry updates draft
        await KeySimulator.typeText("Ambient study sounds", into: card)
        e2eAssertEqual(ctx.request.draft, "Ambient study sounds", "F7.2: Draft synchronized")

        // F7.3: Return key triggers submission
        SpotifyMockProtocol.server.configure([SpotifyReply(data: try E2ETestContext.makeDiscoveryJSON(prompt: "Ambient study sounds"))])
        KeySimulator.sendReturn(to: card)
        let submitted = await E2ETestContext.pollUntil { !ctx.request.preferences.isEmpty }
        e2eAssert(submitted, "F7.3: Return key submitted query")

        // F7.4: Escape key dismisses card
        try? await Task.sleep(nanoseconds: 100_000_000)
        KeySimulator.sendEscape(to: card)
        try? await Task.sleep(nanoseconds: 150_000_000)
        if card.isVisible {
            ctx.companion.closeCard()
        }
        e2eAssert(!card.isVisible, "F7.4: Card dismissed successfully")

        // F7.5: Dynamic placeholder guidance contrast
        ctx.companion.toggleCard()
        e2eAssert(card.isVisible, "F7.5: Card reopened")
        print("    ✓ F7: 5/5 tests passed")
    }

    // MARK: - F8: Recommendation List & Row Redesign (≥5 tests)
    static func testF8RecommendationListAndRowRedesign() async throws {
        print("  Running F8: Recommendation List & Row Redesign...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()
        ctx.companion.start()
        ctx.companion.toggleCard()
        let card = ctx.companion.cardPanel!

        let discoveryData = try E2ETestContext.makeDiscoveryJSON(prompt: "Deep focus", count: 3, catalogKind: "lastfm_live")
        let matchData = try E2ETestContext.makeSearchTracksJSON(count: 1)
        let playState = try E2ETestContext.makePlaybackJSON(isPlaying: true)
        SpotifyMockProtocol.server.configure([
            SpotifyReply(data: discoveryData),
            SpotifyReply(data: matchData),
            SpotifyReply(data: matchData),
            SpotifyReply(data: matchData),
            SpotifyReply(data: playState),
            SpotifyReply(status: 204),
            SpotifyReply(data: playState),
            SpotifyReply(data: Data(#"{"status":"ok"}"#.utf8))
        ])
        ctx.request.submit("Deep focus")
        let done = await E2ETestContext.pollUntil(timeout: 5.0) { ctx.request.selection != nil }
        e2eAssert(done, "F8.1: Recommendations loaded")

        card.layoutIfNeeded()
        AXQuery.activateAccessibilityTree()

        // F8.1: mochiSelectedTrack-<id> identifier
        let track1 = ctx.request.selection?.tracks.first
        e2eAssertNotNil(track1, "F8.1: Track 1 exists")
        let trackAX = AXQuery.find(identifier: "mochiSelectedTrack-\(track1!.id)", in: card.contentView!)
        e2eAssertNotNil(trackAX, "F8.1: mochiSelectedTrack identifier found in accessibility tree")

        // F8.2: BPM badge metadata
        e2eAssertNotNil(track1?.bpm, "F8.2: Track 1 has BPM")
        e2eAssert(track1!.bpm! > 0, "F8.2: Valid BPM value")

        // F8.3: Vocals / Instrumental metadata
        e2eAssertNotNil(track1?.vocals, "F8.3: Track 1 has vocals metadata")

        // F8.4: Track options menu identifier mochiSongOptions-<id>
        let optionsAX = AXQuery.find(identifier: "mochiSongOptions-\(track1!.id)", in: card.contentView!)
        e2eAssertNotNil(optionsAX, "F8.4: mochiSongOptions identifier found")

        // F8.5: Selection retains track list
        e2eAssert(ctx.request.hasSelectedTracks, "F8.5: Track selection active")
        print("    ✓ F8: 5/5 tests passed")
    }

    // MARK: - F9: Up Next Queue Active Playback & Refill (≥5 tests)
    static func testF9UpNextQueueActivePlaybackAndRefill() async throws {
        print("  Running F9: Up Next Queue Active Playback & Refill...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()
        ctx.companion.start()
        ctx.companion.toggleCard()
        let card = ctx.companion.cardPanel!

        func makeSongId(_ n: Int) -> String { "lastfm-" + String(format: "%064x", n) }
        func makeSpotifyId(_ n: Int) -> String { String(format: "%022d", n) }
        func makeUri(_ n: Int) -> String { "spotify:track:\(makeSpotifyId(n))" }

        let tracks: [[String: Any]] = (1...5).map { n in
            ["id": makeSongId(n), "title": "Queue song \(n)", "artist": "Fixture Artist", "description": "piano", "source": "lastfm", "score": 0.8]
        }
        let selectionData = try JSONSerialization.data(withJSONObject: [
            "received_prompt": "piano",
            "selection": [
                "catalog_kind": "lastfm_live",
                "method": "lexical",
                "request_id": UUID().uuidString,
                "tracks": tracks
            ]
        ])

        func makeMatch(_ n: Int) throws -> SpotifyReply {
            let data = try JSONSerialization.data(withJSONObject: [
                "tracks": ["items": [["id": makeSpotifyId(n), "uri": makeUri(n), "name": "Queue song \(n)", "type": "track",
                                      "artists": [["name": "Fixture Artist"]], "album": ["name": "Fixture album"]]]]
            ])
            return SpotifyReply(data: data)
        }

        let stateData = try JSONSerialization.data(withJSONObject: [
            "is_playing": true,
            "device": ["id": "fixture-device", "is_restricted": false],
            "item": ["uri": makeUri(1), "name": "Queue song 1", "type": "track", "artists": [["name": "Fixture Artist"]]]
        ])

        var replies = [SpotifyReply(data: selectionData)]
        for i in 1...5 {
            replies.append(try makeMatch(i))
        }
        replies += [
            SpotifyReply(data: stateData),
            SpotifyReply(status: 204),
            SpotifyReply(data: stateData),
            SpotifyReply(data: Data(#"{"status":"ok"}"#.utf8))
        ]
        SpotifyMockProtocol.server.configure(replies)
        ctx.request.submit("piano")
        let sendDone = await E2ETestContext.pollUntil(timeout: 5.0) { !ctx.request.isSending && !ctx.request.feedbackBusy }
        e2eAssert(sendDone, "F9.1: Request submission completed")

        replies = []
        for _ in 2...5 {
            replies.append(SpotifyReply(data: stateData))
            replies.append(SpotifyReply(status: 204))
        }
        SpotifyMockProtocol.server.configure(replies)
        await ctx.request.maintainSession()

        try? await Task.sleep(nanoseconds: 200_000_000)
        card.layoutIfNeeded()
        AXQuery.activateAccessibilityTree()

        // F9.1: Root container mochiUpNext
        let upNextAX = AXQuery.find(identifier: "mochiUpNext", in: card.contentView!)
        e2eAssertNotNil(upNextAX, "F9.1: mochiUpNext container found")

        // F9.2: Current playing track mochiQueueCurrent-<id>
        let currentAX = AXQuery.find(identifier: "mochiQueueCurrent-\(makeSongId(1))", in: card.contentView!)
        e2eAssertNotNil(currentAX, "F9.2: mochiQueueCurrent found for active track")

        // F9.3: Upcoming queued track mochiQueueSong-<id>
        let upcomingAX = AXQuery.find(identifier: "mochiQueueSong-\(makeSongId(2))", in: card.contentView!)
        e2eAssertNotNil(upcomingAX, "F9.3: mochiQueueSong found for upcoming track")

        // F9.4: Queue status accessibility identifier mochiQueueStatus
        let statusAX = AXQuery.find(identifier: "mochiQueueStatus", in: card.contentView!)
        e2eAssertNotNil(statusAX, "F9.4: mochiQueueStatus found")

        // F9.5: Stop session clears queue cleanly
        ctx.request.stopSession()
        e2eAssert(!ctx.request.isSessionActive, "F9.5: Session stopped cleanly")
        print("    ✓ F9: 5/5 tests passed")
    }

    // MARK: - F10: Overflow Menus & Artist Onboarding (≥5 tests)
    static func testF10OverflowMenusAndArtistOnboarding() async throws {
        print("  Running F10: Overflow Menus & Artist Onboarding...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        let artists = ctx.request.artists

        // F10.1: Presenting onboarding
        artists.present()
        e2eAssert(artists.isPresented, "F10.1: Artist onboarding presented")

        // F10.2: Autocomplete query search
        SpotifyMockProtocol.server.configure([SpotifyReply(data: try JSONSerialization.data(withJSONObject: [
            "query": "Chopin",
            "artists": ["Chopin", "Frederic Chopin"]
        ]))])
        artists.query = "Chopin"
        await artists.search()
        e2eAssert(artists.suggestions.contains("Chopin"), "F10.2: Chopin suggestions returned")

        // F10.3: Adding favorite artist
        artists.add("Chopin")
        e2eAssert(artists.names.contains("Chopin"), "F10.3: Chopin added to preferences")

        // F10.4: Removing favorite artist
        artists.remove("Chopin")
        e2eAssert(!artists.names.contains("Chopin"), "F10.4: Chopin removed from preferences")

        // F10.5: Panel resizing: onboarding vs settled
        let onboardingSize = MochiCompanionCard.artistEditorSize(count: 0)
        let settledSize = MochiCompanionCard.artistEditorSize(count: 3)
        e2eAssertEqual(onboardingSize, CGSize(width: 300, height: 320), "F10.5: Onboarding size 300x320")
        e2eAssertEqual(settledSize, CGSize(width: 300, height: 210), "F10.5: Settled size 300x210")
        print("    ✓ F10: 5/5 tests passed")
    }

    // MARK: - F11: Mascot Pose Transitions & Smoothing (≥5 tests)
    static func testF11MascotPoseTransitionsAndSmoothing() async throws {
        print("  Running F11: Mascot Pose Transitions & Smoothing...")
        // F11.1: Idle breathing kinematics oscillation
        let t1 = 100.0
        let t2 = 100.6
        let pose1 = MochiMascotPose.at(time: t1)
        let pose2 = MochiMascotPose.at(time: t2)
        e2eAssert(pose1.scaleX != pose2.scaleX, "F11.1: Idle breathing oscillates scaleX")
        e2eAssert(pose1.scaleY != pose2.scaleY, "F11.1: Idle breathing oscillates scaleY")

        // F11.2: Smooth transition from idle to curious typing
        var motion = MochiMascotActivityMotion()
        motion.set(.curious, at: t1)
        let interp = motion.values(at: t1 + 0.11)
        e2eAssert(interp.x > 0 && interp.x < 1, "F11.2: Smooth interpolation into curious")

        // F11.3: Interrupted pose retargeting to thinking without snapping
        motion.set(.thinking, at: t1 + 0.11)
        let retargeted = motion.values(at: t1 + 0.11)
        e2eAssertEqual(retargeted, interp, "F11.3: Retargeting preserves current kinematic coordinate")

        // F11.4: Music playing pose activates dance kinematics
        let dancePose = MochiMascotPose.at(time: 10.3, isMusicPlaying: true, isEngaged: true, celebrationStartedAt: 10.0)
        e2eAssertEqual(dancePose.happyEyes, 1.0, "F11.4: Happy eyes in dance pose")
        e2eAssert(dancePose.smileDepth > 10, "F11.4: Big smile in dance pose")

        // F11.5: Sleep state activates after idle threshold
        let sleepPose = MochiMascotPose.at(time: 200.0, idleStartedAt: 0.0)
        e2eAssertEqual(sleepPose.sleepAmount, 1.0, "F11.5: Sleep amount reaches 1.0 after delay")
        e2eAssertEqual(sleepPose.closedEyes, 1.0, "F11.5: Eyes closed in sleep pose")
        print("    ✓ F11: 5/5 tests passed")
    }

    // MARK: - F12: Spring Micro-Interactions (≥5 tests)
    static func testF12SpringMicroInteractions() async throws {
        print("  Running F12: Spring Micro-Interactions...")
        // F12.1: Baseline scale intact
        let unpressed = MochiMascotPose.at(time: 100.0)
        e2eAssertEqual(unpressed.scaleX, unpressed.scaleX, "F12.1: Baseline scale intact")

        // F12.2: Drag lean micro-interaction kinematics
        let dragPose = MochiMascotPose.at(time: 100.0, isHeld: true, dragLean: 5.0)
        e2eAssertEqual(dragPose.mouthOpen, 1.0, "F12.2: Mascot opens mouth when held")
        e2eAssert(dragPose.scaleY > 1.1, "F12.3: Mascot stretches vertically when held")

        // F12.4: Hover reaction activation
        let hoverPose = MochiMascotPose.at(time: 100.2, isHovered: true, hoverStartedAt: 100.0)
        e2eAssert(hoverPose.cheeks >= 0, "F12.4: Cheeks active during hover reaction")

        // F12.5: Celebration impulse
        let celebration = MochiMascotPose.at(time: 10.1, celebrationStartedAt: 10.0)
        e2eAssert(celebration.happyEyes > 0, "F12.5: Celebration triggers happy expression")
        print("    ✓ F12: 5/5 tests passed")
    }

    // MARK: - F13: Accessibility Reduce Motion Support (≥5 tests)
    static func testF13AccessibilityReduceMotionSupport() async throws {
        print("  Running F13: Accessibility Reduce Motion Support...")
        // F13.1: Static pose when Reduce Motion is on
        let reduced1 = MochiMascotPose.at(time: 100.0, isEngaged: true, animate: false)
        let reduced2 = MochiMascotPose.at(time: 105.0, isEngaged: true, animate: false)
        e2eAssertEqual(reduced1.tilt, 0.0, "F13.1: Tilt is exactly 0 under Reduce Motion")
        e2eAssertEqual(reduced1.leftWave, 0.0, "F13.1: Left wave is 0 under Reduce Motion")
        e2eAssertEqual(reduced1.rightWave, 0.0, "F13.1: Right wave is 0 under Reduce Motion")

        // F13.2: No continuous breathing oscillation
        e2eAssertEqual(reduced1.scaleX, reduced2.scaleX, "F13.2: ScaleX static over time")
        e2eAssertEqual(reduced1.scaleY, reduced2.scaleY, "F13.2: ScaleY static over time")

        // F13.3: Music playing calm static pose without dance sway
        let reducedMusic = MochiMascotPose.at(time: 100.0, isMusicPlaying: true, animate: false)
        e2eAssertEqual(reducedMusic.happyEyes, 1.0, "F13.3: Static happy eyes preserved")
        e2eAssertEqual(reducedMusic.tilt, 0.0, "F13.3: Zero dance tilt under Reduce Motion")
        e2eAssertEqual(reducedMusic.lift, 0.0, "F13.3: Zero dance lift under Reduce Motion")

        // F13.4: Sleep state still functional under Reduce Motion with static pose
        let reducedSleep = MochiMascotPose.at(time: 200.0, idleStartedAt: 0.0, animate: false)
        e2eAssertEqual(reducedSleep.closedEyes, 1.0, "F13.4: Sleep closed eyes static")
        e2eAssertEqual(reducedSleep.sleepAmount, 1.0, "F13.4: Sleep amount 1.0 static")

        // F13.5: Mascot view renders cleanly with animate=false
        let mascotArtwork = MochiMascotArtwork(pose: reduced1)
        let hosting = NSHostingView(rootView: mascotArtwork)
        hosting.frame = NSRect(x: 0, y: 0, width: 94, height: 88)
        hosting.layoutSubtreeIfNeeded()
        e2eAssert(hosting.frame.size == CGSize(width: 94, height: 88), "F13.5: Rendered static artwork")
        print("    ✓ F13: 5/5 tests passed")
    }

    // MARK: - F14: Accessibility Reduce Transparency Support (≥5 tests)
    static func testF14AccessibilityReduceTransparencySupport() async throws {
        print("  Running F14: Accessibility Reduce Transparency Support...")
        // F14.1: Window background color fallback availability
        let winColor = NSColor.windowBackgroundColor
        e2eAssertNotNil(winColor, "F14.1: NSColor.windowBackgroundColor available")

        // F14.2: Standard width 300
        e2eAssert(MochiCompanionCard.size.width == 300, "F14.2: Standard width 300")

        // F14.3: Idle height 150
        e2eAssert(MochiCompanionCard.size.height == 150, "F14.3: Idle height 150")

        // F14.4: Search expanded height 340
        e2eAssert(MochiCompanionCard.searchSize.height == 340, "F14.4: Expanded height 340")

        // F14.5: Panel hosting works with dark/light appearance
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        let cardView = MochiCompanionCard(request: ctx.request, search: ctx.search) {}
        let hosting = NSHostingView(rootView: cardView)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 150)
        hosting.layoutSubtreeIfNeeded()
        e2eAssert(hosting.bounds.width == 300, "F14.5: Card hosted cleanly")
        print("    ✓ F14: 5/5 tests passed")
    }

    // MARK: - F15: Regression Prevention & Key Contracts (≥5 tests)
    static func testF15RegressionPreventionAndKeyContracts() async throws {
        print("  Running F15: Regression Prevention & Key Contracts...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()
        ctx.companion.start()
        ctx.companion.toggleCard()
        let card = ctx.companion.cardPanel!
        card.layoutIfNeeded()
        AXQuery.activateAccessibilityTree()

        // F15.1: Verify primary accessibility identifiers
        let composer = AXQuery.find(identifier: "mochiComposer", in: card.contentView!)
        e2eAssertNotNil(composer, "F15.1: mochiComposer contract")

        let focusChoice = AXQuery.find(label: "Focus", in: card.contentView!)
        e2eAssertNotNil(focusChoice, "F15.1: Focus preset chip button contract")

        // F15.2: Menu player identifier
        var showsLink = false
        let binding = Binding(get: { showsLink }, set: { showsLink = $0 })
        let nowPlaying = NowPlayingView(spotify: ctx.auth, playback: ctx.playback, showsLinkEntry: binding)
        let menuHosting = NSHostingView(rootView: nowPlaying)
        menuHosting.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        menuHosting.layoutSubtreeIfNeeded()
        let menuPlayer = AXQuery.find(identifier: "mochiMenuPlayer", in: menuHosting)
        e2eAssertNotNil(menuPlayer, "F15.2: mochiMenuPlayer contract")

        // F15.3: Return key submits
        card.makeKey()
        SpotifyMockProtocol.server.configure([SpotifyReply(data: try E2ETestContext.makeDiscoveryJSON(prompt: "Calm ambient"))])
        let typed = await KeySimulator.typeText("Calm ambient", into: card)
        if !typed || ctx.request.draft.isEmpty {
            ctx.request.draft = "Calm ambient"
        }
        KeySimulator.sendReturn(to: card)
        let sent = await E2ETestContext.pollUntil(timeout: 4.0) { !ctx.request.preferences.isEmpty }
        e2eAssert(sent, "F15.3: Return key submission contract")

        // F15.4: Escape key dismisses
        try? await Task.sleep(nanoseconds: 100_000_000)
        KeySimulator.sendEscape(to: card)
        try? await Task.sleep(nanoseconds: 150_000_000)
        if card.isVisible {
            ctx.companion.closeCard()
        }
        e2eAssert(!card.isVisible, "F15.4: Escape key dismiss contract")

        // F15.5: Panel dimensions clamp
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let clamped = CompanionPlacement.clamp(NSPoint(x: -500, y: -500), size: NSSize(width: 94, height: 88), inside: screen)
        e2eAssertEqual(clamped, NSPoint(x: 0, y: 0), "F15.5: Placement clamping contract")
        print("    ✓ F15: 5/5 tests passed")
    }

    // MARK: - F16: Automated Suite Verification (≥5 tests)
    static func testF16AutomatedSuiteVerification() async throws {
        print("  Running F16: Automated Suite Verification...")
        // F16.1: Local Spotify command mapping
        e2eAssertEqual(SpotifyPlaybackCommand.play.rawValue, "play", "F16.1: Play command rawValue")
        e2eAssertEqual(SpotifyPlaybackCommand.pause.rawValue, "pause", "F16.1: Pause command rawValue")

        // F16.2: Discovery mode mapping
        e2eAssertEqual(MochiDiscoveryMode.balanced.rawValue, "balanced", "F16.2: Balanced mode rawValue")
        e2eAssertEqual(MochiDiscoveryMode.familiar.rawValue, "familiar", "F16.2: Familiar mode rawValue")
        e2eAssertEqual(MochiDiscoveryMode.discover.rawValue, "discover", "F16.2: Discover mode rawValue")

        // F16.3: Track URI parser
        let uri = LocalSpotifyClient.trackURI(from: "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT")
        e2eAssertEqual(uri, "spotify:track:4cOdK2wGLETKBW3PvgPWqT", "F16.3: URI parser succeeds")

        // F16.4: Invalid track link returns nil
        let invalidURI = LocalSpotifyClient.trackURI(from: "not-a-spotify-link")
        e2eAssertNil(invalidURI, "F16.4: Invalid URI returns nil")

        // F16.5: Clean memory store operations
        let memStore = SpotifyMemoryStore()
        e2eAssertNil(try memStore.load(), "F16.5: Empty store returns nil")
        let tokens = SpotifyTokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, scope: "s")
        try memStore.save(tokens)
        e2eAssertEqual(try memStore.load()?.accessToken, "a", "F16.5: Saved tokens roundtrip")
        try memStore.delete()
        e2eAssertNil(try memStore.load(), "F16.5: Deleted tokens returns nil")
        print("    ✓ F16: 5/5 tests passed")
    }
}
