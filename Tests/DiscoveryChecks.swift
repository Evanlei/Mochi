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

        // Favorite setup uses only localhost/Last.fm identities, even without Spotify.
        let suite = "com.evan.Mochi.artist-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let artists = MochiArtistPreferencesModel(backend: backend, defaults: defaults)
        precondition(artists.isPresented && artists.names.isEmpty)
        artists.finish()
        precondition(!MochiArtistPreferencesModel(defaults: defaults).isPresented)
        artists.present()
        for name in ["音楽", "Favorite Artist", "Third Artist"] {
            artists.query = name
            SpotifyMockProtocol.server.configure([try json(["query": name, "artists": [name]])])
            await artists.search()
            precondition(artists.suggestions == [name])
            artists.add(name)
            let sent = SpotifyMockProtocol.server.requests()[0]
            precondition(sent.url?.absoluteString == "http://127.0.0.1:8000/artist-search")
            precondition(sent.value(forHTTPHeaderField: "Authorization") == nil)
        }
        artists.add("Fourth Artist")
        precondition(artists.names == ["音楽", "Favorite Artist", "Third Artist"])
        precondition(artists.lastAdded != nil)
        artists.finish()
        let restoredArtists = MochiArtistPreferencesModel(backend: backend, defaults: defaults)
        precondition(restoredArtists.names == artists.names && !restoredArtists.isPresented)
        restoredArtists.remove("Third Artist")
        precondition(MochiArtistPreferencesModel(defaults: defaults).names == ["音楽", "Favorite Artist"])
        print("PASS: optional artist setup, Unicode autocomplete, three-artist limit, removal and persistence")

        for bad in [try json(["query": "wrong", "artists": ["Artist"]]),
                    try json(["query": "test", "artists": ["Artist", "ARTIST"]]),
                    try json(["query": "test", "artists": ["bad\nname"]]),
                    try json(["query": "test", "artists": Array(repeating: "Artist", count: 6)])] {
            SpotifyMockProtocol.server.configure([bad])
            do { _ = try await backend.searchArtists(query: "test"); fatalError("Malformed artist search accepted") }
            catch MochiBackendError.invalidResponse {}
        }
        let racingArtists = MochiArtistPreferencesModel(backend: backend)
        racingArtists.query = "old"
        var old = try json(["query": "old", "artists": ["Old Artist"]]); old.delay = 0.8
        SpotifyMockProtocol.server.configure([old, try json(["query": "new", "artists": ["New Artist"]])])
        let oldSearch = Task { await racingArtists.search() }
        while !racingArtists.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        // Changing the query invalidates a reply even if its transport can't cancel.
        racingArtists.query = "new"
        await racingArtists.search(); await oldSearch.value
        precondition(racingArtists.suggestions == ["New Artist"])
        SpotifyMockProtocol.server.configure([])
        racingArtists.query = "cancelled"
        let cancelled = Task { await racingArtists.search() }
        try await Task.sleep(for: .milliseconds(20)); cancelled.cancel(); await cancelled.value
        precondition(SpotifyMockProtocol.server.requests().isEmpty && !racingArtists.isSearching)
        racingArtists.query = "offline"
        SpotifyMockProtocol.server.configure([SpotifyReply(error: .cannotConnectToHost)])
        await racingArtists.search()
        precondition(racingArtists.message?.contains("Start it") == true)
        print("PASS: malformed artist replies, stale-query suppression, debounce cancellation and backend errors")

        let personalized = MochiRequestModel(backend: backend, artists: restoredArtists)
        SpotifyMockProtocol.server.configure([try response()])
        personalized.submit("piano"); try await settle(personalized)
        let profileBody = try JSONSerialization.jsonObject(with: spotifyRequestBody(SpotifyMockProtocol.server.requests()[0])!) as! [String: Any]
        precondition(profileBody["favorite_artists"] as? [String] == ["音楽", "Favorite Artist"])
        precondition(Set(profileBody.keys) == ["prompt", "favorite_artists"])
        personalized.reset()
        precondition(restoredArtists.names.count == 2)
        SpotifyMockProtocol.server.configure([try json(["status": "ok"])])
        personalized.clearTaste(); try await settle(personalized)
        precondition(restoredArtists.names.isEmpty && MochiArtistPreferencesModel(defaults: defaults).names.isEmpty)
        print("PASS: explicit favorites accompany discovery, survive request reset, and clear with taste memory")

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

        second["title"] = "Quiet Dawn"
        let secondID = "0000000000000000000002"
        SpotifyMockProtocol.server.configure([try response(tracks: [source(), second]),
            try json(["tracks": ["items": [spotify()]]]),
            try json(["tracks": ["items": [spotify("Quiet Dawn", id: secondID)]]]),
            try state(), SpotifyReply(status: 204), try state(), try json(["status": "ok"])])
        model.submit("piano"); try await settle(model)
        let queue = try JSONSerialization.jsonObject(with: spotifyRequestBody(SpotifyMockProtocol.server.requests()[4])!) as! [String: Any]
        precondition(queue["uris"] as? [String] == ["spotify:track:\(spotifyID)", "spotify:track:\(secondID)"])
        precondition(model.reply == "Started 2 of 2 matches.")
        print("PASS: multiple confirmed recordings start in recommendation order")

        SpotifyMockProtocol.server.configure([try response(), SpotifyReply(status: 401),
            try json(["access_token": "refreshed-access", "token_type": "Bearer", "expires_in": 3600]),
            try json(["tracks": ["items": [spotify()]]]),
            try state(), SpotifyReply(status: 204), try state(), try json(["status": "ok"])])
        model.submit("piano"); try await settle(model)
        let refreshedRequests = SpotifyMockProtocol.server.requests()
        precondition(refreshedRequests[2].url?.path == "/api/token")
        precondition(refreshedRequests[3].value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-access")
        precondition(model.reply == "Started 1 of 1 matches.")
        print("PASS: discovery resolution refreshes a rejected token once before playback")

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
        precondition(offline.reply.contains("Find on Spotify"))
        precondition(SpotifyMockProtocol.server.requests().count == 1)
        let handoff = try decodeSource(source("A/B?C#D%", extras: ["artist": "Björk & friends"]))
        precondition(handoff.spotifySearchURL?.host == "open.spotify.com")
        precondition(handoff.spotifySearchURL?.path == "/search/Björk & friends A/B?C#D%")
        precondition(handoff.spotifySearchURL?.query == nil && handoff.spotifySearchURL?.fragment == nil)
        precondition(handoff.spotifySearchURL?.absoluteString.contains("%2F") == true)
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

        let refining = MochiRequestModel(backend: backend, resolver: resolver)
        let originalPrompt = "piano 80-100 BPM"
        SpotifyMockProtocol.server.configure([try response(originalPrompt)])
        refining.submit(originalPrompt); try await settle(refining)
        refining.draft = "electronic for tomorrow"
        var nextTrack = source("New Piano")
        nextTrack["id"] = "lastfm-" + String(repeating: "b", count: 64)
        SpotifyMockProtocol.server.configure([try response(originalPrompt, tracks: [nextTrack])])
        refining.moreLikeThis(track); try await settle(refining)
        let similarRequest = SpotifyMockProtocol.server.requests()[0]
        let similarBody = try JSONSerialization.jsonObject(with: spotifyRequestBody(similarRequest)!) as! [String: String]
        precondition(similarRequest.url?.path == "/more-like-this" && similarRequest.httpMethod == "POST")
        precondition(similarBody == ["request_id": requestID, "track_id": sourceID, "title": track.title, "artist": track.artist])
        precondition(refining.draft == "electronic for tomorrow" && refining.preferences == [originalPrompt])
        precondition(refining.selection?.tracks.first?.title == "New Piano" && refining.similarTo == track.title)
        let next = refining.selection!.tracks[0]
        print("PASS: similar-song requests use canonical context, preserve the draft and retain original preferences")

        for failure in [SpotifyReply(status: 409), SpotifyReply(status: 422), SpotifyReply(error: .cannotConnectToHost),
                        try response(originalPrompt, tracks: []),
                        try response(originalPrompt, tracks: [fixture], kind: "fictional_sample")] {
            SpotifyMockProtocol.server.configure([failure])
            refining.moreLikeThis(next); try await settle(refining)
            precondition(refining.selection?.tracks.first?.id == next.id && refining.similarTo == track.title)
            precondition(refining.draft == "electronic for tomorrow" && !refining.isSending)
            precondition(SpotifyMockProtocol.server.requests().count == 1)
        }
        print("PASS: expired/invalid/offline/empty refinement keeps the existing songs and allows retry")

        var delayed = try response(originalPrompt, tracks: [source("Late Piano")]); delayed.delay = 0.2
        SpotifyMockProtocol.server.configure([delayed])
        refining.moreLikeThis(next); refining.moreLikeThis(next)
        try await Task.sleep(for: .milliseconds(20)); refining.reset()
        try await Task.sleep(for: .milliseconds(230))
        precondition(refining.selection == nil && refining.similarTo == nil && !refining.isSending)
        precondition(SpotifyMockProtocol.server.requests().count == 1)

        SpotifyMockProtocol.server.configure([try response(), try json(["tracks": ["items": [spotify()]]]),
            try state(), SpotifyReply(status: 204), try state(), try json(["status": "ok"])])
        let similarConnected = MochiRequestModel(backend: backend, resolver: resolver)
        let similarAuth = await auth()
        similarConnected.configure(using: similarAuth, playback: playback)
        similarConnected.submit("piano"); try await settle(similarConnected)
        SpotifyMockProtocol.server.configure([try response(tracks: [nextTrack]),
            try json(["tracks": ["items": [spotify("New Piano")]]]),
            try state(), SpotifyReply(status: 204), try state(), try json(["status": "ok"])])
        similarConnected.moreLikeThis(track); try await settle(similarConnected)
        precondition(similarConnected.reply == "Started 1 of 1 matches.")
        precondition(SpotifyMockProtocol.server.requests().first?.url?.path == "/more-like-this")
        precondition(SpotifyMockProtocol.server.requests().filter { $0.httpMethod == "PUT" }.count == 1)

        SpotifyMockProtocol.server.configure([delayed])
        similarConnected.moreLikeThis(next)
        try await Task.sleep(for: .milliseconds(20)); similarAuth.disconnect()
        try await Task.sleep(for: .milliseconds(230))
        precondition(similarConnected.selection == nil && !similarConnected.isConnected)
        precondition(!SpotifyMockProtocol.server.requests().contains { $0.httpMethod == "PUT" })
        print("PASS: similar-song playback uses the shared resolver/player and reset/disconnect discard late results")

        SpotifyMockProtocol.server.configure([try response(tracks: [fixture], kind: "fictional_sample")])
        refining.submit("piano"); try await settle(refining)
        precondition(!refining.canDiscoverSimilar(refining.selection!.tracks[0]))
        refining.moreLikeThis(refining.selection!.tracks[0])
        precondition(SpotifyMockProtocol.server.requests().count == 1)
        print("PASS: fictional sample selections cannot trigger live similar-song discovery")

        let localState = try JSONDecoder().decode(SpotifyPlaybackState.self, from: state().data)
        let desktop = LocalPlayerFixture(state: localState)
        let desktopPlayback = SpotifyPlaybackModel(client: SpotifyPlaybackClient(session: session), localClient: desktop)
        SpotifyMockProtocol.server.configure([])
        await desktopPlayback.enableDesktopControls()
        let desktopRequest = MochiRequestModel(backend: backend, resolver: resolver)
        let noAPI = SpotifyAuthModel(tokenStore: SpotifyMemoryStore())
        desktopRequest.configure(using: noAPI, playback: desktopPlayback)
        SpotifyMockProtocol.server.configure([try response()])
        desktopRequest.submit("piano"); try await settle(desktopRequest)
        precondition(desktopRequest.hasSelectedTracks && desktopRequest.reply.contains("Find on Spotify"))
        precondition(!desktopRequest.canPlayMatches && SpotifyMockProtocol.server.requests().count == 1)
        precondition(SpotifyMockProtocol.server.requests()[0].url?.host == "127.0.0.1")
        print("PASS: desktop-only discovery uses the independent backend and never requests a Spotify API token")

        let api = await auth()
        desktopRequest.configure(using: api, playback: desktopPlayback)
        let desktopSecond = source("Second song", extras: ["id": "lastfm-" + String(repeating: "b", count: 64)])
        SpotifyMockProtocol.server.configure([try response(tracks: [source(), desktopSecond]),
            try json(["tracks": ["items": [spotify()]]]),
            try json(["tracks": ["items": [spotify("Second song", id: "0000000000000000000002")]]]),
            try json(["status": "ok"])])
        desktopRequest.submit("piano"); try await settle(desktopRequest)
        let localStarts = await desktop.startedTracks
        precondition(localStarts == ["spotify:track:\(spotifyID)"])
        precondition(desktopRequest.resolvedTracks.count == 2)
        precondition(desktopRequest.reply == "Playing the first match on Spotify desktop.")
        precondition(!SpotifyMockProtocol.server.requests().contains(where: { $0.url?.path.hasPrefix("/v1/me/player") == true }))
        precondition(!SpotifyMockProtocol.server.requests().contains(where: { $0.url?.path == "/api/token" }))
        print("PASS: optional API matching hands only the first ranked URI to desktop playback, never a fake queue")
    }
}
