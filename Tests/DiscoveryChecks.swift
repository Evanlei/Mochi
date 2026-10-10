import Foundation

@main
struct DiscoveryChecks {
    @MainActor
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let session = URLSession(configuration: configuration)
        let backend = MochiBackendClient(session: session)
        let resolver = SpotifySearchClient(session: session)
        let requestID = UUID().uuidString
        let sourceID = "lastfm-" + String(repeating: "a", count: 64)
        let spotifyID = "0000000000000000000001"
        let isrc = "USUG11904206"

        func source(_ title: String = "Quiet Window", extras: [String: Any] = [:]) -> [String: Any] {
            var value: [String: Any] = ["id": sourceID, "title": title, "artist": "Test Artist",
                "bpm": NSNull(), "vocals": NSNull(), "energy": NSNull(), "description": "Community tags: piano",
                "score": 0.8, "source": "lastfm", "source_url": "https://www.last.fm/music/Test+Artist/_/Quiet+Window"]
            value.merge(extras) { _, new in new }; return value
        }
        func spotify(_ title: String = "Quiet Window", artist: String = "Test Artist", id: String? = nil,
                     extras: [String: Any] = [:]) -> [String: Any] {
            let id = id ?? spotifyID
            var value: [String: Any] = ["id": id, "uri": "spotify:track:\(id)", "name": title, "type": "track",
                "artists": [["name": artist]], "album": ["name": "Test Album", "images": []]]
            value.merge(extras) { _, new in new }; return value
        }
        func decodeSource(_ value: [String: Any]) throws -> MochiSelectedTrack {
            try JSONDecoder().decode(MochiSelectedTrack.self, from: JSONSerialization.data(withJSONObject: value))
        }
        func decodeSpotify(_ value: [String: Any]) throws -> SpotifySearchTrack {
            try JSONDecoder().decode(SpotifySearchTrack.self, from: JSONSerialization.data(withJSONObject: value))
        }
        func json(_ value: Any) throws -> SpotifyReply { SpotifyReply(data: try JSONSerialization.data(withJSONObject: value)) }
        func response(_ prompt: String = "piano", tracks: [[String: Any]]? = nil, kind: String = "lastfm_live") throws -> SpotifyReply {
            try json(["received_prompt": prompt, "intent": ["vocals": NSNull(), "energy": NSNull()],
                "selection": ["catalog_kind": kind, "method": "lexical", "request_id": requestID,
                    "tracks": tracks ?? [source()], "warnings": [], "message": NSNull()]])
        }
        func state() throws -> SpotifyReply {
            try json(["is_playing": true, "device": ["id": "active-device", "is_restricted": false],
                "item": ["name": "Quiet Window", "type": "track", "artists": [["name": "Test Artist"]]]])
        }
        func auth() async -> SpotifyAuthModel {
            let store = SpotifyMemoryStore()
            store.tokens = SpotifyTokens(accessToken: "fake-access", refreshToken: "fake-refresh",
                expiresAt: Date().addingTimeInterval(3600), scope: SpotifyConfiguration.scopes.joined(separator: " "))
            let auth = SpotifyAuthModel(tokenClient: SpotifyTokenClient(session: session), tokenStore: store)
            await auth.restore(); return auth
        }
        func settle(_ model: MochiRequestModel) async throws {
            let deadline = Date().addingTimeInterval(4)
            while model.isSending || model.isStarting || model.feedbackBusy {
                precondition(Date() < deadline, "Discovery never finished")
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        let track = try decodeSource(source())
        precondition(track.bpm == nil && track.vocals == nil && track.energy == nil)
        precondition(track.details == "Musical features unavailable")
        let exact = try decodeSpotify(spotify())
        precondition(SpotifyRecordingMatcher.match(track, candidates: [exact])?.id == spotifyID)
        for bad in [spotify(artist: "Cover Artist"), spotify("Quiet Window - Live"),
                    spotify("Quiet Window (Remix)"), spotify(extras: ["is_playable": false])] {
            let candidate = try decodeSpotify(bad)
            precondition(SpotifyRecordingMatcher.match(track, candidates: [candidate]) == nil)
        }
        let duplicate = try decodeSpotify(spotify(id: "0000000000000000000002"))
        precondition(SpotifyRecordingMatcher.match(track, candidates: [exact, duplicate]) == nil)
        let reissue = try decodeSpotify(spotify(id: "0000000000000000000002", extras: ["external_ids": ["isrc": isrc]]))
        let original = try decodeSpotify(spotify(extras: ["external_ids": ["isrc": isrc]]))
        precondition(SpotifyRecordingMatcher.match(track, candidates: [reissue, original])?.id == spotifyID)
        print("PASS: nullable features, artist/version/playability checks, ambiguous recordings, equivalent reissues")

        let measured = try decodeSource(source(extras: ["isrc": isrc, "duration_ms": 200000, "feature_spotify_id": spotifyID]))
        for bad in [spotify(extras: ["external_ids": ["isrc": "USUG11904207"], "duration_ms": 200000]),
                    spotify(extras: ["external_ids": ["isrc": isrc], "duration_ms": 205000])] {
            let candidate = try decodeSpotify(bad)
            precondition(SpotifyRecordingMatcher.match(measured, candidates: [candidate]) == nil)
        }
        SpotifyMockProtocol.server.configure([try json(["tracks": ["items": [spotify(extras: ["external_ids": ["isrc": isrc], "duration_ms": 200500])]]])])
        let resolved = try await resolver.resolve(measured, accessToken: "fake-access")
        precondition(resolved?.id == spotifyID)
        let query = URLComponents(url: SpotifyMockProtocol.server.requests()[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.first(where: { $0.name == "q" })?.value == "isrc:\(isrc)")
        print("PASS: ISRC query encoding and feature-to-recording duration/identity binding")

        SpotifyMockProtocol.server.configure([try response(tracks: [source(extras: ["source": "spotify"])])])
        do { _ = try await backend.send(prompt: "piano"); fatalError("Wrong source accepted") }
        catch MochiBackendError.invalidResponse { }
        let connected = await auth()
        let playback = SpotifyPlaybackModel(client: SpotifyPlaybackClient(session: session))
        let model = MochiRequestModel(backend: backend, resolver: resolver)
        model.configure(using: connected, playback: playback)
        var second = source("Wrong Song"); second["id"] = "lastfm-" + String(repeating: "b", count: 64)
        SpotifyMockProtocol.server.configure([try response(tracks: [source(), second]),
            try json(["tracks": ["items": [spotify("Quiet Window", artist: "Cover Artist", id: "0000000000000000000003"), spotify()]]]),
            try json(["tracks": ["items": [spotify("Wrong Song - Live")]]]),
            try state(), SpotifyReply(status: 204), try state(), try json(["status": "ok"])])
        model.submit("piano"); try await settle(model)
        precondition(model.reply == "Started 1 of 2 matches." && model.resolvedTracks.count == 1)
        let requests = SpotifyMockProtocol.server.requests()
        let body = try JSONSerialization.jsonObject(with: spotifyRequestBody(requests[4])!) as! [String: Any]
        precondition(body["uris"] as? [String] == ["spotify:track:\(spotifyID)"])
        precondition(requests[4].url?.path == "/v1/me/player/play")
        let event = try JSONSerialization.jsonObject(with: spotifyRequestBody(requests[6])!) as! [String: Any]
        precondition(Set(event.keys) == ["event_id", "request_id", "track_id", "event"])
        precondition(event["event"] as? String == "select" && event["request_id"] as? String == requestID)
        print("PASS: independent live contract, ranked partial playback, first-party feedback without Spotify payloads")

        SpotifyMockProtocol.server.configure([try json(["status": "ok"])])
        model.feedback(track, event: .like); try await settle(model)
        precondition(model.likedTracks.contains(sourceID))
        SpotifyMockProtocol.server.configure([try json(["status": "ok"])])
        model.clearTaste(); try await settle(model)
        precondition(model.likedTracks.isEmpty && SpotifyMockProtocol.server.requests()[0].httpMethod == "DELETE")
        var slowOK = try json(["status": "ok"]); slowOK.delay = 0.2
        SpotifyMockProtocol.server.configure([slowOK, try response("jazz", tracks: [])])
        model.feedback(track, event: .dislike)
        try await Task.sleep(for: .milliseconds(20))
        model.submit("jazz"); try await settle(model)
        try await Task.sleep(for: .milliseconds(230))
        precondition(model.dislikedTracks.isEmpty && model.feedbackMessage == nil)
        print("PASS: saved likes, explicit taste deletion, and old feedback cannot update a new request")

        var slowSearch = try json(["tracks": ["items": [spotify()]]]); slowSearch.delay = 0.2
        SpotifyMockProtocol.server.configure([try response(), slowSearch])
        model.submit("piano")
        try await Task.sleep(for: .milliseconds(30)); model.reset()
        try await Task.sleep(for: .milliseconds(230))
        precondition(model.selection == nil && !model.isSending)
        precondition(!SpotifyMockProtocol.server.requests().contains(where: { $0.httpMethod == "PUT" }))
        SpotifyMockProtocol.server.configure([try response(), slowSearch])
        model.submit("piano")
        try await Task.sleep(for: .milliseconds(30)); connected.disconnect()
        try await Task.sleep(for: .milliseconds(230))
        precondition(model.selection == nil && !model.isConnected)
        precondition(!SpotifyMockProtocol.server.requests().contains(where: { $0.httpMethod == "PUT" }))
        print("PASS: reset/disconnect during matching cancel playback and discard stale results")

        let offline = MochiRequestModel(backend: backend, resolver: resolver)
        SpotifyMockProtocol.server.configure([try response()])
        offline.submit("piano"); try await settle(offline)
        precondition(offline.reply.contains("Connect Spotify"))
        let reconnected = await auth()
        offline.configure(using: reconnected, playback: playback)
        SpotifyMockProtocol.server.configure([try json(["tracks": ["items": [spotify()]]]),
            try state(), SpotifyReply(status: 204), try state(), try json(["status": "ok"])])
        offline.playMatches(); try await settle(offline)
        precondition(offline.reply == "Started 1 of 1 matches.")
        print("PASS: recommendations made before connection can be matched and played afterward")

        SpotifyMockProtocol.server.configure([try response(), SpotifyReply(status: 429, headers: ["Retry-After": "60"])])
        offline.submit("piano"); try await settle(offline)
        precondition(!offline.canPlayMatches)
        offline.playMatches(); precondition(SpotifyMockProtocol.server.requests().count == 2)
        var fixture = source(); fixture["id"] = "sample-quiet-window"
        SpotifyMockProtocol.server.configure([try response(tracks: [fixture], kind: "fictional_sample")])
        offline.submit("piano"); try await settle(offline)
        precondition(SpotifyMockProtocol.server.requests().count == 1 && !offline.canPlayMatches)
        print("PASS: rate-limit cooldown and fictional fixtures never start real playback")
    }
}
