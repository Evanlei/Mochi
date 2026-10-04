import SwiftUI

@main
struct MochiApp: App {
    var body: some Scene {
        MenuBarExtra("Mochi", systemImage: "music.note") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
