import Foundation

enum SpotifyCallback {
    /// Read only the request line; the listener waits for all HTTP headers first.
    static func authorizationCode(from request: String, expectedState: String) throws -> String {
        guard let line = request.components(separatedBy: "\r\n").first else {
            throw SpotifyAuthError.invalidCallback
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET",
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0",
              parts[1].hasPrefix("/"),
              let url = URLComponents(string: "http://127.0.0.1:8888\(parts[1])"),
              url.path == "/callback", let items = url.queryItems else {
            throw SpotifyAuthError.invalidCallback
        }

        // Reject ambiguous duplicate parameters instead of silently choosing one.
        func singleValue(_ name: String) throws -> String? {
            let matches = items.filter { $0.name == name }
            guard matches.count <= 1 else { throw SpotifyAuthError.invalidCallback }
            return matches.first?.value
        }
        guard let state = try singleValue("state"), !expectedState.isEmpty,
              state == expectedState else { throw SpotifyAuthError.stateMismatch }

        let code = try singleValue("code")
        let error = try singleValue("error")
        guard !(code != nil && error != nil) else { throw SpotifyAuthError.invalidCallback }
        if let error {
            throw error == "access_denied" ? SpotifyAuthError.accessDenied : SpotifyAuthError.authorizationFailed
        }
        guard let code, !code.isEmpty else { throw SpotifyAuthError.invalidCallback }
        return code
    }
}
