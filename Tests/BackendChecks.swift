import Foundation

@main
struct BackendChecks {
    @MainActor
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let client = MochiBackendClient(session: URLSession(configuration: configuration))
        let text = "夜の piano 🎵"
        let data = try JSONSerialization.data(withJSONObject: ["received_prompt": text,
            "intent": ["vocals": false, "energy": "low"], "clarification": NSNull()] as [String: Any])
        SpotifyMockProtocol.server.configure([SpotifyReply(data: data)])
        let result = try await client.send(prompt: "  \(text)  ")
        precondition(result.receivedPrompt == text)
        precondition(result.intent?.summary == "Low energy · Instrumental" && result.clarification == nil)
        let sent = SpotifyMockProtocol.server.requests()[0]
        precondition(sent.url?.absoluteString == "http://127.0.0.1:8000/listening-request")
        precondition(sent.httpMethod == "POST" && sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: spotifyRequestBody(sent)!) as! [String: String]
        precondition(body == ["prompt": text])
        print("PASS: Swift POST address, JSON body, trimming, Unicode and snake_case response")

        for text in [" \n ", String(repeating: "x", count: 501), String(repeating: "👨‍👩‍👧‍👦", count: 100)] {
            SpotifyMockProtocol.server.configure([])
            do { _ = try await client.send(prompt: text); fatalError("Invalid input accepted") }
            catch MochiBackendError.invalidPrompt {}
            precondition(SpotifyMockProtocol.server.requests().isEmpty)
        }
        for (reply, message) in [
            (SpotifyReply(status: 422), "1–500"),
            (SpotifyReply(status: 500), "500"),
            (SpotifyReply(status: 302), "302"),
            (SpotifyReply(data: Data("not json".utf8)), "unexpected"),
            (SpotifyReply(data: Data(#"{"received_prompt":"wrong request"}"#.utf8)), "unexpected"),
            (SpotifyReply(data: Data(#"{"received_prompt":"piano","intent":{"vocals":false,"energy":"invalid"}}"#.utf8)), "unexpected"),
            (SpotifyReply(error: .cannotConnectToHost), "Start it"),
            (SpotifyReply(error: .timedOut), "too long")
        ] {
            SpotifyMockProtocol.server.configure([reply])
            do { _ = try await client.send(prompt: "piano"); fatalError("Failed request accepted") }
            catch let error as MochiBackendError { precondition(error.localizedDescription.contains(message)) }
            precondition(SpotifyMockProtocol.server.requests().count == 1, "Unexpected automatic retry")
        }
        print("PASS: input limits, unavailable server, timeout, HTTP failures and malformed/mismatched replies")

        func waitFor(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !predicate() {
                precondition(Date() < deadline, "Timed out waiting for model state")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let model = MochiRequestModel(backend: client)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: Data(#"{"received_prompt":"piano"}"#.utf8), delay: 0.1)])
        model.draft = "piano"
        model.submit()
        precondition(model.isSending && !model.canSubmit && model.preferences.isEmpty)
        model.submit("duplicate")
        model.draft = "next request"
        try await waitFor { !model.isSending }
        precondition(model.preferences == ["piano"] && model.draft == "next request")
        precondition(model.reply.contains("Request received") && SpotifyMockProtocol.server.requests().count == 1)

        SpotifyMockProtocol.server.configure([SpotifyReply(error: .cannotConnectToHost)])
        model.submit("Unwind")
        try await waitFor { !model.isSending }
        precondition(model.draft == "Unwind" && model.preferences == ["piano"] && model.reply.contains("Start it"))
        SpotifyMockProtocol.server.configure([SpotifyReply(data: Data(#"{"received_prompt":"Unwind"}"#.utf8))])
        model.submit()
        try await waitFor { !model.isSending }
        precondition(model.preferences == ["piano", "Unwind"] && model.draft.isEmpty)

        SpotifyMockProtocol.server.configure([SpotifyReply(data: Data(#"{"received_prompt":"old"}"#.utf8), delay: 0.5)])
        model.draft = "old"
        model.submit()
        try await waitFor { !SpotifyMockProtocol.server.requests().isEmpty }
        model.reset()
        precondition(!model.isSending && model.preferences.isEmpty && model.draft.isEmpty)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: Data(#"{"received_prompt":"new"}"#.utf8))])
        model.draft = "new"
        model.submit()
        try await waitFor { !model.isSending }
        try await Task.sleep(for: .milliseconds(600))
        precondition(model.preferences == ["new"] && model.draft.isEmpty && model.reply.contains("Request received"))
        print("PASS: loading, duplicate prevention, edited draft retention, failure/retry, reset cancellation and stale replies")

        model.reset()
        SpotifyMockProtocol.server.configure([SpotifyReply(data: Data(#"{"received_prompt":"calm instrumentals","intent":{"vocals":false,"energy":"low"},"clarification":null}"#.utf8))])
        model.draft = "calm instrumentals"
        model.submit()
        try await waitFor { !model.isSending }
        precondition(model.reply.contains("Low energy · Instrumental"))
        SpotifyMockProtocol.server.configure([SpotifyReply(data: Data(#"{"received_prompt":"calm and energetic","intent":{"vocals":null,"energy":null},"clarification":"What energy level would you like?"}"#.utf8))])
        model.draft = "calm and energetic"
        model.submit()
        try await waitFor { !model.isSending }
        precondition(model.reply == "What energy level would you like?" && model.canSubmit == false)
        print("PASS: understood preferences and clarification shown in the compact card model")

        if CommandLine.arguments.contains("--live") {
            let result = try await MochiBackendClient().send(prompt: "  Live piano check 🎵  ")
            precondition(result.receivedPrompt == "Live piano check 🎵")
            print("PASS: actual Swift URLSession → local FastAPI → Swift response")
        }
    }
}
