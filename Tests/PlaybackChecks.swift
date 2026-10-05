import Foundation

@main
struct PlaybackChecks {
    @MainActor
    static func main() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PlaybackMockProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let client = SpotifyPlaybackClient(session: session)

        func playback(_ name: String = "Test Song", playing: Bool = true, restricted: Bool = false,
                      actions: [String: Any] = [:]) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "is_playing": playing,
                "currently_playing_type": "track",
                "device": ["id": "device & test", "name": "Test Mac", "is_restricted": restricted],
                "item": ["name": name, "type": "track", "artists": [["name": "Artist One"], ["name": "Artist Two"]]],
                "actions": actions
            ])
        }
        func fixture(_ name: String = "Test Song", playing: Bool = true) throws -> PlaybackReply {
            PlaybackReply(data: try playback(name, playing: playing))
        }
        let trackData = try playback()
        PlaybackMockProtocol.server.configure([PlaybackReply(data: trackData)])
        let state = try await client.fetchState(accessToken: "fake-access")!
        precondition(state.item?.name == "Test Song" && state.isPlaying)
        precondition(state.item?.subtitle == "Artist One, Artist Two")
        precondition(state.permits(.pause) && !state.permits(.play))
        let fetchRequest = PlaybackMockProtocol.server.requests().first!
        precondition(fetchRequest.url?.absoluteString == "https://api.spotify.com/v1/me/player")
        precondition(fetchRequest.httpMethod == "GET")
        precondition(fetchRequest.value(forHTTPHeaderField: "Authorization") == "Bearer fake-access")

        PlaybackMockProtocol.server.configure([PlaybackReply(status: 204)])
        let empty = try await client.fetchState(accessToken: "fake-access")
        precondition(empty == nil)
        let noItem = try JSONDecoder().decode(SpotifyPlaybackState.self, from: Data(#"{"is_playing":false,"item":null}"#.utf8))
        precondition(noItem.item == nil && !noItem.permits(.play))
        let episode = try JSONDecoder().decode(SpotifyPlaybackState.self, from: Data(#"{"is_playing":true,"item":{"name":"Episode","type":"episode","show":{"name":"Test Podcast"}}}"#.utf8))
        precondition(episode.item?.subtitle == "Test Podcast")
        let restricted = try JSONDecoder().decode(SpotifyPlaybackState.self, from: playback(restricted: true))
        precondition(!restricted.permits(.pause) && !restricted.permits(.next))
        for restrictions in [["disallows": ["skipping_next": true]], ["skipping_next": true]] as [[String: Any]] {
            let restricted = try JSONDecoder().decode(SpotifyPlaybackState.self, from: playback(actions: restrictions))
            precondition(!restricted.permits(.next) && restricted.permits(.pause))
        }
        print("PASS: playback request, track/episode/null decoding, restricted devices and actions")

        for (command, method) in [(SpotifyPlaybackCommand.play, "PUT"), (.pause, "PUT"), (.next, "POST"), (.previous, "POST")] {
            PlaybackMockProtocol.server.configure([PlaybackReply(status: 204)])
            try await client.send(command, accessToken: "fake-access", deviceID: "device & test")
            let request = PlaybackMockProtocol.server.requests().first!
            precondition(request.httpMethod == method)
            precondition(request.url?.path == "/v1/me/player/\(command.rawValue)")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.first?.name == "device_id" && query.first?.value == "device & test")
            precondition(request.httpBody == nil)
        }
        for (status, expected) in [(401, "unauthorized"), (403, "forbidden"), (404, "noDevice"), (500, "failure")] {
            PlaybackMockProtocol.server.configure([PlaybackReply(status: status)])
            do {
                _ = try await client.fetchState(accessToken: "fake-access")
                fatalError("Accepted failed response")
            } catch let error as SpotifyPlaybackError {
                switch (error, expected) {
                case (.unauthorized, "unauthorized"), (.forbidden, "forbidden"), (.noDevice, "noDevice"), (.requestFailed(500), "failure"): break
                default: fatalError("Wrong playback error")
                }
            }
        }
        PlaybackMockProtocol.server.configure([PlaybackReply(status: 429, data: Data(#"{"reason":"QUOTA_EXCEEDED"}"#.utf8), headers: ["Retry-After": "12"])])
        do {
            _ = try await client.fetchState(accessToken: "fake-access")
            fatalError("Ignored rate limit")
        } catch SpotifyPlaybackError.rateLimited(let seconds, let quota) {
            precondition(seconds == 12 && quota)
        }
        PlaybackMockProtocol.server.configure([PlaybackReply(data: Data("not-json".utf8))])
        do {
            _ = try await client.fetchState(accessToken: "fake-access")
            fatalError("Accepted malformed JSON")
        } catch SpotifyPlaybackError.unexpectedResponse { }
        print("PASS: play/pause/next/previous HTTP methods, device targeting, failures and rate limits")

        let store = PlaybackMemoryStore()
        store.tokens = SpotifyTokens(accessToken: "fake-access", refreshToken: "fake-refresh",
                                    expiresAt: Date().addingTimeInterval(3600), scope: SpotifyConfiguration.scopes.joined(separator: " "))
        let auth = SpotifyAuthModel(tokenClient: SpotifyTokenClient(session: session), tokenStore: store)
        await auth.restore()
        precondition(auth.isConnected)
        let model = SpotifyPlaybackModel(client: client)
        PlaybackMockProtocol.server.configure([try fixture()])
        await model.refresh(using: auth)
        precondition(model.state?.item?.name == "Test Song" && !model.isBusy)

        for (command, playing, name) in [
            (SpotifyPlaybackCommand.pause, false, "Test Song"),
            (.play, true, "Test Song"), (.next, true, "Next Song"), (.previous, true, "Previous Song")
        ] {
            PlaybackMockProtocol.server.configure([PlaybackReply(status: 204), try fixture(name, playing: playing)])
            await model.perform(command, using: auth)
            let requests = PlaybackMockProtocol.server.requests()
            precondition(requests.count == 2 && requests[0].url?.path == "/v1/me/player/\(command.rawValue)")
            precondition(requests[1].httpMethod == "GET")
            precondition(model.state?.isPlaying == playing && model.state?.item?.name == name && model.errorMessage == nil)
        }

        PlaybackMockProtocol.server.configure([PlaybackReply(status: 204), try fixture(playing: false)])
        let firstControl = Task { await model.perform(.pause, using: auth) }
        await Task.yield()
        await model.perform(.next, using: auth)
        await firstControl.value
        precondition(PlaybackMockProtocol.server.requests().count == 2)
        print("PASS: playback model refreshes after controls and serializes button actions")

        let refreshData = try JSONSerialization.data(withJSONObject: ["access_token": "refreshed-access", "token_type": "Bearer", "expires_in": 3600])
        PlaybackMockProtocol.server.configure([PlaybackReply(status: 401), PlaybackReply(data: refreshData), try fixture()])
        await model.refresh(using: auth)
        let retryRequests = PlaybackMockProtocol.server.requests()
        precondition(retryRequests.count == 3 && retryRequests[1].url?.path == "/api/token")
        precondition(retryRequests[2].value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-access")
        precondition(model.errorMessage == nil)

        PlaybackMockProtocol.server.configure([PlaybackReply(status: 401), PlaybackReply(data: refreshData), PlaybackReply(status: 401)])
        await model.refresh(using: auth)
        precondition(PlaybackMockProtocol.server.requests().count == 3 && model.errorMessage != nil && model.isStale)
        precondition(!model.canPerform(.pause))

        let limitedModel = SpotifyPlaybackModel(client: client)
        PlaybackMockProtocol.server.configure([PlaybackReply(status: 429, headers: ["Retry-After": "60"])])
        await limitedModel.refresh(using: auth)
        await limitedModel.refresh(using: auth)
        precondition(PlaybackMockProtocol.server.requests().count == 1 && limitedModel.errorMessage != nil)

        PlaybackMockProtocol.server.configure([PlaybackReply(status: 204)])
        await model.refresh(using: auth)
        precondition(model.state == nil && model.lastUpdatedAt != nil && !model.canPerform(.play))

        PlaybackMockProtocol.server.configure([PlaybackReply(data: trackData, delay: 0.15)])
        let lateRefresh = Task { await model.refresh(using: auth) }
        try await Task.sleep(for: .milliseconds(20))
        auth.disconnect()
        model.reset()
        await lateRefresh.value
        precondition(model.state == nil && !model.isBusy && model.errorMessage == nil)
        print("PASS: one-time 401 refresh, cooldown, no-device state and stale response after disconnect")
    }
}

@MainActor
final class PlaybackMemoryStore: SpotifyTokenStoring {
    var tokens: SpotifyTokens?
    func load() throws -> SpotifyTokens? { tokens }
    func save(_ tokens: SpotifyTokens) throws { self.tokens = tokens }
    func delete() throws { tokens = nil }
}

struct PlaybackReply: Sendable {
    var status = 200
    var data = Data()
    var headers: [String: String] = [:]
    var delay: TimeInterval = 0
}

final class PlaybackMockServer: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [PlaybackReply] = []
    private var recorded: [URLRequest] = []
    func configure(_ replies: [PlaybackReply]) {
        lock.lock(); defer { lock.unlock() }
        self.replies = replies
        recorded = []
    }
    func respond(to request: URLRequest) -> PlaybackReply {
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

final class PlaybackMockProtocol: URLProtocol, @unchecked Sendable {
    static let server = PlaybackMockServer()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.server.respond(to: request)
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return }
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
