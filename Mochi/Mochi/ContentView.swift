import SwiftUI

struct ContentView: View {
    @ObservedObject var spotify: SpotifyAuthModel
    @ObservedObject var playback: SpotifyPlaybackModel
    @ObservedObject var companion: MochiCompanionController

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Mochi")
                    .font(.headline)
                Spacer()
                if spotify.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { spotify.cancelConnection() }
                } else if spotify.isConnected {
                    Button("Disconnect") { spotify.disconnect() }
                } else {
                    Button("Connect Spotify") { spotify.connect() }
                }
            }
            Text(spotify.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            NowPlayingView(spotify: spotify, playback: playback)
            Divider()
            HStack {
                Button(companion.isVisible ? "Hide Mochi" : "Show Mochi") {
                    companion.setVisible(!companion.isVisible)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding()
        .frame(width: 380)
        .task {
            // Opening the menu refreshes its snapshot without resetting shared in-flight work.
            if spotify.isConnected { await playback.refresh(using: spotify) }
        }
    }
}

#Preview {
    ContentView(spotify: SpotifyAuthModel(), playback: SpotifyPlaybackModel(), companion: MochiCompanionController())
}
