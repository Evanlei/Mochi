import Foundation

@main
struct AuthChecks {
    @MainActor
    static func main() async throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        precondition(SpotifyPKCE.makeChallenge(from: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let generated = (0..<100).map { _ in SpotifyPKCE.makeVerifier() }
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        precondition(generated.allSatisfy { $0.count == 64 && Set($0).isSubset(of: alphabet) })
        precondition(Set(generated).count == generated.count)

        let attempt = SpotifyLoginAttempt.prepare()!
        let items = URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        precondition(query["code_challenge"] == SpotifyPKCE.makeChallenge(from: attempt.verifier))
        precondition(query["state"] == attempt.state)
        precondition(query["code_verifier"] == nil)
        precondition(query["redirect_uri"] == SpotifyConfiguration.redirectURL)
        precondition(query["scope"] == SpotifyConfiguration.scopes.joined(separator: " "))

        func request(_ target: String, method: String = "GET") -> String {
            "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1:8888\r\n\r\n"
        }
        let code = try SpotifyCallback.authorizationCode(from: request("/callback?code=a%2Bb&state=expected"), expectedState: "expected")
        precondition(code == "a+b")
        for invalid in [
            "/callback?code=x&state=wrong", "/callback?code=x", "/favicon.ico",
            "/callback?code=x&state=expected&state=expected",
            "/callback?code=x&code=y&state=expected", "/callback?code=&state=expected",
            "/callback?code=x&error=access_denied&state=expected"
        ] {
            do {
                _ = try SpotifyCallback.authorizationCode(from: request(invalid), expectedState: "expected")
                fatalError("Accepted invalid callback")
            } catch is SpotifyAuthError { }
        }
        do {
            _ = try SpotifyCallback.authorizationCode(from: request("/callback?error=access_denied&state=expected"), expectedState: "expected")
            fatalError("Accepted denied authorization")
        } catch SpotifyAuthError.accessDenied { }
        do {
            _ = try SpotifyCallback.authorizationCode(from: request("/callback?code=x&state=expected", method: "POST"), expectedState: "expected")
            fatalError("Accepted non-GET callback")
        } catch SpotifyAuthError.invalidCallback { }
        print("PASS: PKCE reference vector, verifier generation, URL parameters, callback validation")

        let listener = SpotifyCallbackListener()
        var browserTask: Task<Void, Error>?
        let receivedCode = try await listener.receiveCode(expectedState: "loopback-test", timeout: 5) {
            browserTask = Task {
                let badURL = URL(string: "http://127.0.0.1:8888/callback?code=bad&state=wrong")!
                let (_, badResponse) = try await URLSession.shared.data(from: badURL)
                precondition((badResponse as? HTTPURLResponse)?.statusCode == 400)
                let goodURL = URL(string: "http://127.0.0.1:8888/callback?code=test-code&state=loopback-test")!
                let (body, goodResponse) = try await URLSession.shared.data(from: goodURL)
                precondition((goodResponse as? HTTPURLResponse)?.statusCode == 200)
                precondition(!String(decoding: body, as: UTF8.self).contains("test-code"))
            }
        }
        try await browserTask?.value
        precondition(receivedCode == "test-code")

        do {
            _ = try await SpotifyCallbackListener().receiveCode(expectedState: "timeout", timeout: 0.05) { }
            fatalError("Listener did not time out")
        } catch SpotifyAuthError.timedOut { }

        let cancelledListener = SpotifyCallbackListener()
        do {
            _ = try await cancelledListener.receiveCode(expectedState: "cancel") {
                cancelledListener.cancel()
            }
            fatalError("Listener did not cancel")
        } catch is CancellationError { }
        print("PASS: real loopback callback, forged callback rejection, timeout and cancellation")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockTokenProtocol.self]
        let client = SpotifyTokenClient(session: URLSession(configuration: configuration))
        let scope = SpotifyConfiguration.scopes.joined(separator: " ")
        func reply(_ values: [String: Any], status: Int = 200) throws {
            MockTokenProtocol.server.set(status: status, data: try JSONSerialization.data(withJSONObject: values))
        }
        try reply(["access_token": "fake-access", "refresh_token": "fake-refresh",
                   "token_type": "Bearer", "expires_in": 3600, "scope": scope])
        let tokens = try await client.exchange(code: "code+&/=", verifier: "verifier+&/=")
        let exchange = MockTokenProtocol.server.lastRequest()!
        precondition(exchange.url?.absoluteString == "https://accounts.spotify.com/api/token")
        precondition(exchange.httpMethod == "POST")
        precondition(exchange.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let exchangeFields = formFields(exchange)
        precondition(exchangeFields["code"] == "code+&/=")
        precondition(exchangeFields["code_verifier"] == "verifier+&/=")
        precondition(exchangeFields["grant_type"] == "authorization_code")
        precondition(exchangeFields["redirect_uri"] == SpotifyConfiguration.redirectURL)
        precondition(exchangeFields["client_secret"] == nil)
        precondition(tokens.isUsable())

        try reply(["access_token": "new-access", "token_type": "Bearer", "expires_in": 3600])
        let refreshed = try await client.refresh(tokens)
        precondition(refreshed.refreshToken == tokens.refreshToken)
        precondition(refreshed.scope == tokens.scope)
        precondition(formFields(MockTokenProtocol.server.lastRequest()!)["grant_type"] == "refresh_token")
        precondition(formFields(MockTokenProtocol.server.lastRequest()!)["code_verifier"] == nil)
        try reply(["access_token": "new-access", "refresh_token": "rotated-refresh", "token_type": "Bearer", "expires_in": 3600])
        let rotated = try await client.refresh(tokens)
        precondition(rotated.refreshToken == "rotated-refresh")
        try reply(["error": "invalid_grant"], status: 400)
        do {
            _ = try await client.refresh(tokens)
            fatalError("Accepted invalid refresh token")
        } catch SpotifyAuthError.reconnectRequired { }
        try reply(["access_token": "bad", "refresh_token": "fake", "token_type": "Bearer", "expires_in": -1, "scope": scope])
        do {
            _ = try await client.exchange(code: "fake", verifier: "fake")
            fatalError("Accepted malformed tokens")
        } catch SpotifyAuthError.invalidTokenResponse { }
        precondition(!SpotifyTokens(accessToken: "fake", refreshToken: "fake", expiresAt: Date(), scope: scope).isUsable())
        print("PASS: HTTPS token request fields, form escaping, token decoding, refresh rotation, expiration errors")
    }

    static func formFields(_ request: URLRequest) -> [String: String] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var body = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            data = body
        } else { fatalError("Missing form body") }
        let query = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
        let items = URLComponents(string: "https://example.test/?\(query)")!.queryItems!
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
}

final class MockTokenProtocol: URLProtocol, @unchecked Sendable {
    static let server = MockTokenServer()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.server.respond(to: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class MockTokenServer: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 200
    private var data = Data()
    private var request: URLRequest?
    func set(status: Int, data: Data) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        self.data = data
    }
    func respond(to request: URLRequest) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        self.request = request
        return (status, data)
    }
    func lastRequest() -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return request
    }
}
