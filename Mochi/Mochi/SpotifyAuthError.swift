import Foundation

enum SpotifyAuthError: LocalizedError {
    case invalidCallback
    case stateMismatch
    case accessDenied
    case authorizationFailed
    case callbackUnavailable
    case timedOut
    case browserUnavailable
    case invalidTokenResponse
    case tokenRequestFailed(Int)
    case reconnectRequired
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCallback: "The Spotify callback was malformed."
        case .stateMismatch: "This callback does not belong to the current login attempt."
        case .accessDenied: "Spotify access was declined. You can connect again whenever you like."
        case .authorizationFailed: "Spotify could not authorize Mochi. Please try connecting again."
        case .callbackUnavailable: "Mochi could not listen on port 8888. Close another running copy of Mochi or another app using that port, then retry."
        case .timedOut: "Spotify login timed out. Please connect again."
        case .browserUnavailable: "Mochi could not open your browser."
        case .invalidTokenResponse: "Spotify returned an unexpected token response."
        case .tokenRequestFailed(let status): "Spotify's token request failed (HTTP \(status)). Please try again."
        case .reconnectRequired: "Your Spotify connection has expired or was revoked. Please connect again."
        case .keychain(let status): "Mochi could not access its saved Spotify connection (Keychain error \(status))."
        }
    }
}
