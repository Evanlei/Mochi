import AppKit
import Combine
import SwiftUI

// MARK: - Listening request

@MainActor
final class MochiRequestModel: ObservableObject {
    let artists: MochiArtistPreferencesModel
    @Published var discoveryMode: MochiDiscoveryMode = .balanced {
        didSet { defaults?.set(discoveryMode.rawValue, forKey: Self.modeKey) }
    }
    @Published var isSearchPresented = false
    @Published var draft = ""
    @Published private(set) var preferences: [String] = []
    @Published private(set) var reply = "What do you feel like\nlistening to?"
    @Published private(set) var resultNotice: String?
    @Published private(set) var isSending = false
    @Published private(set) var selection: MochiSongSelection?
    @Published private(set) var resolvedTracks: [String: SpotifySearchTrack] = [:]
    @Published private(set) var isStarting = false
    @Published private(set) var isPlaybackBusy = false
    @Published private(set) var isConnected = false
    @Published private(set) var usesDesktopPlayer = false
    @Published private(set) var feedbackMessage: String?
    @Published private(set) var feedbackError: String?
    @Published private(set) var feedbackBusy = false
    @Published private(set) var likedTracks: Set<String> = []
    @Published private(set) var dislikedTracks: Set<String> = []
    @Published private(set) var similarTo: String?

    private let backend: MochiBackendClient
    private let defaults: UserDefaults?
    private static let modeKey = "mochi.taste.discovery-mode"
    private var artistsSubscription: AnyCancellable?
    private var sendTask: Task<Void, Never>?
    private var requestGeneration = UUID()
    private let resolver: SpotifySearchClient
    private weak var auth: SpotifyAuthModel?
    private weak var playback: SpotifyPlaybackModel?
    private var subscriptions: [AnyCancellable] = []
    private var playTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var retryAfter: Date?
    private var lastSelectedID: String?
    private var currentPrompt: String?

    init(backend: MochiBackendClient? = nil, resolver: SpotifySearchClient? = nil, artists: MochiArtistPreferencesModel? = nil, defaults: UserDefaults? = nil) {
        self.backend = backend ?? MochiBackendClient()
        self.resolver = resolver ?? SpotifySearchClient()
        self.artists = artists ?? MochiArtistPreferencesModel(backend: backend)
        self.defaults = defaults
        if !self.artists.names.isEmpty, let saved = defaults?.string(forKey: Self.modeKey), let mode = MochiDiscoveryMode(rawValue: saved) {
            discoveryMode = mode
        }
        artistsSubscription = self.artists.$names.dropFirst().sink { [weak self] names in
            if names.isEmpty { self?.discoveryMode = .balanced }
        }
    }

    func configure(using auth: SpotifyAuthModel, playback: SpotifyPlaybackModel) {
        guard self.auth !== auth || self.playback !== playback else { return }
        self.auth = auth; self.playback = playback
        subscriptions = [auth.$isConnected.removeDuplicates().sink { [weak self] connected in
            guard let self else { return }
            if !connected && self.isConnected { self.reset() }
            self.isConnected = connected
        }, playback.$isBusy.removeDuplicates().sink { [weak self] busy in self?.isPlaybackBusy = busy },
        playback.$usesDesktopPlayer.removeDuplicates().sink { [weak self] desktop in
            guard let self else { return }
            if self.usesDesktopPlayer != desktop { self.reset() }
            self.usesDesktopPlayer = desktop
        }]
    }

    var canSubmit: Bool { !isSending && !isStarting && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var summary: String { preferences.joined(separator: " · ") }
    var hasSelectedTracks: Bool { selection?.tracks.isEmpty == false }

    func submit(_ choice: String? = nil) {
        let text = (choice ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !isStarting else { return }
        if choice != nil { draft = text }
        sendRequest(text)
    }

    func canDiscoverSimilar(_ track: MochiSelectedTrack) -> Bool {
        !isSending && !isStarting && !isPlaybackBusy && !feedbackBusy
            && selection?.catalogKind == .lastfmLive && selection?.requestID != nil && currentPrompt != nil
            && !dislikedTracks.contains(track.id) && selection?.tracks.contains(where: { $0.id == track.id }) == true
    }

    func moreLikeThis(_ track: MochiSelectedTrack) {
        guard canDiscoverSimilar(track), let selection, let requestID = selection.requestID,
              let canonical = selection.tracks.first(where: { $0.id == track.id }), let currentPrompt else { return }
        sendRequest(currentPrompt, seed: canonical, seedRequestID: requestID)
    }

    private func sendRequest(_ text: String, seed: MochiSelectedTrack? = nil, seedRequestID: String? = nil) {
        requestGeneration = UUID()
        feedbackTask?.cancel(); feedbackTask = nil; feedbackBusy = false
        isSending = true
        if seed == nil {
            selection = nil; currentPrompt = nil; similarTo = nil
            resolvedTracks = [:]; likedTracks = []; dislikedTracks = []
        }
        feedbackMessage = nil; feedbackError = nil; resultNotice = nil
        reply = seed.map { "Finding songs like \($0.title)…" } ?? "Sending your request…"
        let generation = requestGeneration
        let favoriteArtists = artists.names
        let mode = favoriteArtists.isEmpty ? MochiDiscoveryMode.balanced : discoveryMode
        sendTask = Task { [weak self, backend] in
            do {
                let response: MochiListeningResponse
                if let seed, let seedRequestID {
                    response = try await backend.moreLikeThis(seed, requestID: seedRequestID, prompt: text)
                } else {
                    response = try await backend.send(prompt: text, favoriteArtists: favoriteArtists, discoveryMode: mode)
                }
                try Task.checkCancellation()
                guard let self, self.requestGeneration == generation else { return }
                if seed != nil && response.selection?.tracks.isEmpty != false {
                    // Failed/empty refinement leaves the existing songs playable.
                    self.reply = response.clarification ?? response.selection?.message ?? "No new similar songs. Try another song."
                    self.resultNotice = self.reply
                    self.isSending = false; self.sendTask = nil
                    return
                }
                if seed == nil { self.preferences = Array((self.preferences + [response.receivedPrompt]).suffix(20)) }
                self.selection = response.selection
                self.currentPrompt = response.receivedPrompt
                self.similarTo = seed?.title
                self.resolvedTracks = [:]; self.likedTracks = []; self.dislikedTracks = []
                if seed == nil && self.draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { self.draft = "" }
                if let question = response.clarification {
                    self.reply = question
                } else if let selection = response.selection {
                    if selection.tracks.isEmpty {
                        self.reply = selection.message ?? "No matching tracks. Try another request."
                    } else {
                        let summary = response.intent?.summary ?? ""
                        let title = selection.catalogKind == .fictionalSample ? "Sample matches" : (seed == nil ? "Music matches" : "Similar matches")
                        self.reply = summary.isEmpty ? title : "\(title)\n\(summary)"
                    }
                } else if let summary = response.intent?.summary, !summary.isEmpty {
                    self.reply = "Request received.\n\(summary)"
                } else {
                    self.reply = "Request received.\nRecommendations are coming next."
                }
                if response.selection?.catalogKind == .lastfmLive, self.hasSelectedTracks {
                    if let auth = self.auth, auth.isConnected {
                        await self.resolveAndPlay(generation: generation, auth: auth)
                        guard self.requestGeneration == generation else { return }
                    } else {
                        self.reply = "Music matches ready.\nChoose Find on Spotify in a song’s menu."
                    }
                }
                self.isSending = false
                self.sendTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.requestGeneration == generation else { return }
                self.reply = (error as? MochiBackendError)?.errorDescription ?? "Couldn't send your request. Try again."
                self.resultNotice = self.reply
                self.isSending = false
                self.sendTask = nil
            }
        }
    }

    private func check(_ generation: UUID, auth: SpotifyAuthModel, connection: Int) throws {
        try Task.checkCancellation()
        guard generation == requestGeneration, auth.isConnected, connection == auth.connectionVersion else { throw CancellationError() }
    }

    private func resolveAndPlay(generation: UUID, auth: SpotifyAuthModel) async {
        guard let playback, let selection, selection.catalogKind == .lastfmLive else { return }
        let connection = auth.connectionVersion
        var failures: [String] = []
        resultNotice = nil
        if let retryAfter, retryAfter > Date() {
            reply = "Spotify is limiting requests. Try again later."
            resultNotice = reply
            return
        }
        do {
            var token = try await auth.validAccessToken()
            try check(generation, auth: auth, connection: connection)
            let deadline = Date().addingTimeInterval(25)
            for track in selection.tracks {
                guard Date() < deadline else { failures.append("Spotify matching reached its time limit."); break }
                reply = "Finding Spotify matches…"
                do {
                    let match: SpotifySearchTrack?
                    do { match = try await resolver.resolve(track, accessToken: token, timeout: deadline.timeIntervalSinceNow) }
                    catch SpotifySearchError.unauthorized {
                        try check(generation, auth: auth, connection: connection)
                        token = try await auth.validAccessToken(forceRefresh: true)
                        try check(generation, auth: auth, connection: connection)
                        guard Date() < deadline else { throw URLError(.timedOut) }
                        match = try await resolver.resolve(track, accessToken: token, timeout: deadline.timeIntervalSinceNow)
                    }
                    try check(generation, auth: auth, connection: connection)
                    if let match { resolvedTracks[track.id] = match }
                } catch {
                    try check(generation, auth: auth, connection: connection)
                    switch error {
                    case SpotifySearchError.rateLimited(let seconds), SpotifySearchError.quotaExceeded(let seconds):
                        retryAfter = Date().addingTimeInterval(seconds)
                        reply = error.localizedDescription
                        resultNotice = reply
                        return
                    case SpotifySearchError.forbidden, SpotifySearchError.unauthorized:
                        reply = error.localizedDescription
                        resultNotice = reply
                        return
                    default: failures.append(error.localizedDescription)
                    }
                }
            }
            try check(generation, auth: auth, connection: connection)
            var seen = Set<String>()
            let matched = selection.tracks.filter { source in
                guard let match = resolvedTracks[source.id] else { return false }
                return seen.insert(match.uri).inserted
            }
            guard !matched.isEmpty else {
                reply = failures.first ?? "No confident Spotify matches.\nTry another request."
                resultNotice = reply
                return
            }
            // Spotify's desktop scripting interface cannot create a queue.
            let toPlay = playback.usesDesktopPlayer ? Array(matched.prefix(1)) : matched
            let uris = toPlay.compactMap { resolvedTracks[$0.id]?.uri }
            reply = "Starting your music…"
            let accepted = await playback.startTracks(uris: uris, using: auth)
            try check(generation, auth: auth, connection: connection)
            let startedMessage = playback.usesDesktopPlayer ? "Playing the first match on Spotify desktop." : "Started \(matched.count) of \(selection.tracks.count) matches."
            reply = playback.errorMessage ?? (accepted ? startedMessage : "Playback is busy. Try a play button.")
            if !accepted || playback.errorMessage != nil || (!playback.usesDesktopPlayer && matched.count < selection.tracks.count) { resultNotice = reply }
            if accepted, let first = toPlay.first {
                // Record our selection, not imported Spotify history or inferred listens.
                recordSelection(first, generation: generation)
            }
        } catch {
            guard !(error is CancellationError), generation == requestGeneration else { return }
            reply = error.localizedDescription
            resultNotice = reply
        }
    }

    func canPlay(_ track: MochiSelectedTrack) -> Bool {
        isConnected && !isSending && !isStarting && !isPlaybackBusy && !dislikedTracks.contains(track.id) && resolvedTracks[track.id] != nil
            && (retryAfter.map { $0 <= Date() } ?? true)
    }

    var canPlayMatches: Bool {
        isConnected && !isSending && !isStarting && !isPlaybackBusy
            && selection?.catalogKind == .lastfmLive && hasSelectedTracks
            && (retryAfter.map { $0 <= Date() } ?? true)
    }

    func playMatches() {
        guard canPlayMatches, let auth else { return }
        let generation = requestGeneration
        isStarting = true
        resultNotice = nil
        playTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.requestGeneration { self.isStarting = false; self.playTask = nil } }
            await self.resolveAndPlay(generation: generation, auth: auth)
        }
    }

    func play(_ track: MochiSelectedTrack) {
        guard canPlay(track), let match = resolvedTracks[track.id], let auth, let playback,
              selection?.tracks.contains(where: { $0.id == track.id }) == true else { return }
        let generation = requestGeneration
        let connection = auth.connectionVersion
        isStarting = true
        reply = "Starting your music…"; resultNotice = nil
        playTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.requestGeneration { self.isStarting = false; self.playTask = nil } }
            let accepted = await playback.startTrack(uri: match.uri, using: auth)
            guard generation == self.requestGeneration, auth.isConnected, connection == auth.connectionVersion else { return }
            self.reply = playback.errorMessage ?? (accepted ? "Playing \(track.title)." : "Playback is busy. Try again.")
            self.resultNotice = accepted && playback.errorMessage == nil ? nil : self.reply
            if accepted { self.recordSelection(track, generation: generation) }
        }
    }

    private func recordSelection(_ track: MochiSelectedTrack, generation: UUID) {
        guard generation == requestGeneration else { return }
        let event: MochiBackendClient.FeedbackEvent = lastSelectedID == track.id ? .replay : .select
        lastSelectedID = track.id
        feedback(track, event: event)
    }

    func feedback(_ track: MochiSelectedTrack, event: MochiBackendClient.FeedbackEvent) {
        guard !feedbackBusy, let selection, selection.catalogKind == .lastfmLive,
              let requestID = selection.requestID, selection.tracks.contains(where: { $0.id == track.id }) else { return }
        let generation = requestGeneration
        feedbackBusy = true; feedbackMessage = nil; feedbackError = nil
        feedbackTask = Task { [weak self, backend] in
            guard let self else { return }
            defer { if generation == self.requestGeneration { self.feedbackBusy = false; self.feedbackTask = nil } }
            do {
                try await backend.feedback(requestID: requestID, trackID: track.id, event: event)
                guard generation == self.requestGeneration, !Task.isCancelled else { return }
                if event == .like { self.likedTracks.insert(track.id); self.dislikedTracks.remove(track.id) }
                if event == .dislike { self.dislikedTracks.insert(track.id); self.likedTracks.remove(track.id) }
                self.feedbackMessage = "Taste saved. Future requests will use it."
            } catch {
                guard generation == self.requestGeneration, !Task.isCancelled else { return }
                self.feedbackMessage = "Couldn't save taste. Try again."
                self.feedbackError = self.feedbackMessage
            }
        }
    }

    func clearTaste() {
        guard !feedbackBusy, !isSending, !isStarting else { return }
        let generation = requestGeneration
        feedbackBusy = true
        feedbackError = nil
        feedbackTask = Task { [weak self, backend] in
            guard let self else { return }
            defer { if generation == self.requestGeneration { self.feedbackBusy = false; self.feedbackTask = nil } }
            do {
                try await backend.clearTaste()
                guard generation == self.requestGeneration, !Task.isCancelled else { return }
                self.likedTracks = []; self.dislikedTracks = []; self.lastSelectedID = nil
                self.artists.clear()
                self.feedbackMessage = "Taste memory cleared."
            } catch {
                guard generation == self.requestGeneration, !Task.isCancelled else { return }
                self.feedbackMessage = "Couldn't clear taste. Try again."
                self.feedbackError = self.feedbackMessage
            }
        }
    }

    func cancelRequest() {
        guard isSending else { return }
        requestGeneration = UUID()
        sendTask?.cancel(); sendTask = nil
        isSending = false
        resultNotice = nil
        reply = hasSelectedTracks ? "Music matches ready." : "Request cancelled. You can edit and try again."
    }

    func reset() {
        requestGeneration = UUID()
        sendTask?.cancel()
        playTask?.cancel(); feedbackTask?.cancel()
        playTask = nil; feedbackTask = nil
        sendTask = nil
        isSending = false
        draft = ""
        preferences = []
        selection = nil
        currentPrompt = nil; similarTo = nil
        resolvedTracks = [:]; likedTracks = []; dislikedTracks = []
        isStarting = false; feedbackBusy = false; feedbackMessage = nil; feedbackError = nil; resultNotice = nil
        reply = "What do you feel like\nlistening to?"
    }
}

// MARK: - Companion card

struct MochiCompanionCard: View {
    static let size = CGSize(width: 300, height: 150)
    static let searchSize = CGSize(width: 300, height: 340)
    static let artistSize = CGSize(width: 300, height: 320)
    static func artistEditorSize(count: Int) -> CGSize {
        count == 3 ? CGSize(width: 300, height: 210) : artistSize
    }
    var cardSize: CGSize { artists.isPresented ? Self.artistEditorSize(count: artists.names.count) : (request.isSearchPresented || request.hasSelectedTracks ? Self.searchSize : Self.size) }
    @ObservedObject var request: MochiRequestModel
    @ObservedObject var search: SpotifySearchModel
    @ObservedObject var artists: MochiArtistPreferencesModel
    var onClose: () -> Void
    @FocusState private var composerFocused: Bool
    @State private var modePickerPresented = false
    @State private var optionsPresented = false
    @State private var selectedTrack: MochiSelectedTrack?

    init(request: MochiRequestModel, search: SpotifySearchModel, onClose: @escaping () -> Void) {
        self.request = request; self.search = search; self.artists = request.artists; self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                if artists.isPresented || request.isSearchPresented {
                    Text(artists.isPresented ? "Favorite artists" : "Search Spotify")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    discoveryPicker
                    Spacer(minLength: 0)
                }
                if !artists.isPresented {
                    optionsButton
                }
                Button(action: onClose) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .help("Close Mochi")
                    .accessibilityLabel("Close Mochi")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))

            if artists.isPresented {
                MochiArtistPreferencesView(artists: artists)
            } else if request.isSearchPresented {
                searchContent
            } else if request.hasSelectedTracks {
                selectionContent
            } else if request.preferences.isEmpty && !request.isSending && request.reply == "What do you feel like\nlistening to?" {
                HStack(spacing: 6) {
                    choice("Focus")
                    choice("Unwind")
                    choice("Surprise me")
                }
            } else {
                HStack(spacing: 6) {
                    Text(request.reply)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        .help(request.reply).accessibilityIdentifier("mochiReply")
                    if request.isSending {
                        Button("Cancel") { request.cancelRequest() }
                            .font(.system(size: 10)).buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 0)

            if !artists.isPresented {
                HStack(spacing: 8) {
                    TextField("", text: composerText, axis: .vertical)
                        .id(request.isSearchPresented)
                        .font(.system(size: 11))
                        .textFieldStyle(.plain)
                        .lineLimit(1...2)
                        .focused($composerFocused)
                        .onSubmit { submit() }
                        .onChange(of: composerText.wrappedValue) { _, text in
                            let limit = request.isSearchPresented ? 200 : 500
                            if text.count > limit { composerText.wrappedValue = String(text.prefix(limit)) }
                        }
                        .overlay(alignment: .leading) {
                            if composerText.wrappedValue.isEmpty {
                                Text(request.isSearchPresented
                                     ? (search.kind == .song ? "Song title…" : "Artist name…") : "Mood, artist, or song…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel(request.isSearchPresented ? "Search query" : "Describe what you want to listen to")
                        .accessibilityIdentifier("mochiComposer")

                    Button { submit() } label: {
                        Group {
                            if !request.isSearchPresented && request.isSending {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: request.isSearchPresented ? "magnifyingglass" : "arrow.up")
                            }
                        }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.07), in: Circle())
                    }
                    .buttonStyle(MochiPressStyle())
                    .disabled(request.isSearchPresented ? !search.canSubmit : !request.canSubmit)
                    .help(request.isSearchPresented ? "Search Spotify" : "Send listening request")
                    .accessibilityLabel(request.isSearchPresented ? "Search Spotify" : "Send listening request")
                }
                .padding(.horizontal, 10)
                .frame(height: 42)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
            }
        }
        .padding(12)
        .frame(width: cardSize.width, height: cardSize.height)
        .foregroundStyle(.primary)
        .modifier(CompanionMaterial())
        .onExitCommand {
            if selectedTrack != nil { selectedTrack = nil }
            else if optionsPresented { optionsPresented = false }
            else if modePickerPresented { modePickerPresented = false }
            else { onClose() }
        }
        .onChange(of: request.isSending) { _, busy in if busy { selectedTrack = nil; optionsPresented = false } }
        .task(id: "\(request.isSearchPresented)-\(artists.isPresented)") {
            composerFocused = false
            await Task.yield()
            composerFocused = !artists.isPresented
        }
    }

    private var composerText: Binding<String> { request.isSearchPresented ? $search.query : $request.draft }

    private var optionsButton: some View {
        Button { modePickerPresented = false; optionsPresented.toggle() } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 24)
        }
        .help("Search, favorite artists, and listening options")
        .accessibilityLabel("Listening options")
        .popover(isPresented: $optionsPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                utilityAction(request.isSearchPresented ? "Back to listening request" : "Search songs and artists", symbol: "magnifyingglass",
                              disabled: request.isSending || request.isStarting) { request.isSearchPresented.toggle() }
                utilityAction("Edit favorite artists", symbol: "heart", disabled: request.isSending || request.isStarting || request.feedbackBusy) { artists.present() }
                utilityAction(request.isSearchPresented ? "Clear search" : "New listening request", symbol: "arrow.counterclockwise",
                              disabled: request.isSearchPresented && search.isStarting) {
                    if request.isSearchPresented { search.reset() } else { request.reset() }
                }
                if request.isConnected && request.hasSelectedTracks {
                    utilityAction(request.usesDesktopPlayer ? "Play first match" : "Play matches", symbol: "play", disabled: !request.canPlayMatches) { request.playMatches() }
                }
                Divider().padding(.vertical, 4)
                utilityAction("Forget taste memory", symbol: "eraser", disabled: request.feedbackBusy || request.isSending || request.isStarting) { request.clearTaste() }
            }.font(.system(size: 12)).padding(6).frame(width: 225)
        }
    }

    private func utilityAction(_ title: String, symbol: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            // Dismiss before replacing the focused field. A native popover's delayed
            // close animation could otherwise restore the retired composer's responder.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                optionsPresented = false
                action()
                composerFocused = !artists.isPresented
            }
        } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled).accessibilityLabel(title)
    }

    private var discoveryPicker: some View {
        Button { optionsPresented = false; modePickerPresented.toggle() } label: {
            HStack(spacing: 5) {
                Text(request.discoveryMode.title).font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.frame(height: 24).contentShape(Rectangle())
        }
        .help("Choose how familiar or adventurous your next request should be")
        .accessibilityLabel("Music discovery preference")
        .accessibilityValue(request.discoveryMode.title)
        .accessibilityIdentifier("mochiDiscoveryPicker")
        .disabled(request.isSending || request.isStarting || request.feedbackBusy)
        .popover(isPresented: $modePickerPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(MochiDiscoveryMode.allCases) { mode in
                    Button {
                        request.discoveryMode = mode
                        modePickerPresented = false
                        composerFocused = true
                    } label: {
                        HStack {
                            Text(mode.title)
                            Spacer()
                            if request.discoveryMode == mode { Image(systemName: "checkmark") }
                        }.padding(8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(mode != .balanced && artists.names.isEmpty)
                    .help(mode.detail)
                    .accessibilityLabel("\(mode.title) recommendations")
                    .accessibilityValue(request.discoveryMode == mode ? "Selected" : "Not selected")
                    .accessibilityIdentifier("mochiDiscoveryMode-\(mode.rawValue)")
                }
                Text(artists.names.isEmpty ? "Add a favorite artist with the heart button to use Familiar or Discover." : "Applies to your next request.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(8)
            }.font(.system(size: 12)).padding(5).frame(width: 220)
        }
        .onChange(of: request.isSending) { _, busy in if busy { modePickerPresented = false } }
        .onChange(of: request.isStarting) { _, busy in if busy { modePickerPresented = false } }
        .onChange(of: request.feedbackBusy) { _, busy in if busy { modePickerPresented = false } }
        .onChange(of: artists.isPresented) { _, editing in if editing { modePickerPresented = false } }
        .onChange(of: request.isSearchPresented) { _, searching in if searching { modePickerPresented = false } }
    }

    private func submit() {
        if request.isSearchPresented { search.search() } else { request.submit() }
    }

    private var selectionContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            if request.isSending || request.isStarting || request.resultNotice != nil {
                HStack(spacing: 6) {
                    Text(request.resultNotice ?? request.reply).font(.system(size: 11)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(request.resultNotice ?? request.reply).accessibilityIdentifier("mochiReply")
                    if request.isSending {
                        Button("Cancel") { request.cancelRequest() }.font(.system(size: 10)).buttonStyle(.plain)
                    }
                }.foregroundStyle(.secondary)
            }
            if let seed = request.similarTo {
                Text("More like \(seed)").font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).help("More like \(seed)").accessibilityIdentifier("mochiSimilarSeed")
            }
            if request.selection?.catalogKind == .fictionalSample {
                Text("Fictional sample tracks").font(.system(size: 10)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("mochiSampleCatalog")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(request.selection?.tracks ?? []) { track in
                        HStack(spacing: 4) {
                            if request.selection?.catalogKind == .lastfmLive && request.isConnected {
                                Button { request.play(track) } label: { songLabel(track) }
                                    .buttonStyle(.plain).disabled(!request.canPlay(track))
                                    .accessibilityLabel("Play \(track.title)")
                                    .help("Play \(track.title) by \(track.artist)")
                            } else {
                                songLabel(track)
                            }
                            if request.selection?.catalogKind == .lastfmLive { songOptions(track) }
                        }
                        .padding(.vertical, 5).padding(.horizontal, 3)
                        .overlay(alignment: .bottom) { Color.primary.opacity(0.07).frame(height: 0.5) }
                        .help("\(track.title)\n\(track.artist)\n\(track.description)")
                        .accessibilityElement(children: request.selection?.catalogKind == .lastfmLive ? .contain : .combine)
                        .accessibilityIdentifier("mochiSelectedTrack-\(track.id)")
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if request.selection?.catalogKind == .lastfmLive {
                HStack {
                    Link("Last.fm", destination: URL(string: "https://www.last.fm")!)
                        .accessibilityIdentifier("mochiDiscoverySource")
                        .help(request.selection?.warnings?.joined(separator: "\n") ?? "Music discovered through Last.fm and ranked by Mochi")
                    Spacer()
                    if let mode = request.selection?.discoveryMode, mode != request.discoveryMode {
                        Text(mode.title).accessibilityLabel("\(mode.title) picks")
                            .help("The mode used for these songs. The dropdown applies to your next request.")
                            .accessibilityIdentifier("mochiAppliedDiscoveryMode")
                    }
                }.font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if let message = request.feedbackError {
                Text(message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
        }.frame(maxHeight: .infinity)
    }

    private func songLabel(_ track: MochiSelectedTrack) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
            Text(track.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if track.bpm != nil || track.vocals != nil || track.energy != nil {
                Text(track.details).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private func songOptions(_ track: MochiSelectedTrack) -> some View {
        Button { optionsPresented = false; modePickerPresented = false; selectedTrack = track } label: {
            Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 28, height: 30)
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .help("Like, dislike, more like this, and Spotify options")
        .accessibilityLabel("Options for \(track.title)")
        .accessibilityIdentifier("mochiSongOptions-\(track.id)")
        .popover(isPresented: Binding(get: { selectedTrack?.id == track.id }, set: { if !$0 { selectedTrack = nil } }), arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 2) {
                songAction(request.likedTracks.contains(track.id) ? "Liked" : "Like", symbol: request.likedTracks.contains(track.id) ? "hand.thumbsup.fill" : "hand.thumbsup",
                           accessibilityLabel: "Like \(track.title)", disabled: request.feedbackBusy || request.isSending || request.isStarting) { request.feedback(track, event: .like) }
                songAction(request.dislikedTracks.contains(track.id) ? "Disliked" : "Dislike", symbol: request.dislikedTracks.contains(track.id) ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                           accessibilityLabel: "Dislike \(track.title)", disabled: request.feedbackBusy || request.isSending || request.isStarting) { request.feedback(track, event: .dislike) }
                songAction("More like this", symbol: "sparkles", accessibilityLabel: "More like \(track.title)", disabled: !request.canDiscoverSimilar(track)) { request.moreLikeThis(track) }
                Divider().padding(.vertical, 4)
                if let url = track.spotifySearchURL { Link("Find on Spotify", destination: url).padding(8) }
                if let url = track.lastfmURL { Link("Open on Last.fm", destination: url).padding(8) }
            }.font(.system(size: 12)).padding(6).frame(width: 190)
        }
    }

    private func songAction(_ title: String, symbol: String, accessibilityLabel: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button { selectedTrack = nil; action() } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled).accessibilityLabel(accessibilityLabel)
    }

    private var searchContent: some View {
        VStack(spacing: 8) {
            Picker("Search by", selection: $search.kind) {
                ForEach(SpotifySearchKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
            }
            .pickerStyle(.segmented).controlSize(.small).labelsHidden()
            .disabled(search.isStarting)

            if search.isSearching {
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    ProgressView().controlSize(.small)
                    Text("Searching Spotify…").font(.system(size: 11))
                    Button("Cancel search") { search.cancelSearch() }.font(.system(size: 11))
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if search.results.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Image(systemName: "music.note.list").font(.system(size: 22)).foregroundStyle(.secondary)
                    Text(search.isConnected
                         ? "Find a song, or choose Artists\nto find tracks by an artist."
                         : "Connect Spotify from the menu bar\nto find and play songs.")
                        .font(.system(size: 11)).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(search.results) { track in resultRow(track) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let message = search.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).help(message)
                    .accessibilityIdentifier("mochiSearchMessage")
            }
        }.frame(maxHeight: .infinity)
    }

    private func resultRow(_ track: SpotifySearchTrack) -> some View {
        HStack(spacing: 4) {
            Button { search.play(track) } label: {
                HStack(spacing: 8) {
                    AsyncImage(url: track.artworkURL) { image in image.resizable().scaledToFit() } placeholder: {
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white.opacity(0.3))
                    }.frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(track.artistNames).font(.system(size: 10)).lineLimit(1)
                        Text(track.canPlay ? track.album.name : "Unavailable in your account")
                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if search.startingTrackID == track.id {
                        ProgressView().controlSize(.mini).frame(width: 16)
                    } else {
                        Image(systemName: "play.fill").font(.system(size: 9)).frame(width: 16)
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!search.canPlay(track))
            .opacity(track.canPlay ? 1 : 0.55)
            .help("\(track.name)\n\(track.artistNames)\n\(track.album.name)")
            .accessibilityLabel("Play \(track.name) by \(track.artistNames)")
            Link(destination: track.spotifyURL) {
                Image(systemName: "arrow.up.right").font(.system(size: 9)).frame(width: 18, height: 28)
            }
            .foregroundStyle(.secondary)
            .help("Open in Spotify")
            .accessibilityLabel("Open \(track.name) in Spotify")
        }
        .padding(6)
        .background(Color.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func choice(_ title: String) -> some View {
        Button { request.submit(title); composerFocused = true } label: {
            Text(title).font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).frame(height: 26).contentShape(Capsule())
        }
        .buttonStyle(MochiPressStyle())
        .disabled(request.isSending || request.isStarting)
    }
}

private struct MochiPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(reduceMotion ? .easeOut(duration: 0.08) : .spring(response: configuration.isPressed ? 0.18 : 0.22, dampingFraction: 0.86), value: configuration.isPressed)
    }
}

private struct CompanionMaterial: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
    }
}

// MARK: - Native vector rendering of design/mochi.svg

enum MochiMascotActivity {
    case idle, curious, thinking
}

// Retarget from the current pose, so cancel/retry and rapid edits never snap back to zero.
struct MochiMascotActivityMotion {
    private(set) var activity = MochiMascotActivity.idle
    private var from = SIMD2<Double>.zero
    private var target = SIMD2<Double>.zero
    private var startedAt: TimeInterval = 0

    mutating func set(_ activity: MochiMascotActivity, at time: TimeInterval) {
        guard activity != self.activity else { return }
        from = values(at: time)
        target = activity == .curious ? SIMD2(1, 0) : (activity == .thinking ? SIMD2(0, 1) : .zero)
        startedAt = time
        self.activity = activity
    }

    func values(at time: TimeInterval, animate: Bool = true) -> SIMD2<Double> {
        guard animate else { return target }
        let progress = min(max((time - startedAt) / 0.22, 0), 1)
        let eased = progress * progress * (3 - 2 * progress)
        return from + (target - from) * eased
    }
}

struct MochiMascotView: View {
    var isAnimating = true
    var isHovered = false
    var isHeld = false
    var isEngaged = false
    var isMusicPlaying = false
    var dragLean: CGFloat = 0
    var hoverStartedAt: TimeInterval?
    var releasedAt: TimeInterval?
    var idleStartedAt = Date.timeIntervalSinceReferenceDate
    var wakeStartedAt: TimeInterval?
    var wakeStrength: CGFloat = 0
    var activityMotion = MochiMascotActivityMotion()
    var celebrationStartedAt: TimeInterval?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30, paused: !isAnimating)) { timeline in
            MochiMascotArtwork(pose: isAnimating
                ? MochiMascotPose.at(time: timeline.date.timeIntervalSinceReferenceDate, isMusicPlaying: isMusicPlaying,
                                    isHovered: isHovered, isHeld: isHeld, isEngaged: isEngaged, dragLean: dragLean,
                                    hoverStartedAt: hoverStartedAt, releasedAt: releasedAt,
                                    idleStartedAt: idleStartedAt, wakeStartedAt: wakeStartedAt,
                                    wakeStrength: wakeStrength, activityMotion: activityMotion,
                                    celebrationStartedAt: celebrationStartedAt, animate: !reduceMotion)
                : MochiMascotPose())
        }
        .accessibilityHidden(true)
    }
}

// Each pose changes the body, face and hands independently. All motion stays inside the panel.
struct MochiMascotPose {
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var tilt: CGFloat = 0
    var lift: CGFloat = 0
    var lookX: CGFloat = 0
    var eyeHeight: CGFloat = 1
    var eyeWidth: CGFloat = 1
    var happyEyes: CGFloat = 0
    var smileDepth: CGFloat = 5
    var mouthOpen: CGFloat = 0
    var cheeks: CGFloat = 0
    var leftWave: CGFloat = 0
    var rightWave: CGFloat = 0
    var closedEyes: CGFloat = 0
    var sleepAmount: CGFloat = 0
    var sleepPhase: CGFloat = 0

    static let sleepDelay: TimeInterval = 90

    static func at(time: TimeInterval, isMusicPlaying: Bool = false,
                   isHovered: Bool = false, isHeld: Bool = false, isEngaged: Bool = false,
                   dragLean: CGFloat = 0, hoverStartedAt: TimeInterval? = nil,
                   releasedAt: TimeInterval? = nil, idleStartedAt: TimeInterval? = nil,
                   wakeStartedAt: TimeInterval? = nil, wakeStrength: CGFloat = 0,
                   activityMotion: MochiMascotActivityMotion = .init(),
                   celebrationStartedAt: TimeInterval? = nil, animate: Bool = true) -> Self {
        var pose = Self()
        let idleDuration = idleStartedAt.map { max(0, time - $0) } ?? 0
        let sleep = !isHovered && !isHeld && !isEngaged
            ? keyframe(idleDuration, [(0, 0), (sleepDelay, 0), (sleepDelay + 3, 1)]) : 0
        if !animate {
            // Reduce Motion still permits the sleep state, with a static pose and static z's.
            if isMusicPlaying { pose.happyEyes = 1; pose.smileDepth = 17 }
            if activityMotion.activity == .curious { pose.eyeWidth = 1.2; pose.smileDepth = 9 }
            if activityMotion.activity == .thinking { pose.eyeHeight = 0.8; pose.smileDepth = 1 }
            if sleep > 0 {
                pose.scaleX = 1.07
                pose.scaleY = 0.85
                pose.closedEyes = 1
                pose.sleepAmount = 1
                pose.happyEyes = 0
                pose.smileDepth = 5
            }
            return pose
        }
        let reacting = isActive(hoverStartedAt, at: time, duration: 1.5)
            || isActive(releasedAt, at: time, duration: 0.7)
            || isActive(wakeStartedAt, at: time, duration: 1.2)
            || isActive(celebrationStartedAt, at: time, duration: 0.8)
        let listening = isMusicPlaying && !isHovered && !isHeld && !isEngaged && !reacting
        let breath = CGFloat(sin(time * .pi / 2.4))
        pose.scaleX = 1 - breath * 0.045
        pose.scaleY = 1 + breath * 0.055
        pose.tilt = CGFloat(sin(time * .pi / 4.5)) * 2
        // A short glance left and right, then back to the center.
        pose.lookX = keyframe(time.truncatingRemainder(dividingBy: 11),
                             [(0, 0), (4, 0), (4.5, -8), (5.5, -8), (6.1, 8), (7.1, 8), (7.7, 0), (11, 0)])
        let blinkPhase = time.truncatingRemainder(dividingBy: 5.5)
        pose.eyeHeight = keyframe(blinkPhase, [(0, 1), (0.09, 0.08), (0.18, 1), (5.5, 1)])
        if listening {
            // A steady party rhythm: two squash-and-stretch bounces per side-to-side sway.
            let beat = time * 2 * .pi / 1.8
            let landing = CGFloat(cos(beat * 2))
            pose.scaleX = 1 + landing * 0.1
            pose.scaleY = 1 - landing * 0.14
            pose.tilt = CGFloat(sin(beat)) * 14
            pose.lift = (1 - landing) * 9
            pose.lookX = 0
            pose.happyEyes = 1
            pose.smileDepth = 17
            pose.cheeks = 0.22
            let sway = CGFloat(sin(beat))
            pose.leftWave = 45 + sway * 35
            pose.rightWave = -(45 - sway * 35)
        }

        if sleep > 0 {
            let slowBreath = CGFloat(sin(time * .pi / 4))
            pose.scaleX += (1.07 - slowBreath * 0.012 - pose.scaleX) * sleep
            pose.scaleY += (0.85 + slowBreath * 0.018 - pose.scaleY) * sleep
            pose.tilt += (-3 + slowBreath * 0.5 - pose.tilt) * sleep
            pose.lookX *= 1 - sleep
            pose.eyeHeight *= 1 - sleep * 0.9
            pose.closedEyes = sleep
            pose.sleepAmount = sleep
            pose.sleepPhase = CGFloat(time / 2.8)
            pose.lift *= 1 - sleep
            pose.happyEyes *= 1 - sleep
            pose.cheeks *= 1 - sleep
            pose.leftWave *= 1 - sleep
            pose.rightWave *= 1 - sleep
            pose.smileDepth += (5 - pose.smileDepth) * sleep
            return pose
        }

        if !isMusicPlaying, !isHovered, !isHeld, !isEngaged, let idleStartedAt, time - idleStartedAt >= 26 {
            let age = (time - idleStartedAt).truncatingRemainder(dividingBy: 26)
            if age <= 1.2 {
                // A brief spontaneous hop: crouch, stretch into the air, squash on landing.
                let reaction = keyframe(age, [(0, 0), (0.06, 1), (0.95, 1), (1.2, 0)])
                let width = keyframe(age, [(0, 1), (0.16, 1.18), (0.3, 0.9), (0.55, 0.98), (0.75, 1.2), (1, 1)])
                let height = keyframe(age, [(0, 1), (0.16, 0.78), (0.3, 1.16), (0.55, 1.04), (0.75, 0.8), (1, 1)])
                pose.scaleX += (width - pose.scaleX) * reaction
                pose.scaleY += (height - pose.scaleY) * reaction
                pose.lift = keyframe(age, [(0, 0), (0.18, 0), (0.43, 30), (0.7, 0), (1.2, 0)])
                pose.lookX *= 1 - reaction
                pose.happyEyes = keyframe(age, [(0, 0), (0.2, 0), (0.35, 1), (0.65, 1), (0.9, 0), (1.2, 0)])
                pose.smileDepth += 10 * reaction
            }
        }

        if isHovered {
            pose.lookX = 0
            pose.eyeWidth = 1.3
            pose.eyeHeight *= 1.12
            pose.smileDepth = 15
            pose.cheeks = 0.38
        }
        if let hoverStartedAt {
            let age = time - hoverStartedAt
            if (0...1.5).contains(age) {
                // Crouch, stretch upward, land softly, then wave with a happy expression.
                let reaction = keyframe(age, [(0, 0), (0.06, 1), (1.1, 1), (1.5, 0)])
                let width = keyframe(age, [(0, 1), (0.12, 1.24), (0.25, 0.85), (0.45, 1.04), (0.58, 1.15), (0.8, 1)])
                let height = keyframe(age, [(0, 1), (0.12, 0.74), (0.25, 1.22), (0.45, 0.96), (0.58, 0.84), (0.8, 1)])
                pose.scaleX += (width - pose.scaleX) * reaction
                pose.scaleY += (height - pose.scaleY) * reaction
                pose.lift = keyframe(age, [(0, 0), (0.12, 0), (0.3, 12), (0.48, 0), (1.5, 0)])
                pose.tilt += keyframe(age, [(0, 0), (0.4, 0), (0.6, -7), (0.9, 5), (1.5, 0)])
                pose.happyEyes = keyframe(age, [(0, 0), (0.45, 0), (0.65, 1), (1.1, 1), (1.5, 0)])
                pose.smileDepth = 5 + 12 * keyframe(age, [(0, 0), (0.4, 1), (1.1, 1), (1.5, 0)])
                if age > 0.45 {
                    let wave = (age - 0.45) / 1.05
                    pose.rightWave = -CGFloat(sin(wave * .pi) * (65 + 20 * sin(wave * 4 * .pi)))
                }
            }
        }
        if let releasedAt {
            let age = time - releasedAt
            if (0...0.7).contains(age) {
                pose.scaleX *= keyframe(age, [(0, 1.22), (0.22, 0.94), (0.45, 1.045), (0.7, 1)])
                pose.scaleY *= keyframe(age, [(0, 0.75), (0.22, 1.08), (0.45, 0.96), (0.7, 1)])
            }
        }
        if !isHeld, let wakeStartedAt {
            let age = time - wakeStartedAt
            if (0...1.2).contains(age) {
                let reaction = wakeStrength * keyframe(age, [(0, 1), (0.95, 1), (1.2, 0)])
                let width = keyframe(age, [(0, 1.07), (0.3, 0.88), (0.5, 0.88), (0.8, 1.1), (1.2, 1)])
                let height = keyframe(age, [(0, 0.85), (0.3, 1.16), (0.5, 1.16), (0.8, 0.92), (1.2, 1)])
                pose.scaleX += (width - pose.scaleX) * reaction
                pose.scaleY += (height - pose.scaleY) * reaction
                pose.closedEyes = wakeStrength * keyframe(age, [(0, 1), (0.45, 0.7), (0.65, 0), (0.82, 1), (0.95, 0), (1.2, 0)])
                pose.sleepAmount = wakeStrength * keyframe(age, [(0, 1), (0.3, 0), (1.2, 0)])
                pose.sleepPhase = CGFloat(time / 2.8)
                pose.lift = 0
                pose.rightWave = 0
            }
        }
        if !isHeld, isEngaged || activityMotion.activity == .thinking {
            let activity = activityMotion.values(at: time)
            let release = min(reactionRelease(hoverStartedAt, at: time, duration: 1.5),
                              reactionRelease(releasedAt, at: time, duration: 0.7),
                              reactionRelease(wakeStartedAt, at: time, duration: 1.2),
                              reactionRelease(celebrationStartedAt, at: time, duration: 0.8))
            let curious = CGFloat(activity.x) * release, thinking = CGFloat(activity.y) * release
            let rhythm = CGFloat(sin(time * 2.4))
            pose.scaleX += (0.97 - pose.scaleX) * curious
            pose.scaleY += (1.04 - pose.scaleY) * curious
            pose.tilt += (-6 - pose.tilt) * curious
            pose.lookX += (9 - pose.lookX) * curious
            pose.eyeWidth += (1.2 - pose.eyeWidth) * curious
            pose.smileDepth += (9 - pose.smileDepth) * curious
            pose.scaleX += (1.04 + rhythm * 0.025 - pose.scaleX) * thinking
            pose.scaleY += (0.94 - rhythm * 0.025 - pose.scaleY) * thinking
            pose.tilt += (7 + rhythm * 3 - pose.tilt) * thinking
            pose.lookX += (rhythm * 12 - pose.lookX) * thinking
            pose.eyeHeight *= 1 - thinking * 0.2
            pose.smileDepth += (1 - pose.smileDepth) * thinking
            pose.rightWave += (-30 + rhythm * 8 - pose.rightWave) * thinking
        }
        if !isHeld, !isHovered, let celebrationStartedAt {
            let age = time - celebrationStartedAt
            if (0..<0.8).contains(age) {
                let amount = keyframe(age, [(0, 0), (0.08, 1), (0.5, 1), (0.8, 0)])
                pose.scaleX += (keyframe(age, [(0, 1), (0.14, 1.15), (0.3, 0.91), (0.5, 1.06), (0.8, 1)]) - pose.scaleX) * amount
                pose.scaleY += (keyframe(age, [(0, 1), (0.14, 0.83), (0.3, 1.12), (0.5, 0.94), (0.8, 1)]) - pose.scaleY) * amount
                pose.happyEyes = amount
                pose.smileDepth += (17 - pose.smileDepth) * amount
                pose.cheeks = amount * 0.3
                pose.rightWave += (-55 - pose.rightWave) * amount
            }
        }
        if isHeld {
            pose.scaleX = 0.88
            pose.scaleY = 1.16
            pose.tilt = dragLean * 9
            pose.lift = 0
            pose.lookX = dragLean * 8
            pose.eyeHeight = 1.4
            pose.eyeWidth = 1.35
            pose.happyEyes = 0
            pose.mouthOpen = 1
            pose.cheeks = 0
            pose.rightWave = 0
        }
        return pose
    }

    private static func isActive(_ startedAt: TimeInterval?, at time: TimeInterval, duration: TimeInterval) -> Bool {
        guard let startedAt else { return false }
        return (0..<duration).contains(time - startedAt)
    }

    private static func reactionRelease(_ startedAt: TimeInterval?, at time: TimeInterval, duration: TimeInterval) -> CGFloat {
        guard let startedAt, isActive(startedAt, at: time, duration: duration) else { return 1 }
        return keyframe(time - startedAt, [(0, 0), (duration - 0.22, 0), (duration, 1)])
    }

    private static func keyframe(_ time: TimeInterval, _ frames: [(TimeInterval, CGFloat)]) -> CGFloat {
        guard let first = frames.first, let last = frames.last else { return 0 }
        if time <= first.0 { return first.1 }
        for (left, right) in zip(frames, frames.dropFirst()) where time <= right.0 {
            let progress = CGFloat((time - left.0) / (right.0 - left.0))
            let eased = progress * progress * (3 - 2 * progress)
            return left.1 + (right.1 - left.1) * eased
        }
        return last.1
    }
}

struct MochiMascotArtwork: View {
    let pose: MochiMascotPose

    var body: some View {
        Canvas { context, size in
            // Extra margin contains stretched poses and the waving hand, without changing the hit area.
            let scale = min(size.width / 420, size.height / 360)
            context.translateBy(x: (size.width - 420 * scale) / 2, y: (size.height - 360 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -30, y: -30)
            let markers = context
            context.translateBy(x: 0, y: -pose.lift)
            context.translateBy(x: 240, y: 350)
            context.rotate(by: .degrees(Double(pose.tilt)))
            context.scaleBy(x: pose.scaleX, y: pose.scaleY)
            context.translateBy(x: -240, y: -350)

            // Rotate from roots inside the body, then cover them with the body fill.
            // The hidden overlap keeps large waves attached instead of exposing an open seam.
            for (hand, anchor, angle) in [(MochiArt.leftHand, MochiArt.leftHandRoot, pose.leftWave),
                                          (MochiArt.rightHand, MochiArt.rightHandRoot, pose.rightWave)] {
                var handContext = context
                handContext.translateBy(x: anchor.x, y: anchor.y)
                handContext.rotate(by: .degrees(Double(angle)))
                let handScale = 1 + min(abs(angle) / 65, 1) * 0.6
                handContext.scaleBy(x: handScale, y: handScale)
                handContext.translateBy(x: -anchor.x, y: -anchor.y)
                handContext.fill(hand, with: .color(Color(hex: 0xC8DACE)))
                handContext.stroke(hand, with: .color(Color(hex: 0x8EA69D)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            context.fill(MochiArt.body, with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(hex: 0xE1EADF), location: 0),
                    .init(color: Color(hex: 0xD9E5D9), location: 0.43),
                    .init(color: Color(hex: 0xC8DACE), location: 0.68),
                    .init(color: Color(hex: 0xB6CEC3), location: 0.88),
                    .init(color: Color(hex: 0xA5BCB6), location: 1)
                ]), startPoint: CGPoint(x: 97.9254, y: 109.838), endPoint: CGPoint(x: 126.788, y: 372.605)))
            context.fill(MochiArt.base, with: .color(Color(hex: 0x9DAFAF).opacity(0.3)))

            var face = context
            face.translateBy(x: pose.lookX, y: 0)
            // Keep the sleeping face readable even as the body flattens and breathes.
            let sleepStroke = 5 / min(pose.scaleX, pose.scaleY)
            for x: CGFloat in [190, 290] {
                if pose.closedEyes == 0 {
                    // Preserve the existing awake eyes and happy expression.
                    let height = 22 * pose.eyeHeight
                    let width = 14 * pose.eyeWidth
                    face.fill(Path(ellipseIn: CGRect(x: x - width / 2, y: 244 - height / 2, width: width, height: height)),
                              with: .color(Color.mochiInk.opacity(Double(1 - pose.happyEyes))))
                    let happyEye = Path { p in
                        p.move(to: CGPoint(x: x - 10, y: 245))
                        p.addQuadCurve(to: CGPoint(x: x + 10, y: 245), control: CGPoint(x: x, y: 229))
                    }
                    face.stroke(happyEye, with: .color(Color.mochiInk.opacity(Double(pose.happyEyes))),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    continue
                }
                // One solid contour morphs from an oval to a curved lid; no translucent overlap.
                let closure = pose.closedEyes
                let width = 14 * pose.eyeWidth * (1 - closure) + 20 * closure
                let height = max(sleepStroke, 22 * pose.eyeHeight) * (1 - closure)
                let bend = 3 * pose.closedEyes - 7 * pose.happyEyes * (1 - pose.closedEyes)
                let radiusX = width / 2, radiusY = height / 2
                let curve: CGFloat = 0.5522848
                let eye = Path { p in
                    p.move(to: CGPoint(x: x - radiusX, y: 244))
                    p.addCurve(to: CGPoint(x: x, y: 244 + bend - radiusY),
                               control1: CGPoint(x: x - radiusX, y: 244 + bend / 2 - radiusY * curve),
                               control2: CGPoint(x: x - radiusX * curve, y: 244 + bend - radiusY))
                    p.addCurve(to: CGPoint(x: x + radiusX, y: 244),
                               control1: CGPoint(x: x + radiusX * curve, y: 244 + bend - radiusY),
                               control2: CGPoint(x: x + radiusX, y: 244 + bend / 2 - radiusY * curve))
                    p.addCurve(to: CGPoint(x: x, y: 244 + bend + radiusY),
                               control1: CGPoint(x: x + radiusX, y: 244 + bend / 2 + radiusY * curve),
                               control2: CGPoint(x: x + radiusX * curve, y: 244 + bend + radiusY))
                    p.addCurve(to: CGPoint(x: x - radiusX, y: 244),
                               control1: CGPoint(x: x - radiusX * curve, y: 244 + bend + radiusY),
                               control2: CGPoint(x: x - radiusX, y: 244 + bend / 2 + radiusY * curve))
                    p.closeSubpath()
                }
                face.fill(eye, with: .color(Color.mochiInk))
                if closure > 0 {
                    face.stroke(eye, with: .color(Color.mochiInk),
                                style: StrokeStyle(lineWidth: sleepStroke * closure, lineCap: .round, lineJoin: .round))
                }
            }
            for x: CGFloat in [173, 291] {
                face.fill(Path(ellipseIn: CGRect(x: x, y: 263, width: 20, height: 9)),
                          with: .color(Color(hex: 0xDBAFA9).opacity(Double(pose.cheeks))))
            }
            let smile = Path { p in
                p.move(to: CGPoint(x: 231, y: 243))
                p.addQuadCurve(to: CGPoint(x: 251, y: 243), control: CGPoint(x: 241, y: 243 + pose.smileDepth))
            }
            let sleepWeight = max(pose.sleepAmount, pose.closedEyes)
            let mouthStroke = 3 + (sleepStroke - 3) * sleepWeight
            face.stroke(smile, with: .color(Color.mochiInk.opacity(Double(1 - pose.mouthOpen))),
                        style: StrokeStyle(lineWidth: mouthStroke, lineCap: .round))
            face.fill(Path(ellipseIn: CGRect(x: 235, y: 240, width: 12, height: 14)),
                      with: .color(Color.mochiInk.opacity(Double(pose.mouthOpen))))
            if pose.sleepAmount > 0 {
                for index in 0..<3 {
                    let phase = (pose.sleepPhase + CGFloat(index) / 3 + 0.15).truncatingRemainder(dividingBy: 1)
                    let opacity = pose.sleepAmount * sin(phase * .pi) * 0.8
                    let letter = Text("z").font(.system(size: 20 + phase * 8, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.mochiInk.opacity(Double(opacity)))
                    markers.draw(letter, at: CGPoint(x: 315 + phase * 48, y: 128 - phase * 70))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private enum MochiArt {
    static let body = Path { p in
        p.move(to: CGPoint(x: 236, y: 110))
        p.addCurve(to: CGPoint(x: 367, y: 200), control1: CGPoint(x: 302, y: 107), control2: CGPoint(x: 349, y: 146))
        p.addCurve(to: CGPoint(x: 380, y: 330), control1: CGPoint(x: 379, y: 238), control2: CGPoint(x: 391, y: 294))
        p.addCurve(to: CGPoint(x: 240, y: 372), control1: CGPoint(x: 371, y: 361), control2: CGPoint(x: 336, y: 372))
        p.addCurve(to: CGPoint(x: 104, y: 332), control1: CGPoint(x: 155, y: 372), control2: CGPoint(x: 115, y: 362))
        p.addCurve(to: CGPoint(x: 114, y: 208), control1: CGPoint(x: 91, y: 297), control2: CGPoint(x: 101, y: 248))
        p.addCurve(to: CGPoint(x: 236, y: 110), control1: CGPoint(x: 133, y: 147), control2: CGPoint(x: 173, y: 112))
        p.closeSubpath()
    }
    static let base = Path { p in
        p.move(to: CGPoint(x: 105, y: 340))
        p.addCurve(to: CGPoint(x: 240, y: 361), control1: CGPoint(x: 144, y: 355), control2: CGPoint(x: 184, y: 360))
        p.addCurve(to: CGPoint(x: 376, y: 340), control1: CGPoint(x: 297, y: 362), control2: CGPoint(x: 340, y: 355))
        p.addCurve(to: CGPoint(x: 240, y: 372), control1: CGPoint(x: 363, y: 364), control2: CGPoint(x: 320, y: 372))
        p.addCurve(to: CGPoint(x: 105, y: 340), control1: CGPoint(x: 169, y: 372), control2: CGPoint(x: 124, y: 363))
        p.closeSubpath()
    }
    static let leftHandRoot = CGPoint(x: 112, y: 284)
    static let rightHandRoot = CGPoint(x: 370, y: 284)
    static let leftHand = hand(root: leftHandRoot, angle: atan2(15, -12))
    static let rightHand = hand(root: rightHandRoot, angle: atan2(15, 12))

    private static func hand(root: CGPoint, angle: CGFloat) -> Path {
        // One convex outline avoids a second lobe as the arm rotates.
        // Its six-point root stays covered by the body even at maximum hand scale.
        let shape = Path(roundedRect: CGRect(x: -6, y: -6, width: 32, height: 12), cornerRadius: 6)
        let transform = CGAffineTransform(translationX: root.x, y: root.y).rotated(by: angle)
        return shape.applying(transform)
    }

}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
    static let mochiInk = Color(hex: 0x514951)
    static let mochiMuted = Color(hex: 0x637167)
}

#Preview("Companion") {
    MochiCompanionCard(request: MochiRequestModel(), search: SpotifySearchModel(), onClose: {})
}
