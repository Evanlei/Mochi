import SwiftUI

struct ContentView: View {
    @ObservedObject var spotify: SpotifyAuthModel
    @ObservedObject var playback: SpotifyPlaybackModel
    @ObservedObject var companion: MochiCompanionController
    var engine: MochiEngineModel? = nil
    @State private var settingsPresented = false
    @State private var settingsHovered = false
    @State private var showsLinkEntry = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Spotify").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if playback.isBusy { ProgressView().controlSize(.mini).accessibilityLabel("Updating playback") }
                Button { settingsPresented.toggle() } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 22)
                        .background(settingsHovered ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Player settings").accessibilityLabel("Player settings")
                .onHover { settingsHovered = $0 }
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
        VStack(alignment: .leading, spacing: 3) {
            if engine != nil {
                SettingsLink {
                    Label {
                        Text("Setup & Settings")
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .center)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(SettingsRowButtonStyle())
                .accessibilityLabel("Setup & Settings")
                .simultaneousGesture(TapGesture().onEnded {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { settingsPresented = false }
                })
                Divider().padding(.vertical, 4)
            }

            // Section 1: Playback Controls
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Playback Controls")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(playback.usesDesktopPlayer ? "Desktop" : "Web API")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 2)

                settingsAction("Refresh playback", symbol: "arrow.clockwise", disabled: playback.isBusy || (!spotify.isConnected && !playback.usesDesktopPlayer)) {
                    Task { await playback.refresh(using: spotify) }
                }
                settingsAction("Open Spotify", symbol: "arrow.up.forward.app") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") { NSWorkspace.shared.open(url) }
                }
                if playback.usesDesktopPlayer {
                    settingsAction("Play a Spotify link", symbol: "link") { showsLinkEntry.toggle() }
                    settingsAction("Use Web API controls", symbol: "network", disabled: playback.isBusy) {
                        playback.useWebPlayer()
                        Task { await playback.refresh(using: spotify) }
                    }
                } else {
                    settingsAction("Use desktop controls", symbol: "desktopcomputer", disabled: playback.isBusy) {
                        Task { await playback.enableDesktopControls() }
                    }
                }
            }

            Divider().padding(.vertical, 4)

            // Section 2: Spotify API Connection
            VStack(alignment: .leading, spacing: 2) {
                Text("Spotify API Connection")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .padding(.bottom, 2)

                if spotify.isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Connecting to Spotify…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                    settingsAction("Cancel connection", symbol: "xmark") { spotify.cancelConnection() }
                } else if spotify.isConnected {
                    settingsAction("Disconnect Spotify API", symbol: "person.crop.circle.badge.xmark") { spotify.disconnect() }
                } else {
                    settingsAction("Connect Spotify API", symbol: "person.crop.circle.badge.plus") { spotify.connect() }
                    Text("Optional connection for song matching and continuous listening.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !spotify.statusMessage.isEmpty {
                    Text(spotify.statusMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(6)
        .frame(width: 240)
    }

    private func settingsAction(_ title: String, symbol: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                settingsPresented = false
                action()
            }
        } label: {
            Label {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(iconTint(for: symbol))
                    .frame(width: 16, alignment: .center)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(SettingsRowButtonStyle())
        .disabled(disabled)
        .accessibilityLabel(title)
    }

    private func iconTint(for symbol: String) -> Color {
        switch symbol {
        case "person.crop.circle.badge.plus":
            return Color.green.opacity(0.85)
        case "person.crop.circle.badge.xmark", "xmark":
            return Color.red.opacity(0.8)
        case "link", "network", "desktopcomputer":
            return Color.accentColor.opacity(0.85)
        default:
            return Color.secondary
        }
    }
}

struct SettingsRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        !isEnabled ? Color.clear :
                        configuration.isPressed
                            ? Color.primary.opacity(0.12)
                            : (isHovered ? Color.primary.opacity(0.08) : Color.clear)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isEnabled ? 1.0 : 0.45)
            .onHover { hovering in
                if isEnabled {
                    isHovered = hovering
                }
            }
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
