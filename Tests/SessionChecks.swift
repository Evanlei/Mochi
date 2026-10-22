import Foundation

/// Deterministic continuous-playback checks. No real account or music is touched.
@main
struct SessionChecks {
    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let network = URLSession(configuration: configuration)
        let backend = MochiBackendClient(session: network)
        let resolver = SpotifySearchClient(session: network)
        func json(_ body: Any, delay: TimeInterval = 0) throws -> SpotifyReply {
            SpotifyReply(data: try JSONSerialization.data(withJSONObject: body), delay: delay)
        }
        func canonicalID(_ n: Int) -> String { "lastfm-" + String(format: "%064x", n) }
        func spotifyID(_ n: Int) -> String { String(format: "%022d", n) }
        func uri(_ n: Int) -> String { "spotify:track:\(spotifyID(n))" }
        func source(_ n: Int) -> [String: Any] {
            ["id": canonicalID(n), "title": "Fixture \(n)", "artist": "Fixture Artist", "description": "piano",
             "score": 0.8, "source": "lastfm"]
        }
        func search(_ n: Int) throws -> SpotifyReply {
            try json(["tracks": ["items": [["id": spotifyID(n), "uri": uri(n), "name": "Fixture \(n)",
                "type": "track", "artists": [["name": "Fixture Artist"]], "album": ["name": "Fixture"]]]]])
        }
        func response(_ numbers: [Int], delay: TimeInterval = 0) throws -> SpotifyReply {
            try json(["received_prompt": "piano", "selection": ["catalog_kind": "lastfm_live", "method": "lexical",
                "request_id": UUID().uuidString, "tracks": numbers.map(source), "discovery_mode": "balanced"]], delay: delay)
        }
        func state(_ n: Int, playing: Bool = true, device: String = "fixture-device") throws -> SpotifyReply {
            try json(["is_playing": playing, "device": ["id": device, "is_restricted": false],
                "item": ["uri": uri(n), "name": "Fixture \(n)", "type": "track", "artists": [["name": "Fixture Artist"]]]])
        }
        let store = SpotifyMemoryStore()
        store.tokens = SpotifyTokens(accessToken: "fake", refreshToken: "fake-refresh", expiresAt: .distantFuture,
                                    scope: SpotifyConfiguration.scopes.joined(separator: " "))
        let auth = SpotifyAuthModel(tokenClient: SpotifyTokenClient(session: network), tokenStore: store)
        await auth.restore()
        let playback = SpotifyPlaybackModel(client: SpotifyPlaybackClient(session: network))
        let model = MochiRequestModel(backend: backend, resolver: resolver)
        model.configure(using: auth, playback: playback)
        func start() async throws {
            var replies = [try response(Array(1...5))]
            replies += try (1...5).map(search)
            replies += [try state(1), SpotifyReply(status: 204), try state(1), try json(["status": "ok"])]
            SpotifyMockProtocol.server.configure(replies)
            model.submit("piano")
            let deadline = Date().addingTimeInterval(5)
            while model.isSending || model.feedbackBusy {
                precondition(Date() < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(model.isSessionActive && model.queuedSongCount == 0)
            precondition(model.sessionQueue.current?.uri == uri(1) && model.sessionQueue.upcoming.isEmpty,
                         "Pending songs must not appear accepted before queue acknowledgement")
            replies = []
            for _ in 2...5 { replies += [try state(1), SpotifyReply(status: 204)] }
            SpotifyMockProtocol.server.configure(replies)
            await model.maintainSession()
            precondition(model.queuedSongCount == 4)
            precondition(model.sessionQueue.upcoming.map(\.uri) == (2...5).map(uri))
        }
        try await start()
        // Five initial songs advance to the third; refill adds five more without /play.
        var replies = [try state(3), try response(Array(6...10))]
        replies += try (6...10).map(search)
        for _ in 6...10 { replies += [try state(3), SpotifyReply(status: 204)] }
        SpotifyMockProtocol.server.configure(replies)
        await playback.refresh(using: auth)
        await model.maintainSession()
        precondition(model.isSessionActive && model.queuedSongCount == 7)
        precondition(model.sessionQueue.current?.uri == uri(3))
        precondition(model.sessionQueue.upcoming.map(\.uri) == (4...10).map(uri),
                     "Up Next must retain earlier queued songs when a new discovery batch arrives")
        let requests = SpotifyMockProtocol.server.requests()
        precondition(requests.filter { $0.url?.path == "/v1/me/player/queue" }.count == 5)
        precondition(!requests.contains { $0.url?.path == "/v1/me/player/play" })
        let continuation = requests.first { $0.url?.path == "/continue-listening" }!
        let body = try JSONSerialization.jsonObject(with: spotifyRequestBody(continuation)!) as! [String: Any]
        precondition(Set(body["exclude_tracks"] as! [String]) == Set((1...5).map(canonicalID)))
        precondition(body["track_id"] as? String == canonicalID(5) && body["prompt"] == nil)
        for (index, request) in requests.filter({ $0.url?.path == "/v1/me/player/queue" }).enumerated() {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.first { $0.name == "uri" }?.value == uri(index + 6))
            precondition(query.first { $0.name == "device_id" }?.value == "fixture-device")
        }
        print("PASS: continuous refill plays beyond five, preserves context/exclusions, appends ordered URIs without restarting")

        SpotifyMockProtocol.server.configure([try state(8, playing: false)])
        await playback.refresh(using: auth); await model.maintainSession()
        precondition(model.isSessionActive && SpotifyMockProtocol.server.requests().count == 1)
        precondition(!model.sessionQueue.isPlaying && model.sessionQueue.current?.uri == uri(8))
        precondition(model.sessionQueue.upcoming.map(\.uri) == [uri(9), uri(10)])
        SpotifyMockProtocol.server.configure([try state(8), try response([])])
        await playback.refresh(using: auth); await model.maintainSession()
        precondition(!model.isSessionActive && model.resultNotice != nil)
        precondition(model.sessionQueue.current == nil && model.sessionQueue.upcoming.isEmpty)
        precondition(SpotifyMockProtocol.server.requests().count == 2)
        print("PASS: pause never advances or refills; exhausted discovery ends gracefully without touching playback")

        try await start()
        SpotifyMockProtocol.server.configure([try state(1)])
        await playback.refresh(using: auth); await model.maintainSession() // Establish ownership.
        SpotifyMockProtocol.server.configure([try state(99)])
        await playback.refresh(using: auth)
        precondition(model.sessionQueue.current == nil && model.sessionQueue.upcoming.isEmpty)
        await model.maintainSession()
        precondition(!model.isSessionActive && SpotifyMockProtocol.server.requests().count == 1)
        precondition(model.resultNotice?.contains("playback changed") == true)
        print("PASS: unrelated Spotify playback stops refills without taking over")

        try await start()
        SpotifyMockProtocol.server.configure([try state(3), try response(Array(6...10), delay: 0.3)])
        await playback.refresh(using: auth)
        let pending = Task { await model.maintainSession() }
        try await Task.sleep(for: .milliseconds(50))
        model.stopSession()
        await pending.value
        precondition(!model.isSessionActive && !model.isRefilling)
        precondition(model.sessionQueue.current == nil && model.sessionQueue.upcoming.isEmpty)
        precondition(SpotifyMockProtocol.server.requests().count == 2)
        print("PASS: stopping a session cancels in-flight discovery before any queue write")

        try await start()
        replies = [try state(3), try response([6]), try search(6), try state(99)]
        SpotifyMockProtocol.server.configure(replies)
        await playback.refresh(using: auth); await model.maintainSession()
        precondition(!model.isSessionActive)
        precondition(!SpotifyMockProtocol.server.requests().contains { $0.url?.path == "/v1/me/player/queue" })
        print("PASS: a playback change during discovery is rechecked before queue mutation")

        try await start()
        SpotifyMockProtocol.server.configure([try state(3), try response([6]), try search(6), try state(3),
                                              SpotifyReply(error: .timedOut)])
        await playback.refresh(using: auth); await model.maintainSession()
        precondition(!model.isSessionActive)
        precondition(SpotifyMockProtocol.server.requests().filter { $0.url?.path == "/v1/me/player/queue" }.count == 1)
        print("PASS: ambiguous queue acknowledgement stops without retrying a possibly accepted song")

        try await start()
        SpotifyMockProtocol.server.configure([try state(3), try response([1])])
        await playback.refresh(using: auth); await model.maintainSession()
        precondition(!model.isSessionActive && SpotifyMockProtocol.server.requests().count == 2)
        print("PASS: repeated canonical songs are never searched or enqueued again")

        try await start()
        SpotifyMockProtocol.server.configure([try state(1)])
        await playback.refresh(using: auth); await model.maintainSession()
        SpotifyMockProtocol.server.configure([try state(1, device: "other-device")])
        await playback.refresh(using: auth); await model.maintainSession()
        precondition(!model.isSessionActive && SpotifyMockProtocol.server.requests().count == 1)
        print("PASS: moving the same song to another device releases session ownership")

        let localState = try JSONDecoder().decode(SpotifyPlaybackState.self, from: state(1).data)
        let local = LocalPlayerFixture(state: localState)
        let desktop = SpotifyPlaybackModel(client: SpotifyPlaybackClient(session: network), localClient: local)
        await desktop.enableDesktopControls()
        let desktopRequest = MochiRequestModel(backend: backend, resolver: resolver)
        desktopRequest.configure(using: auth, playback: desktop)
        replies = [try response(Array(1...5))] + (try (1...5).map(search)) + [try json(["status": "ok"])]
        SpotifyMockProtocol.server.configure(replies)
        desktopRequest.submit("piano")
        while desktopRequest.isSending || desktopRequest.feedbackBusy { try await Task.sleep(for: .milliseconds(10)) }
        replies = []
        for _ in 2...5 { replies += [try state(1), SpotifyReply(status: 204)] }
        SpotifyMockProtocol.server.configure(replies)
        await desktopRequest.maintainSession()
        let starts = await local.startedTracks
        precondition(starts == [uri(1)] && desktopRequest.queuedSongCount == 4)
        precondition(SpotifyMockProtocol.server.requests().filter { $0.url?.path == "/v1/me/player/queue" }.count == 4)
        desktopRequest.stopSession()
        print("PASS: desktop controls start locally; the optional API connection supplies the real ordered queue")

        replies = [try response(Array(1...5))] + (try (1...5).map(search)) + [try json(["status": "ok"])]
        SpotifyMockProtocol.server.configure(replies)
        desktopRequest.submit("piano")
        while desktopRequest.isSending || desktopRequest.feedbackBusy { try await Task.sleep(for: .milliseconds(10)) }
        SpotifyMockProtocol.server.configure([try state(1), SpotifyReply(status: 204), try state(1, device: "other-device")])
        await desktopRequest.maintainSession()
        precondition(!desktopRequest.isSessionActive)
        precondition(SpotifyMockProtocol.server.requests().filter { $0.url?.path == "/v1/me/player/queue" }.count == 1)
        print("PASS: desktop-assisted queues bind to the first confirmed API device and reject later device changes")

        try await start()
        SpotifyMockProtocol.server.configure([try state(3), try response([6]), try search(6), try state(3),
                                              SpotifyReply(status: 204, delay: 0.3)])
        await playback.refresh(using: auth)
        let delayedAppend = Task { await model.maintainSession() }
        let appendDeadline = Date().addingTimeInterval(3)
        while !SpotifyMockProtocol.server.requests().contains(where: { $0.url?.path == "/v1/me/player/queue" }) {
            precondition(Date() < appendDeadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(model.isRefilling && model.sessionQueue.upcoming.map(\.uri) == [uri(4), uri(5)])
        await delayedAppend.value
        precondition(model.sessionQueue.upcoming.map(\.uri) == [uri(4), uri(5), uri(6)])
        print("PASS: Up Next follows playback and pause, spans batches, clears on stop, and waits for queue acknowledgements")
    }
}
