import Foundation

struct MochiListeningRequest: Encodable {
    let prompt: String
}

struct MochiListeningResponse: Decodable {
    let receivedPrompt: String
    let intent: MochiListeningIntent?
    let clarification: String?

    enum CodingKeys: String, CodingKey {
        case receivedPrompt = "received_prompt"
        case intent, clarification
    }
}

struct MochiListeningIntent: Decodable {
    enum Energy: String, Decodable { case low, high }
    let vocals: Bool?
    let energy: Energy?

    var summary: String {
        var parts: [String] = []
        if let energy { parts.append(energy == .low ? "Low energy" : "High energy") }
        if let vocals { parts.append(vocals ? "With vocals" : "Instrumental") }
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
