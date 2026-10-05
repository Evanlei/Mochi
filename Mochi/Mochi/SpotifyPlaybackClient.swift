import Foundation

// MARK: - Send playback requests

@MainActor
final class SpotifyPlaybackClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: configuration)
    }

    func fetchState(accessToken: String) async throws -> SpotifyPlaybackState? {
        let (data, status) = try await request(path: "", method: "GET", accessToken: accessToken)
        if status == 204 { return nil }
        guard status == 200 else { throw SpotifyPlaybackError.unexpectedResponse }
        do {
            return try JSONDecoder().decode(SpotifyPlaybackState.self, from: data)
        } catch {
            throw SpotifyPlaybackError.unexpectedResponse
        }
    }

    func send(_ command: SpotifyPlaybackCommand, accessToken: String, deviceID: String?) async throws {
        _ = try await request(path: "/\(command.rawValue)", method: command.method,
                              accessToken: accessToken, deviceID: deviceID)
    }

    private func request(path: String, method: String, accessToken: String, deviceID: String? = nil) async throws -> (Data, Int) {
        var components = URLComponents(string: "https://api.spotify.com/v1/me/player\(path)")!
        if let deviceID { components.queryItems = [URLQueryItem(name: "device_id", value: deviceID)] }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request, delegate: NoPlaybackRedirects())
        guard let response = response as? HTTPURLResponse else {
            throw SpotifyPlaybackError.unexpectedResponse
        }
        switch response.statusCode {
        case 200..<300: return (data, response.statusCode)
        case 401: throw SpotifyPlaybackError.unauthorized
        case 403: throw SpotifyPlaybackError.forbidden
        case 404: throw SpotifyPlaybackError.noDevice
        case 429:
            let rawDelay = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            let delay = rawDelay.isFinite ? min(max(rawDelay, 1), 86_400) : 60
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let nested = body?["error"] as? [String: Any]
            let quotaExceeded = (body?["reason"] as? String ?? nested?["reason"] as? String) == "QUOTA_EXCEEDED"
            throw SpotifyPlaybackError.rateLimited(seconds: delay, quotaExceeded: quotaExceeded)
        default: throw SpotifyPlaybackError.requestFailed(response.statusCode)
        }
    }
}

enum SpotifyPlaybackCommand: String, Sendable {
    case play, pause, next, previous

    var method: String { self == .play || self == .pause ? "PUT" : "POST" }
}

enum SpotifyPlaybackError: LocalizedError {
    case unauthorized, forbidden, noDevice, unexpectedResponse
    case rateLimited(seconds: TimeInterval, quotaExceeded: Bool)
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Spotify rejected the connection. Disconnect and connect again."
        case .forbidden: "Spotify did not allow this action. Check Premium, app access, and device restrictions."
        case .noDevice: "No Spotify player is available. Open Spotify, start a song, then refresh."
        case .unexpectedResponse: "Spotify returned playback information Mochi could not read."
        case .rateLimited(let seconds, let quotaExceeded):
            quotaExceeded ? "Spotify's API quota is exhausted. Try again later." : "Spotify asked Mochi to wait \(Int(seconds.rounded(.up))) seconds before another request."
        case .requestFailed(let status): "Spotify playback request failed (HTTP \(status)). Try refreshing."
        }
    }
}

private final class NoPlaybackRedirects: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

// MARK: - Read playback information

struct SpotifyPlaybackState: Decodable, Sendable {
    let isPlaying: Bool
    let item: SpotifyPlaybackItem?
    let device: SpotifyPlaybackDevice?
    let actions: SpotifyPlaybackActions?
    let currentlyPlayingType: String?

    func permits(_ command: SpotifyPlaybackCommand) -> Bool {
        guard let device, device.isRestricted != true,
              let item, ["track", "episode"].contains(item.type) else { return false }
        if command == .play && isPlaying { return false }
        if command == .pause && !isPlaying { return false }
        return actions?.disallows(command) != true
    }

    enum CodingKeys: String, CodingKey {
        case isPlaying = "is_playing"
        case item
        case device
        case actions
        case currentlyPlayingType = "currently_playing_type"
    }
}

struct SpotifyPlaybackItem: Decodable, Sendable {
    let name: String
    let type: String
    let artists: [SpotifyPlaybackArtist]?
    let show: SpotifyPlaybackShow?

    var subtitle: String {
        if let artists, !artists.isEmpty { return artists.map(\.name).joined(separator: ", ") }
        return show?.name ?? (type == "episode" ? "Podcast episode" : "Spotify")
    }
}

struct SpotifyPlaybackArtist: Decodable, Sendable {
    let name: String
}

struct SpotifyPlaybackShow: Decodable, Sendable { let name: String }

struct SpotifyPlaybackDevice: Decodable, Sendable {
    let id: String?
    let name: String?
    let isRestricted: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name
        case isRestricted = "is_restricted"
    }
}

struct SpotifyPlaybackActions: Decodable, Sendable {
    private let restrictions: [String: Bool]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let nested = try container.decodeIfPresent([String: Bool].self, forKey: .disallows) {
            restrictions = nested
        } else {
            // Accept the flattened form shown in Spotify's reference schema too.
            var values: [String: Bool] = [:]
            for key in [Keys.pausing, .resuming, .skippingNext, .skippingPrevious] {
                values[key.rawValue] = try container.decodeIfPresent(Bool.self, forKey: key)
            }
            restrictions = values
        }
    }

    func disallows(_ command: SpotifyPlaybackCommand) -> Bool {
        let key: String
        switch command {
        case .play: key = "resuming"
        case .pause: key = "pausing"
        case .next: key = "skipping_next"
        case .previous: key = "skipping_prev"
        }
        return restrictions[key] == true
    }

    private enum Keys: String, CodingKey {
        case disallows, pausing, resuming
        case skippingNext = "skipping_next"
        case skippingPrevious = "skipping_prev"
    }
}
