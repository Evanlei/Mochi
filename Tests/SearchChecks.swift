import Foundation

@main
struct SearchChecks {
    @MainActor
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SpotifySearchClient(session: session)
        let player = SpotifyPlaybackClient(session: session)
        let id = "0000000000000000000001"
        let uri = "spotify:track:\(id)"
        func track(_ name: String = "Test Song", playable: Bool? = nil, invalid: Bool = false) -> [String: Any] {
            var value: [String: Any] = [
                "id": id, "uri": invalid ? "spotify:episode:\(id)" : uri,
                "name": name, "type": "track", "artists": [["name": "Test Artist"]],
                "album": ["name": "Test Album", "images": []]
            ]
            if let playable { value["is_playable"] = playable }
            return value
        }
        func page(_ name: String = "Test Song") throws -> SpotifyReply {
            SpotifyReply(data: try JSONSerialization.data(withJSONObject: ["tracks": ["items": [track(name)]]]))
        }
        func state(_ name: String = "Playing Song", restricted: Bool = false) throws -> SpotifyReply {
            SpotifyReply(data: try JSONSerialization.data(withJSONObject: [
                "is_playing": true,
                "device": ["id": "active & device", "is_restricted": restricted],
                "item": ["name": name, "type": "track", "artists": [["name": "Test Artist"]]]
            ]))
        }
        func auth() async -> SpotifyAuthModel {
            let store = SpotifyMemoryStore()
            store.tokens = SpotifyTokens(accessToken: "fake-access", refreshToken: "fake-refresh",
                expiresAt: Date().addingTimeInterval(3600), scope: SpotifyConfiguration.scopes.joined(separator: " "))
            let auth = SpotifyAuthModel(tokenClient: SpotifyTokenClient(session: session), tokenStore: store)
            await auth.restore()
            precondition(auth.isConnected)
            return auth
        }
        func settled(_ model: SpotifySearchModel) async throws {
            let deadline = Date().addingTimeInterval(3)
            while model.isSearching || model.isStarting {
                precondition(Date() < deadline, "Search/play never finished")
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        let query = "AC/DC & étude + live"
        SpotifyMockProtocol.server.configure([try page()])
        let results = try await client.search(query: query, kind: .song, accessToken: "fake-access")
        precondition(results.count == 1 && results[0].canPlay && results[0].artistNames == "Test Artist")
        let request = SpotifyMockProtocol.server.requests()[0]
        let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(request.url?.path == "/v1/search" && request.httpMethod == "GET")
        precondition(queryItems.first(where: { $0.name == "q" })?.value == query)
        precondition(queryItems.first(where: { $0.name == "type" })?.value == "track")
        precondition(queryItems.first(where: { $0.name == "limit" })?.value == "5")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-access")
        SpotifyMockProtocol.server.configure([try page()])
        _ = try await client.search(query: "Frank Ocean", kind: .artist, accessToken: "fake-access")
        let artistQuery = URLComponents(url: SpotifyMockProtocol.server.requests()[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(artistQuery.first(where: { $0.name == "q" })?.value == "artist:Frank Ocean")
        print("PASS: encoded song/artist queries, user authorization, and five-result limit")

        let mixed: [Any] = [track(), NSNull(), track(), track(invalid: true)]
        SpotifyMockProtocol.server.configure([SpotifyReply(data: try JSONSerialization.data(withJSONObject: ["tracks": ["items": mixed]]))])
        let filtered = try await client.search(query: "test", kind: .song, accessToken: "fake-access")
        precondition(filtered.count == 1)
        let unavailable = try JSONDecoder().decode(SpotifySearchTrack.self, from: JSONSerialization.data(withJSONObject: track(playable: false)))
        precondition(!unavailable.canPlay)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: Data(#"{"tracks":{"items":[]}}"#.utf8))])
        let empty = try await client.search(query: "test", kind: .song, accessToken: "fake-access")
        precondition(empty.isEmpty)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: Data("bad JSON".utf8))])
        do { _ = try await client.search(query: "test", kind: .song, accessToken: "fake-access"); fatalError("Bad JSON accepted") }
        catch SpotifySearchError.unexpectedResponse { }
        for status in [401, 403, 429, 500] {
            SpotifyMockProtocol.server.configure([SpotifyReply(status: status, headers: ["Retry-After": "12"])])
            do { _ = try await client.search(query: "test", kind: .song, accessToken: "fake-access"); fatalError("Failure accepted") }
            catch let error as SpotifySearchError {
                switch (status, error) {
                case (401, .unauthorized), (403, .forbidden), (429, .rateLimited(12)), (500, .requestFailed(500)): break
                default: fatalError("Wrong search error")
                }
            }
        }
        print("PASS: missing optional metadata, duplicates/nulls/invalid identities, unavailable tracks, and failures")

        let connected = await auth()
        let playback = SpotifyPlaybackModel(client: player)
        let model = SpotifySearchModel(client: client)
        model.configure(using: connected, playback: playback)
        SpotifyMockProtocol.server.configure([try page()])
        model.query = "Test Song"; model.search()
        try await settled(model)
        precondition(model.results.count == 1 && model.message == nil)

        var slow = try page("Old Song"); slow.delay = 0.15
        SpotifyMockProtocol.server.configure([slow, try page("New Song")])
        model.query = "old"; model.search()
        try await Task.sleep(for: .milliseconds(20))
        model.query = "new"; model.search()
        try await settled(model)
        try await Task.sleep(for: .milliseconds(170))
        precondition(model.results.first?.name == "New Song" && model.submittedQuery == "new")
        SpotifyMockProtocol.server.configure([slow])
        model.search()
        try await Task.sleep(for: .milliseconds(20))
        model.reset()
        try await Task.sleep(for: .milliseconds(170))
        precondition(model.results.isEmpty && !model.isSearching && model.message == nil)
        print("PASS: latest-query wins and reset cancels pending responses")

        let refreshed = SpotifyReply(data: Data(#"{"access_token":"refreshed-access","token_type":"Bearer","expires_in":3600}"#.utf8))
        SpotifyMockProtocol.server.configure([SpotifyReply(status: 401), refreshed, try page()])
        model.query = "test"; model.search()
        try await settled(model)
        let retry = SpotifyMockProtocol.server.requests()
        precondition(retry.count == 3 && retry[1].url?.path == "/api/token")
        precondition(retry[2].value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-access")
        SpotifyMockProtocol.server.configure([SpotifyReply(status: 401), refreshed, SpotifyReply(status: 401)])
        model.search(); try await settled(model)
        precondition(SpotifyMockProtocol.server.requests().count == 3 && model.message != nil)
        SpotifyMockProtocol.server.configure([SpotifyReply(status: 429, headers: ["Retry-After": "60"])])
        model.search(); try await settled(model)
        model.search()
        precondition(SpotifyMockProtocol.server.requests().count == 1)
        print("PASS: one-time token refresh/retry and rate-limit cooldown")

        let quotaModel = SpotifySearchModel(client: client)
        quotaModel.configure(using: connected, playback: playback)
        SpotifyMockProtocol.server.configure([SpotifyReply(status: 429,
            data: Data(#"{"error":{"reason":"QUOTA_EXCEEDED"}}"#.utf8), headers: ["Retry-After": "60"])])
        quotaModel.query = "test"; quotaModel.search(); try await settled(quotaModel)
        quotaModel.reset(); quotaModel.query = "test"; quotaModel.search()
        precondition(quotaModel.message?.contains("quota") == true && SpotifyMockProtocol.server.requests().count == 1)
        print("PASS: quota-exhausted message and cooldown survive clearing the card")

        let playModel = SpotifySearchModel(client: client)
        playModel.configure(using: connected, playback: playback)
        SpotifyMockProtocol.server.configure([try page()])
        playModel.query = "test"; playModel.search(); try await settled(playModel)
        let selected = playModel.results[0]
        SpotifyMockProtocol.server.configure([try state("Old Song"), SpotifyReply(status: 204), try state("Selected Song")])
        playModel.play(selected)
        try await Task.sleep(for: .milliseconds(20))
        await playback.perform(.next, using: connected)
        try await settled(playModel)
        let requests = SpotifyMockProtocol.server.requests()
        precondition(requests.count == 3 && requests[1].httpMethod == "PUT")
        precondition(requests[1].url?.path == "/v1/me/player/play")
        precondition(requests[1].value(forHTTPHeaderField: "Content-Type") == "application/json")
        let payload = try JSONSerialization.jsonObject(with: spotifyRequestBody(requests[1])!) as! [String: Any]
        precondition(payload["uris"] as? [String] == [uri] && payload["position_ms"] as? Int == 0)
        let device = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(device.first?.value == "active & device")
        precondition(playback.state?.item?.name == "Selected Song" && !playback.isBusy)
        precondition(playModel.message == "Sent Test Song to Spotify.")
        print("PASS: selected URI/JSON, current device targeting, refreshed state, and serialized menu controls")

        SpotifyMockProtocol.server.configure([try state(), SpotifyReply(error: .timedOut)])
        playModel.play(selected); try await settled(playModel)
        precondition(SpotifyMockProtocol.server.requests().count == 2 && playModel.message != nil)
        SpotifyMockProtocol.server.configure([try state(restricted: true)])
        playModel.play(selected); try await settled(playModel)
        precondition(SpotifyMockProtocol.server.requests().count == 1 && playModel.message != nil)
        SpotifyMockProtocol.server.configure([try state(), SpotifyReply(status: 404)])
        playModel.play(selected); try await settled(playModel)
        precondition(SpotifyMockProtocol.server.requests().count == 2 && playModel.message?.contains("No Spotify player") == true)
        SpotifyMockProtocol.server.configure([try state(), SpotifyReply(status: 204), SpotifyReply(status: 500)])
        playModel.play(selected); try await settled(playModel)
        precondition(playModel.message?.contains("accepted") == true && playback.isStale)
        SpotifyMockProtocol.server.configure([try state(), SpotifyReply(status: 401), refreshed,
                                              try state(), SpotifyReply(status: 204), try state()])
        playModel.play(selected); try await settled(playModel)
        let retriedPlay = SpotifyMockProtocol.server.requests()
        precondition(retriedPlay.count == 6 && retriedPlay[2].url?.path == "/api/token")
        precondition(retriedPlay[4].value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-access")
        precondition(!playback.isStale)
        SpotifyMockProtocol.server.configure([])
        do { try await player.startTrack(uri: "spotify:episode:\(id)", accessToken: "fake-access", deviceID: nil); fatalError("Invalid URI accepted") }
        catch SpotifyPlaybackError.invalidTrack { }
        precondition(SpotifyMockProtocol.server.requests().isEmpty)
        print("PASS: no retry after uncertain playback outcome, restricted device, and invalid URI rejection")

        let signOutAuth = await auth()
        let signOutPlayback = SpotifyPlaybackModel(client: player)
        let signOutModel = SpotifySearchModel(client: client)
        signOutModel.configure(using: signOutAuth, playback: signOutPlayback)
        SpotifyMockProtocol.server.configure([try page()])
        signOutModel.query = "test"; signOutModel.search(); try await settled(signOutModel)
        var slowState = try state(); slowState.delay = 0.15
        SpotifyMockProtocol.server.configure([slowState])
        signOutModel.play(signOutModel.results[0])
        try await Task.sleep(for: .milliseconds(20))
        signOutAuth.disconnect(); signOutPlayback.reset()
        try await Task.sleep(for: .milliseconds(170))
        precondition(SpotifyMockProtocol.server.requests().count == 1 && !signOutModel.isStarting && !signOutPlayback.isBusy)
        print("PASS: no track-start command after disconnect during device lookup")

        SpotifyMockProtocol.server.configure([slow])
        playModel.search()
        try await Task.sleep(for: .milliseconds(20))
        connected.disconnect()
        try await Task.sleep(for: .milliseconds(170))
        precondition(playModel.results.isEmpty && !playModel.isSearching && !playModel.isConnected)
        SpotifyMockProtocol.server.configure([])
        playModel.query = "test"; playModel.search()
        precondition(playModel.message?.contains("Connect Spotify") == true && SpotifyMockProtocol.server.requests().isEmpty)
        print("PASS: disconnect clears account results and prevents stale responses or unauthenticated searches")
    }
}
