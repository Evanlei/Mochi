import Combine
import Foundation

@MainActor
final class SpotifySearchModel: ObservableObject {
    @Published var query = ""
    @Published var kind: SpotifySearchKind = .song
    @Published private(set) var results: [SpotifySearchTrack] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isStarting = false
    @Published private(set) var isConnected = false
    @Published private(set) var isPlaybackBusy = false
    @Published private(set) var message: String?
    @Published private(set) var submittedQuery: String?
    @Published private(set) var startingTrackID: String?

    private let client: SpotifySearchClient
    private weak var auth: SpotifyAuthModel?
    private weak var playback: SpotifyPlaybackModel?
    private var subscriptions: [AnyCancellable] = []
    private var searchTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var version = 0
    private var retryAfter: Date?
    private var quotaExceeded = false

    init(client: SpotifySearchClient? = nil) { self.client = client ?? SpotifySearchClient() }

    var canSubmit: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStarting }
    func canPlay(_ track: SpotifySearchTrack) -> Bool {
        isConnected && !isSearching && !isStarting && !isPlaybackBusy && track.canPlay
    }

    func configure(using auth: SpotifyAuthModel, playback: SpotifyPlaybackModel) {
        guard self.auth !== auth || self.playback !== playback else { return }
        reset()
        self.auth = auth
        self.playback = playback
        subscriptions = [
            auth.$isConnected.removeDuplicates().sink { [weak self] connected in
                guard let self else { return }
                if !connected { self.reset() }
                self.isConnected = connected
            },
            playback.$isBusy.removeDuplicates().sink { [weak self] busy in self?.isPlaybackBusy = busy }
        ]
    }

    func search() {
        guard canSubmit else { return }
        guard let auth, auth.isConnected else {
            message = "Connect Spotify from the menu bar to search."
            return
        }
        if let retryAfter, retryAfter > Date() {
            message = (quotaExceeded ? SpotifySearchError.quotaExceeded(0)
                       : .rateLimited(retryAfter.timeIntervalSinceNow)).localizedDescription
            return
        }
        cancelSearch()
        let current = version
        let connection = auth.connectionVersion
        let query = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let kind = kind
        results = []
        submittedQuery = query
        message = nil
        isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            defer { if current == self.version { self.isSearching = false; self.searchTask = nil } }
            do {
                var token = try await auth.validAccessToken()
                try self.check(current, connection: connection, auth: auth)
                let tracks: [SpotifySearchTrack]
                do { tracks = try await self.client.search(query: query, kind: kind, accessToken: token) }
                catch SpotifySearchError.unauthorized {
                    // Only an explicit token rejection gets one refresh and retry.
                    try self.check(current, connection: connection, auth: auth)
                    token = try await auth.validAccessToken(forceRefresh: true)
                    try self.check(current, connection: connection, auth: auth)
                    tracks = try await self.client.search(query: query, kind: kind, accessToken: token)
                }
                try self.check(current, connection: connection, auth: auth)
                self.results = tracks
                self.quotaExceeded = false
                self.message = tracks.isEmpty ? "No matches. Try another song or artist." : nil
            } catch {
                guard current == self.version, !(error is CancellationError),
                      (error as? URLError)?.code != .cancelled else { return }
                if case SpotifySearchError.rateLimited(let seconds) = error {
                    self.retryAfter = Date().addingTimeInterval(seconds)
                    self.quotaExceeded = false
                } else if case SpotifySearchError.quotaExceeded(let seconds) = error {
                    self.retryAfter = Date().addingTimeInterval(seconds)
                    self.quotaExceeded = true
                }
                self.message = error.localizedDescription
            }
        }
    }

    func play(_ track: SpotifySearchTrack) {
        guard canPlay(track), results.contains(where: { $0.uri == track.uri }),
              let auth, let playback, auth.isConnected else { return }
        let current = version
        let connection = auth.connectionVersion
        isStarting = true
        startingTrackID = track.id
        message = nil
        playTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if current == self.version {
                    self.isStarting = false; self.startingTrackID = nil; self.playTask = nil
                }
            }
            let accepted = await playback.startTrack(uri: track.uri, using: auth)
            guard current == self.version, auth.isConnected, connection == auth.connectionVersion else { return }
            self.message = playback.errorMessage ?? (accepted ? "Sent \(track.name) to Spotify." : "Playback is busy. Try again.")
        }
    }

    func cancelSearch() {
        // A play already in progress keeps its own version until it finishes.
        guard !isStarting else { return }
        version += 1
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    func reset() {
        version += 1
        searchTask?.cancel(); playTask?.cancel()
        searchTask = nil; playTask = nil
        query = ""; submittedQuery = nil; results = []
        message = nil; startingTrackID = nil
        isSearching = false; isStarting = false
        // Keep the account-level cooldown even if the card is cleared or Spotify disconnects.
    }

    private func check(_ current: Int, connection: Int, auth: SpotifyAuthModel) throws {
        try Task.checkCancellation()
        guard current == version, auth.isConnected, connection == auth.connectionVersion else { throw CancellationError() }
    }
}
