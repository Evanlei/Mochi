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
    }
}
