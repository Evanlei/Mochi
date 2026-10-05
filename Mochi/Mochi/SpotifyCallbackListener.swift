import Foundation
import Network

@MainActor
final class SpotifyCallbackListener {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var timeoutTask: Task<Void, Never>?
    private var acceptingCallback = true
    private var openedBrowser = false

    /// Open the browser only after the port is actually ready to accept its redirect.
    func receiveCode(
        expectedState: String,
        timeout: TimeInterval = 180,
        onReady: @escaping @MainActor () throws -> Void
    ) async throws -> String {
        guard continuation == nil else { throw SpotifyAuthError.authorizationFailed }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                acceptingCallback = true
                openedBrowser = false
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: 8888)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        Task { @MainActor [weak self] in
                            guard let self, self.continuation != nil else { return }
                            switch state {
                            case .ready:
                                guard !self.openedBrowser else { return }
                                self.openedBrowser = true
                                do { try onReady() } catch { self.finish(.failure(error)) }
                            case .failed:
                                self.finish(.failure(SpotifyAuthError.callbackUnavailable))
                            default: break
                            }
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        Task { @MainActor [weak self] in
                            guard let self, self.continuation != nil,
                                  self.connections.count < 8 else { connection.cancel(); return }
                            self.connections[ObjectIdentifier(connection)] = connection
                            connection.start(queue: .main)
                            self.read(connection, buffer: Data(), expectedState: expectedState)
                        }
                    }
                    listener.start(queue: .main)
                    timeoutTask = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                        self?.finish(.failure(SpotifyAuthError.timedOut))
                    }
                } catch {
                    finish(.failure(SpotifyAuthError.callbackUnavailable))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func read(_ connection: NWConnection, buffer: Data, expectedState: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.continuation != nil else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                guard buffer.count <= 16_384 else {
                    self.respond(connection, status: "431 Request Header Fields Too Large", message: "Request too large.")
                    return
                }
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    guard self.acceptingCallback, let request = String(data: buffer, encoding: .utf8) else {
                        self.respond(connection, status: "400 Bad Request", message: "Invalid callback.")
                        return
                    }
                    do {
                        let code = try SpotifyCallback.authorizationCode(from: request, expectedState: expectedState)
                        self.acceptingCallback = false
                        self.respond(connection, status: "200 OK", message: "Spotify answered Mochi. Return to Mochi to check the connection.", result: .success(code))
                    } catch SpotifyAuthError.accessDenied {
                        self.acceptingCallback = false
                        self.respond(connection, status: "200 OK", message: "Spotify access was declined. You can close this tab.", result: .failure(SpotifyAuthError.accessDenied))
                    } catch SpotifyAuthError.authorizationFailed {
                        self.acceptingCallback = false
                        self.respond(connection, status: "400 Bad Request", message: "Spotify could not authorize this request. Return to Mochi.", result: .failure(SpotifyAuthError.authorizationFailed))
                    } catch {
                        // A favicon request or unrelated/forged callback must not consume the login.
                        self.respond(connection, status: "400 Bad Request", message: "This is not a valid callback for the current Mochi login.")
                    }
                } else if complete || error != nil {
                    self.close(connection)
                } else {
                    self.read(connection, buffer: buffer, expectedState: expectedState)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, message: String, result: Result<String, Error>? = nil) {
        let body = Data(message.utf8)
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.close(connection)
                if let result { self?.finish(result) }
            }
        })
    }

    private func close(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        continuation.resume(with: result)
    }
}
