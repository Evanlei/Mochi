import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var spotify: SpotifyAuthModel
    @ObservedObject var playback: SpotifyPlaybackModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                .disabled(!spotify.isConnected || playback.isBusy)
            }

            if !spotify.isConnected {
                Text("Connect Spotify to see what’s playing.")
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
        .disabled(!spotify.isConnected || !playback.canPerform(command))
    }
}
