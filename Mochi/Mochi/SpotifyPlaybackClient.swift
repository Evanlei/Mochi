import Foundation

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
