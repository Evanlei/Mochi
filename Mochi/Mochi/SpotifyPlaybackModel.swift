import Combine
import Foundation

@MainActor
final class SpotifyPlaybackModel: ObservableObject {
    @Published private(set) var state: SpotifyPlaybackState?
    @Published private(set) var isBusy = false
    @Published private(set) var isStale = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdatedAt: Date?

    private let client: SpotifyPlaybackClient
    private var requestVersion = 0
    private var retryAfter: Date?

    init(client: SpotifyPlaybackClient? = nil) {
        self.client = client ?? SpotifyPlaybackClient()
    }

    func reset() {
        requestVersion += 1
        state = nil
        isBusy = false
        isStale = false
        errorMessage = nil
        lastUpdatedAt = nil
        // Preserve an account-level rate-limit deadline across local sign-out.
    }

    func canPerform(_ command: SpotifyPlaybackCommand) -> Bool {
        let isCoolingDown = retryAfter.map { $0 > Date() } ?? false
        return !isBusy && !isStale && !isCoolingDown && state?.permits(command) == true
    }

    func refresh(using auth: SpotifyAuthModel) async {
        guard auth.isConnected, !isBusy, readyToRequest() else { return }
        let version = requestVersion
        isBusy = true
        errorMessage = nil
        defer { if version == requestVersion { isBusy = false } }
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
