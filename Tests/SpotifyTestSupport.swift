import Foundation

@MainActor
final class SpotifyMemoryStore: SpotifyTokenStoring {
    var tokens: SpotifyTokens?
    func load() throws -> SpotifyTokens? { tokens }
    func save(_ tokens: SpotifyTokens) throws { self.tokens = tokens }
    func delete() throws { tokens = nil }
}

struct SpotifyReply: Sendable {
    var status = 200
    var data = Data()
    var headers: [String: String] = [:]
    var delay: TimeInterval = 0
    var error: URLError.Code?
}

final class SpotifyMockServer: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [SpotifyReply] = []
    private var recorded: [URLRequest] = []
    func configure(_ replies: [SpotifyReply]) {
        lock.lock(); defer { lock.unlock() }
        self.replies = replies
        recorded = []
    }
    func respond(to request: URLRequest) -> SpotifyReply {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        precondition(!replies.isEmpty, "Unexpected extra network request")
        return replies.removeFirst()
    }
    func requests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

final class SpotifyMockProtocol: URLProtocol, @unchecked Sendable {
    static let server = SpotifyMockServer()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.server.respond(to: request)
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return }
            if let error = reply.error {
                client?.urlProtocol(self, didFailWithError: URLError(error))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                           httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
    }
}

func spotifyRequestBody(_ request: URLRequest) -> Data? {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}
