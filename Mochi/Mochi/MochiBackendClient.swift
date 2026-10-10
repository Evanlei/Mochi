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
    enum CatalogKind: String, Decodable { case fictionalSample = "fictional_sample" }
    enum Method: String, Decodable { case semantic, lexical, none }
    let catalogKind: CatalogKind
    let method: Method
    let tracks: [MochiSelectedTrack]
    let message: String?

    enum CodingKeys: String, CodingKey {
        case catalogKind = "catalog_kind"
        case method, tracks, message
    }
}

struct MochiSelectedTrack: Decodable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let bpm: Double?
    let vocals: Bool
    let energy: MochiListeningIntent.Energy
    let description: String
    let score: Double

    var details: String {
        var parts = [energy == .low ? "Low energy" : "High energy", vocals ? "Vocals" : "Instrumental"]
        if let bpm { parts.append("\(String(format: "%g", bpm)) BPM") }
        return parts.joined(separator: " · ")
    }
}

struct MochiBackendClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
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
        request.timeoutInterval = 10
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
        return result
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
