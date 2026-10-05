import AppKit
import Combine
import Foundation

@MainActor
final class SpotifyAuthModel: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = "Spotify is not connected."

    private let tokenClient: SpotifyTokenClient
    private let tokenStore: any SpotifyTokenStoring
    private let openBrowser: @MainActor (URL) -> Bool
    private var tokens: SpotifyTokens?
    private var callbackListener: SpotifyCallbackListener?
    private var loginTask: Task<Void, Never>?
    private var refreshTask: Task<SpotifyTokens, Error>?
    private var generation = 0
    private var hasRestored = false

    init(
        tokenClient: SpotifyTokenClient? = nil,
        tokenStore: (any SpotifyTokenStoring)? = nil,
        openBrowser: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.tokenClient = tokenClient ?? SpotifyTokenClient()
        self.tokenStore = tokenStore ?? SpotifyTokenStore()
        self.openBrowser = openBrowser
    }

    func restore() async {
        guard !hasRestored else { return }
        hasRestored = true
        guard !isBusy else { return }
        let currentGeneration = generation
        isBusy = true
        statusMessage = "Checking saved Spotify connection…"
        defer { if generation == currentGeneration { isBusy = false } }
        do {
            guard let saved = try tokenStore.load() else {
                statusMessage = "Spotify is not connected."
                return
            }
            guard Set(SpotifyConfiguration.scopes).isSubset(of: Set(saved.scope.split(separator: " ").map(String.init))) else {
                try tokenStore.delete()
                throw SpotifyAuthError.reconnectRequired
            }
            tokens = saved
            _ = try await validAccessToken()
            guard generation == currentGeneration else { return }
            isConnected = true
            statusMessage = "Spotify connected."
        } catch {
            guard generation == currentGeneration else { return }
            statusMessage = error.localizedDescription
        }
    }

    func connect() {
        guard !isBusy, !isConnected else { return }
        guard let attempt = SpotifyLoginAttempt.prepare() else {
            statusMessage = "Mochi could not prepare the Spotify login URL."
            return
        }
        generation += 1
        let currentGeneration = generation
        let listener = SpotifyCallbackListener()
        callbackListener = listener
        isBusy = true
        statusMessage = "Opening Spotify login…"

        // This task belongs to the app model, rather than the temporary menu-bar panel.
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                let code = try await listener.receiveCode(expectedState: attempt.state) { [weak self] in
                    guard let self, self.openBrowser(attempt.authorizationURL) else {
                        throw SpotifyAuthError.browserUnavailable
                    }
                    self.statusMessage = "Approve access in your browser, then return here."
                }
                try Task.checkCancellation()
                self.statusMessage = "Finishing Spotify connection…"
                let tokens = try await self.tokenClient.exchange(code: code, verifier: attempt.verifier)
                try Task.checkCancellation()
                guard self.generation == currentGeneration else { return }
                try self.tokenStore.save(tokens)
                self.tokens = tokens
                self.isConnected = true
                self.statusMessage = "Spotify connected."
            } catch {
                guard self.generation == currentGeneration else { return }
                self.statusMessage = error is CancellationError ? "Spotify login cancelled." : error.localizedDescription
            }
            guard self.generation == currentGeneration else { return }
            self.callbackListener = nil
            self.loginTask = nil
            self.isBusy = false
        }
    }

    func cancelConnection() {
        guard isBusy else { return }
        generation += 1
        loginTask?.cancel()
        callbackListener?.cancel()
        refreshTask?.cancel()
        loginTask = nil
        callbackListener = nil
        refreshTask = nil
        if !isConnected { tokens = nil }
        isBusy = false
        statusMessage = "Spotify login cancelled."
    }

    func disconnect() {
        do {
            // Remove only Mochi's Keychain item. This is local sign-out, not remote revocation.
            try tokenStore.delete()
            generation += 1
            loginTask?.cancel()
            callbackListener?.cancel()
            refreshTask?.cancel()
            loginTask = nil
            callbackListener = nil
            refreshTask = nil
            tokens = nil
            isConnected = false
            isBusy = false
            statusMessage = "Spotify disconnected from Mochi."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Playback services will call this instead of reading or storing tokens themselves.
    func validAccessToken() async throws -> String {
        guard let tokens else { throw SpotifyAuthError.reconnectRequired }
        if tokens.isUsable() { return tokens.accessToken }
        let currentGeneration = generation
        let task: Task<SpotifyTokens, Error>
        if let existing = refreshTask {
            task = existing
        } else {
            task = Task { try await tokenClient.refresh(tokens) }
            refreshTask = task
        }
        do {
            let refreshed = try await task.value
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            try tokenStore.save(refreshed)
            self.tokens = refreshed
            refreshTask = nil
            return refreshed.accessToken
        } catch {
            guard generation == currentGeneration else { throw CancellationError() }
            refreshTask = nil
            if case SpotifyAuthError.reconnectRequired = error {
                try tokenStore.delete()
                self.tokens = nil
                isConnected = false
                statusMessage = SpotifyAuthError.reconnectRequired.localizedDescription
            }
            throw error
        }
    }
}
