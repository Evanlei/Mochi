import Foundation
import CryptoKit

// MARK: - App configuration

enum SpotifyConfiguration {
    nonisolated static let clientID = "eef25c48db8b4a66b83ff6f83b757c6c"
    nonisolated static let redirectURL = "http://127.0.0.1:8888/callback"
    nonisolated static let scopes = [
        "user-read-playback-state",
        "user-modify-playback-state"
    ]
}

// MARK: - Prepare a login attempt

struct SpotifyLoginAttempt {
    let verifier: String
    let state: String
    let authorizationURL: URL

    static func prepare() -> SpotifyLoginAttempt? {
        let verifier = SpotifyPKCE.makeVerifier()
        let challenge = SpotifyPKCE.makeChallenge(from: verifier)
        let state = SpotifyPKCE.makeVerifier()

        guard let url = SpotifyAuthorization.makeURL(
            challenge: challenge,
            state: state
        ) else {
            return nil
        }

        return SpotifyLoginAttempt(
            verifier: verifier,
            state: state,
            authorizationURL: url
        )
    }
}

// MARK: - Build the browser authorization URL

enum SpotifyAuthorization {
    static func makeURL(challenge: String, state: String) -> URL? {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")

        components?.queryItems = [
            URLQueryItem(name: "client_id", value: SpotifyConfiguration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: SpotifyConfiguration.redirectURL),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: SpotifyConfiguration.scopes.joined(separator: " "))
        ]

        return components?.url
    }
}

// MARK: - Generate the PKCE verifier and challenge

enum SpotifyPKCE {
    static func makeVerifier() -> String {
        let alphabet = Array(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        var generator = SystemRandomNumberGenerator()
        var verifier = ""

        for _ in 0..<64 {
            let index = Int.random(in: 0..<alphabet.count, using: &generator)
            verifier.append(alphabet[index])
        }

        return verifier
    }

    static func makeChallenge(from verifier: String) -> String {
        let bytes = Data(verifier.utf8)
        let digest = SHA256.hash(data: bytes)
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
