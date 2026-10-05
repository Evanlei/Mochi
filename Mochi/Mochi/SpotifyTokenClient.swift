import Foundation

@MainActor
final class SpotifyTokenClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration)
    }

    func exchange(code: String, verifier: String) async throws -> SpotifyTokens {
        try await request([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": SpotifyConfiguration.redirectURL,
            "client_id": SpotifyConfiguration.clientID,
            "code_verifier": verifier
        ], previous: nil)
    }

    func refresh(_ tokens: SpotifyTokens) async throws -> SpotifyTokens {
        try await request([
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": SpotifyConfiguration.clientID
        ], previous: tokens)
    }

    private func request(_ fields: [String: String], previous: SpotifyTokens?) async throws -> SpotifyTokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields)
        let (data, response) = try await session.data(for: request, delegate: NoTokenRedirects())
        guard let response = response as? HTTPURLResponse else {
            throw SpotifyAuthError.invalidTokenResponse
        }
        guard response.statusCode == 200 else {
            if response.statusCode == 400,
               let error = try? JSONDecoder().decode(TokenError.self, from: data),
               error.error == "invalid_grant" {
                throw SpotifyAuthError.reconnectRequired
            }
            // Never include Spotify's raw response in logs or UI: it may contain credentials.
            throw SpotifyAuthError.tokenRequestFailed(response.statusCode)
        }
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data),
              response.tokenType.lowercased() == "bearer", !response.accessToken.isEmpty,
              response.expiresIn > 0,
              let refreshToken = response.refreshToken ?? previous?.refreshToken,
              !refreshToken.isEmpty,
              let scope = response.scope ?? previous?.scope,
              Set(SpotifyConfiguration.scopes).isSubset(of: Set(scope.split(separator: " ").map(String.init))) else {
            throw SpotifyAuthError.invalidTokenResponse
        }
        return SpotifyTokens(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            scope: scope
        )
    }

    static func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed)!
                .replacingOccurrences(of: "%20", with: "+")
        }
        return Data(fields.sorted { $0.key < $1.key }
            .map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&").utf8)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let tokenType: String
        let expiresIn: Int
        let refreshToken: String?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
        }
    }

    private struct TokenError: Decodable { let error: String }
}

/// Never forward a token request (and its verifier/refresh token) to a redirected URL.
private final class NoTokenRedirects: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
