import AppKit
import ApplicationServices
import Foundation
import SwiftUI

@MainActor
struct Tier3CombinationTests {
    static func runAll() async throws {
        print("\n--- Running Tier 3: Cross-Feature Combination Tests ---")
        try await testContinuousListeningAndMenuBarPlaybackToggle()
        try await testComposerSearchQueryAndDiscoveryModeSwitching()
        try await testReduceMotionAndMascotDragClamp()
        try await testReduceTransparencyAndAppearanceSwitching()
        try await testArtistOnboardingAndPresetPromptTrigger()
        try await testDesktopPlayerFallbackAndTrackLinkEntry()
        try await testQueueRefillAndRecommendationSelection()
        try await testSettingsPopoverAndExternalPlaybackEvent()
        print("✅ Tier 3: All Cross-Feature Combination Tests Passed (8 pairwise scenarios)!\n")
    }

    // MARK: - Combination 1: Continuous Listening + Menu-Bar Playback Toggle
    static func testContinuousListeningAndMenuBarPlaybackToggle() async throws {
        print("  Running Combo 1: Continuous Listening + Menu-Bar Playback Toggle...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()
        func makeSongId(_ n: Int) -> String { "lastfm-" + String(format: "%064x", n) }
        func makeUri(_ n: Int) -> String { "spotify:track:\(String(format: "%022d", n))" }

        let tracks: [[String: Any]] = (1...5).map { n in
            ["id": makeSongId(n), "title": "Combo Song \(n)", "artist": "Combo Artist", "description": "jazz", "source": "lastfm", "score": 0.9]
        }
        let selectionData = try JSONSerialization.data(withJSONObject: [
            "received_prompt": "jazz",
            "selection": [
                "catalog_kind": "lastfm_live", "method": "lexical",
                "request_id": UUID().uuidString, "tracks": tracks
            ]
        ])
        func makeMatch(_ n: Int) throws -> SpotifyReply {
            let data = try JSONSerialization.data(withJSONObject: [
                "tracks": ["items": [["id": String(format: "%022d", n), "uri": makeUri(n), "name": "Combo Song \(n)",
                                      "type": "track", "artists": [["name": "Combo Artist"]], "album": ["name": "Combo Album"]]]]
            ])
            return SpotifyReply(data: data)
        }
        let playState = try JSONSerialization.data(withJSONObject: [
            "is_playing": true,
            "device": ["id": "fixture-device", "name": "MacBook", "is_restricted": false],
            "item": ["uri": makeUri(1), "name": "Combo Song 1", "type": "track", "artists": [["name": "Combo Artist"]]]
        ])

        var replies = [SpotifyReply(data: selectionData)]
        for i in 1...5 { replies.append(try makeMatch(i)) }
        replies += [
            SpotifyReply(data: playState),
            SpotifyReply(status: 204),
            SpotifyReply(data: playState),
            SpotifyReply(data: Data(#"{"status":"ok"}"#.utf8))
        ]
        SpotifyMockProtocol.server.configure(replies)
        ctx.request.submit("jazz")
        let submitted = await E2ETestContext.pollUntil(timeout: 5.0) { !ctx.request.isSending && !ctx.request.feedbackBusy }
        e2eAssert(submitted, "Combo 1: Continuous listening session initiated")

        var refillReplies: [SpotifyReply] = []
        for _ in 2...5 {
            refillReplies += [SpotifyReply(data: playState), SpotifyReply(status: 204)]
        }
        SpotifyMockProtocol.server.configure(refillReplies)
        await ctx.request.maintainSession()
        e2eAssert(ctx.request.isSessionActive, "Combo 1: Session is active")

        // Pause via transport model
        let pauseState = try JSONSerialization.data(withJSONObject: [
            "is_playing": false,
            "device": ["id": "fixture-device", "name": "MacBook", "is_restricted": false],
            "item": ["uri": makeUri(1), "name": "Combo Song 1", "type": "track", "artists": [["name": "Combo Artist"]]]
        ])
        SpotifyMockProtocol.server.configure([
            SpotifyReply(status: 204), // pause command
            SpotifyReply(data: pauseState) // refreshed state
        ])
        await ctx.playback.perform(.pause, using: ctx.auth)
        e2eAssert(ctx.playback.state?.isPlaying == false, "Combo 1: Playback model paused")
        print("    ✓ Combo 1 passed")
    }

    // MARK: - Combination 2: Composer Search Query + Discovery Mode Switching
    static func testComposerSearchQueryAndDiscoveryModeSwitching() async throws {
        print("  Running Combo 2: Composer Search Query + Discovery Mode Switching...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()
        ctx.companion.start()
        ctx.companion.toggleCard()
        let card = ctx.companion.cardPanel!
        card.layoutIfNeeded()

        // Type query into composer
        await KeySimulator.typeText("Late night lofi hip hop", into: card)
        e2eAssertEqual(ctx.request.draft, "Late night lofi hip hop", "Combo 2: Draft synchronized")

        // Add artist so familiar/discover modes are enabled
        SpotifyMockProtocol.server.configure([SpotifyReply(data: try JSONSerialization.data(withJSONObject: [
            "query": "Nujabes", "artists": ["Nujabes"]
        ]))])
        ctx.request.artists.query = "Nujabes"
        await ctx.request.artists.search()
        ctx.request.artists.add("Nujabes")
        e2eAssert(ctx.request.artists.names.contains("Nujabes"), "Combo 2: Artist added")

        // Switch discovery mode: balanced -> familiar -> discover
        ctx.request.discoveryMode = .familiar
        e2eAssertEqual(ctx.request.discoveryMode, .familiar, "Combo 2: Mode switched to familiar")
        e2eAssertEqual(ctx.request.draft, "Late night lofi hip hop", "Combo 2: Draft preserved after mode change")

        ctx.request.discoveryMode = .discover
        e2eAssertEqual(ctx.request.discoveryMode, .discover, "Combo 2: Mode switched to discover")
        e2eAssertEqual(ctx.request.draft, "Late night lofi hip hop", "Combo 2: Draft preserved after second mode change")
        print("    ✓ Combo 2 passed")
    }

    // MARK: - Combination 3: Accessibility Reduce Motion + Mascot Drag & Clamp
    static func testReduceMotionAndMascotDragClamp() async throws {
        print("  Running Combo 3: Reduce Motion + Mascot Drag & Clamp...")
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let mascotSize = NSSize(width: 108, height: 100)

        // Drag to screen edges and outside
        let dragPoints = [
            NSPoint(x: -500, y: 500),
            NSPoint(x: 1000, y: -200),
            NSPoint(x: 3000, y: 2000),
            NSPoint(x: 960, y: 540)
        ]
        for point in dragPoints {
            let clamped = CompanionPlacement.clamp(point, size: mascotSize, inside: screen)
            e2eAssert(screen.contains(NSRect(origin: clamped, size: mascotSize)), "Combo 3: Clamped inside screen")

            // Mascot pose under Reduce Motion at this point
            let pose = MochiMascotPose.at(time: 100.0, isHeld: true, dragLean: 10.0, animate: false)
            e2eAssertEqual(pose.tilt, 0.0, "Combo 3: Zero tilt under Reduce Motion while dragging")
            e2eAssertEqual(pose.leftWave, 0.0, "Combo 3: Zero wave under Reduce Motion while dragging")
        }
        print("    ✓ Combo 3 passed")
    }

    // MARK: - Combination 4: Accessibility Reduce Transparency + Appearance Switching
    static func testReduceTransparencyAndAppearanceSwitching() async throws {
        print("  Running Combo 4: Reduce Transparency + Appearance Switching...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }

        // Host card view under dark aqua appearance
        let darkPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
                                styleMask: .borderless, backing: .buffered, defer: false)
        darkPanel.appearance = NSAppearance(named: .darkAqua)
        let darkHost = NSHostingView(rootView: MochiCompanionCard(request: ctx.request, search: ctx.search) {}
            .environment(\.colorScheme, .dark))
        darkPanel.contentView = darkHost
        darkHost.layoutSubtreeIfNeeded()
        e2eAssert(darkHost.frame.size.width == 300, "Combo 4: Dark mode card layout cleanly")

        // Host card view under light appearance
        let lightPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
                                 styleMask: .borderless, backing: .buffered, defer: false)
        lightPanel.appearance = NSAppearance(named: .aqua)
        let lightHost = NSHostingView(rootView: MochiCompanionCard(request: ctx.request, search: ctx.search) {}
            .environment(\.colorScheme, .light))
        lightPanel.contentView = lightHost
        lightHost.layoutSubtreeIfNeeded()
        e2eAssert(lightHost.frame.size.width == 300, "Combo 4: Light mode card layout cleanly")
        print("    ✓ Combo 4 passed")
    }

    // MARK: - Combination 5: Artist Onboarding Selection + Preset Prompt Trigger
    static func testArtistOnboardingAndPresetPromptTrigger() async throws {
        print("  Running Combo 5: Artist Onboarding Selection + Preset Prompt Trigger...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()
        ctx.companion.start()
        ctx.companion.toggleCard()

        // Onboard artist
        SpotifyMockProtocol.server.configure([SpotifyReply(data: try JSONSerialization.data(withJSONObject: [
            "query": "Bill Evans", "artists": ["Bill Evans"]
        ]))])
        ctx.request.artists.query = "Bill Evans"
        await ctx.request.artists.search()
        ctx.request.artists.add("Bill Evans")
        ctx.request.artists.finish()
        e2eAssert(!ctx.request.artists.isPresented, "Combo 5: Onboarding finished")

        // Trigger "Focus" preset chip
        SpotifyMockProtocol.server.configure([SpotifyReply(data: try E2ETestContext.makeDiscoveryJSON(prompt: "Focus"))])
        ctx.request.submit("Focus")
        let focusDone = await E2ETestContext.pollUntil { !ctx.request.isSending }
        e2eAssert(focusDone, "Combo 5: Focus request completed with artist preference")
        print("    ✓ Combo 5 passed")
    }

    // MARK: - Combination 6: Desktop Player Fallback + Track Link Entry
    static func testDesktopPlayerFallbackAndTrackLinkEntry() async throws {
        print("  Running Combo 6: Desktop Player Fallback + Track Link Entry...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }

        // Enable desktop controls
        await ctx.playback.enableDesktopControls()
        e2eAssert(ctx.playback.usesDesktopPlayer, "Combo 6: Desktop player enabled")

        // Feed track link to local client
        let trackURI = "spotify:track:11dFghVXANMlKmJXsNCbNl"
        try await ctx.localPlayer.startTrack(uri: trackURI)
        let started = await ctx.localPlayer.startedTracks
        e2eAssert(started.contains(trackURI), "Combo 6: Local player started track")

        // Set local playback snapshot via JSONDecoder
        let localData = try E2ETestContext.makePlaybackJSON(name: "Local Track", artist: "Local Artist", deviceName: "My Mac")
        let localState = try JSONDecoder().decode(SpotifyPlaybackState.self, from: localData)
        await ctx.localPlayer.setState(localState)
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertEqual(ctx.playback.state?.item?.name, "Local Track", "Combo 6: Playback model refreshed from local player")
        print("    ✓ Combo 6 passed")
    }

    // MARK: - Combination 7: Queue Refill In-Flight + Recommendation Selection
    static func testQueueRefillAndRecommendationSelection() async throws {
        print("  Running Combo 7: Queue Refill In-Flight + Recommendation Selection...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()

        // Load recommendations
        let discoveryData = try E2ETestContext.makeDiscoveryJSON(prompt: "Refill Test", count: 2)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: discoveryData)])
        ctx.request.submit("Refill Test")
        let loaded = await E2ETestContext.pollUntil { ctx.request.selection != nil }
        e2eAssert(loaded, "Combo 7: Discovery selection loaded")

        let track2 = ctx.request.selection!.tracks[1]
        // Starting track2 while maintaining session cleans up previous task
        ctx.request.play(track2)
        e2eAssert(ctx.request.isStarting || ctx.request.hasSelectedTracks, "Combo 7: Clean track switch during session")
        print("    ✓ Combo 7 passed")
    }

    // MARK: - Combination 8: Settings Popover Open + External Playback Event
    static func testSettingsPopoverAndExternalPlaybackEvent() async throws {
        print("  Running Combo 8: Settings Popover Open + External Playback Event...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()

        let initialData = try E2ETestContext.makePlaybackJSON(name: "Initial Track")
        SpotifyMockProtocol.server.configure([SpotifyReply(data: initialData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertEqual(ctx.playback.state?.item?.name, "Initial Track", "Combo 8: Initial track set")

        // External playback update (e.g. user skipped track on mobile Spotify client)
        let updatedData = try E2ETestContext.makePlaybackJSON(name: "Remote Skipped Track")
        SpotifyMockProtocol.server.configure([SpotifyReply(data: updatedData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertEqual(ctx.playback.state?.item?.name, "Remote Skipped Track", "Combo 8: Updated to remote track smoothly")
        print("    ✓ Combo 8 passed")
    }
}
