import SwiftUI

struct ContentView: View {
    @State private var message = "What do you want to hear?"
    @State private var prompt = ""

    var body: some View {
        VStack {
            Text(message)

            TextField("Describe what you want to hear", text: $prompt)

            Button("Find Music") { 
                if prompt.isEmpty {
                    message = "Describe some music first."
                } else {
                    message = prompt
                } 
            }


        }
        .padding()
    }
}

#Preview {
    ContentView()
}
