import SwiftUI

struct ContentView: View {
    @ObservedObject var spotify: SpotifyAuthModel
    @ObservedObject var playback: SpotifyPlaybackModel
    @ObservedObject var companion: MochiCompanionController
    var engine: MochiEngineModel? = nil
    @State private var settingsPresented = false
    @State private var showsLinkEntry = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Spotify").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if playback.isBusy { ProgressView().controlSize(.mini).accessibilityLabel("Updating playback") }
                Button { settingsPresented.toggle() } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Player settings").accessibilityLabel("Player settings")
                .popover(isPresented: $settingsPresented, arrowEdge: .trailing) { settings }
            }
            NowPlayingView(spotify: spotify, playback: playback, showsLinkEntry: $showsLinkEntry)

            if !spotify.isConnected && !playback.usesDesktopPlayer {
                Button("Use desktop controls") { Task { await playback.enableDesktopControls() } }
                    .controlSize(.small).disabled(playback.isBusy)
            }
            ListeningSessionStatus(request: companion.request)
            Divider()
            HStack {
                Button(companion.isVisible ? "Hide Mochi" : "Show Mochi") { companion.setVisible(!companion.isVisible) }
                    .accessibilityLabel(companion.isVisible ? "Hide Mochi" : "Show Mochi")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 300)
        .task {
            if spotify.isConnected || playback.usesDesktopPlayer { await playback.refresh(using: spotify) }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 2) {
            if engine != nil {
                SettingsLink { Label("Setup & Settings", systemImage: "gearshape").font(.system(size: 12)).padding(8) }
                    .buttonStyle(.plain).accessibilityLabel("Setup & Settings")
                Divider().padding(.vertical, 4)
            }
            Text(playback.usesDesktopPlayer ? "Spotify desktop controls" : "Spotify API controls")
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(8)
            settingsAction("Refresh playback", symbol: "arrow.clockwise", disabled: playback.isBusy || (!spotify.isConnected && !playback.usesDesktopPlayer)) {
                Task { await playback.refresh(using: spotify) }
            }
            settingsAction("Open Spotify", symbol: "arrow.up.forward.app") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") { NSWorkspace.shared.open(url) }
            }
            if playback.usesDesktopPlayer {
                settingsAction("Play a Spotify link", symbol: "link") { showsLinkEntry.toggle() }
                settingsAction("Use Web API controls", symbol: "network", disabled: playback.isBusy) {
                    playback.useWebPlayer(); Task { await playback.refresh(using: spotify) }
                }
            } else {
                settingsAction("Use desktop controls", symbol: "desktopcomputer", disabled: playback.isBusy) {
                    Task { await playback.enableDesktopControls() }
                }
            }
            Divider().padding(.vertical, 4)
            if spotify.isBusy {
                ProgressView().controlSize(.small).padding(8)
                settingsAction("Cancel connection", symbol: "xmark") { spotify.cancelConnection() }
            } else if spotify.isConnected {
                settingsAction("Disconnect Spotify API", symbol: "person.crop.circle.badge.xmark") { spotify.disconnect() }
            } else {
                settingsAction("Connect Spotify API", symbol: "person.crop.circle.badge.plus") { spotify.connect() }
                Text("Optional connection for song matching and continuous listening.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(8)
            }
            Text(spotify.statusMessage).font(.system(size: 10)).foregroundStyle(.secondary).padding(8)
        }.padding(6).frame(width: 235)
    }

    private func settingsAction(_ title: String, symbol: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { settingsPresented = false; action() }
        } label: {
            Label(title, systemImage: symbol).font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled).accessibilityLabel(title)
    }
}

private struct ListeningSessionStatus: View {
    @ObservedObject var request: MochiRequestModel
    @State private var showsQueue = false
    var body: some View {
        if request.isSessionActive {
            HStack {
                Button { showsQueue.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "list.bullet")
                        Text(request.isRefilling ? "Finding more music…" : "Up Next · \(request.queuedSongCount) queued")
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Show Up Next")
                .help("View Mochi's current song and confirmed upcoming songs")
                .popover(isPresented: $showsQueue, arrowEdge: .trailing) {
                    MochiUpNextView(request: request).padding(12).frame(width: 292, height: 300)
                }
                Spacer()
                Button { request.stopSession() } label: { Image(systemName: "stop.circle").frame(width: 24, height: 22) }
                    .buttonStyle(.plain).help("Stop continuous listening").accessibilityLabel("Stop continuous listening")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        } else if let notice = request.resultNotice {
            Text(notice).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
        }
    }
}

#Preview {
    ContentView(spotify: SpotifyAuthModel(), playback: SpotifyPlaybackModel(), companion: MochiCompanionController())
}
