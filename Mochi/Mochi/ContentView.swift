import SwiftUI

struct ContentView: View {
    @ObservedObject var spotify: SpotifyAuthModel
    @State private var message = "What do you want to hear?"
    @State private var prompt = ""

    var body: some View {
        VStack {
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
            Text(message)

            TextField("Describe what you want to hear", text: $prompt)

            Button("Find Music") { 
                let cleanedPrompt = prompt.trimmingCharacters(in:.whitespacesAndNewlines) 

                if cleanedPrompt.isEmpty {
                    message = "Describe some music first."
                } else {
                    message = cleanedPrompt
                } 
            }
            .keyboardShortcut(.defaultAction)


        }
        .padding()
        .frame(width: 360, height: 250)
        .task { await spotify.restore() }
    }
}

#Preview {
    ContentView(spotify: SpotifyAuthModel())
}
