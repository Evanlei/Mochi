import Foundation

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
