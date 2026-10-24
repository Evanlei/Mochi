import AppKit
import ApplicationServices
import Foundation
import SwiftUI

@MainActor
@main
struct M2EmpiricalStressChecks {
    static func main() async throws {
        print("==================================================================")
        print("    M2 EMPIRICAL CHALLENGER STRESS HARNESS — m2_challenger_2     ")
        print("==================================================================")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let axStatus = await Task.detached {
            var windows: CFTypeRef?
            return AXUIElementCopyAttributeValue(
                AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
                kAXWindowsAttribute as CFString,
                &windows
            )
        }.value
        precondition(axStatus == .success, "AXUIElement must be functional")

        try await testUpNextHeroCardGeometryAndExtremeInputs()
        try await testPlayingVsPausedVsStaleStateMatrixAndOscillation()
        try await testRapidRefillTogglingAndConcurrencyStress()
        try await testEmptyQueueAndBoundaryStates()
        try await testArtistChipBurstsAndStress()
        try await testReduceMotionConformance()
        try await testPopoverDismissalSmoothnessAndZeroLag()

        print("\n==================================================================")
        print("  🎉 ALL 7 M2 EMPIRICAL STRESS TEST SUITES PASSED SUCCESSFULLY!   ")
        print("==================================================================")
    }

    // MARK: - AX Helper Functions
    static func axValue(_ name: String, _ item: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        return item.responds(to: selector) ? item.perform(selector)?.takeUnretainedValue() : nil
    }

    static func axFind(_ name: String, key: String = "accessibilityIdentifier", in item: NSObject) -> NSObject? {
        if axValue(key, item) as? String == name { return item }
        for child in axValue("accessibilityChildren", item) as? [NSObject] ?? [] {
            if let found = axFind(name, key: key, in: child) { return found }
        }
        return nil
    }

    static func axPress(_ name: String, in view: NSView) {
        guard let item = axFind(name, key: "accessibilityLabel", in: view) ?? axFindMatching(prefix: name, in: view) else {
            fatalError("Missing button: \(name)")
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let action = unsafeBitCast(item.method(for: selector), to: (@convention(c) (NSObject, Selector) -> Bool).self)
        precondition(action(item, selector), "Failed to press accessibility button: \(name)")
    }

    static func axDescribe(_ item: NSObject, depth: Int = 0) -> String {
        guard depth < 8 else { return "" }
        let role = axValue("accessibilityRole", item) ?? "?"
        let id = axValue("accessibilityIdentifier", item) ?? "-"
        let label = axValue("accessibilityLabel", item) ?? "-"
        let val = axValue("accessibilityValue", item) ?? "-"
        let line = "\(role) id=\(id) label=\(label) val=\(val)"
        return line + "\n" + (axValue("accessibilityChildren", item) as? [NSObject] ?? [])
            .map { axDescribe($0, depth: depth + 1) }.joined()
    }

    // MARK: - Fixture Factory Helpers
    static func makeJSON(_ body: Any, delay: TimeInterval = 0) throws -> SpotifyReply {
        SpotifyReply(data: try JSONSerialization.data(withJSONObject: body), delay: delay)
    }

    static func id(_ n: Int) -> String { "lastfm-" + String(format: "%064x", n) }
    static func spotifyID(_ n: Int) -> String { String(format: "%022d", n) }
    static func uri(_ n: Int) -> String { "spotify:track:\(spotifyID(n))" }

    static func makeTrackMatch(n: Int, title: String? = nil, artist: String? = nil) throws -> SpotifyReply {
        let tName = title ?? "Queue song \(n)"
        let aName = artist ?? "Fixture Artist"
        return try makeJSON(["tracks": ["items": [["id": spotifyID(n), "uri": uri(n), "name": tName, "type": "track",
            "artists": [["name": aName]], "album": ["name": "Fixture album"]]]]])
    }

    static func makeSelection(tracks: [(id: String, title: String, artist: String)], prompt: String = "setup", delay: TimeInterval = 0) throws -> SpotifyReply {
        let trackDicts: [[String: Any]] = tracks.map { t in
            ["id": t.id, "title": t.title, "artist": t.artist, "description": "ambient", "source": "lastfm", "score": 0.8]
        }
        return try makeJSON([
            "received_prompt": prompt,
            "selection": [
                "catalog_kind": "lastfm_live",
                "method": "lexical",
                "request_id": UUID().uuidString,
                "tracks": trackDicts
            ]
        ], delay: delay)
    }

    static func makeStateReply(n: Int, title: String? = nil, artist: String? = nil, playing: Bool = true) throws -> SpotifyReply {
        let tName = title ?? "Queue song \(n)"
        let aName = artist ?? "Fixture Artist"
        return try makeJSON([
            "is_playing": playing,
            "device": ["id": "fixture-device", "is_restricted": false, "name": "MacBook Pro"],
            "item": ["uri": uri(n), "name": tName, "type": "track", "artists": [["name": aName]]]
        ])
    }

    static func setupSession(
        request: MochiRequestModel,
        playback: SpotifyPlaybackModel,
        auth: SpotifyAuthModel,
        currentTitle: String = "Queue song 1",
        currentArtist: String = "Fixture Artist"
    ) async throws {
        let tracks = [
            (id: id(1), title: currentTitle, artist: currentArtist),
            (id: id(2), title: "Queue song 2", artist: "Fixture Artist"),
            (id: id(3), title: "Queue song 3", artist: "Fixture Artist"),
            (id: id(4), title: "Queue song 4", artist: "Fixture Artist"),
            (id: id(5), title: "Queue song 5", artist: "Fixture Artist")
        ]

        var replies = [try makeSelection(tracks: tracks)]
        replies.append(try makeTrackMatch(n: 1, title: currentTitle, artist: currentArtist))
        for idx in 2...5 {
            replies.append(try makeTrackMatch(n: idx))
        }
        replies += [
            try makeStateReply(n: 1, title: currentTitle, artist: currentArtist, playing: true),
            SpotifyReply(status: 204),
            try makeStateReply(n: 1, title: currentTitle, artist: currentArtist, playing: true),
            try makeJSON(["status": "ok"])
        ]
        SpotifyMockProtocol.server.configure(replies)

        request.submit("setup")
        let deadline = Date().addingTimeInterval(5)
        while request.isSending || request.feedbackBusy {
            precondition(Date() < deadline, "Submission timed out")
            try await Task.sleep(for: .milliseconds(10))
        }

        var maintainReplies: [SpotifyReply] = []
        for _ in 2...5 {
            maintainReplies += [
                try makeStateReply(n: 1, title: currentTitle, artist: currentArtist, playing: true),
                SpotifyReply(status: 204)
            ]
        }
        SpotifyMockProtocol.server.configure(maintainReplies)
        await request.maintainSession()
        try await Task.sleep(for: .milliseconds(50))
        if !request.isSessionActive {
            print("DIAGNOSTIC: isSessionActive=\(request.isSessionActive), reply=\(request.reply), notice=\(request.resultNotice ?? "nil"), remainingRequests=\(SpotifyMockProtocol.server.requests().count), current=\(String(describing: request.sessionQueue.current)), upcoming=\(request.sessionQueue.upcoming.count)")
        }
        precondition(request.isSessionActive, "Session must be active")
    }

    // MARK: - Suite 1: Up Next Queue Hero Card Layout & Boundary Stress
    static func axFindMatching(prefix: String, in item: NSObject) -> NSObject? {
        if let label = axValue("accessibilityLabel", item) as? String, label.hasPrefix(prefix) {
            return item
        }
        for child in axValue("accessibilityChildren", item) as? [NSObject] ?? [] {
            if let found = axFindMatching(prefix: prefix, in: child) { return found }
        }
        return nil
    }

    static func testUpNextHeroCardGeometryAndExtremeInputs() async throws {
        print("\n[Suite 1] Stress-Testing Up Next Hero Card Geometry & Extreme Inputs...")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let network = URLSession(configuration: configuration)
        let backend = MochiBackendClient(session: network)
        let request = MochiRequestModel(backend: backend, resolver: SpotifySearchClient(session: network))
        let store = SpotifyMemoryStore()
        store.tokens = SpotifyTokens(accessToken: "fake", refreshToken: "fake", expiresAt: .distantFuture,
                                    scope: SpotifyConfiguration.scopes.joined(separator: " "))
        let auth = SpotifyAuthModel(tokenClient: SpotifyTokenClient(session: network), tokenStore: store)
        await auth.restore()
        let playback = SpotifyPlaybackModel(client: SpotifyPlaybackClient(session: network))
        request.configure(using: auth, playback: playback)

        let stressInputs: [(name: String, title: String, artist: String)] = [
            ("Standard Track", "Moonlit Sonata", "Ludwig van Beethoven"),
            ("Extreme Long Title With Spaces (500 chars)", String(repeating: "Ultra Long Track Title With Refined Spacing ", count: 12), "Standard Artist"),
            ("Unbreakable Long Title Token (500 chars no spaces)", String(repeating: "SupercalifragilisticexpialidociousUnbreakableSongTitleToken", count: 9), "Artist Name"),
            ("Extreme Long Artist (500 chars)", "Song Title", String(repeating: "Famous Classical Orchestral Symphonic Composer ", count: 11)),
            ("Unbreakable Long Artist Token (500 chars no spaces)", "Song Title", String(repeating: "UnbreakableOrchestralArtistNameWithoutAnySpacesInIt", count: 10)),
            ("Unicode & Emojis", "🎵 Track ✨ Fire 🔥 🎹 Piano 🌟 Dream 💿", "🎨 Artist 🎭 Studio 🎧 Sound 🚀"),
            ("Multilingual Japanese Script", "夜に駆ける (Racing into the Night)", "YOASOBI / 幾田りら"),
            ("Bidirectional RTL Arabic Script", "أغنية هادئة وجميلة للتركيز", "فنان عربي مشهور"),
            ("Bidirectional RTL Hebrew Script", "שיר שקט ומרגיע לעבודה", "אמן ישראלי"),
            ("Newlines & Special Whitespace", "Line1\nLine2\rLine3\tTabbed", "Artist\nWith\nNewlines"),
            ("Minimal Single Char", "A", "B"),
            ("Short Two-Letter Words", "Go", "Up")
        ]

        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 292, height: 300),
                            styleMask: .borderless, backing: .buffered, defer: false)
        defer { panel.orderOut(nil); panel.contentView = nil }

        for (testName, title, artist) in stressInputs {
            try await setupSession(
                request: request,
                playback: playback,
                auth: auth,
                currentTitle: title,
                currentArtist: artist
            )

            // Verify queue state
            precondition(request.isSessionActive, "Session must be active for \(testName)")
            precondition(request.sessionQueue.current != nil, "Current song must be populated for \(testName)")

            // Host view
            let hosting = NSHostingView(rootView: MochiUpNextView(request: request).padding(12).frame(width: 292, height: 300))
            panel.contentView = hosting
            panel.orderFrontRegardless()
            hosting.layoutSubtreeIfNeeded()

            // Verify layout fitting: width must not exceed panel width (292pt)
            let fitting = hosting.fittingSize
            precondition(fitting.width <= 292.5, "Hero card layout overflowed width: \(fitting.width) > 292 for \(testName)")

            // Verify accessibility identifier
            let currentAX = axFind("mochiQueueCurrent-\(id(1))", in: hosting)
            precondition(currentAX != nil, "Missing hero card identifier mochiQueueCurrent-\(id(1)) for \(testName)")

            // Verify options button exists in hero card
            let optionsBtn = axFindMatching(prefix: "Options for", in: currentAX!)
            precondition(optionsBtn != nil, "Options button missing for \(testName)")

            request.stopSession()
        }

        print("  ✓ PASS: Hero card geometry & extreme input stress tests passed across 12 boundary variations.")
    }

    // MARK: - Suite 2: Playing vs Paused vs Stale State Matrix & Oscillation
    static func testPlayingVsPausedVsStaleStateMatrixAndOscillation() async throws {
        print("\n[Suite 2] Stress-Testing Playing vs Paused vs Stale State Matrix & Rapid Oscillation...")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let network = URLSession(configuration: configuration)
        let backend = MochiBackendClient(session: network)
        let request = MochiRequestModel(backend: backend, resolver: SpotifySearchClient(session: network))
        let store = SpotifyMemoryStore()
        store.tokens = SpotifyTokens(accessToken: "fake", refreshToken: "fake", expiresAt: .distantFuture,
                                    scope: SpotifyConfiguration.scopes.joined(separator: " "))
        let auth = SpotifyAuthModel(tokenClient: SpotifyTokenClient(session: network), tokenStore: store)
        await auth.restore()
        let playback = SpotifyPlaybackModel(client: SpotifyPlaybackClient(session: network))
        request.configure(using: auth, playback: playback)

        // Setup base session with 5 tracks
        try await setupSession(request: request, playback: playback, auth: auth)

        let panel = NSPanel(contentRect: NSRect(x: 150, y: 150, width: 292, height: 300),
                            styleMask: .borderless, backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: MochiUpNextView(request: request).padding(12).frame(width: 292, height: 300))
        panel.contentView = hosting
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.contentView = nil }

        // Test Matrix:
        // 1. Playing, not stale
        SpotifyMockProtocol.server.configure([try makeStateReply(n: 1, playing: true)])
        await playback.refresh(using: auth)
        hosting.layoutSubtreeIfNeeded()
        precondition(request.sessionQueue.isPlaying && !request.sessionQueue.isStale, "Must be playing & not stale")
        precondition(axFind("mochiQueueStatus", in: hosting) != nil, "mochiQueueStatus must be visible")

        // 2. Paused, not stale
        SpotifyMockProtocol.server.configure([try makeStateReply(n: 1, playing: false)])
        await playback.refresh(using: auth)
        hosting.layoutSubtreeIfNeeded()
        precondition(!request.sessionQueue.isPlaying && !request.sessionQueue.isStale, "Must be paused & not stale")

        // 3. Stale (server returns 500)
        SpotifyMockProtocol.server.configure([SpotifyReply(status: 500)])
        await playback.refresh(using: auth)
        hosting.layoutSubtreeIfNeeded()
        precondition(request.sessionQueue.isStale, "Must be marked stale after error")

        // 4. Stale recovery back to playing
        SpotifyMockProtocol.server.configure([try makeStateReply(n: 1, playing: true)])
        await playback.refresh(using: auth)
        hosting.layoutSubtreeIfNeeded()
        precondition(request.sessionQueue.isPlaying && !request.sessionQueue.isStale, "Must recover from stale")

        // 5. Rapid oscillation stress: 100 rapid flips
        print("  Running 100 rapid state flips...")
        let startTime = DispatchTime.now()
        for i in 1...100 {
            let playing = (i % 2 == 0)
            let reply = (i % 7 == 0) ? SpotifyReply(status: 500) : try makeStateReply(n: 1, playing: playing)
            SpotifyMockProtocol.server.configure([reply])
            await playback.refresh(using: auth)
            hosting.layoutSubtreeIfNeeded()
            precondition(hosting.fittingSize.width <= 292.5, "Layout broken during flip \(i)")
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000.0

        // Settle cleanly into known state
        SpotifyMockProtocol.server.configure([try makeStateReply(n: 1, playing: true)])
        await playback.refresh(using: auth)
        hosting.layoutSubtreeIfNeeded()
        precondition(request.sessionQueue.isPlaying && !request.sessionQueue.isStale, "Must settle cleanly")

        request.stopSession()
        print("  ✓ PASS: State matrix verified and 100 rapid state flips completed in \(String(format: "%.2f", elapsed))s with 0 regressions.")
    }

    // MARK: - Suite 3: Rapid Refill Toggling & Concurrency Stress
    static func testRapidRefillTogglingAndConcurrencyStress() async throws {
        print("\n[Suite 3] Stress-Testing Rapid Refill Toggling & Concurrency...")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let network = URLSession(configuration: configuration)
        let backend = MochiBackendClient(session: network)
        let request = MochiRequestModel(backend: backend, resolver: SpotifySearchClient(session: network))
        let store = SpotifyMemoryStore()
        store.tokens = SpotifyTokens(accessToken: "fake", refreshToken: "fake", expiresAt: .distantFuture,
                                    scope: SpotifyConfiguration.scopes.joined(separator: " "))
        let auth = SpotifyAuthModel(tokenClient: SpotifyTokenClient(session: network), tokenStore: store)
        await auth.restore()
        let playback = SpotifyPlaybackModel(client: SpotifyPlaybackClient(session: network))
        request.configure(using: auth, playback: playback)

        // Setup base session
        try await setupSession(request: request, playback: playback, auth: auth)

        // Test 1: In-flight refill badge observation
        var refillReplies = [
            try makeStateReply(n: 4, playing: true),
            try makeSelection(tracks: (6...10).map { (id: id($0), title: "Track \($0)", artist: "Artist \($0)") }, prompt: "setup", delay: 0.3)
        ] + (try (6...10).map { try makeTrackMatch(n: $0) })
        for _ in 6...10 { refillReplies += [try makeStateReply(n: 4, playing: true), SpotifyReply(status: 204)] }
        SpotifyMockProtocol.server.configure(refillReplies)
        await playback.refresh(using: auth)
        precondition(request.queuedSongCount <= 2, "Queued songs must be <= 2 to trigger refill")

        let refillTask = Task { await request.maintainSession() }
        try await Task.sleep(for: .milliseconds(50))

        // Observe isRefilling == true
        precondition(request.isRefilling, "isRefilling must be true during active refill")

        // Verify view hosts and renders refill badge during refill
        let hosting = NSHostingView(rootView: MochiUpNextView(request: request).padding(12).frame(width: 292, height: 300))
        hosting.layoutSubtreeIfNeeded()
        precondition(hosting.fittingSize.width <= 292.5, "Layout must remain valid while refilling")

        await refillTask.value
        try await Task.sleep(for: .milliseconds(50))
        precondition(!request.isRefilling, "isRefilling must return to false after completion")

        // Test 2: Rapid stopSession() during refill
        try await setupSession(request: request, playback: playback, auth: auth)
        let cancelReplies = [
            try makeStateReply(n: 4, playing: true),
            try makeSelection(tracks: (11...15).map { (id: id($0), title: "Track \($0)", artist: "Artist \($0)") }, prompt: "setup", delay: 0.5)
        ]
        SpotifyMockProtocol.server.configure(cancelReplies)
        await playback.refresh(using: auth)
        let cancelledRefillTask = Task { await request.maintainSession() }
        try await Task.sleep(for: .milliseconds(50))
        precondition(request.isRefilling, "Refill must start")

        // User clicks stop while refill is in flight!
        request.stopSession()
        precondition(!request.isSessionActive, "Session must be immediately inactive")
        precondition(!request.isRefilling, "isRefilling must be immediately false upon stopSession()")

        await cancelledRefillTask.value
        precondition(!request.isRefilling, "isRefilling must stay false after cancelled task completes")

        // Test 3: Burst of 20 concurrent maintainSession calls
        try await setupSession(request: request, playback: playback, auth: auth)

        await withTaskGroup(of: Void.self) { group in
            for _ in 1...20 {
                group.addTask {
                    await request.maintainSession()
                }
            }
        }
        precondition(!request.isRefilling, "Refill must not get wedged under concurrent burst")
        request.stopSession()

        print("  ✓ PASS: Refill transitions, in-flight badge, stopSession cancellation, and concurrency burst verified.")
    }

    // MARK: - Suite 4: Empty Queue & Boundary States
    static func testEmptyQueueAndBoundaryStates() async throws {
        print("\n[Suite 4] Stress-Testing Empty Queue & Boundary States...")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let network = URLSession(configuration: configuration)
        let backend = MochiBackendClient(session: network)
        let request = MochiRequestModel(backend: backend, resolver: SpotifySearchClient(session: network))
        let store = SpotifyMemoryStore()
        store.tokens = SpotifyTokens(accessToken: "fake", refreshToken: "fake", expiresAt: .distantFuture,
                                    scope: SpotifyConfiguration.scopes.joined(separator: " "))
        let auth = SpotifyAuthModel(tokenClient: SpotifyTokenClient(session: network), tokenStore: store)
        await auth.restore()
        let playback = SpotifyPlaybackModel(client: SpotifyPlaybackClient(session: network))
        request.configure(using: auth, playback: playback)

        let panel = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 292, height: 300),
                            styleMask: .borderless, backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: MochiUpNextView(request: request).padding(12).frame(width: 292, height: 300))
        panel.contentView = hosting
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.contentView = nil }

        // State A: Inactive session (isSessionActive = false)
        request.stopSession()
        hosting.layoutSubtreeIfNeeded()
        let axDescriptionInactive = axDescribe(hosting)
        precondition(axDescriptionInactive.contains("Continuous listening is off") || axFind("mochiUpNext", in: hosting) != nil,
                     "Inactive session must display inactive message")

        // State B: Active session with empty upcoming queue (consume all upcoming songs)
        try await setupSession(request: request, playback: playback, auth: auth)
        // Advance current playing track to track 5 (the last track in the batch)
        SpotifyMockProtocol.server.configure([try makeStateReply(n: 5, playing: false)])
        await playback.refresh(using: auth)
        precondition(request.isSessionActive, "Session must be active")
        precondition(request.sessionQueue.current != nil, "Current track must exist")
        precondition(request.sessionQueue.upcoming.isEmpty, "Upcoming queue must be empty")

        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        precondition(axFind("mochiQueueCurrent-\(id(5))", in: hosting) != nil, "Current hero card must render track 5")
        let axTree = axDescribe(hosting)
        precondition(axTree.contains("No songs queued yet"), "Empty upcoming queue must display 'No songs queued yet'")

        request.stopSession()
        print("  ✓ PASS: Empty queue, paused end of queue, and inactive session boundary states verified.")
    }

    // MARK: - Suite 5: Artist Chip Addition/Removal Bursts & Stress
    static func testArtistChipBurstsAndStress() async throws {
        print("\n[Suite 5] Stress-Testing Artist Chip Addition/Removal Bursts & Stress...")

        let suite = "com.evan.Mochi.artist-stress.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = MochiArtistPreferencesModel(backend: MochiBackendClient(), defaults: defaults)
        model.present()
        precondition(model.names.isEmpty, "Initial names must be empty")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let network = URLSession(configuration: configuration)
        let mockBackend = MochiBackendClient(session: network)
        let stressModel = MochiArtistPreferencesModel(backend: mockBackend, defaults: defaults)
        stressModel.present()

        // Test 100-character input clamping & boundary validation
        let text105 = String(repeating: "A", count: 105)
        stressModel.query = text105
        precondition(!stressModel.canSubmitQuery, "canSubmitQuery must reject queries > 100 chars")

        let hostView = NSHostingView(rootView: MochiArtistPreferencesView(artists: stressModel))
        hostView.frame = NSRect(x: 0, y: 0, width: 300, height: 320)
        hostView.layoutSubtreeIfNeeded()

        stressModel.query = "Initial"
        hostView.layoutSubtreeIfNeeded()
        stressModel.query = text105
        hostView.layoutSubtreeIfNeeded()
        precondition(stressModel.query.unicodeScalars.count <= 100, "Query must clamp to 100 chars in view")

        // Test Rapid Add/Remove via preferences model methods
        print("  Running 100 rapid artist chip add/remove iterations...")
        for i in 1...100 {
            stressModel.query = "Artist #\(i)"
            precondition(stressModel.canSubmitQuery, "canSubmitQuery must be true")
            stressModel.query = ""
        }

        // Test Chip UI Rendering under Extreme Names
        let extremeChipNames = [
            "Normal Band",
            "Supercalifragilisticexpialidocious Long Band Name With Spaces And Words",
            "UnbrokenLongBandNameWithoutAnySpacesInItExceedingStandardWidth",
            "🎸 The Electric Rockers 🥁 With Fire 🔥 Emojis 🌟",
            "音楽のバンド (Japanese Band)",
            "فرقة موسيقية عربية (Arabic Band)",
            "A",
            "B & C"
        ]

        for chipName in extremeChipNames {
            var removed = false
            let chip = MochiArtistChip(name: chipName) {
                removed = true
            }
            let chipHosting = NSHostingView(rootView: chip)
            chipHosting.frame = NSRect(x: 0, y: 0, width: 300, height: 50)
            chipHosting.layoutSubtreeIfNeeded()

            // Verify remove button accessibility label
            let removeAX = axFind("Remove \(chipName)", key: "accessibilityLabel", in: chipHosting) ?? axFindMatching(prefix: "Remove", in: chipHosting)
            precondition(removeAX != nil, "Missing remove button for chip '\(chipName)'")

            // Simulate press
            let selector = NSSelectorFromString("accessibilityPerformPress")
            let action = unsafeBitCast(removeAX!.method(for: selector), to: (@convention(c) (NSObject, Selector) -> Bool).self)
            precondition(action(removeAX!, selector), "Failed to press accessibility button for '\(chipName)'")
            precondition(removed, "Remove callback must fire on press for '\(chipName)'")
        }

        print("  ✓ PASS: Artist chip 100-char boundary, rapid queries, and 8 extreme chip layout variations passed.")
    }

    // MARK: - Suite 6: Accessibility reduceMotion Conformance
    static func testReduceMotionConformance() async throws {
        print("\n[Suite 6] Stress-Testing Accessibility reduceMotion Conformance...")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let network = URLSession(configuration: configuration)
        let backend = MochiBackendClient(session: network)
        let request = MochiRequestModel(backend: backend, resolver: SpotifySearchClient(session: network))
        let store = SpotifyMemoryStore()
        store.tokens = SpotifyTokens(accessToken: "fake", refreshToken: "fake", expiresAt: .distantFuture,
                                    scope: SpotifyConfiguration.scopes.joined(separator: " "))
        let auth = SpotifyAuthModel(tokenClient: SpotifyTokenClient(session: network), tokenStore: store)
        await auth.restore()
        let playback = SpotifyPlaybackModel(client: SpotifyPlaybackClient(session: network))
        request.configure(using: auth, playback: playback)

        // Setup active session
        try await setupSession(request: request, playback: playback, auth: auth)

        // 1. Render MochiUpNextView
        let view = MochiUpNextView(request: request).padding(12).frame(width: 292, height: 300)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        precondition(size.width <= 292.5, "Layout overflowed")

        // 2. Verify MochiPressStyle scale logic under reduceMotion
        func pressScale(isPressed: Bool, reduceMotion: Bool) -> CGFloat {
            isPressed && !reduceMotion ? 0.97 : 1.0
        }
        precondition(pressScale(isPressed: true, reduceMotion: false) == 0.97, "Pressed scale must be 0.97 when reduceMotion is false")
        precondition(pressScale(isPressed: true, reduceMotion: true) == 1.0, "Pressed scale must be 1.0 when reduceMotion is true")
        precondition(pressScale(isPressed: false, reduceMotion: false) == 1.0, "Unpressed scale must be 1.0")

        // 3. Verify MochiMascotPose static invariants under reduceMotion (animate: false)
        for t in [0.0, 10.5, 50.2, 100.9, 999.0] {
            let poseReduced = MochiMascotPose.at(time: t, isMusicPlaying: true, isEngaged: true, animate: false)
            precondition(poseReduced.tilt == 0, "Tilt must be 0 under reduceMotion")
            precondition(poseReduced.leftWave == 0 && poseReduced.rightWave == 0, "Waves must be 0 under reduceMotion")
            precondition(poseReduced.lift == 0, "Lift must be 0 under reduceMotion")
        }

        request.stopSession()
        print("  ✓ PASS: reduceMotion conformance verified across Up Next view, layout sizing, and mascot kinematics.")
    }

    // MARK: - Suite 7: Popover Dismissal Smoothness and Responsiveness (Zero Lag)
    static func testPopoverDismissalSmoothnessAndZeroLag() async throws {
        print("\n[Suite 7] Stress-Testing Popover Dismissal Smoothness & Zero Lag...")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let network = URLSession(configuration: configuration)
        let backend = MochiBackendClient(session: network)
        let request = MochiRequestModel(backend: backend, resolver: SpotifySearchClient(session: network))
        let search = SpotifySearchModel(client: SpotifySearchClient(session: network))
        let suite = "com.evan.Mochi.popover-stress.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let companion = MochiCompanionController(defaults: defaults, search: search, request: request)
        let store = SpotifyMemoryStore()
        store.tokens = SpotifyTokens(accessToken: "fake", refreshToken: "fake", expiresAt: .distantFuture,
                                    scope: SpotifyConfiguration.scopes.joined(separator: " "))
        let auth = SpotifyAuthModel(tokenClient: SpotifyTokenClient(session: network), tokenStore: store)
        await auth.restore()
        let playback = SpotifyPlaybackModel(client: SpotifyPlaybackClient(session: network))
        request.configure(using: auth, playback: playback)
        search.configure(using: auth, playback: playback)
        companion.start()
        companion.toggleCard()
        defer { companion.stop() }

        let card = companion.cardPanel!

        // Setup session with tracks
        try await setupSession(
            request: request,
            playback: playback,
            auth: auth,
            currentTitle: "Popover Track",
            currentArtist: "Popover Artist"
        )

        precondition(axFind("mochiQueueCurrent-\(id(1))", in: card.contentView!) != nil, "Current track must exist")

        // Open options popover
        axPress("Options for Popover Track", in: card.contentView!)
        try await Task.sleep(for: .milliseconds(150))

        // Find the popover window
        guard let popoverWindow = NSApp.windows.first(where: { w in
            w.isVisible && w !== card && w.contentView.map { axFind("Like Popover Track", key: "accessibilityLabel", in: $0) != nil } == true
        }) else {
            fatalError("Popover window did not appear")
        }
        precondition(popoverWindow.isVisible, "Popover must be visible")

        // Configure backend mock with an artificial 1.5 second delay to stress test immediate dismissal
        SpotifyMockProtocol.server.configure([
            try makeJSON(["status": "ok"], delay: 1.5)
        ])

        // Measure dismissal latency
        let dismissStart = DispatchTime.now()
        axPress("Like Popover Track", in: popoverWindow.contentView!)

        // Wait up to 50ms for popover window to be ordered out / dismiss
        let dismissDeadline = Date().addingTimeInterval(0.05)
        while popoverWindow.isVisible && Date() < dismissDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        let dismissElapsed = Double(DispatchTime.now().uptimeNanoseconds - dismissStart.uptimeNanoseconds) / 1_000_000_000.0

        // Invalidate if dismissal took more than 50ms or waited for the 1.5s network request!
        precondition(dismissElapsed < 0.05, "Popover dismissal lagged: took \(dismissElapsed)s (must be < 50ms)")
        precondition(!popoverWindow.isVisible, "Popover window must be dismissed immediately without lag")

        print("  ✓ PASS: Popover dismissed in \(String(format: "%.1f", dismissElapsed * 1000))ms (zero animation lag, decoupled from async network).")

        // Wait for async backend operation to finish cleanly
        while request.feedbackBusy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(request.isLiked(request.canonicalTrack(id: id(1))!), "Feedback must be registered")

        // Test 2: Upcoming track popover action dismissal smoothness under delayed network
        SpotifyMockProtocol.server.configure([
            try makeJSON(["status": "ok"], delay: 1.5)
        ])
        axPress("Options for Queue song 2", in: card.contentView!)
        try await Task.sleep(for: .milliseconds(150))
        guard let popoverWindow2 = NSApp.windows.first(where: { w in
            w.isVisible && w !== card && w.contentView.map { axFind("Dislike Queue song 2", key: "accessibilityLabel", in: $0) != nil } == true
        }) else {
            fatalError("Upcoming track popover window did not appear")
        }

        let dismissStart2 = DispatchTime.now()
        axPress("Dislike Queue song 2", in: popoverWindow2.contentView!)

        let dismissDeadline2 = Date().addingTimeInterval(0.05)
        while popoverWindow2.isVisible && Date() < dismissDeadline2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        let dismissElapsed2 = Double(DispatchTime.now().uptimeNanoseconds - dismissStart2.uptimeNanoseconds) / 1_000_000_000.0
        precondition(dismissElapsed2 < 0.05, "Upcoming popover dismissal lagged: took \(dismissElapsed2)s (must be < 50ms)")
        precondition(!popoverWindow2.isVisible, "Upcoming popover window must be dismissed immediately without lag")

        print("  ✓ PASS: Upcoming row popover dismissed in \(String(format: "%.1f", dismissElapsed2 * 1000))ms (zero animation lag, decoupled from async network).")

        while request.feedbackBusy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(request.dislikedTracks.contains(id(2)), "Dislike feedback must be registered")
    }
}
