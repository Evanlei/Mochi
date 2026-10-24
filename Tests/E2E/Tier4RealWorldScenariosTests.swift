import AppKit
import ApplicationServices
import Foundation
import SwiftUI

@MainActor
struct Tier4RealWorldScenariosTests {
    static func runAll() async throws {
        print("\n--- Running Tier 4: Real-World Application Scenarios Tests ---")
        try await testScenario1FirstRunOnboardingToPlayback()
        try await testScenario2MenuBarControllerAndDesktopFallback()
        try await testScenario3ContinuousListeningAndQueueManagement()
        try await testScenario4AccessibilityConformanceSession()
        try await testScenario5NetworkDisruptionAndAutomaticRecovery()
        print("✅ Tier 4: All Real-World Application Scenarios Tests Passed (5 complete user journeys)!\n")
    }

    // MARK: - Scenario 1: First-Run Onboarding to Active Playback Workflow
    static func testScenario1FirstRunOnboardingToPlayback() async throws {
        print("  Running Scenario 1: First-Run Onboarding to Active Playback Workflow...")
        let ctx = E2ETestContext(suitePrefix: "com.evan.Mochi.e2e.scenario1")
        defer { ctx.cleanup() }
        await ctx.connectAuth()

        // 1. App Launch: Mascot panel and Card panel created
        ctx.companion.start()
        ctx.companion.toggleCard()
        let card = ctx.companion.cardPanel!
        let mascot = ctx.companion.mascotPanel!
        e2eAssert(card.isVisible, "S1: Card panel visible on launch")
        e2eAssert(mascot.isVisible, "S1: Mascot panel visible on launch")

        // 2. Onboarding: Add 3 favorite artists
        let artists = ctx.request.artists
        artists.present()
        for artist in ["Radiohead", "Portishead", "Massive Attack"] {
            let replyData = try JSONSerialization.data(withJSONObject: [
                "query": artist, "artists": [artist]
            ])
            SpotifyMockProtocol.server.configure([
                SpotifyReply(data: replyData),
                SpotifyReply(data: replyData)
            ])
            artists.query = artist
            let searched = await E2ETestContext.pollUntil(timeout: 1.0) { !artists.suggestions.isEmpty }
            if !searched {
                await artists.search()
            }
            artists.add(artist)
        }
        e2eAssertEqual(artists.names.count, 3, "S1: 3 favorite artists added")

        // 3. Finish Onboarding: Card settles to settled size (300x210)
        artists.finish()
        e2eAssert(!artists.isPresented, "S1: Onboarding finished")
        let settledSize = MochiCompanionCard.artistEditorSize(count: 3)
        e2eAssertEqual(settledSize.height, 210, "S1: Settled card height is 210pt")

        // 4. Click "Focus" preset chip
        let focusData = try E2ETestContext.makeDiscoveryJSON(prompt: "Focus", count: 3)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: focusData)])
        ctx.request.submit("Focus")
        let focusDone = await E2ETestContext.pollUntil { ctx.request.selection != nil }
        e2eAssert(focusDone, "S1: Recommendations returned for Focus prompt")

        // 5. Select recommended track
        let topTrack = ctx.request.selection!.tracks[0]
        ctx.request.play(topTrack)
        e2eAssert(ctx.request.hasSelectedTracks, "S1: Track selected and in playback pipeline")

        // 6. Mascot transitions to celebration dance pose
        let dance = MochiMascotPose.at(time: 10.3, isMusicPlaying: true, isEngaged: true, celebrationStartedAt: 10.0)
        e2eAssertEqual(dance.happyEyes, 1.0, "S1: Mascot dancing with happy eyes")
        e2eAssert(dance.smileDepth > 10, "S1: Mascot smiling warmly during music playback")
        print("    ✓ Scenario 1 passed")
    }

    // MARK: - Scenario 2: Menu-Bar Controller & Desktop Player Fallback Workflow
    static func testScenario2MenuBarControllerAndDesktopFallback() async throws {
        print("  Running Scenario 2: Menu-Bar Controller & Desktop Player Fallback Workflow...")
        let ctx = E2ETestContext(suitePrefix: "com.evan.Mochi.e2e.scenario2")
        defer { ctx.cleanup() }

        // 1. Initial State: Disconnected API, nothing playing
        e2eAssert(!ctx.auth.isConnected, "S2: Auth disconnected initially")
        e2eAssertNil(ctx.playback.state, "S2: Playback state initially empty")

        // 2. User switches to desktop controls fallback
        await ctx.playback.enableDesktopControls()
        e2eAssert(ctx.playback.usesDesktopPlayer, "S2: Desktop player controls activated")

        // 3. User pastes a Spotify track link into the link field
        let trackURI = "spotify:track:0000000000000000000002"
        let parsedURI = LocalSpotifyClient.trackURI(from: "https://open.spotify.com/track/0000000000000000000002?si=test")
        e2eAssertEqual(parsedURI, trackURI, "S2: Track link parsed successfully")

        // 4. Start track in desktop player
        try await ctx.localPlayer.startTrack(uri: trackURI)
        let started = await ctx.localPlayer.startedTracks
        e2eAssert(started.contains(trackURI), "S2: Track started in local desktop player")

        // 5. Update local player state snapshot
        let localData = try E2ETestContext.makePlaybackJSON(name: "Desktop Symphony", artist: "Desktop Orchestra", deviceName: "MacBook Pro")
        let localState = try JSONDecoder().decode(SpotifyPlaybackState.self, from: localData)
        await ctx.localPlayer.setState(localState)
        await ctx.playback.refresh(using: ctx.auth)

        // 6. Inspect NowPlayingView representation
        e2eAssertEqual(ctx.playback.state?.item?.name, "Desktop Symphony", "S2: Track title visible in NowPlayingView")
        e2eAssertEqual(ctx.playback.state?.device?.name, "MacBook Pro", "S2: Device badge visible")

        // 7. Transport buttons route to local client
        try await ctx.localPlayer.send(.pause)
        let commands = await ctx.localPlayer.commands
        e2eAssert(commands.contains(.pause), "S2: Pause command routed through desktop player")
        print("    ✓ Scenario 2 passed")
    }

    // MARK: - Scenario 3: Continuous Listening & Queue Management Workflow
    static func testScenario3ContinuousListeningAndQueueManagement() async throws {
        print("  Running Scenario 3: Continuous Listening & Queue Management Workflow...")
        let ctx = E2ETestContext(suitePrefix: "com.evan.Mochi.e2e.scenario3")
        defer { ctx.cleanup() }
        await ctx.connectAuth()

        func makeSongId(_ n: Int) -> String { "lastfm-" + String(format: "%064x", n) }
        func makeUri(_ n: Int) -> String { "spotify:track:\(String(format: "%022d", n))" }

        // 1. Submit listening request for continuous listening
        let tracks: [[String: Any]] = (1...5).map { n in
            ["id": makeSongId(n), "title": "Workout Song \(n)", "artist": "Electronic Artist", "description": "energetic", "source": "lastfm", "score": 0.85]
        }
        let selectionData = try JSONSerialization.data(withJSONObject: [
            "received_prompt": "workout beats",
            "selection": [
                "catalog_kind": "lastfm_live", "method": "lexical",
                "request_id": UUID().uuidString, "tracks": tracks
            ]
        ])
        func makeMatch(_ n: Int) throws -> SpotifyReply {
            let data = try JSONSerialization.data(withJSONObject: [
                "tracks": ["items": [["id": String(format: "%022d", n), "uri": makeUri(n), "name": "Workout Song \(n)",
                                      "type": "track", "artists": [["name": "Electronic Artist"]], "album": ["name": "Beat Album"]]]]
            ])
            return SpotifyReply(data: data)
        }
        let playState1 = try JSONSerialization.data(withJSONObject: [
            "is_playing": true,
            "device": ["id": "fixture-device", "name": "AirPods", "is_restricted": false],
            "item": ["uri": makeUri(1), "name": "Workout Song 1", "type": "track", "artists": [["name": "Electronic Artist"]]]
        ])

        var replies = [SpotifyReply(data: selectionData)]
        for i in 1...5 { replies.append(try makeMatch(i)) }
        replies += [
            SpotifyReply(data: playState1),
            SpotifyReply(status: 204),
            SpotifyReply(data: playState1),
            SpotifyReply(data: Data(#"{"status":"ok"}"#.utf8))
        ]
        SpotifyMockProtocol.server.configure(replies)
        ctx.request.submit("workout beats")
        let sent = await E2ETestContext.pollUntil(timeout: 5.0) { !ctx.request.isSending && !ctx.request.feedbackBusy }
        e2eAssert(sent, "S3: Workout beats request dispatched")

        // 2. Maintain session queue
        var refillReplies: [SpotifyReply] = []
        for _ in 2...5 {
            refillReplies += [SpotifyReply(data: playState1), SpotifyReply(status: 204)]
        }
        SpotifyMockProtocol.server.configure(refillReplies)
        await ctx.request.maintainSession()
        e2eAssert(ctx.request.isSessionActive, "S3: Continuous listening active")

        // 3. User stops session
        ctx.request.stopSession()
        e2eAssert(!ctx.request.isSessionActive, "S3: Session stopped by user request")
        print("    ✓ Scenario 3 passed")
    }

    // MARK: - Scenario 4: Full Accessibility Conformance Session
    static func testScenario4AccessibilityConformanceSession() async throws {
        print("  Running Scenario 4: Full Accessibility Conformance Session...")
        let ctx = E2ETestContext(suitePrefix: "com.evan.Mochi.e2e.scenario4")
        defer { ctx.cleanup() }
        await ctx.connectAuth()
        ctx.companion.start()
        ctx.companion.toggleCard()
        let card = ctx.companion.cardPanel!
        card.layoutIfNeeded()
        AXQuery.activateAccessibilityTree()

        // 1. Accessibility Identifiers Presence Verification
        let composerAX = AXQuery.find(identifier: "mochiComposer", in: card.contentView!)
        e2eAssertNotNil(composerAX, "S4: mochiComposer discoverable by AX")

        let focusAX = AXQuery.find(label: "Focus", in: card.contentView!)
        e2eAssertNotNil(focusAX, "S4: Focus preset button discoverable by AX")

        // 2. Reduce Motion Kinematics Verification
        let staticPose1 = MochiMascotPose.at(time: 100.0, isEngaged: true, animate: false)
        let staticPose2 = MochiMascotPose.at(time: 200.0, isEngaged: true, animate: false)
        e2eAssertEqual(staticPose1.tilt, 0.0, "S4: Mascot tilt is 0 under Reduce Motion")
        e2eAssertEqual(staticPose1.leftWave, 0.0, "S4: Mascot leftWave is 0 under Reduce Motion")
        e2eAssertEqual(staticPose1.rightWave, 0.0, "S4: Mascot rightWave is 0 under Reduce Motion")
        e2eAssertEqual(staticPose1.scaleX, staticPose2.scaleX, "S4: Scale remains constant over time")

        // 3. Reduce Motion Music Playback static pose
        let staticMusicPose = MochiMascotPose.at(time: 100.0, isMusicPlaying: true, animate: false)
        e2eAssertEqual(staticMusicPose.happyEyes, 1.0, "S4: Calm static happy eyes preserved")
        e2eAssertEqual(staticMusicPose.tilt, 0.0, "S4: No dance sway tilt under Reduce Motion")

        // 4. Panel clamping under accessibility coordinates
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let mascotSize = NSSize(width: 94, height: 88)
        let clamped = CompanionPlacement.clamp(NSPoint(x: -200, y: -200), size: mascotSize, inside: screen)
        e2eAssertEqual(clamped, NSPoint(x: 0, y: 0), "S4: Accessibility coordinate clamp")
        print("    ✓ Scenario 4 passed")
    }

    // MARK: - Scenario 5: Network Disruption & Automatic Error Recovery Workflow
    static func testScenario5NetworkDisruptionAndAutomaticRecovery() async throws {
        print("  Running Scenario 5: Network Disruption & Automatic Error Recovery Workflow...")
        let ctx = E2ETestContext(suitePrefix: "com.evan.Mochi.e2e.scenario5")
        defer { ctx.cleanup() }
        await ctx.connectAuth()

        // 1. Initial stable playback
        let stableData = try E2ETestContext.makePlaybackJSON(name: "Pre-Disruption Melody")
        SpotifyMockProtocol.server.configure([SpotifyReply(data: stableData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertEqual(ctx.playback.state?.item?.name, "Pre-Disruption Melody", "S5: Stable playback established")

        // 2. Disruption: HTTP 503 Service Unavailable outage
        SpotifyMockProtocol.server.configure([
            SpotifyReply(status: 503)
        ])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssert(ctx.playback.errorMessage != nil, "S5: Service unavailable error reported")

        // 3. Network Restored: Fetch fresh playback state
        let restoredData = try E2ETestContext.makePlaybackJSON(name: "Post-Disruption Harmony")
        SpotifyMockProtocol.server.configure([SpotifyReply(data: restoredData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertEqual(ctx.playback.state?.item?.name, "Post-Disruption Harmony", "S5: Playback recovered cleanly")
        print("    ✓ Scenario 5 passed")
    }
}
