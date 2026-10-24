import AppKit
import Combine
import Security
import SwiftUI

struct MochiEngineStatus: Decodable {
    let service: String
    let apiVersion: Int
    let catalogMode: String
    let discoveryConfigured: Bool
    let semanticModelInstalled: Bool
    enum CodingKeys: String, CodingKey {
        case service, apiVersion = "api_version", catalogMode = "catalog_mode"
        case discoveryConfigured = "discovery_configured", semanticModelInstalled = "semantic_model_installed"
    }
}

@MainActor protocol MochiEngineSecretStoring {
    func load() throws -> String?
    func save(_ value: String) throws
}

@MainActor final class MochiEngineSecretStore: MochiEngineSecretStoring {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.evan.Mochi.lastfm",
         kSecAttrAccount as String: "discovery"]
    }
    func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SpotifyAuthError.keychain(status) }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }
    func save(_ value: String) throws {
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SpotifyAuthError.keychain(status) }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let inserted = SecItemAdd(item as CFDictionary, nil)
        guard inserted == errSecSuccess else { throw SpotifyAuthError.keychain(inserted) }
    }
}

/// Own only the bundled child process. An externally started engine is checked,
/// never terminated. Credentials travel directly from Keychain to that child.
@MainActor final class MochiEngineModel: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var isReady = false
    @Published private(set) var discoveryConfigured = false
    @Published private(set) var semanticModelInstalled = false
    @Published private(set) var isExternal = false
    @Published private(set) var message = "Checking the music engine…"
    @Published private(set) var keyMessage: String?
    private let session: URLSession
    private let secrets: any MochiEngineSecretStoring
    private let helper: URL?
    private let dataDirectory: URL
    private let port: Int
    private var ownedProcess: Process?
    private var generation = UUID()

    init(session: URLSession? = nil, secrets: (any MochiEngineSecretStoring)? = nil, helper: URL? = nil,
         dataDirectory: URL? = nil, port: Int = 8000) {
        precondition((1024...65535).contains(port))
        self.port = port
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: EngineNoRedirects(), delegateQueue: nil)
        self.secrets = secrets ?? MochiEngineSecretStore()
        self.helper = helper ?? Bundle.main.resourceURL?.appendingPathComponent("Engine/mochi-backend")
        self.dataDirectory = dataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mochi/Engine", isDirectory: true)
    }

    func probe() async throws -> MochiEngineStatus {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/status")!)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let status = try? JSONDecoder().decode(MochiEngineStatus.self, from: data), status.service == "mochi",
              status.apiVersion == 1, ["live", "sample"].contains(status.catalogMode) else { throw EngineError.foreignService }
        return status
    }

    func ensureRunning() async {
        guard !isBusy else { return }
        let version = generation
        isBusy = true
        defer { if version == generation { isBusy = false } }
        do {
            let status = try await probe()
            guard version == generation else { return }
            apply(status)
            return
        } catch {
            guard !Task.isCancelled, version == generation else { return }
            guard (error as? URLError)?.code == .cannotConnectToHost else {
                isReady = false
                message = "Couldn't confirm Mochi's music engine. Port 8000 may be used by another app."
                return
            }
        }
        guard let helper, FileManager.default.isExecutableFile(atPath: helper.path) else {
            isReady = false
            message = "This development build needs the local backend. Run scripts/run-mochi.sh, or use a bundled beta build."
            return
        }
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = helper
            process.arguments = ["--port", String(port)]
            let inherited = ProcessInfo.processInfo.environment
            var environment = inherited.filter { ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "__CF_USER_TEXT_ENCODING"].contains($0.key) }
            environment["LASTFM_API_KEY"] = try secrets.load() ?? ""
            environment["MOCHI_DATA_DIRECTORY"] = dataDirectory.path
            environment["MOCHI_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
            environment["MOCHI_MANAGED_ENGINE"] = "1"
            environment["MOCHI_CATALOG_MODE"] = "live"
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            ownedProcess = process
            message = "Starting the music engine…"
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(250))
                guard version == generation, process.isRunning else { throw EngineError.startFailed }
                if let status = try? await probe() { apply(status); return }
            }
            throw EngineError.startFailed
        } catch {
            guard version == generation else { return }
            ownedProcess?.terminate(); ownedProcess = nil
            isReady = false
            message = error is CancellationError ? "Music engine start cancelled." : "The music engine couldn't start. Try Restart engine."
        }
    }

    private func apply(_ status: MochiEngineStatus) {
        isReady = true
        isExternal = ownedProcess == nil
        discoveryConfigured = status.discoveryConfigured
        semanticModelInstalled = status.semanticModelInstalled
        message = status.catalogMode == "sample" ? "Development sample mode is active." :
            (status.discoveryConfigured ? "Ready to discover music." : "Add your Last.fm API key to enable discovery.")
    }

    func saveKey(_ value: String) async {
        guard !isBusy else { return }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil else {
            keyMessage = "Enter the 32-character Last.fm API key."; return
        }
        do { try secrets.save(key) }
        catch { keyMessage = "Couldn't save the key in macOS Keychain."; return }
        keyMessage = "Saved in macOS Keychain."
        if isExternal && isReady {
            keyMessage = "Saved for the bundled engine. An external backend still uses its own configuration."
        } else { await restart() }
    }

    func restart() async {
        guard !isBusy else { return }
        let process = ownedProcess
        stopOwned()
        if let process {
            for _ in 0..<30 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            guard !process.isRunning else { message = "The old engine is still stopping. Try again shortly."; return }
        }
        await ensureRunning()
    }

    func stopOwned() {
        generation = UUID()
        if ownedProcess?.isRunning == true { ownedProcess?.terminate() }
        ownedProcess = nil
        isBusy = false; isReady = false
    }

    private enum EngineError: Error { case foreignService, startFailed }
}

private final class EngineNoRedirects: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct MochiSettingsView: View {
    @ObservedObject var engine: MochiEngineModel
    @ObservedObject var spotify: SpotifyAuthModel
    @ObservedObject var companion: MochiCompanionController
    @State private var key = ""

    var body: some View {
        Form {
            Section("Music engine") {
                Text(engine.message).font(.callout)
                if engine.isReady {
                    Text(engine.semanticModelInstalled ? "Semantic ranking model installed" : "Using word matching; semantic model is not installed")
                        .font(.caption).foregroundStyle(.secondary)
                    if engine.isExternal { Text("Connected to an engine started outside Mochi.").font(.caption).foregroundStyle(.secondary) }
                }
                HStack {
                    Button(engine.isBusy ? "Starting…" : "Check / Start engine") { Task { await engine.ensureRunning() } }
                    Button("Restart engine") { Task { await engine.restart() } }
                }.disabled(engine.isBusy)
            }
            Section("Last.fm discovery") {
                SecureField("Last.fm API key", text: $key)
                    .textContentType(.password).accessibilityLabel("Last.fm API key")
                Button("Save key") {
                    let value = key; key = ""
                    Task { await engine.saveKey(value) }
                }.disabled(engine.isBusy || key.isEmpty)
                if let message = engine.keyMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                Link("Get a Last.fm API key", destination: URL(string: "https://www.last.fm/api/account/create")!)
            }
            Section("Spotify") {
                Text(spotify.statusMessage).font(.caption)
                Button(spotify.isConnected ? "Disconnect Spotify API" : "Connect Spotify API") {
                    if spotify.isConnected { spotify.disconnect() } else { spotify.connect() }
                }.disabled(spotify.isBusy)
                Text("The private API beta requires Spotify Premium and an invitation from the app owner. Desktop controls can be used without API login.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Your listening data") {
                MochiTasteSettings(request: companion.request)
            }
        }.formStyle(.grouped).frame(width: 460, height: 600)
            .task { await engine.ensureRunning() }
    }
}

private struct MochiTasteSettings: View {
    @ObservedObject var request: MochiRequestModel
    var body: some View {
        Text("Preferences and recent requests stay on this Mac. Discovery requests go to Last.fm; song matching and controls go to Spotify.")
            .font(.caption).foregroundStyle(.secondary)
        Button("Clear recent list") { request.clearRecentSessions() }
        Button(request.feedbackBusy ? "Updating taste…" : "Forget taste memory") { request.clearTaste() }
            .disabled(request.feedbackBusy || request.isSending || request.isStarting)
        if let error = request.feedbackError { Text(error).font(.caption).foregroundStyle(.secondary) }
    }
}
