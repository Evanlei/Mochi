import SwiftUI

@main
struct MochiApp: App {
    @NSApplicationDelegateAdaptor(MochiAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Mochi", systemImage: "music.note") {
            ContentView(spotify: appDelegate.spotify, playback: appDelegate.playback, companion: appDelegate.companion, engine: appDelegate.engine)
        }
        .menuBarExtraStyle(.window)
        Settings {
            if let engine = appDelegate.engine {
                MochiSettingsView(engine: engine, spotify: appDelegate.spotify, companion: appDelegate.companion)
            }
        }
    }
}
