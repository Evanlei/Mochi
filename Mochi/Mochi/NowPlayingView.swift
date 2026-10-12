import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var spotify: SpotifyAuthModel
    @ObservedObject var playback: SpotifyPlaybackModel
    @State private var trackLink = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(playback.usesDesktopPlayer ? "Spotify desktop" : "Spotify Web API")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Use desktop controls") {
                        Task { await playback.enableDesktopControls() }
                    }
                    .disabled(playback.isBusy)
                    Button("Use Web API controls") {
                        playback.useWebPlayer()
                        Task { await playback.refresh(using: spotify) }
                    }
                    .disabled(playback.isBusy)
                } label: { Image(systemName: "slider.horizontal.3") }
                .help("Choose Spotify controls")
                .accessibilityLabel("Choose Spotify controls")
            }
            if !playback.usesDesktopPlayer {
                Button("Use desktop controls") {
                    Task { await playback.enableDesktopControls() }
                }
                .disabled(playback.isBusy)
                .help("Control the Spotify Mac app without connecting a Spotify API account")
            }
            HStack {
                Text("Now Playing").font(.headline)
                Spacer()
                if playback.isBusy { ProgressView().controlSize(.small) }
                Button {
                    Task { await playback.refresh(using: spotify) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh playback")
                .accessibilityLabel("Refresh playback")
                .disabled((!spotify.isConnected && !playback.usesDesktopPlayer) || playback.isBusy)
            }

            if !spotify.isConnected && !playback.usesDesktopPlayer {
                Text("Use desktop controls, or connect the Spotify API.")
                    .foregroundStyle(.secondary)
            } else if let state = playback.state {
                if let item = state.item {
                    Text(item.name).font(.title3.weight(.semibold)).lineLimit(2)
                    Text(item.subtitle).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text(state.currentlyPlayingType == "ad" ? "Advertisement" : "No track information available")
                }
                HStack {
                    Label(state.isPlaying ? "Playing" : "Paused", systemImage: state.isPlaying ? "waveform" : "pause.fill")
                    Spacer()
                    if let name = state.device?.name { Text(name).lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if state.device?.isRestricted == true {
                    Text("This Spotify device does not allow remote controls.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if playback.lastUpdatedAt != nil {
                Text("Open Spotify and start a song, then refresh here.")
                    .foregroundStyle(.secondary)
            } else {
                Text(playback.isBusy ? "Reading Spotify playback…" : "Refresh to read Spotify playback.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 20) {
                Spacer()
                control(.previous, symbol: "backward.end.fill", label: "Previous track")
                let command: SpotifyPlaybackCommand = playback.state?.isPlaying == true ? .pause : .play
                control(command, symbol: command == .pause ? "pause.fill" : "play.fill", label: command == .pause ? "Pause" : "Play")
                control(.next, symbol: "forward.end.fill", label: "Next track")
                Spacer()
            }
            .font(.title3)

            if playback.usesDesktopPlayer {
                HStack {
                    TextField("Spotify track link", text: $trackLink)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Spotify track link")
                        .onSubmit { playLink() }
                    Button("Play link") { playLink() }
                        .disabled(playback.isBusy || LocalSpotifyClient.trackURI(from: trackLink) == nil)
                }
                Text("Copy a song’s link in Spotify to play it here.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if playback.isStale {
                Text("Showing the last result. Refresh before using controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = playback.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let updated = playback.lastUpdatedAt {
                Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func control(_ command: SpotifyPlaybackCommand, symbol: String, label: String) -> some View {
        Button {
            Task { await playback.perform(command, using: spotify) }
        } label: {
            Image(systemName: symbol).frame(width: 30, height: 26)
        }
        .help(label)
        .accessibilityLabel(label)
        .disabled((!spotify.isConnected && !playback.usesDesktopPlayer) || !playback.canPerform(command))
    }

    private func playLink() {
        guard !playback.isBusy, let uri = LocalSpotifyClient.trackURI(from: trackLink) else { return }
        Task { _ = await playback.startTrack(uri: uri, using: spotify) }
    }
}
