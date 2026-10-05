import Foundation

struct SpotifyTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scope: String

    // Refresh a little early instead of letting a token expire during an API request.
    func isUsable(at date: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(date) > 60
    }
}
