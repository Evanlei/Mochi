import Foundation

struct MochiListeningRequest: Encodable {
    let prompt: String
}

struct MochiListeningResponse: Decodable {
    let receivedPrompt: String
    let intent: MochiListeningIntent?
    let clarification: String?
    let selection: MochiSongSelection?

    enum CodingKeys: String, CodingKey {
        case receivedPrompt = "received_prompt"
        case intent, clarification, selection
    }
}

struct MochiListeningIntent: Decodable {
    enum Energy: String, Decodable { case low, high }
    let vocals: Bool?
    let energy: Energy?
    let bpmMin: Double?
    let bpmMax: Double?

    enum CodingKeys: String, CodingKey {
        case vocals, energy
        case bpmMin = "bpm_min", bpmMax = "bpm_max"
    }

    var summary: String {
        var parts: [String] = []
        if let energy { parts.append(energy == .low ? "Low energy" : "High energy") }
        if let vocals { parts.append(vocals ? "With vocals" : "Instrumental") }
        if let lower = bpmMin, let upper = bpmMax {
            let tempo = lower == upper ? String(format: "%g", lower) : "\(String(format: "%g", lower))–\(String(format: "%g", upper))"
            parts.append("\(tempo) BPM")
        }
        return parts.joined(separator: " · ")
    }
}

struct MochiSongSelection: Decodable {
    enum CatalogKind: String, Decodable { case fictionalSample = "fictional_sample", lastfmLive = "lastfm_live" }
    enum Method: String, Decodable { case semantic, lexical, none }
    let catalogKind: CatalogKind
    let method: Method
    let tracks: [MochiSelectedTrack]
    let message: String?
    let requestID: String?
    let warnings: [String]?

    enum CodingKeys: String, CodingKey {
        case catalogKind = "catalog_kind"
        case method, tracks, message
        case requestID = "request_id", warnings
    }
}

struct MochiSelectedTrack: Decodable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let bpm: Double?
    let vocals: Bool?
    let energy: MochiListeningIntent.Energy?
    let description: String
    let score: Double
    let source: String?
    let sourceURL: String?
    let isrc: String?
    let durationMS: Int?
    let featureSpotifyID: String?

    enum CodingKeys: String, CodingKey {
        case id, title, artist, bpm, vocals, energy, description, score, source, isrc
        case sourceURL = "source_url", durationMS = "duration_ms", featureSpotifyID = "feature_spotify_id"
    }

    var lastfmURL: URL? {
        guard let sourceURL, let url = URL(string: sourceURL), url.scheme == "https",
              ["www.last.fm", "last.fm"].contains(url.host ?? "") else { return nil }
        return url
    }

    var details: String {
        var parts: [String] = []
        if let energy { parts.append(energy == .low ? "Low energy" : "High energy") }
        if let vocals { parts.append(vocals ? "Vocals" : "Instrumental") }
        if let bpm { parts.append("\(String(format: "%g", bpm)) BPM") }
        return parts.isEmpty ? "Musical features unavailable" : parts.joined(separator: " · ")
    }
}

struct MochiBackendClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: configuration,
            delegate: MochiBackendRedirectDelegate(), delegateQueue: nil)
    }

    func send(prompt: String) async throws -> MochiListeningResponse {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= 500 else {
            throw MochiBackendError.invalidPrompt
        }
        guard let url = URL(
            string: "http://127.0.0.1:8000/listening-request"
        ) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            MochiListeningRequest(prompt: text)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw MochiBackendError.timeout }
            if [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet].contains(error.code) {
                throw MochiBackendError.unavailable
            }
            throw MochiBackendError.connectionFailed
        }
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MochiBackendError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 422 { throw MochiBackendError.invalidPrompt }
            throw MochiBackendError.server(httpResponse.statusCode)
        }
        guard let result = try? JSONDecoder().decode(MochiListeningResponse.self, from: data),
              result.receivedPrompt == text else { throw MochiBackendError.invalidResponse }
        if let tracks = result.selection?.tracks {
            guard tracks.count <= 5, Set(tracks.map(\.id)).count == tracks.count,
                  tracks.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty && !$0.artist.isEmpty && $0.score.isFinite &&
                      ($0.bpm.map { $0.isFinite && (20...400).contains($0) } ?? true) }) else {
                throw MochiBackendError.invalidResponse
            }
        }
        if let selection = result.selection, selection.catalogKind == .lastfmLive, !selection.tracks.isEmpty {
            guard let requestID = selection.requestID, UUID(uuidString: requestID) != nil,
                  selection.tracks.allSatisfy({ $0.source == "lastfm" && $0.id.range(of: "^lastfm-[0-9a-f]{64}$", options: .regularExpression) != nil &&
                      ($0.featureSpotifyID.map { $0.range(of: "^[A-Za-z0-9]{22}$", options: .regularExpression) != nil } ?? true) }) else {
                throw MochiBackendError.invalidResponse
            }
        }
        return result
    }

    enum FeedbackEvent: String { case like, dislike, select, replay }

    func feedback(requestID: String, trackID: String, event: FeedbackEvent, eventID: UUID = UUID()) async throws {
        guard UUID(uuidString: requestID) != nil else { throw MochiBackendError.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject: ["event_id": eventID.uuidString, "request_id": requestID,
            "track_id": trackID, "event": event.rawValue])
        try await write(path: "feedback", method: "POST", body: data)
    }

    func clearTaste() async throws { try await write(path: "taste", method: "DELETE", body: nil) }

    private func write(path: String, method: String, body: Data?) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8000/\(path)")!)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 10
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw MochiBackendError.invalidResponse }
        guard response.statusCode == 200 else { throw MochiBackendError.server(response.statusCode) }
        guard (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["status"] == "ok" else {
            throw MochiBackendError.invalidResponse
        }
    }
}

enum MochiBackendError: LocalizedError {
    case invalidPrompt, unavailable, timeout, connectionFailed, invalidResponse
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPrompt: return "Use 1–500 characters of text."
        case .unavailable: return "Can't reach the backend. Start it, then try again."
        case .timeout: return "The backend took too long. Try again."
        case .connectionFailed: return "Couldn't contact the backend. Try again."
        case .invalidResponse: return "The backend sent an unexpected reply. Try again."
        case .server(let status): return "The backend couldn't accept this request (\(status)). Try again."
        }
    }
}

// Keep listening text on the local backend rather than following a redirect elsewhere.
private final class MochiBackendRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
