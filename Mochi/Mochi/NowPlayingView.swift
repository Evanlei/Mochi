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
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { Image(systemName: playback.state?.isPlaying == true ? "waveform" : "music.note").font(.system(size: 22, weight: .medium)) }
                }
                    .frame(width: 48, height: 48)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(playback.state?.item?.name ?? "Nothing playing")
                        .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text(playback.state?.item?.subtitle ?? "Start a song in Spotify.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 24) {
                Spacer(minLength: 0)
                control(.previous, symbol: "backward.end.fill", label: "Previous track")
                let command: SpotifyPlaybackCommand = playback.state?.isPlaying == true ? .pause : .play
                control(command, symbol: command == .pause ? "pause.fill" : "play.fill",
                        label: command == .pause ? "Pause" : "Play", prominent: true)
                control(.next, symbol: "forward.end.fill", label: "Next track")
                Spacer(minLength: 0)
            }

            if let state = playback.state {
                Text([state.isPlaying ? "Playing" : "Paused", state.device?.name].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
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
        Button { Task { await playback.perform(command, using: spotify) } } label: {
            Image(systemName: symbol).font(.system(size: prominent ? 20 : 16, weight: .semibold))
                .frame(width: prominent ? 44 : 32, height: 44)
                .background(.primary.opacity(prominent ? 0.08 : 0), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .disabled((!spotify.isConnected && !playback.usesDesktopPlayer) || !playback.canPerform(command))
    }

    private func playLink() {
        guard !playback.isBusy, let uri = LocalSpotifyClient.trackURI(from: trackLink) else { return }
        Task { _ = await playback.startTrack(uri: uri, using: spotify) }
    }
}
