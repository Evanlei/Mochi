import Foundation

@MainActor private final class EngineMemorySecrets: MochiEngineSecretStoring {
    var value: String?
    func load() throws -> String? { value }
    func save(_ value: String) throws { self.value = value }
}

@main struct EngineChecks {
    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let session = URLSession(configuration: configuration)
        let secrets = EngineMemorySecrets()
        let payload: [String: Any] = ["service": "mochi", "api_version": 1, "catalog_mode": "live",
                                    "discovery_configured": true, "semantic_model_installed": true]
        let good = SpotifyReply(data: try JSONSerialization.data(withJSONObject: payload))
        let model = MochiEngineModel(session: session, secrets: secrets, helper: URL(fileURLWithPath: "/private/tmp/no-mochi-helper"))
        SpotifyMockProtocol.server.configure([good])
        await model.ensureRunning()
        precondition(model.isReady && model.isExternal && model.discoveryConfigured && model.semanticModelInstalled)
        precondition(SpotifyMockProtocol.server.requests()[0].url?.path == "/status")
        await model.saveKey("wrong")
        precondition(secrets.value == nil)
        await model.saveKey(String(repeating: "a", count: 32))
        precondition(secrets.value?.count == 32 && model.keyMessage?.contains("external") == true)
        print("PASS: safe readiness/configuration status, Keychain abstraction and validated API-key entry")

        SpotifyMockProtocol.server.configure([SpotifyReply(data: Data(#"{"status":"ok"}"#.utf8))])
        await model.ensureRunning()
        precondition(!model.isReady && model.message.contains("Port 8000"))
        SpotifyMockProtocol.server.configure([SpotifyReply(error: .cannotConnectToHost)])
        await model.ensureRunning()
        precondition(!model.isReady && model.message.contains("development build"))
        print("PASS: foreign services and missing development helpers never launch or terminate unrelated processes")

        var late = good; late.delay = 0.3
        SpotifyMockProtocol.server.configure([late])
        let pending = Task { await model.ensureRunning() }
        try await Task.sleep(for: .milliseconds(30))
        model.stopOwned()
        await pending.value
        precondition(!model.isReady && !model.isBusy)
        print("PASS: shutdown invalidates late engine responses")

        if let path = ProcessInfo.processInfo.environment["MOCHI_ENGINE_TEST_HELPER"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mochi-engine-check-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let packaged = MochiEngineModel(secrets: EngineMemorySecrets(), helper: URL(fileURLWithPath: path), dataDirectory: directory, port: 18764)
            await packaged.ensureRunning()
            precondition(packaged.isReady && !packaged.isExternal, packaged.message)
            precondition(!packaged.discoveryConfigured && packaged.semanticModelInstalled)
            packaged.stopOwned()
            try await Task.sleep(for: .seconds(2))
            do { _ = try await packaged.probe(); fatalError("Owned engine survived shutdown") }
            catch { }
            print("PASS: real bundled child starts, reports model/configuration and exits with its owning controller")
        }
    }
}
