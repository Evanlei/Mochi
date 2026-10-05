import SwiftUI

@main
struct MochiApp: App {
    @StateObject private var spotify = SpotifyAuthModel()

    var body: some Scene {
        MenuBarExtra("Mochi", systemImage: "music.note") {
            ContentView(spotify: spotify)
        }
        .menuBarExtraStyle(.window)
    }
}
