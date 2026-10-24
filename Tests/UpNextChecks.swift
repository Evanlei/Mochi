import AppKit
import ApplicationServices
import SwiftUI

/// Native controls backed exclusively by fixture responses, never a real account.
@main
struct UpNextChecks {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let network = URLSession(configuration: configuration)
        let backend = MochiBackendClient(session: network)
        let request = MochiRequestModel(backend: backend, resolver: SpotifySearchClient(session: network))
        let search = SpotifySearchModel(client: SpotifySearchClient(session: network))
        let suite = "com.evan.Mochi.up-next-checks.\(UUID().uuidString)"
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
        companion.start(); companion.toggleCard()
        defer { companion.stop() }
        let card = companion.cardPanel!
        let axStatus = await Task.detached {
            var windows: CFTypeRef?
            return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
                                               kAXWindowsAttribute as CFString, &windows)
        }.value
        precondition(axStatus == .success)

        func value(_ name: String, _ item: NSObject) -> Any? {
            let selector = NSSelectorFromString(name)
            return item.responds(to: selector) ? item.perform(selector)?.takeUnretainedValue() : nil
        }
        func find(_ name: String, key: String = "accessibilityIdentifier", in item: NSObject) -> NSObject? {
            if value(key, item) as? String == name { return item }
            for child in value("accessibilityChildren", item) as? [NSObject] ?? [] {
                if let found = find(name, key: key, in: child) { return found }
            }
            return nil
        }
        func press(_ name: String, in view: NSView) {
            guard let item = find(name, key: "accessibilityLabel", in: view) else { fatalError("Missing button: \(name)") }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            let action = unsafeBitCast(item.method(for: selector), to: (@convention(c) (NSObject, Selector) -> Bool).self)
            precondition(action(item, selector))
        }
        func describe(_ item: NSObject, depth: Int = 0) -> String {
            guard depth < 8 else { return "" }
            let line = "\(value("accessibilityRole", item) ?? "?") \(value("accessibilityIdentifier", item) ?? "-") \(value("accessibilityLabel", item) ?? "-")"
            return line + "\n" + (value("accessibilityChildren", item) as? [NSObject] ?? [])
                .map { describe($0, depth: depth + 1) }.joined()
        }
        func json(_ body: Any, delay: TimeInterval = 0) throws -> SpotifyReply {
            SpotifyReply(data: try JSONSerialization.data(withJSONObject: body), delay: delay)
        }
        func id(_ n: Int) -> String { "lastfm-" + String(format: "%064x", n) }
        func spotifyID(_ n: Int) -> String { String(format: "%022d", n) }
        func uri(_ n: Int) -> String { "spotify:track:\(spotifyID(n))" }
        func state(_ n: Int, playing: Bool = true) throws -> SpotifyReply {
            try json(["is_playing": playing, "device": ["id": "fixture-device", "is_restricted": false],
                "item": ["uri": uri(n), "name": "Queue song \(n)", "type": "track", "artists": [["name": "Fixture Artist"]]]])
        }
        func selection(_ numbers: [Int], delay: TimeInterval = 0) throws -> SpotifyReply {
            let tracks: [[String: Any]] = numbers.map { n in
                ["id": id(n), "title": "Queue song \(n)", "artist": "Fixture Artist", "description": "piano", "source": "lastfm", "score": 0.8]
            }
            return try json(["received_prompt": "piano", "selection": ["catalog_kind": "lastfm_live", "method": "lexical",
                "request_id": UUID().uuidString, "tracks": tracks]], delay: delay)
        }
        func match(_ n: Int) throws -> SpotifyReply {
            try json(["tracks": ["items": [["id": spotifyID(n), "uri": uri(n), "name": "Queue song \(n)", "type": "track",
                "artists": [["name": "Fixture Artist"]], "album": ["name": "Fixture album"]]]]])
        }
        func render(_ filename: String, dark: Bool = false) throws {
            guard let directory = CommandLine.arguments.dropFirst().first else { return }
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let panel = NSPanel(contentRect: NSRect(x: 160, y: 160, width: 292, height: 300),
                                styleMask: .borderless, backing: .buffered, defer: false)
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: MochiUpNextView(request: request).padding(12)
                .environment(\.colorScheme, dark ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
            host.sizingOptions = []
            panel.contentView = host; panel.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(filename))
            panel.orderOut(nil); panel.contentView = nil
        }

        var replies = [try selection(Array(1...5))] + (try (1...5).map(match))
        replies += [try state(1), SpotifyReply(status: 204), try state(1), try json(["status": "ok"])]
        SpotifyMockProtocol.server.configure(replies)
        request.submit("piano")
        let sendDeadline = Date().addingTimeInterval(5)
        while request.isSending || request.feedbackBusy {
            precondition(Date() < sendDeadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        replies = []
        for _ in 2...5 { replies += [try state(1), SpotifyReply(status: 204)] }
        SpotifyMockProtocol.server.configure(replies)
        await request.maintainSession()
        try await Task.sleep(for: .milliseconds(200))
        precondition(card.frame.size == MochiCompanionCard.searchSize)
        precondition(find("mochiUpNext", in: card.contentView!) != nil)
        precondition(find("mochiQueueCurrent-\(id(1))", in: card.contentView!) != nil,
                     "snapshot=\(request.sessionQueue) tree=\(describe(card.contentView!))")
        precondition(find("mochiQueueSong-\(id(2))", in: card.contentView!) != nil)
        press("Show recommendations", in: card.contentView!)
        try await Task.sleep(for: .milliseconds(100))
        precondition(find("mochiUpNext", in: card.contentView!) == nil)
        precondition(find("mochiSelectedTrack-\(id(1))", in: card.contentView!) != nil)
        press("Show Up Next", in: card.contentView!)
        try await Task.sleep(for: .milliseconds(100))
        precondition(find("mochiQueueCurrent-\(id(1))", in: card.contentView!) != nil)
        try render("up-next-light.png"); try render("up-next-dark.png", dark: true)
        print("PASS: real native Picks/Up Next controls, default queue selection, current/upcoming rows and unchanged compact footprint")

        SpotifyMockProtocol.server.configure([try state(2, playing: false)])
        await playback.refresh(using: auth)
        try await Task.sleep(for: .milliseconds(100))
        precondition(!request.sessionQueue.isPlaying && request.queuedSongCount == 3)
        precondition(find("mochiQueueCurrent-\(id(2))", in: card.contentView!) != nil)
        precondition(find("mochiQueueSong-\(id(2))", in: card.contentView!) == nil)
        try render("up-next-paused.png")

        replies = [try state(3), try selection(Array(6...10), delay: 0.3)] + (try (6...10).map(match))
        for _ in 6...10 { replies += [try state(3), SpotifyReply(status: 204)] }
        SpotifyMockProtocol.server.configure(replies)
        await playback.refresh(using: auth)
        let refill = Task { await request.maintainSession() }
        try await Task.sleep(for: .milliseconds(100))
        precondition(request.isRefilling)
        try render("up-next-refilling.png")
        await refill.value
        try await Task.sleep(for: .milliseconds(100))
        precondition(request.sessionQueue.upcoming.map(\.uri) == (4...10).map(uri))
        precondition(find("mochiQueueSong-\(id(4))", in: card.contentView!) != nil)
        precondition(find("mochiQueueSong-\(id(6))", in: card.contentView!) != nil)
        print("PASS: visible queue follows pause/current-song changes and spans old/new batches while refilling")

        press("Options for Queue song 3", in: card.contentView!)
        try await Task.sleep(for: .milliseconds(150))
        guard let actions = NSApp.windows.first(where: { window in
            window.isVisible && window.contentView.map { find("Like Queue song 3", key: "accessibilityLabel", in: $0) != nil } == true
        }) else { fatalError("Current-song feedback actions missing") }
        SpotifyMockProtocol.server.configure([try json(["status": "ok"])])
        press("Like Queue song 3", in: actions.contentView!)
        while request.feedbackBusy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(request.isLiked(request.canonicalTrack(id: id(3))!))
        print("PASS: native Up Next feedback works on a current song from an earlier batch")

        SpotifyMockProtocol.server.configure([SpotifyReply(status: 500)])
        await playback.refresh(using: auth)
        precondition(request.sessionQueue.isStale)
        SpotifyMockProtocol.server.configure([try state(3)])
        await playback.refresh(using: auth)
        let menu = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 300, height: 300),
                           styleMask: .borderless, backing: .buffered, defer: false)
        SpotifyMockProtocol.server.configure([try state(3)])
        menu.contentView = NSHostingView(rootView: ContentView(spotify: auth, playback: playback, companion: companion))
        menu.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(200))
        press("Show Up Next", in: menu.contentView!)
        try await Task.sleep(for: .milliseconds(200))
        guard let popup = NSApp.windows.first(where: { window in
            window !== card && window !== menu && window.isVisible
                && window.contentView.map { find("mochiUpNext", in: $0) != nil } == true
        }) else { fatalError("Menu queue popover missing") }
        precondition(find("mochiQueueCurrent-\(id(3))", in: popup.contentView!) != nil)
        SpotifyMockProtocol.server.configure([])
        press("Stop continuous listening", in: popup.contentView!)
        try await Task.sleep(for: .milliseconds(100))
        precondition(!request.isSessionActive && request.sessionQueue.upcoming.isEmpty)
        precondition(playback.state?.isPlaying == true && SpotifyMockProtocol.server.requests().isEmpty)
        precondition(find("mochiSelectedTrack-\(id(6))", in: card.contentView!) != nil)
        menu.orderOut(nil); menu.contentView = nil
        print("PASS: menu popover shares the queue, stale state stays explicit, and Stop returns to Picks without touching Spotify playback")
    }
}
