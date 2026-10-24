import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var spotify: SpotifyAuthModel
    @ObservedObject var playback: SpotifyPlaybackModel
    @Binding var showsLinkEntry: Bool
    @State private var trackLink = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AsyncImage(url: playback.state?.item?.artworkURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            LinearGradient(
                                colors: [Color.primary.opacity(0.06), Color.primary.opacity(0.02)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: playback.state?.isPlaying == true ? "waveform" : "music.note")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
                .shadow(color: .black.opacity(0.08), radius: 1.5, x: 0, y: 1)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playback.state?.item?.name ?? "Nothing playing")
                        .font(.system(size: 14.5, weight: .semibold))
                        .lineLimit(2)
                    Text(playback.state?.item?.subtitle ?? "Start a song in Spotify.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let albumName = playback.state?.item?.album?.name, !albumName.isEmpty {
                        Text(albumName)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 20) {
                Spacer(minLength: 0)
                control(.previous, symbol: "backward.end.fill", label: "Previous track")
                let command: SpotifyPlaybackCommand = playback.state?.isPlaying == true ? .pause : .play
                control(command, symbol: command == .pause ? "pause.fill" : "play.fill",
                        label: command == .pause ? "Pause" : "Play", prominent: true)
                control(.next, symbol: "forward.end.fill", label: "Next track")
                Spacer(minLength: 0)
            }

            if let state = playback.state {
                HStack(spacing: 5) {
                    Circle()
                        .fill(state.isPlaying ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Image(systemName: deviceSymbol(for: state.device?.name))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text([state.isPlaying ? "Playing" : "Paused", state.device?.name].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .frame(maxWidth: .infinity, alignment: .center)
            }
            if showsLinkEntry && playback.usesDesktopPlayer {
                HStack(spacing: 6) {
                    TextField("Spotify track link", text: $trackLink)
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                        .accessibilityLabel("Spotify track link").onSubmit { playLink() }
                    Button("Play link") { playLink() }.controlSize(.small)
                        .disabled(playback.isBusy || LocalSpotifyClient.trackURI(from: trackLink) == nil)
                }
            }
            if playback.isStale || playback.errorMessage != nil {
                Text(playback.errorMessage ?? "Playback is out of date. Refresh in Player settings.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("mochiMenuPlayer")
    }

    private func control(_ command: SpotifyPlaybackCommand, symbol: String, label: String, prominent: Bool = false) -> some View {
        TransportControlView(
            command: command,
            symbol: symbol,
            label: label,
            prominent: prominent,
            spotify: spotify,
            playback: playback
        )
    }

    private func deviceSymbol(for deviceName: String?) -> String {
        if playback.usesDesktopPlayer { return "desktopcomputer" }
        guard let name = deviceName?.lowercased() else { return "speaker.wave.2.fill" }
        if name.contains("iphone") || name.contains("phone") { return "iphone" }
        if name.contains("ipad") { return "ipad" }
        if name.contains("mac") || name.contains("book") || name.contains("desktop") { return "desktopcomputer" }
        if name.contains("speaker") || name.contains("echo") || name.contains("homepod") { return "hifispeaker.fill" }
        if name.contains("tv") { return "tv" }
        return "speaker.wave.2.fill"
    }

    private func playLink() {
        guard !playback.isBusy, let uri = LocalSpotifyClient.trackURI(from: trackLink) else { return }
        Task { _ = await playback.startTrack(uri: uri, using: spotify) }
    }
}

// MARK: - Transport Control Components

struct TransportButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.78 : (isEnabled ? 1.0 : 0.45))
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.08)
                    : .spring(response: 0.18, dampingFraction: 0.72),
                value: configuration.isPressed
            )
    }
}

private struct TransportControlView: View {
    let command: SpotifyPlaybackCommand
    let symbol: String
    let label: String
    var prominent: Bool = false
    @ObservedObject var spotify: SpotifyAuthModel
    @ObservedObject var playback: SpotifyPlaybackModel

    @State private var isHovered = false

    private var isEnabled: Bool {
        (spotify.isConnected || playback.usesDesktopPlayer) && playback.canPerform(command)
    }

    private var backgroundOpacity: Double {
        guard isEnabled else { return prominent ? 0.04 : 0 }
        if prominent {
            return isHovered ? 0.14 : 0.08
        } else {
            return isHovered ? 0.08 : 0
        }
    }

    var body: some View {
        Button {
            Task { await playback.perform(command, using: spotify) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 20 : 16, weight: .semibold))
                .frame(width: prominent ? 44 : 40, height: prominent ? 44 : 40)
                .background(Circle().fill(Color.primary.opacity(backgroundOpacity)))
                .contentShape(Circle())
        }
        .buttonStyle(TransportButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help(label)
        .accessibilityLabel(label)
        .disabled(!isEnabled)
    }
}
