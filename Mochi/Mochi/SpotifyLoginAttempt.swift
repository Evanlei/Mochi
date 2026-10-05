import Foundation

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
