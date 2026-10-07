import SwiftUI

@main
struct MochiApp: App {
    @NSApplicationDelegateAdaptor(MochiAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Mochi", systemImage: "music.note") {
            ContentView(spotify: appDelegate.spotify, playback: appDelegate.playback, companion: appDelegate.companion)
        }
        .menuBarExtraStyle(.window)
    }
}
