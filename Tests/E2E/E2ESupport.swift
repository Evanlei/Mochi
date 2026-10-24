import AppKit
import ApplicationServices
import Foundation
import SwiftUI

// MARK: - E2E Assertions

func e2eAssert(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if !condition() {
        let filename = URL(fileURLWithPath: "\(file)").lastPathComponent
        print("  ❌ ASSERTION FAILED [\(filename):\(line)]: \(message)")
        preconditionFailure("E2E Assertion Failed: \(message)")
    }
}

func e2eAssertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if a != b {
        let detail = message.isEmpty ? "Expected '\(b)', got '\(a)'" : "\(message) — Expected '\(b)', got '\(a)'"
        let filename = URL(fileURLWithPath: "\(file)").lastPathComponent
        print("  ❌ ASSERTION FAILED [\(filename):\(line)]: \(detail)")
        preconditionFailure("E2E Assertion Failed: \(detail)")
    }
}

func e2eAssertNotNil(_ a: Any?, _ message: String = "Expected non-nil value", file: StaticString = #file, line: UInt = #line) {
    if a == nil {
        let filename = URL(fileURLWithPath: "\(file)").lastPathComponent
        print("  ❌ ASSERTION FAILED [\(filename):\(line)]: \(message)")
        preconditionFailure("E2E Assertion Failed: \(message)")
    }
}

func e2eAssertNil(_ a: Any?, _ message: String = "Expected nil value", file: StaticString = #file, line: UInt = #line) {
    if a != nil {
        let filename = URL(fileURLWithPath: "\(file)").lastPathComponent
        print("  ❌ ASSERTION FAILED [\(filename):\(line)]: \(message)")
        preconditionFailure("E2E Assertion Failed: \(message)")
    }
}

// MARK: - AppKit Accessibility Query Helpers

@MainActor
enum AXQuery {
    static func activateAccessibilityTree() {
        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var windows: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
    }

    static func value(_ name: String, from item: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        guard item.responds(to: selector) else { return nil }
        return item.perform(selector)?.takeUnretainedValue()
    }

    static func find(key: String, value target: String, in item: NSObject) -> NSObject? {
        if let val = self.value(key, from: item) as? String, val == target {
            return item
        }
        for child in self.value("accessibilityChildren", from: item) as? [NSObject] ?? [] {
            if let found = find(key: key, value: target, in: child) {
                return found
            }
        }
        return nil
    }

    static func findAll(key: String, value target: String, in item: NSObject) -> [NSObject] {
        var results: [NSObject] = []
        if let val = self.value(key, from: item) as? String, val == target {
            results.append(item)
        }
        for child in self.value("accessibilityChildren", from: item) as? [NSObject] ?? [] {
            results.append(contentsOf: findAll(key: key, value: target, in: child))
        }
        return results
    }

    static func find(identifier: String, in item: NSObject) -> NSObject? {
        find(key: "accessibilityIdentifier", value: identifier, in: item)
    }

    static func find(label: String, in item: NSObject) -> NSObject? {
        find(key: "accessibilityLabel", value: label, in: item)
    }

    static func find(role: String, in item: NSObject) -> NSObject? {
        find(key: "accessibilityRole", value: role, in: item)
    }

    static func findButton(label: String, in item: NSObject) -> NSObject? {
        if self.value("accessibilityLabel", from: item) as? String == label,
           self.value("accessibilityRole", from: item) as? String == "AXButton" {
            return item
        }
        for child in self.value("accessibilityChildren", from: item) as? [NSObject] ?? [] {
            if let found = findButton(label: label, in: child) {
                return found
            }
        }
        return nil
    }

    static func press(_ item: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard item.responds(to: selector) else { return false }
        let action = unsafeBitCast(item.method(for: selector), to: (@convention(c) (NSObject, Selector) -> Bool).self)
        return action(item, selector)
    }

    static func pressButton(label: String, in item: NSObject) -> Bool {
        guard let btn = findButton(label: label, in: item) else { return false }
        return press(btn)
    }
}

// MARK: - Key Event Simulation

@MainActor
enum KeySimulator {
    static func sendReturn(to window: NSWindow) {
        let enter = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )!
        window.sendEvent(enter)
    }

    static func sendEscape(to window: NSWindow) {
        let escape = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        )!
        window.sendEvent(escape)
    }

    @discardableResult
    static func typeText(_ text: String, into window: NSWindow) async -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if let input = window.firstResponder as? NSTextInputClient {
                input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                try? await Task.sleep(nanoseconds: 50_000_000)
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}

// MARK: - E2E Test Context & Environment

@MainActor
final class E2ETestContext {
    let suiteName: String
    let defaults: UserDefaults
    let session: URLSession
    let store: SpotifyMemoryStore
    let auth: SpotifyAuthModel
    let localPlayer: LocalPlayerFixture
    let playback: SpotifyPlaybackModel
    let search: SpotifySearchModel
    let request: MochiRequestModel
    let companion: MochiCompanionController

    init(suitePrefix: String = "com.evan.Mochi.e2e") {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        self.suiteName = "\(suitePrefix).\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: suiteName)!
        self.defaults.set(true, forKey: "mochi.taste.artist-setup-complete")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SpotifyMockProtocol.self]
        self.session = URLSession(configuration: config)

        self.store = SpotifyMemoryStore()
        self.auth = SpotifyAuthModel(tokenClient: SpotifyTokenClient(session: session), tokenStore: store)

        self.localPlayer = LocalPlayerFixture(state: nil)
        self.playback = SpotifyPlaybackModel(
            client: SpotifyPlaybackClient(session: session),
            localClient: localPlayer,
            defaults: defaults
        )

        let backend = MochiBackendClient(session: session)
        self.request = MochiRequestModel(
            backend: backend,
            resolver: SpotifySearchClient(session: session),
            artists: MochiArtistPreferencesModel(backend: backend, defaults: defaults),
            defaults: defaults
        )
        self.search = SpotifySearchModel(client: SpotifySearchClient(session: session))

        self.companion = MochiCompanionController(defaults: defaults, search: search, request: request)
        self.search.configure(using: auth, playback: playback)
        self.request.configure(using: auth, playback: playback)
    }

    func connectAuth() async {
        store.tokens = SpotifyTokens(
            accessToken: "fake-e2e-access",
            refreshToken: "fake-e2e-refresh",
            expiresAt: Date().addingTimeInterval(7200),
            scope: SpotifyConfiguration.scopes.joined(separator: " ")
        )
        await auth.restore()
        e2eAssert(auth.isConnected, "Spotify auth restore failed")
    }

    func cleanup() {
        companion.stop()
        request.cancelRequest()
        request.stopSession()
        defaults.removePersistentDomain(forName: suiteName)
        SpotifyMockProtocol.server.configure([])
    }

    static func pollUntil(
        timeout: TimeInterval = 3.0,
        interval: TimeInterval = 0.02,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return condition()
    }

    // MARK: - Mock Payload Generators

    static func makePlaybackJSON(
        name: String = "E2E Test Song",
        artist: String = "E2E Artist",
        album: String? = "E2E Album",
        artworkURL: String? = nil,
        isPlaying: Bool = true,
        deviceName: String = "E2E MacBook Pro",
        isRestricted: Bool = false,
        actions: [String: Any] = [:]
    ) throws -> Data {
        var item: [String: Any] = [
            "name": name,
            "type": "track",
            "artists": [["name": artist]]
        ]
        if let album = album {
            var albumObj: [String: Any] = ["name": album]
            if let artwork = artworkURL {
                albumObj["images"] = [["url": artwork, "height": 300, "width": 300]]
            } else {
                albumObj["images"] = []
            }
            item["album"] = albumObj
        }
        return try JSONSerialization.data(withJSONObject: [
            "is_playing": isPlaying,
            "currently_playing_type": "track",
            "device": [
                "id": "e2e-device-id",
                "name": deviceName,
                "is_restricted": isRestricted
            ],
            "item": item,
            "actions": actions
        ])
    }

    static func makeSearchTracksJSON(count: Int = 3, prefix: String = "Track") throws -> Data {
        let items = (1...count).map { i -> [String: Any] in
            let id = "e2e-id-\(i)"
            return [
                "id": id,
                "uri": "spotify:track:\(id)",
                "type": "track",
                "name": "\(prefix) \(i)",
                "artists": [["name": "Artist \(i)"]],
                "album": ["name": "Album \(i)", "images": []]
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["tracks": ["items": items]])
    }

    static func makeDiscoveryJSON(prompt: String = "Test Prompt", count: Int = 3, catalogKind: String = "fictional_sample") throws -> Data {
        let isLastFM = catalogKind == "lastfm_live"
        let tracks = (1...count).map { i -> [String: Any] in
            let trackId = isLastFM ? "lastfm-" + String(format: "%064x", i) : "sample-\(i)"
            var trackObj: [String: Any] = [
                "id": trackId,
                "title": "Discovered Track \(i)",
                "artist": "Discovery Artist",
                "bpm": 80.0 + Double(i) * 5.0,
                "vocals": i % 2 == 0,
                "energy": "low",
                "description": "A relaxing test track",
                "score": 0.95 - Double(i) * 0.05
            ]
            if isLastFM {
                trackObj["source"] = "lastfm"
            }
            return trackObj
        }
        var selectionObj: [String: Any] = [
            "catalog_kind": catalogKind,
            "method": "semantic",
            "tracks": tracks,
            "message": NSNull()
        ]
        if isLastFM {
            selectionObj["request_id"] = UUID().uuidString
        }
        return try JSONSerialization.data(withJSONObject: [
            "received_prompt": prompt,
            "intent": NSNull(),
            "clarification": NSNull(),
            "selection": selectionObj
        ])
    }
}
