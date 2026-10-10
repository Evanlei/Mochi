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
        return try await search(url: url.url!, accessToken: accessToken)
    }

    private func search(url: URL, accessToken: String, timeout: TimeInterval = 15) async throws -> [SpotifySearchTrack] {
        var request = URLRequest(url: url)
        request.timeoutInterval = max(0.1, min(15, timeout))
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
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let nested = body?["error"] as? [String: Any]
            if (body?["reason"] as? String ?? nested?["reason"] as? String) == "QUOTA_EXCEEDED" {
                throw SpotifySearchError.quotaExceeded(delay)
            }
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

    /// Deterministic entity resolution only. Spotify payloads never reach the ML backend.
    func resolve(_ track: MochiSelectedTrack, accessToken: String, timeout: TimeInterval = 15) async throws -> SpotifySearchTrack? {
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        let query: String
        if let isrc = track.isrc, isrc.range(of: "^[A-Za-z]{2}[A-Za-z0-9]{3}[0-9]{7}$", options: .regularExpression) != nil {
            query = "isrc:\(isrc)"
        } else {
            let title = track.title.replacingOccurrences(of: "\"", with: " ")
            let artist = track.artist.replacingOccurrences(of: "\"", with: " ")
            query = "track:\"\(title)\" artist:\"\(artist)\""
        }
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: "track"), URLQueryItem(name: "limit", value: "10")]
        let candidates = try await search(url: components.url!, accessToken: accessToken, timeout: timeout)
        return SpotifyRecordingMatcher.match(track, candidates: candidates)
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
    let durationMS: Int?
    let externalIDs: ExternalIDs?

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
    struct ExternalIDs: Decodable, Sendable { let isrc: String? }

    enum CodingKeys: String, CodingKey {
        case id, uri, name, type, artists, album, restrictions
        case isPlayable = "is_playable", isLocal = "is_local"
        case durationMS = "duration_ms", externalIDs = "external_ids"
    }
}

enum SpotifyRecordingMatcher {
    static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func versions(_ title: String) -> Set<String> {
        let text = " " + normalized(title) + " "
        return Set(["live", "remix", "acoustic", "instrumental", "remaster", "remastered", "demo", "sped up", "slowed", "radio edit"]
            .filter { text.contains(" \($0) ") })
    }

    static func similarity(_ left: String, _ right: String) -> Double {
        let a = Array(normalized(left)), b = Array(normalized(right))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = Array(0...b.count)
        for (i, character) in a.enumerated() {
            var next = [i + 1]
            for (j, other) in b.enumerated() { next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (character == other ? 0 : 1))) }
            row = next
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }

    static func match(_ source: MochiSelectedTrack, candidates: [SpotifySearchTrack]) -> SpotifySearchTrack? {
        let eligible = candidates.filter { candidate in
            guard candidate.canPlay, versions(source.title) == versions(candidate.name),
                  similarity(source.title, candidate.name) >= 0.96,
                  candidate.artists.contains(where: { similarity(source.artist, $0.name) >= 0.96 }) else { return false }
            if let duration = source.durationMS {
                guard let actual = candidate.durationMS, abs(actual - duration) <= 2000 else { return false }
            }
            if let isrc = source.isrc {
                guard candidate.externalIDs?.isrc?.uppercased() == isrc.uppercased() else { return false }
            }
            if let featureID = source.featureSpotifyID, source.isrc == nil, candidate.id != featureID { return false }
            return true
        }
        if eligible.count <= 1 { return eligible.first }
        let isrcs = Set(eligible.compactMap { $0.externalIDs?.isrc?.uppercased() })
        guard isrcs.count == 1, eligible.allSatisfy({ $0.externalIDs?.isrc != nil }) else { return nil }
        return eligible.sorted { $0.id < $1.id }.first
    }
}

enum SpotifySearchError: LocalizedError {
    case unauthorized, forbidden, unexpectedResponse
    case rateLimited(TimeInterval), quotaExceeded(TimeInterval), requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Spotify rejected the connection. Connect Spotify again from the menu bar."
        case .forbidden: "Spotify did not allow this search. Check your app access in the Spotify dashboard."
        case .unexpectedResponse: "Mochi could not read Spotify's search results. Try searching again."
        case .rateLimited(let seconds): "Spotify asked Mochi to wait \(Int(seconds.rounded(.up))) seconds before searching again."
        case .quotaExceeded: "Spotify's API quota is exhausted. Try again later."
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
