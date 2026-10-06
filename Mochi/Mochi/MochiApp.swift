import SwiftUI

@main
struct MochiApp: App {
    @NSApplicationDelegateAdaptor(MochiAppDelegate.self) private var appDelegate
    @StateObject private var spotify = SpotifyAuthModel()
    @StateObject private var playback = SpotifyPlaybackModel()

    var body: some Scene {
        MenuBarExtra("Mochi", systemImage: "music.note") {
            ContentView(spotify: spotify, playback: playback, companion: appDelegate.companion)
        }
        .menuBarExtraStyle(.window)
    }
}
