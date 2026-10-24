import Combine
import Foundation

@MainActor
final class SpotifyPlaybackModel: ObservableObject {
    @Published private(set) var state: SpotifyPlaybackState?
    @Published private(set) var isBusy = false
    @Published private(set) var isStale = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var usesDesktopPlayer = false

    private let client: SpotifyPlaybackClient
    private let localClient: any LocalSpotifyControlling
    private let defaults: UserDefaults?
    private var requestVersion = 0
    private var retryAfter: Date?
    private var isRefreshing = false

    init(client: SpotifyPlaybackClient? = nil, localClient: (any LocalSpotifyControlling)? = nil,
         defaults: UserDefaults? = nil) {
        self.client = client ?? SpotifyPlaybackClient()
        self.localClient = localClient ?? LocalSpotifyClient()
        self.defaults = defaults
        self.usesDesktopPlayer = defaults?.bool(forKey: "mochi.spotify.desktop-controls") ?? false
    }

    /// Permission is requested only after an explicit action, never by polling.
    func enableDesktopControls() async {
        guard !isBusy else { return }
        reset()
        usesDesktopPlayer = true
        defaults?.set(true, forKey: "mochi.spotify.desktop-controls")
        _ = await localOperation(refreshDelay: false) { try await self.localClient.authorize() }
    }

    func useWebPlayer() {
        reset()
        usesDesktopPlayer = false
        defaults?.set(false, forKey: "mochi.spotify.desktop-controls")
    }

    func reset() {
        requestVersion += 1
        state = nil
        isBusy = false
        isRefreshing = false
        isStale = false
        errorMessage = nil
        lastUpdatedAt = nil
        // Preserve an account-level rate-limit deadline across local sign-out.
    }

    func canPerform(_ command: SpotifyPlaybackCommand) -> Bool {
        let isCoolingDown = !usesDesktopPlayer && (retryAfter.map { $0 > Date() } ?? false)
        return !isBusy && !isStale && !isCoolingDown && state?.permits(command) == true
    }

    func refresh(using auth: SpotifyAuthModel) async {
        if usesDesktopPlayer {
            guard !isBusy else { return }
            let version = requestVersion
            isRefreshing = true
            isBusy = true; errorMessage = nil
            defer { if version == requestVersion { isBusy = false; isRefreshing = false } }
            do {
                let snapshot = try await localClient.fetchState()
                try Task.checkCancellation()
                guard version == requestVersion else { return }
                update(snapshot)
            } catch {
                guard version == requestVersion, !(error is CancellationError) else { return }
                report(error)
            }
            return
        }
        guard auth.isConnected, !isBusy, readyToRequest() else { return }
        let version = requestVersion
        isRefreshing = true
        isBusy = true
        errorMessage = nil
        defer { if version == requestVersion { isBusy = false; isRefreshing = false } }
        do {
            let state = try await authorized(using: auth) { token in
                try await self.client.fetchState(accessToken: token)
            }
            try Task.checkCancellation()
            guard version == requestVersion else { return }
            update(state)
        } catch {
            guard version == requestVersion, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            report(error)
        }
    }

    func perform(_ command: SpotifyPlaybackCommand, using auth: SpotifyAuthModel) async {
        guard canPerform(command) else { return }
        if usesDesktopPlayer {
            _ = await localOperation { try await self.localClient.send(command) }
            return
        }
        let deviceID = state?.device?.id
        _ = await changePlayback(using: auth) { token in
            try await self.client.send(command, accessToken: token, deviceID: deviceID)
        }
    }

    /// Shares the same busy state as menu controls so player commands cannot overlap.
    /// True means Spotify accepted the track; a failed follow-up refresh is reported separately.
    func startTrack(uri: String, using auth: SpotifyAuthModel) async -> Bool {
        await startTracks(uris: [uri], using: auth)
    }

    func startTracks(uris: [String], using auth: SpotifyAuthModel) async -> Bool {
        guard await awaitPendingRefresh(using: auth) else { return false }
        if usesDesktopPlayer {
            guard uris.count == 1 else { errorMessage = LocalSpotifyError.queueUnsupported.localizedDescription; return false }
            guard let uri = uris.first, LocalSpotifyClient.trackURI(from: uri) == uri else {
                errorMessage = LocalSpotifyError.invalidTrack.localizedDescription; return false
            }
            return await localOperation { try await self.localClient.startTrack(uri: uri) }
        }
        let version = requestVersion
        let connectionVersion = auth.connectionVersion
        return await changePlayback(using: auth) { token in
            // Read the active device now rather than targeting an old menu-panel snapshot.
            let current = try await self.client.fetchState(accessToken: token)
            try Task.checkCancellation()
            guard version == self.requestVersion, auth.isConnected,
                  connectionVersion == auth.connectionVersion else { throw CancellationError() }
            guard current?.device?.isRestricted != true else { throw SpotifyPlaybackError.forbidden }
            try await self.client.startTracks(uris: uris, accessToken: token, deviceID: current?.device?.id)
        }
    }

    /// Append without replacing playback. Recheck ownership/device before every
    /// write. An uncertain acknowledgement is never retried (it could duplicate).
    func enqueueTrack(uri: String, allowedCurrentURIs: Set<String>, deviceID: String?, using auth: SpotifyAuthModel) async -> String? {
        guard await awaitPendingRefresh(using: auth) else { return nil }
        guard auth.isConnected, !isBusy, readyToRequest() else { return nil }
        let version = requestVersion
        isBusy = true; errorMessage = nil
        var queuedDevice: String?
        defer { if version == requestVersion { isBusy = false } }
        do {
            try await authorized(using: auth) { token in
                let current = try await self.client.fetchState(accessToken: token)
                try Task.checkCancellation()
                guard version == self.requestVersion,
                      let currentURI = current?.item?.uri, allowedCurrentURIs.contains(currentURI),
                      let activeDevice = current?.device?.id, current?.device?.isRestricted != true,
                      deviceID == nil || activeDevice == deviceID else { throw SpotifyPlaybackError.sessionChanged }
                try await self.client.enqueueTrack(uri: uri, accessToken: token, deviceID: activeDevice)
                queuedDevice = activeDevice
            }
            try Task.checkCancellation()
            return version == requestVersion ? queuedDevice : nil
        } catch {
            guard version == requestVersion, !(error is CancellationError) else { return nil }
            report(error)
            return nil
        }
    }

    /// A discovery result can arrive during a passive Now Playing read. Wait for
    /// that read only; a real control still rejects overlapping mutations. This
    /// never retries a write and revalidates reset/route/account changes.
    private func awaitPendingRefresh(using auth: SpotifyAuthModel) async -> Bool {
        let version = requestVersion
        let connection = auth.connectionVersion
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while isRefreshing && isBusy {
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return false }
            guard version == requestVersion, connection == auth.connectionVersion else { return false }
        }
        return !Task.isCancelled && version == requestVersion && connection == auth.connectionVersion
    }

    private func localOperation(refreshDelay: Bool = true, operation: () async throws -> Void) async -> Bool {
        guard usesDesktopPlayer, !isBusy else { return false }
        let version = requestVersion
        isBusy = true; errorMessage = nil
        var accepted = false
        defer { if version == requestVersion { isBusy = false } }
        do {
            try Task.checkCancellation()
            try await operation()
            accepted = true
            try Task.checkCancellation()
            guard version == requestVersion else { return false }
            if refreshDelay { try await Task.sleep(for: .milliseconds(350)) }
            guard version == requestVersion else { return false }
            let snapshot = try await localClient.fetchState()
            try Task.checkCancellation()
            guard version == requestVersion else { return false }
            update(snapshot)
        } catch {
            guard version == requestVersion, !(error is CancellationError) else { return false }
            report(error)
            if accepted && refreshDelay {
                errorMessage = "Spotify desktop accepted the control, but Mochi couldn't refresh its result. \(error.localizedDescription)"
            }
        }
        return accepted
    }

    private func changePlayback(using auth: SpotifyAuthModel,
                                operation: (String) async throws -> Void) async -> Bool {
        guard auth.isConnected, !isBusy, readyToRequest() else { return false }
        let version = requestVersion
        let connectionVersion = auth.connectionVersion
        isBusy = true
        errorMessage = nil
        var commandAccepted = false
        defer { if version == requestVersion { isBusy = false } }
        do {
            try await authorized(using: auth, operation: operation)
            commandAccepted = true
            try Task.checkCancellation()
            guard version == requestVersion else { return false }
            // Spotify's command acknowledgement can arrive before playback state catches up.
            try await Task.sleep(for: .milliseconds(350))
            guard version == requestVersion, auth.isConnected,
                  connectionVersion == auth.connectionVersion else { return false }
            let state = try await authorized(using: auth) { token in
                try await self.client.fetchState(accessToken: token)
            }
            try Task.checkCancellation()
            guard version == requestVersion else { return false }
            update(state)
        } catch {
            guard version == requestVersion, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return false }
            report(error)
            if commandAccepted {
                errorMessage = "Spotify accepted the control, but Mochi could not refresh its result. \(error.localizedDescription)"
            }
        }
        return commandAccepted
    }

    private func authorized<T>(using auth: SpotifyAuthModel, operation: (String) async throws -> T) async throws -> T {
        let connectionVersion = auth.connectionVersion
        guard auth.isConnected else { throw CancellationError() }
        let token = try await auth.validAccessToken()
        try Task.checkCancellation()
        guard auth.isConnected, connectionVersion == auth.connectionVersion else { throw CancellationError() }
        do {
            let result = try await operation(token)
            try Task.checkCancellation()
            guard auth.isConnected, connectionVersion == auth.connectionVersion else { throw CancellationError() }
            return result
        } catch SpotifyPlaybackError.unauthorized {
            // Retry only an explicit 401, once. Never repeat skip after a timeout/unknown outcome.
            guard auth.isConnected, connectionVersion == auth.connectionVersion else { throw CancellationError() }
            let refreshed = try await auth.validAccessToken(forceRefresh: true)
            try Task.checkCancellation()
            guard auth.isConnected, connectionVersion == auth.connectionVersion else { throw CancellationError() }
            let result = try await operation(refreshed)
            try Task.checkCancellation()
            guard auth.isConnected, connectionVersion == auth.connectionVersion else { throw CancellationError() }
            return result
        }
    }

    private func update(_ state: SpotifyPlaybackState?) {
        self.state = state
        isStale = false
        lastUpdatedAt = Date()
        errorMessage = nil
        retryAfter = nil
    }

    private func readyToRequest() -> Bool {
        guard let retryAfter, retryAfter > Date() else { return true }
        errorMessage = "Spotify is limiting requests. Wait \(Int(retryAfter.timeIntervalSinceNow.rounded(.up))) seconds, then refresh."
        return false
    }

    private func report(_ error: Error) {
        isStale = state != nil
        if case SpotifyPlaybackError.rateLimited(let seconds, _) = error {
            retryAfter = Date().addingTimeInterval(seconds)
        }
        errorMessage = error.localizedDescription
    }
}
