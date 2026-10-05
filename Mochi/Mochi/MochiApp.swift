import SwiftUI

@main
struct MochiApp: App {
    @StateObject private var spotify = SpotifyAuthModel()
    @StateObject private var playback = SpotifyPlaybackModel()

    var body: some Scene {
        MenuBarExtra("Mochi", systemImage: "music.note") {
            ContentView(spotify: spotify, playback: playback)
        }
        .menuBarExtraStyle(.window)
    }
}
