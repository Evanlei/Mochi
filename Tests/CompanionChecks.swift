import AppKit
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
        precondition(companion.request.reply.contains("Request received"))
        if liveBackend { print("PASS: native card Return → real FastAPI → confirmed request in card") }
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: card.windowNumber, context: nil, characters: "\u{1b}",
                                     charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        card.sendEvent(escape)
        try await Task.sleep(for: .milliseconds(50))
        precondition(!card.isVisible)
        companion.closeCard()
        precondition(mascot.contentView!.accessibilityPerformPress())
        precondition(companion.request.summary == "Soft piano for studying")
        print("PASS: native panel creation, accessible toggle, keyboard typing/Return/Escape, and request retention")

        // Exercise SwiftUI buttons through their native accessibility actions.
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
        guard let toggle = button("Search songs and artists", in: card.contentView!) else {
            fatalError("Search toggle is not accessible")
        }
        precondition(press(toggle))
        try await Task.sleep(for: .milliseconds(100))
        precondition(companion.request.isSearchPresented, "Search button did not switch modes")
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

        guard let back = button("Back to listening request", in: card.contentView!) else { fatalError("Missing back button") }
        precondition(press(back))
        try await Task.sleep(for: .milliseconds(100))
        precondition(!companion.request.isSearchPresented && card.frame.size == MochiCompanionCard.size)
        precondition(companion.request.summary == "Soft piano for studying")
        print("PASS: Return searches, rendered results, native result-click playback, and compact mode restoration")

        for (prompt, expected, filename, intent, clarification) in [
            ("Help me unwind after a long day, no vocals", "Low energy · Instrumental", "understood-card.png",
             ["vocals": false, "energy": "low"] as [String: Any], NSNull() as Any),
            ("calm and energetic music with vocals", "What energy level would you like?", "clarification-card.png",
             ["vocals": true, "energy": NSNull()] as [String: Any], "What energy level would you like?" as Any)
        ] {
            if !liveBackend {
                let data = try JSONSerialization.data(withJSONObject: ["received_prompt": prompt,
                    "intent": intent, "clarification": clarification] as [String: Any])
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
