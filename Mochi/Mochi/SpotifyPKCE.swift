import Foundation
import CryptoKit

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
