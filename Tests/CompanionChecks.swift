import AppKit
import ApplicationServices
import Foundation
import SwiftUI

@main
struct CompanionChecks {
    @MainActor
    static func main() async throws {
        let screen = NSRect(x: 0, y: 40, width: 1200, height: 800)
        let mascotSize = NSSize(width: 94, height: 88)
        let cardSize = MochiCompanionCard.size
        precondition(CompanionPlacement.clamp(NSPoint(x: -200, y: -300), size: mascotSize, inside: screen) == NSPoint(x: 0, y: 40))
        precondition(CompanionPlacement.clamp(NSPoint(x: 9000, y: 9000), size: mascotSize, inside: screen) == NSPoint(x: 1106, y: 752))
        let bottom = NSRect(x: 1080, y: 50, width: 94, height: 88)
        let above = CompanionPlacement.cardOrigin(near: bottom, size: cardSize, inside: screen)
        precondition(screen.contains(NSRect(origin: above, size: cardSize)) && above.y > bottom.maxY)
        let top = NSRect(x: 1080, y: 700, width: 94, height: 88)
        let below = CompanionPlacement.cardOrigin(near: top, size: cardSize, inside: screen)
        precondition(screen.contains(NSRect(origin: below, size: cardSize)) && below.y + cardSize.height < top.minY)
        let leftDisplay = NSRect(x: -1600, y: 0, width: 1600, height: 900)
        precondition(CompanionPlacement.closestFrame(to: NSPoint(x: -400, y: 200), frames: [screen, leftDisplay]) == leftDisplay)
        precondition(CompanionPlacement.closestFrame(to: NSPoint(x: -400, y: 200), frames: [screen]) == screen)
        precondition(CompanionPlacement.closestFrame(to: .zero, frames: []) == nil)
        print("PASS: screen-edge clamping, above/below card placement, and removed/negative-coordinate displays")

        var activityMotion = MochiMascotActivityMotion()
        activityMotion.set(.curious, at: 100)
        let interrupted = activityMotion.values(at: 100.11)
        precondition(interrupted.x > 0 && interrupted.x < 1)
        activityMotion.set(.thinking, at: 100.11)
        precondition(activityMotion.values(at: 100.11) == interrupted, "A new reaction snapped instead of continuing its current pose")
        precondition(activityMotion.values(at: 101) == SIMD2(0, 1))
        let thinking = MochiMascotPose.at(time: 101, isEngaged: true, activityMotion: activityMotion)
        precondition(thinking.rightWave < 0 && thinking.smileDepth < 3)
        let held = MochiMascotPose.at(time: 101, isHeld: true, activityMotion: activityMotion)
        precondition(held.scaleY == 1.16 && held.mouthOpen == 1)
        let sleeping = MochiMascotPose.at(time: 200, idleStartedAt: 0, activityMotion: activityMotion)
        precondition(sleeping.sleepAmount == 1 && sleeping.closedEyes == 1)
        let reduced = MochiMascotPose.at(time: 101, isEngaged: true, activityMotion: activityMotion, animate: false)
        let reducedLater = MochiMascotPose.at(time: 102, isEngaged: true, activityMotion: activityMotion, animate: false)
        precondition(reduced.scaleX == reducedLater.scaleX && reduced.tilt == 0 && reduced.rightWave == 0)
        let happy = MochiMascotPose.at(time: 10.3, isMusicPlaying: true, isEngaged: true, celebrationStartedAt: 10)
        precondition(happy.happyEyes == 1 && happy.smileDepth > 15 && happy.scaleX < 1)
        print("PASS: interruptible character reactions, thought/playback poses, drag/sleep priority and reduced motion")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let suite = "com.evan.Mochi.companion-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let session = URLSession(configuration: configuration)
        let search = SpotifySearchModel(client: SpotifySearchClient(session: session))
        // Simulate a remembered display that is no longer connected.
        defaults.set(["x": -100_000.0, "y": -100_000.0], forKey: "mochi.companion.position")
        let liveBackend = CommandLine.arguments.contains("--live-backend")
        let requestModel = MochiRequestModel(backend: liveBackend ? MochiBackendClient() : MochiBackendClient(session: session))
        let companion = MochiCompanionController(defaults: defaults, search: search, request: requestModel)
        companion.start()
        defer { companion.stop() }
        let mascot = companion.mascotPanel!
        let card = companion.cardPanel!
        precondition(mascot.isVisible && !card.isVisible)
        precondition(!mascot.canBecomeKey && card.canBecomeKey)
        precondition(mascot.styleMask.contains(.nonactivatingPanel) && mascot.collectionBehavior.contains(.canJoinAllSpaces))
        precondition(NSScreen.screens.contains { $0.visibleFrame.contains(mascot.frame) })
        precondition(mascot.contentView!.accessibilityPerformPress())
        precondition(card.isVisible && NSScreen.screens.contains { $0.visibleFrame.contains(card.frame) })
        try await Task.sleep(for: .milliseconds(300))

        if let previewDirectory = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
            let directory = URL(fileURLWithPath: previewDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, panel) in [("card", card), ("mascot", mascot)] {
                let view = panel.contentView!
                view.layoutSubtreeIfNeeded()
                let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: image)
                try image.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name).png"))
            }
            var curiousMotion = MochiMascotActivityMotion()
            curiousMotion.set(.curious, at: 100)
            let curious = MochiMascotPose.at(time: 101, isEngaged: true, activityMotion: curiousMotion)
            for (name, pose) in [("curious", curious), ("thinking", thinking), ("happy", happy), ("reduced-motion", reduced), ("sleeping", sleeping)] {
                let view = NSHostingView(rootView: MochiMascotArtwork(pose: pose))
                view.frame = NSRect(x: 0, y: 0, width: 216, height: 200)
                view.layoutSubtreeIfNeeded()
                let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: image)
                try image.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("mascot-\(name).png"))
            }
            print("Rendered native companion previews to \(directory.path)")
        }

        guard let input = card.firstResponder as? NSTextInputClient else {
            fatalError("The companion composer did not receive keyboard focus")
        }
        input.insertText("Soft piano for studying", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        precondition(companion.request.draft == "Soft piano for studying")
        companion.closeCard()
        companion.toggleCard()
        precondition(card.isVisible && companion.request.draft == "Soft piano for studying")
        try await Task.sleep(for: .milliseconds(50))
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: card.windowNumber, context: nil, characters: "\r",
                                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        SpotifyMockProtocol.server.configure([SpotifyReply(data: Data(#"{"received_prompt":"Soft piano for studying"}"#.utf8))])
        card.sendEvent(enter)
        let sendDeadline = Date().addingTimeInterval(3)
        while companion.request.preferences.isEmpty {
            precondition(Date() < sendDeadline, "Backend request never finished")
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        precondition(companion.request.summary == "Soft piano for studying" && companion.request.draft.isEmpty)
        precondition(companion.request.reply.contains(liveBackend ? "Sample matches" : "Request received"))
        if liveBackend { print("PASS: native card Return → real FastAPI → confirmed request in card") }
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: card.windowNumber, context: nil, characters: "\u{1b}",
                                     charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        card.sendEvent(escape)
        try await Task.sleep(for: .milliseconds(150))
        precondition(!card.isVisible)
        companion.closeCard()
        precondition(mascot.contentView!.accessibilityPerformPress())
        precondition(companion.request.summary == "Soft piano for studying")
        print("PASS: native panel creation, accessible toggle, keyboard typing/Return/Escape, and request retention")

        // Exercise SwiftUI buttons through their native accessibility actions.
        // A client query makes SwiftUI create its virtual accessibility children.
        let accessibilityStatus = await Task.detached {
            let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            var windows: CFTypeRef?
            return AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
        }.value
        precondition(accessibilityStatus == .success, "Could not initialize native accessibility checks")
        func value(_ name: String, from element: NSObject) -> Any? {
            let selector = NSSelectorFromString(name)
            guard element.responds(to: selector) else { return nil }
            return element.perform(selector)?.takeUnretainedValue()
        }
        func button(_ label: String, in element: NSObject) -> NSObject? {
            if value("accessibilityLabel", from: element) as? String == label,
               value("accessibilityRole", from: element) as? String == "AXButton" { return element }
            for child in value("accessibilityChildren", from: element) as? [Any] ?? [] {
                if let child = child as? NSObject, let found = button(label, in: child) { return found }
            }
            return nil
        }
        func press(_ element: NSObject) -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            let action = unsafeBitCast(element.method(for: selector), to: (@convention(c) (NSObject, Selector) -> Bool).self)
            return action(element, selector)
        }
        func popupButton(_ label: String) -> NSObject? {
            for window in NSApp.windows where window.isVisible {
                if let content = window.contentView, let item = button(label, in: content) { return item }
            }
            return nil
        }
        func utilityButton(_ label: String, in panel: NSPanel) async throws -> NSObject {
            guard let options = button("Listening options", in: panel.contentView!) else { fatalError("Missing listening options") }
            precondition(press(options))
            let deadline = Date().addingTimeInterval(2)
            repeat {
                if let item = popupButton(label) { return item }
                try await Task.sleep(for: .milliseconds(20))
            } while Date() < deadline
            fatalError("Missing listening action: \(label)")
        }
        func modeChoice(_ mode: MochiDiscoveryMode, in panel: NSPanel) async throws -> NSObject {
            guard let toggle = button("Music discovery preference", in: panel.contentView!) else {
                fatalError("Compact discovery dropdown is not accessible")
            }
            precondition(press(toggle))
            try await Task.sleep(for: .milliseconds(180))
            for window in NSApp.windows where window.isVisible {
                if let content = window.contentView,
                   let choice = button("\(mode.title) recommendations", in: content) { return choice }
            }
            fatalError("Discovery dropdown did not present its choices")
        }
        func waitForSize(_ panel: NSPanel, _ size: CGSize) async throws {
            let deadline = Date().addingTimeInterval(2)
            while panel.frame.size != size {
                precondition(Date() < deadline, "Native card did not settle at \(size); got \(panel.frame.size)")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        let toggle = try await utilityButton("Search songs and artists", in: card)
        precondition(press(toggle))
        try await Task.sleep(for: .milliseconds(100))
        precondition(companion.request.isSearchPresented, "Search button did not switch modes")
        try await waitForSize(card, MochiCompanionCard.searchSize)
        precondition(card.frame.size == MochiCompanionCard.searchSize, "Expanded card size was \(card.frame.size)")
        precondition(NSScreen.screens.contains { $0.visibleFrame.contains(card.frame) })
        SpotifyMockProtocol.server.configure([])
        guard let searchInput = card.firstResponder as? NSTextInputClient else { fatalError("Search lost keyboard focus") }
        searchInput.insertText("Test Song", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        precondition(search.query == "Test Song", "Search query was '\(search.query)', request draft was '\(companion.request.draft)'")
        card.sendEvent(enter)
        try await Task.sleep(for: .milliseconds(50))
        precondition(search.message?.contains("Connect Spotify") == true && SpotifyMockProtocol.server.requests().isEmpty)
        print("PASS: accessible search toggle, card expansion, keyboard input, and disconnected guidance")

        let store = SpotifyMemoryStore()
        store.tokens = SpotifyTokens(accessToken: "fake-access", refreshToken: "fake-refresh",
            expiresAt: Date().addingTimeInterval(3600), scope: SpotifyConfiguration.scopes.joined(separator: " "))
        let auth = SpotifyAuthModel(tokenClient: SpotifyTokenClient(session: session), tokenStore: store)
        let playback = SpotifyPlaybackModel(client: SpotifyPlaybackClient(session: session))
        let playing = Data(#"{"is_playing":true,"device":{"id":"test-device","is_restricted":false},"item":{"name":"Test Song","type":"track","artists":[{"name":"Test Artist"}]}}"#.utf8)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: playing)])
        let delegate = MochiAppDelegate(spotify: auth, playback: playback, companion: companion)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        let restoreDeadline = Date().addingTimeInterval(3)
        while playback.lastUpdatedAt == nil {
            precondition(Date() < restoreDeadline, "Launch did not restore connection and playback")
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(auth.isConnected && search.isConnected && SpotifyMockProtocol.server.requests().count == 1)
        print("PASS: app launch restores shared Spotify connection and playback without opening the menu")

        let tracks = (1...5).map { index -> [String: Any] in
            let id = String(repeating: "0", count: 21) + String(index)
            return ["id": id, "uri": "spotify:track:\(id)", "type": "track", "name": "Test Song \(index)",
                    "artists": [["name": "Test Artist"]], "album": ["name": "Test Album", "images": []]]
        }
        SpotifyMockProtocol.server.configure([SpotifyReply(data: try JSONSerialization.data(withJSONObject: ["tracks": ["items": tracks]]))])
        search.query = "Test Song"
        card.sendEvent(enter)
        let searchDeadline = Date().addingTimeInterval(3)
        while search.isSearching {
            precondition(Date() < searchDeadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        precondition(search.results.count == 5)
        if let previewDirectory = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
            let view = card.contentView!
            view.layoutSubtreeIfNeeded()
            let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: image)
            let path = URL(fileURLWithPath: previewDirectory).appendingPathComponent("search-card.png")
            try image.representation(using: .png, properties: [:])!.write(to: path)
        }
        guard let play = button("Play Test Song 1 by Test Artist", in: card.contentView!) else {
            fatalError("Search result play button is not accessible")
        }
        SpotifyMockProtocol.server.configure([SpotifyReply(data: playing), SpotifyReply(status: 204), SpotifyReply(data: playing)])
        precondition(press(play))
        let playDeadline = Date().addingTimeInterval(3)
        while search.isStarting {
            precondition(Date() < playDeadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(SpotifyMockProtocol.server.requests().count == 3 && search.message == "Sent Test Song 1 to Spotify.")
        let payload = try JSONSerialization.jsonObject(with: spotifyRequestBody(SpotifyMockProtocol.server.requests()[1])!) as! [String: Any]
        precondition(payload["uris"] as? [String] == ["spotify:track:0000000000000000000001"])

        // Menu appearance still refreshes its snapshot, while lifetime/reset belongs to the delegate.
        SpotifyMockProtocol.server.configure([SpotifyReply(data: playing)])
        let menu = NSPanel(contentRect: NSRect(x: 80, y: 80, width: 380, height: 420),
                           styleMask: .borderless, backing: .buffered, defer: false)
        menu.contentView = NSHostingView(rootView: ContentView(spotify: auth, playback: playback, companion: companion))
        menu.orderFrontRegardless()
        let menuDeadline = Date().addingTimeInterval(3)
        while SpotifyMockProtocol.server.requests().isEmpty || playback.isBusy {
            precondition(Date() < menuDeadline, "Menu appearance did not refresh playback")
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(SpotifyMockProtocol.server.requests().count == 1 && playback.state != nil)
        menu.orderOut(nil)
        menu.contentView = nil
        print("PASS: menu appearance refreshes the shared playback snapshot")

        let back = try await utilityButton("Back to listening request", in: card)
        precondition(press(back))
        try await Task.sleep(for: .milliseconds(100))
        let listeningSize = companion.request.hasSelectedTracks ? MochiCompanionCard.searchSize : MochiCompanionCard.size
        try await waitForSize(card, listeningSize)
        precondition(!companion.request.isSearchPresented && card.frame.size == listeningSize)
        precondition(companion.request.summary == "Soft piano for studying")
        print("PASS: Return searches, rendered results, native result-click playback, and listening mode restoration")

        for (prompt, expected, filename, intent, clarification) in [
            ("Help me unwind after a long day, no vocals", "Low energy · Instrumental", "understood-card.png",
             ["vocals": false, "energy": "low"] as [String: Any], NSNull() as Any),
            ("calm and energetic music with vocals", "What energy level would you like?", "clarification-card.png",
             ["vocals": true, "energy": NSNull()] as [String: Any], "What energy level would you like?" as Any)
        ] {
            if !liveBackend {
                let selection = clarification is NSNull ? mochiSampleSelectionPayload() : [
                    "catalog_kind": "fictional_sample", "method": "none", "tracks": [], "message": "Clarify your request."]
                let data = try JSONSerialization.data(withJSONObject: ["received_prompt": prompt,
                    "intent": intent, "clarification": clarification, "selection": selection] as [String: Any])
                SpotifyMockProtocol.server.configure([SpotifyReply(data: data)])
            }
            guard let requestInput = card.firstResponder as? NSTextInputClient else { fatalError("Request input lost focus") }
            requestInput.insertText(prompt, replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(50))
            card.sendEvent(enter)
            let deadline = Date().addingTimeInterval(3)
            while !companion.request.preferences.contains(prompt) {
                precondition(Date() < deadline, "Native understanding request failed: \(companion.request.reply)")
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(companion.request.reply.contains(expected))
            try await Task.sleep(for: .milliseconds(50))
            if let previewDirectory = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
                let view = card.contentView!
                view.layoutSubtreeIfNeeded()
                let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: image)
                let path = URL(fileURLWithPath: previewDirectory).appendingPathComponent(filename)
                try image.representation(using: .png, properties: [:])!.write(to: path)
            }
        }
        print("PASS: native Return displays understood preferences and asks about conflicting energy")

        func findIdentifier(_ identifier: String, in element: NSObject) -> NSObject? {
            if value("accessibilityIdentifier", from: element) as? String == identifier { return element }
            for child in value("accessibilityChildren", from: element) as? [Any] ?? [] {
                if let child = child as? NSObject, let found = findIdentifier(identifier, in: child) { return found }
            }
            return nil
        }
        for (prompt, matching, filename) in [("calm piano without vocals 80-100 BPM", true, "selection-card.png"),
                                            ("no vocals 300 BPM", false, "empty-selection-card.png")] {
            if !liveBackend {
                var selection = mochiSampleSelectionPayload()
                if matching {
                    selection["tracks"] = (selection["tracks"] as! [[String: Any]]).filter {
                        let bpm = $0["bpm"] as! Int
                        return (80...100).contains(bpm)
                    }
                }
                if !matching {
                    selection["tracks"] = []
                    selection["method"] = "none"
                    selection["message"] = "No sample tracks meet those requirements. Try a wider BPM range or different preferences."
                }
                let data = try JSONSerialization.data(withJSONObject: ["received_prompt": prompt,
                    "intent": ["vocals": false, "energy": matching ? "low" : NSNull(),
                               "bpm_min": matching ? 80 : 300, "bpm_max": matching ? 100 : 300], "selection": selection] as [String: Any])
                SpotifyMockProtocol.server.configure([SpotifyReply(data: data)])
            }
            guard let input = card.firstResponder as? NSTextInputClient else { fatalError("Selection composer lost focus") }
            input.insertText(prompt, replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(50))
            card.sendEvent(enter)
            let deadline = Date().addingTimeInterval(3)
            while !companion.request.preferences.contains(prompt) {
                precondition(Date() < deadline, "Selection submission failed: \(companion.request.reply)")
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(100))
            precondition(companion.request.hasSelectedTracks == matching)
            try await waitForSize(card, matching ? MochiCompanionCard.searchSize : MochiCompanionCard.size)
            precondition(card.frame.size == (matching ? MochiCompanionCard.searchSize : MochiCompanionCard.size))
            precondition(NSScreen.screens.contains { $0.visibleFrame.contains(card.frame) })
            precondition(card.firstResponder is NSTextInputClient, "Resizing lost composer focus")
            if matching {
                let first = companion.request.selection!.tracks[0]
                precondition(findIdentifier("mochiSelectedTrack-\(first.id)", in: card.contentView!) != nil,
                             "Selected sample row was not rendered accessibly")
                let searchToggle = try await utilityButton("Search songs and artists", in: card)
                precondition(press(searchToggle))
                try await Task.sleep(for: .milliseconds(100))
                let backToggle = try await utilityButton("Back to listening request", in: card)
                precondition(press(backToggle))
                try await Task.sleep(for: .milliseconds(100))
                precondition(companion.request.selection!.tracks[0].id == first.id && card.frame.size == MochiCompanionCard.searchSize)
            } else {
                precondition(companion.request.reply.contains("No sample tracks"))
            }
            if let previewDirectory = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
                let view = card.contentView!
                view.layoutSubtreeIfNeeded()
                let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: image)
                try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: previewDirectory).appendingPathComponent(filename))
            }
        }
        let reset = try await utilityButton("New listening request", in: card)
        precondition(press(reset))
        try await Task.sleep(for: .milliseconds(100))
        try await waitForSize(card, MochiCompanionCard.size)
        precondition(companion.request.selection == nil && companion.request.preferences.isEmpty && card.frame.size == MochiCompanionCard.size)
        print("PASS: native sample rows, keyboard submission, expanded placement, search/back retention, empty results and reset")

        if !liveBackend {
            auth.disconnect()
            let rows: [[String: Any]] = (0..<5).map { index in
                ["id": "lastfm-" + String(repeating: String(index), count: 64),
                 "title": "Development recording \(index + 1)", "artist": "Fixture Artist",
                 "bpm": NSNull(), "vocals": NSNull(), "energy": NSNull(), "score": 0.8,
                 "description": "Community tags: piano", "source": "lastfm",
                 "source_url": "https://www.last.fm/music/Fixture+Artist"]
            }
            let data = try JSONSerialization.data(withJSONObject: ["received_prompt": "piano",
                "selection": ["catalog_kind": "lastfm_live", "method": "lexical",
                    "request_id": UUID().uuidString, "tracks": rows, "warnings": []]])
            SpotifyMockProtocol.server.configure([SpotifyReply(data: data)])
            companion.request.submit("piano")
            while companion.request.isSending { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(100))
            try await waitForSize(card, MochiCompanionCard.searchSize)
            precondition(card.frame.size == MochiCompanionCard.searchSize)
            precondition(findIdentifier("mochiDiscoverySource", in: card.contentView!) != nil)
            precondition(button("Like Development recording 1", in: card.contentView!) == nil, "Song rows should expose only their overflow control")
            precondition(button("Dislike Development recording 1", in: card.contentView!) == nil)
            precondition(press(button("Options for Development recording 1", in: card.contentView!)!))
            try await Task.sleep(for: .milliseconds(180))
            precondition(popupButton("Like Development recording 1") != nil)
            precondition(popupButton("Dislike Development recording 1") != nil)
            // Return to the list through the popup's Escape action.
            guard let popup = NSApp.windows.first(where: { window in
                window.isVisible && window.contentView.map { button("Like Development recording 1", in: $0) != nil } == true
            }) else { fatalError("Song options window missing") }
            let dismissPopup = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: popup.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            popup.sendEvent(dismissPopup)
            try await Task.sleep(for: .milliseconds(180))
            precondition(card.isVisible && companion.isCardPresented)
            precondition(button("Play matches", in: card.contentView!) == nil)
            let seed = companion.request.selection!.tracks[0]
            precondition(findIdentifier("mochiSongOptions-\(seed.id)", in: card.contentView!) != nil,
                         "Song options menu was not accessible")
            if let previewDirectory = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
                let view = card.contentView!
                view.layoutSubtreeIfNeeded()
                let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: image)
                try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: previewDirectory).appendingPathComponent("live-selection-card.png"))
                // cacheDisplay omits the window-composited Liquid Glass material.
                // Flat diagnostic backdrops make text/layout visible in these image exports.
                for scheme in [ColorScheme.light, .dark] {
                    let preview = NSHostingView(rootView: MochiCompanionCard(request: companion.request, search: companion.search, onClose: {})
                        .environment(\.colorScheme, scheme)
                        .background(scheme == .light ? Color.white : Color.black))
                    preview.frame = NSRect(origin: .zero, size: MochiCompanionCard.searchSize)
                    preview.layoutSubtreeIfNeeded()
                    let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds)!
                    preview.cacheDisplay(in: preview.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: previewDirectory)
                        .appendingPathComponent("layout-results-\(scheme == .light ? "light" : "dark").png"))
                }
            }
            print("PASS: live discovery attribution, accessible feedback controls, nullable-feature rows and compact card")
            let similarRows = rows.enumerated().map { index, row in
                var next = row
                next["id"] = "lastfm-" + String(repeating: String(index + 5), count: 64)
                next["title"] = "Similar recording \(index + 1)"
                return next
            }
            let similarData = try JSONSerialization.data(withJSONObject: ["received_prompt": "piano",
                "selection": ["catalog_kind": "lastfm_live", "method": "lexical",
                    "request_id": UUID().uuidString, "tracks": similarRows, "warnings": []]])
            companion.request.draft = "jazz for tomorrow"
            SpotifyMockProtocol.server.configure([SpotifyReply(data: similarData)])
            companion.request.moreLikeThis(seed)
            while companion.request.isSending { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(100))
            precondition(companion.request.similarTo == seed.title && companion.request.draft == "jazz for tomorrow")
            try await waitForSize(card, MochiCompanionCard.searchSize)
            precondition(card.frame.size == MochiCompanionCard.searchSize)
            precondition(findIdentifier("mochiSimilarSeed", in: card.contentView!) != nil)
            precondition(findIdentifier("mochiSelectedTrack-\(similarRows[0]["id"] as! String)", in: card.contentView!) != nil)
            if let previewDirectory = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
                let view = card.contentView!
                view.layoutSubtreeIfNeeded()
                let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: image)
                try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: previewDirectory).appendingPathComponent("similar-selection-card.png"))
            }
            companion.request.reset()
            print("PASS: accessible song options, similar-song context, draft retention and compact native rendering")
        }

        if !liveBackend {
            let localState = try JSONDecoder().decode(SpotifyPlaybackState.self, from: playing)
            let local = LocalPlayerFixture(state: localState)
            let localPlayback = SpotifyPlaybackModel(localClient: local)
            let offlineAuth = SpotifyAuthModel(tokenStore: SpotifyMemoryStore())
            SpotifyMockProtocol.server.configure([])
            let localMenu = NSPanel(contentRect: NSRect(x: 120, y: 120, width: 380, height: 430),
                                    styleMask: .borderless, backing: .buffered, defer: false)
            localMenu.contentView = NSHostingView(rootView: ContentView(spotify: offlineAuth, playback: localPlayback, companion: companion)
                .environment(\.colorScheme, .light).background(Color.white))
            localMenu.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(150))
            guard let desktopButton = button("Use desktop controls", in: localMenu.contentView!) else { fatalError("Desktop action missing") }
            precondition(press(desktopButton))
            let deadline = Date().addingTimeInterval(3)
            while !localPlayback.usesDesktopPlayer || localPlayback.isBusy {
                precondition(Date() < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(150))
            precondition(localPlayback.state?.item?.name == "Test Song")
            precondition(button("Pause", in: localMenu.contentView!) != nil)
            precondition(button("Play link", in: localMenu.contentView!) == nil, "Link entry stays out of the main player")
            guard let settings = button("Player settings", in: localMenu.contentView!) else { fatalError("Player settings missing") }
            precondition(press(settings))
            try await Task.sleep(for: .milliseconds(150))
            guard let linkAction = popupButton("Play a Spotify link") else { fatalError("Link action missing") }
            precondition(press(linkAction))
            try await Task.sleep(for: .milliseconds(150))
            precondition(button("Play link", in: localMenu.contentView!) != nil)
            precondition(SpotifyMockProtocol.server.requests().isEmpty)
            func editableField(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.isEditable { return field }
                for child in view.subviews { if let field = editableField(in: child) { return field } }
                return nil
            }
            guard let field = editableField(in: localMenu.contentView!) else { fatalError("Track-link field missing") }
            localMenu.makeKeyAndOrderFront(nil)
            precondition(localMenu.makeFirstResponder(field))
            guard let editor = localMenu.firstResponder as? NSTextInputClient else { fatalError("Track-link field not editable") }
            editor.insertText("https://open.spotify.com/track/0000000000000000000001?si=test", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(50))
            precondition(press(button("Play link", in: localMenu.contentView!)!))
            let linkDeadline = Date().addingTimeInterval(3)
            while await local.startedTracks.isEmpty || localPlayback.isBusy {
                precondition(Date() < linkDeadline, "Link playback did not finish; field=\(field.stringValue), busy=\(localPlayback.isBusy)")
                try await Task.sleep(for: .milliseconds(10))
            }
            let starts = await local.startedTracks
            precondition(starts == ["spotify:track:0000000000000000000001"])
            precondition(SpotifyMockProtocol.server.requests().isEmpty)
            if let previewDirectory = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
                let view = localMenu.contentView!
                view.layoutSubtreeIfNeeded()
                let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: image)
                try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: previewDirectory).appendingPathComponent("desktop-player-menu.png"))
            }
            localMenu.orderOut(nil); localMenu.contentView = nil
            print("PASS: desktop action, Now Playing, native track-link typing/click playback without Spotify API login")
            let pollingCompanion = MochiCompanionController(defaults: defaults)
            let localDelegate = MochiAppDelegate(spotify: offlineAuth, playback: localPlayback, companion: pollingCompanion)
            localDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            try await Task.sleep(for: .milliseconds(100))
            let pausedState = SpotifyPlaybackState(isPlaying: false, item: localState.item, device: localState.device,
                                                  actions: nil, currentlyPlayingType: "track")
            await local.setState(pausedState)
            let refreshDeadline = Date().addingTimeInterval(7)
            while localPlayback.state?.isPlaying != false {
                precondition(Date() < refreshDeadline, "Desktop state wasn't refreshed with the menu closed")
                try await Task.sleep(for: .milliseconds(30))
            }
            let authorizations = await local.authorizationCount
            precondition(authorizations == 1 && SpotifyMockProtocol.server.requests().isEmpty)
            localDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            print("PASS: desktop state refreshes with menu closed and app launch never repeats permission or OAuth requests")
        }

        // Actual native artist editor buttons/typing with fixture-only HTTP.
        let artistSuite = "com.evan.Mochi.artist-ui-checks.\(UUID().uuidString)"
        let artistDefaults = UserDefaults(suiteName: artistSuite)!
        defer { artistDefaults.removePersistentDomain(forName: artistSuite) }
        let artists = MochiArtistPreferencesModel(backend: MochiBackendClient(session: session), defaults: artistDefaults)
        let artistRequest = MochiRequestModel(backend: MochiBackendClient(session: session), artists: artists, defaults: artistDefaults)
        let artistCompanion = MochiCompanionController(defaults: artistDefaults, request: artistRequest)
        artistCompanion.start(); artistCompanion.toggleCard()
        defer { artistCompanion.stop() }
        let artistCard = artistCompanion.cardPanel!
        try await Task.sleep(for: .milliseconds(100))
        precondition(artistCard.frame.size == MochiCompanionCard.artistSize)
        guard let skip = button("Skip for now", in: artistCard.contentView!) else { fatalError("Setup cannot be skipped") }
        precondition(press(skip)); try await Task.sleep(for: .milliseconds(100))
        try await waitForSize(artistCard, MochiCompanionCard.size)
        precondition(!artists.isPresented && artistCard.frame.size == MochiCompanionCard.size)
        let unavailableMode = try await modeChoice(.familiar, in: artistCard)
        _ = press(unavailableMode)
        precondition(artistRequest.discoveryMode == .balanced, "Familiar should require a favorite artist")
        if let balanced = popupButton("Balanced recommendations") { precondition(press(balanced)); try await Task.sleep(for: .milliseconds(150)) }
        let edit = try await utilityButton("Edit favorite artists", in: artistCard)
        precondition(press(edit)); try await Task.sleep(for: .milliseconds(100))
        for name in ["Fixture Artist", "Second Fixture Artist", "Third Fixture Artist"] {
            let suggestions = name == "Fixture Artist" ? [name, "Fixture Band", "An Artist With a Very Long Display Name That Must Truncate", "音楽", "Fixture Singer"] : [name]
            SpotifyMockProtocol.server.configure([SpotifyReply(data: try JSONSerialization.data(withJSONObject: ["query": name, "artists": suggestions]))])
            let focusDeadline = Date().addingTimeInterval(2)
            while !(artistCard.firstResponder is NSTextInputClient) {
                precondition(Date() < focusDeadline, "Artist input did not receive focus after the options menu closed")
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let artistInput = artistCard.firstResponder as? NSTextInputClient else { fatalError("Artist input is not focused") }
            artistInput.insertText(name, replacementRange: NSRange(location: NSNotFound, length: 0))
            let deadline = Date().addingTimeInterval(3)
            if name == "Second Fixture Artist" {
                let artistReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: artistCard.windowNumber,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                artistCard.sendEvent(artistReturn) // Actual Return, before autocomplete returns.
            } else if name == "Third Fixture Artist" {
                try await Task.sleep(for: .milliseconds(30))
                guard let addTyped = button("Add typed artist", in: artistCard.contentView!) else { fatalError("No visible Add action") }
                precondition(press(addTyped))
            }
            if name != "Fixture Artist" {
                while !artists.names.contains(name) {
                    precondition(Date() < deadline, "Return/Add didn't save the typed artist")
                    try await Task.sleep(for: .milliseconds(10))
                }
                precondition(SpotifyMockProtocol.server.requests().count == 1)
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            while artists.suggestions.isEmpty {
                precondition(Date() < deadline, "Artist autocomplete didn't finish")
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(100))
            if name == "Fixture Artist", let directory = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
                let view = artistCard.contentView!
                view.layoutSubtreeIfNeeded()
                let rendered = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rendered)
                try rendered.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("artist-autocomplete.png"))
            }
            guard let add = button("Add \(name)", in: artistCard.contentView!) else { fatalError("Autocomplete result is not accessible") }
            precondition(press(add)); try await Task.sleep(for: .milliseconds(100))
        }
        precondition(artists.names.count == 3)
        try await waitForSize(artistCard, MochiCompanionCard.artistEditorSize(count: 3))
        precondition(artistCard.frame.size == MochiCompanionCard.artistEditorSize(count: 3))
        try await Task.sleep(for: .milliseconds(400)) // Capture the settled spring pose.
        if let previewDirectory = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
            let view = artistCard.contentView!
            view.layoutSubtreeIfNeeded()
            let rendered = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rendered)
            try rendered.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: previewDirectory).appendingPathComponent("artist-favorites.png"))
        }
        guard let remove = button("Remove Second Fixture Artist", in: artistCard.contentView!) else { fatalError("Artist chip cannot be removed") }
        precondition(press(remove)); try await Task.sleep(for: .milliseconds(100))
        guard let done = button("Done", in: artistCard.contentView!) else { fatalError("No Done action") }
        precondition(press(done)); try await Task.sleep(for: .milliseconds(100))
        precondition(artists.names == ["Fixture Artist", "Third Fixture Artist"] && !artists.isPresented)
        precondition(MochiArtistPreferencesModel(defaults: artistDefaults).names == artists.names)
        try await waitForSize(artistCard, MochiCompanionCard.size)
        precondition(artistCard.frame.size == MochiCompanionCard.size)
        precondition(NSScreen.screens.contains { $0.visibleFrame.contains(artistCard.frame) })

        for mode in MochiDiscoveryMode.allCases {
            let modeButton = try await modeChoice(mode, in: artistCard)
            precondition(press(modeButton)); try await Task.sleep(for: .milliseconds(60))
            precondition(artistRequest.discoveryMode == mode)
            precondition(MochiRequestModel(artists: artists, defaults: artistDefaults).discoveryMode == mode)
            precondition(artistCard.frame.size == MochiCompanionCard.size)
            if let directory = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
                let view = artistCard.contentView!
                view.layoutSubtreeIfNeeded()
                let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: image)
                try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("mode-\(mode.rawValue).png"))
            }
        }
        let familiarChoice = try await modeChoice(.familiar, in: artistCard)
        precondition(press(familiarChoice))
        let modeRow: [String: Any] = ["id": "lastfm-" + String(repeating: "a", count: 64), "title": "Fixture Session",
            "artist": "Fixture Artist", "bpm": NSNull(), "vocals": NSNull(), "energy": NSNull(), "score": 0.8,
            "description": "Community tags: piano", "source": "lastfm", "source_url": "https://www.last.fm/music/Fixture+Artist"]
        let modeData = try JSONSerialization.data(withJSONObject: ["received_prompt": "piano", "selection": [
            "catalog_kind": "lastfm_live", "method": "lexical", "request_id": UUID().uuidString,
            "tracks": [modeRow], "warnings": [], "discovery_mode": "familiar"]])
        SpotifyMockProtocol.server.configure([SpotifyReply(data: modeData, delay: 0.2)])
        guard let modeInput = artistCard.firstResponder as? NSTextInputClient else { fatalError("Mode choice lost composer focus") }
        modeInput.insertText("piano", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(40))
        precondition(press(button("Send listening request", in: artistCard.contentView!)!))
        try await Task.sleep(for: .milliseconds(40))
        _ = press(button("Music discovery preference", in: artistCard.contentView!)!)
        precondition(artistRequest.discoveryMode == .familiar, "Mode changed while its request was pending")
        let modeDeadline = Date().addingTimeInterval(3)
        while artistRequest.isSending {
            precondition(Date() < modeDeadline); try await Task.sleep(for: .milliseconds(10))
        }
        let sentMode = try JSONSerialization.jsonObject(with: spotifyRequestBody(SpotifyMockProtocol.server.requests()[0])!) as! [String: Any]
        precondition(sentMode["discovery_mode"] as? String == "familiar")
        try await Task.sleep(for: .milliseconds(100))
        precondition(findIdentifier("mochiAppliedDiscoveryMode", in: artistCard.contentView!) == nil, "Matching modes should not repeat a label")
        precondition(artistRequest.selection?.discoveryMode == .familiar)
        let discoverChoice = try await modeChoice(.discover, in: artistCard)
        precondition(press(discoverChoice))
        precondition(artistRequest.discoveryMode == .discover && artistRequest.selection?.discoveryMode == .familiar)
        let appliedModeDeadline = Date().addingTimeInterval(2)
        while findIdentifier("mochiAppliedDiscoveryMode", in: artistCard.contentView!) == nil {
            precondition(Date() < appliedModeDeadline, "A changed next-request mode must identify the existing batch")
            try await Task.sleep(for: .milliseconds(10))
        }
        if let directory = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
            try await Task.sleep(for: .milliseconds(100))
            let view = artistCard.contentView!
            view.layoutSubtreeIfNeeded()
            let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("mode-results.png"))
        }
        SpotifyMockProtocol.server.configure([SpotifyReply(data: modeData)])
        artistRequest.moreLikeThis(artistRequest.selection!.tracks[0])
        while artistRequest.isSending { try await Task.sleep(for: .milliseconds(10)) }
        let similarMode = try JSONSerialization.jsonObject(with: spotifyRequestBody(SpotifyMockProtocol.server.requests()[0])!) as! [String: Any]
        precondition(similarMode["discovery_mode"] == nil && similarMode["request_id"] != nil)
        precondition(artistRequest.selection?.discoveryMode == .familiar && artistRequest.discoveryMode == .discover)
        artistRequest.reset()
        precondition(artistRequest.discoveryMode == .discover)
        artists.clear()
        precondition(artistRequest.discoveryMode == .balanced)
        artistCompanion.stop()
        print("PASS: native artist onboarding, autocomplete, Return/visible Add/result/Remove/Done, card resizing and saved choices")
        print("PASS: native familiarity choices, saved mode, pending-request lock, applied-mode label and original-mode refinement")

        companion.closeCard()
        companion.toggleCard()
        try await Task.sleep(for: .milliseconds(250))
        precondition(companion.isCardPresented && card.isVisible && card.alphaValue == 1 && !card.ignoresMouseEvents,
                     "A stale close completion hid the reopened panel")
        if !liveBackend {
            companion.request.reset()
            try await waitForSize(card, MochiCompanionCard.size)
            companion.request.draft = "Keep this request"
            let artwork = mascot.contentView!.subviews.first as! NSHostingView<MochiMascotView>
            precondition(artwork.rootView.activityMotion.activity == .curious)
            SpotifyMockProtocol.server.configure([SpotifyReply(data: Data(#"{"received_prompt":"Keep this request"}"#.utf8), delay: 0.3)])
            companion.request.submit()
            precondition(artwork.rootView.activityMotion.activity == .thinking)
            try await Task.sleep(for: .milliseconds(40))
            guard let cancel = button("Cancel", in: card.contentView!) else { fatalError("Pending request has no Cancel action") }
            precondition(press(cancel))
            precondition(!companion.request.isSending && companion.request.draft == "Keep this request")
            precondition(artwork.rootView.activityMotion.activity == .curious)
            try await Task.sleep(for: .milliseconds(350))
            precondition(companion.request.preferences.isEmpty && companion.request.draft == "Keep this request",
                         "A cancelled request replaced the draft or saved a late response")
        }
        print("PASS: rapid close/reopen, native typing/search reactions, visible cancellation and late-response rejection")

        companion.moveMascot(to: NSPoint(x: 100_000, y: 100_000))
        precondition(NSScreen.screens.contains { $0.visibleFrame.contains(mascot.frame) })
        precondition(NSScreen.screens.contains { $0.visibleFrame.contains(card.frame) })
        companion.savePosition()
        let savedOrigin = mascot.frame.origin
        companion.setVisible(false)
        precondition(!mascot.isVisible && !card.isVisible)
        companion.stop()

        let restored = MochiCompanionController(defaults: defaults)
        restored.start()
        defer { restored.stop() }
        precondition(!restored.isVisible && restored.mascotPanel?.isVisible == false)
        precondition(restored.mascotPanel?.frame.origin == savedOrigin)
        restored.setVisible(true)
        precondition(restored.mascotPanel?.isVisible == true)
        restored.toggleCard()
        restored.setVisible(false)
        precondition(restored.cardPanel?.isVisible == false)
        print("PASS: moving both windows, saved placement, hidden-state restoration, and show/hide cleanup")
    }
}
