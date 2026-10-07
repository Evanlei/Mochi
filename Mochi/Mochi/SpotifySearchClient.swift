import Foundation

// MARK: - Catalog search (no recommendation model or automatic selection)

enum SpotifySearchKind: String, CaseIterable, Identifiable {
    case song = "Songs", artist = "Artists"
    var id: Self { self }
}

@MainActor
final class SpotifySearchClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: configuration)
    }

    func search(query: String, kind: SpotifySearchKind, accessToken: String) async throws -> [SpotifySearchTrack] {
        let text = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !text.isEmpty else { return [] }
        var url = URLComponents(string: "https://api.spotify.com/v1/search")!
        url.queryItems = [
            URLQueryItem(name: "q", value: kind == .artist ? "artist:\(text)" : text),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: "5")
        ]
        // The user's token supplies their Spotify market; no hardcoded country is needed.
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request, delegate: NoSearchRedirects())
        guard let response = response as? HTTPURLResponse else { throw SpotifySearchError.unexpectedResponse }
        switch response.statusCode {
        case 200: break
        case 401: throw SpotifySearchError.unauthorized
        case 403: throw SpotifySearchError.forbidden
        case 429:
            let rawDelay = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            let delay = rawDelay.isFinite ? min(max(rawDelay, 1), 86_400) : 60
            throw SpotifySearchError.rateLimited(delay)
        default: throw SpotifySearchError.requestFailed(response.statusCode)
        }
        do {
            let page = try JSONDecoder().decode(SearchResponse.self, from: data)
            var seen = Set<String>()
            return page.tracks.items.compactMap { $0 }.filter {
                $0.hasValidIdentity && seen.insert($0.uri).inserted
            }
        } catch { throw SpotifySearchError.unexpectedResponse }
    }

    private struct SearchResponse: Decodable {
        let tracks: Page
        struct Page: Decodable { let items: [SpotifySearchTrack?] }
    }
}

struct SpotifySearchTrack: Decodable, Identifiable, Sendable {
    let id: String
    let uri: String
    let name: String
    let type: String
    let artists: [Artist]
    let album: Album
    let isPlayable: Bool?
    let isLocal: Bool?
    let restrictions: Restrictions?

    var artistNames: String { artists.map(\.name).joined(separator: ", ") }
    var canPlay: Bool { hasValidIdentity && isPlayable != false && restrictions == nil }
    var spotifyURL: URL { URL(string: "https://open.spotify.com/track/\(id)")! }
    var artworkURL: URL? {
        guard let raw = album.images?.last?.url, let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }
    var hasValidIdentity: Bool {
        type == "track" && isLocal != true && id.count == 22 && uri == "spotify:track:\(id)"
            && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }

    struct Artist: Decodable, Sendable { let name: String }
    struct Album: Decodable, Sendable {
        let name: String
        let images: [Image]?
    }
    struct Image: Decodable, Sendable { let url: String }
    struct Restrictions: Decodable, Sendable { let reason: String? }

    enum CodingKeys: String, CodingKey {
        case id, uri, name, type, artists, album, restrictions
        case isPlayable = "is_playable", isLocal = "is_local"
    }
}

enum SpotifySearchError: LocalizedError {
    case unauthorized, forbidden, unexpectedResponse
    case rateLimited(TimeInterval), requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Spotify rejected the connection. Connect Spotify again from the menu bar."
        case .forbidden: "Spotify did not allow this search. Check your app access in the Spotify dashboard."
        case .unexpectedResponse: "Mochi could not read Spotify's search results. Try searching again."
        case .rateLimited(let seconds): "Spotify asked Mochi to wait \(Int(seconds.rounded(.up))) seconds before searching again."
        case .requestFailed(let status): "Spotify search failed (HTTP \(status)). Try again."
        }
    }
}

private final class NoSearchRedirects: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
