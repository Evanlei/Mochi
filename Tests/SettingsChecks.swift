import AppKit
import ApplicationServices
import SwiftUI

@MainActor private final class SettingsSecrets: MochiEngineSecretStoring {
    var value: String?
    func load() throws -> String? { value }
    func save(_ value: String) throws { self.value = value }
}

@main struct SettingsChecks {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let network = URLSession(configuration: configuration)
        let secret = SettingsSecrets()
        let engine = MochiEngineModel(session: network, secrets: secret)
        let auth = SpotifyAuthModel(tokenStore: SpotifyMemoryStore())
        let suite = "com.evan.Mochi.settings-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let companion = MochiCompanionController(defaults: defaults)
        let status: [String: Any] = ["service": "mochi", "api_version": 1, "catalog_mode": "live",
                                    "discovery_configured": true, "semantic_model_installed": true]
        let reply = SpotifyReply(data: try JSONSerialization.data(withJSONObject: status))
        SpotifyMockProtocol.server.configure([reply])
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 460, height: 600),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: MochiSettingsView(engine: engine, spotify: auth, companion: companion))
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil); panel.contentView = nil }
        let initialized = await Task.detached {
            var windows: CFTypeRef?
            return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
                                               kAXWindowsAttribute as CFString, &windows)
        }.value
        precondition(initialized == .success)
        let deadline = Date().addingTimeInterval(3)
        while !engine.isReady || engine.isBusy {
            precondition(Date() < deadline); try await Task.sleep(for: .milliseconds(10))
        }
        func value(_ name: String, _ object: NSObject) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        func button(_ label: String, in object: NSObject) -> NSObject? {
            if value("accessibilityLabel", object) as? String == label,
               value("accessibilityRole", object) as? String == "AXButton" { return object }
            for child in value("accessibilityChildren", object) as? [NSObject] ?? [] {
                if let item = button(label, in: child) { return item }
            }
            return nil
        }
        func secureField(_ view: NSView) -> NSSecureTextField? {
            if let field = view as? NSSecureTextField { return field }
            for child in view.subviews { if let field = secureField(child) { return field } }
            return nil
        }
        guard let field = secureField(panel.contentView!) else { fatalError("Key entry missing") }
        precondition(panel.makeFirstResponder(field))
        guard let editor = panel.firstResponder as? NSTextInputClient else { fatalError("Key entry not editable") }
        editor.insertText(String(repeating: "a", count: 32), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(150))
        guard let save = button("Save key", in: panel.contentView!) else { fatalError("Save key control missing") }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let press = unsafeBitCast(save.method(for: selector), to: (@convention(c) (NSObject, Selector) -> Bool).self)
        precondition(press(save, selector))
        let savedDeadline = Date().addingTimeInterval(3)
        while secret.value == nil {
            precondition(Date() < savedDeadline); try await Task.sleep(for: .milliseconds(10))
        }
        precondition(secret.value == String(repeating: "a", count: 32))
        precondition(engine.keyMessage?.contains("external") == true)
        precondition(button("Check / Start engine", in: panel.contentView!) != nil)
        precondition(button("Connect Spotify API", in: panel.contentView!) != nil)
        if let directory = CommandLine.arguments.dropFirst().first {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let view = panel.contentView!
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings.png"))
        }
        print("PASS: native settings opens, probes engine status, accepts a secure key, saves via the credential store and exposes setup controls")
    }
}
