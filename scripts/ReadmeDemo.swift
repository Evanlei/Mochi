import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Renders the production views with intercepted requests and memory-only tokens.
/// No real backend, Keychain, Spotify application, or user defaults are used.
@main struct ReadmeDemo {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "design/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let network = URLSession(configuration: configuration)
        let backend = MochiBackendClient(session: network)
        let resolver = SpotifySearchClient(session: network)
        let search = SpotifySearchModel(client: resolver)
        let composer = MochiRequestModel(backend: backend, resolver: resolver)
        let loading = MochiRequestModel(backend: backend, resolver: resolver)
        let picks = MochiRequestModel(backend: backend, resolver: resolver)
        let queue = MochiRequestModel(backend: backend, resolver: resolver)
        defer { loading.reset(); picks.reset(); queue.reset() }

        let titles = ["Quiet Window", "Moonlit Keys", "Paper Lantern", "Velvet Room"]
        let artist = "Mochi Demo Studio"
        let prompt = "Mellow piano for studying"
        func identifier(_ index: Int) -> String { String(format: "%022d", index + 1) }
        func uri(_ index: Int) -> String { "spotify:track:\(identifier(index))" }
        func json(_ value: Any, delay: TimeInterval = 0) throws -> SpotifyReply {
            SpotifyReply(data: try JSONSerialization.data(withJSONObject: value), delay: delay)
        }
        func selection() throws -> SpotifyReply {
            let tracks: [[String: Any]] = titles.enumerated().map { index, title in
                ["id": "lastfm-" + String(format: "%064x", index + 1), "title": title, "artist": artist,
                 "description": "Community tags: piano, mellow, study", "source": "lastfm", "score": 0.8,
                 "reasons": ["Shares musical tags with your request."]]
            }
            return try json(["received_prompt": prompt, "selection": ["catalog_kind": "lastfm_live", "method": "lexical",
                "request_id": UUID().uuidString, "tracks": tracks]])
        }
        func state() throws -> SpotifyReply {
            try json(["is_playing": true, "device": ["id": "demo-device", "name": "This Mac", "is_restricted": false],
                "item": ["uri": uri(0), "name": titles[0], "type": "track", "artists": [["name": artist]]]])
        }
        func waitUntil(_ condition: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !condition() {
                guard ContinuousClock.now < deadline else { throw DemoError.timedOut }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        SpotifyMockProtocol.server.configure([try selection()])
        picks.submit(prompt)
        try await waitUntil { !picks.isSending }
        guard picks.selection?.tracks.count == 4 else { throw DemoError.missingFixture }

        let memory = SpotifyMemoryStore()
        memory.tokens = SpotifyTokens(accessToken: "demo-only", refreshToken: "demo-only", expiresAt: .distantFuture,
                                      scope: SpotifyConfiguration.scopes.joined(separator: " "))
        let auth = SpotifyAuthModel(tokenClient: SpotifyTokenClient(session: network), tokenStore: memory)
        await auth.restore()
        let playback = SpotifyPlaybackModel(client: SpotifyPlaybackClient(session: network), localClient: LocalPlayerFixture(state: nil))
        queue.configure(using: auth, playback: playback)
        var replies = [try selection()]
        for (index, title) in titles.enumerated() {
            replies.append(try json(["tracks": ["items": [["id": identifier(index), "uri": uri(index), "name": title,
                "type": "track", "artists": [["name": artist]], "album": ["name": "Demo recordings"]]]]]))
        }
        replies += [try state(), SpotifyReply(status: 204), try state(), try json(["status": "ok"])]
        SpotifyMockProtocol.server.configure(replies)
        queue.submit(prompt)
        try await waitUntil { !queue.isSending && !queue.feedbackBusy }
        replies = []
        for _ in 1..<titles.count { replies += [try state(), SpotifyReply(status: 204)] }
        SpotifyMockProtocol.server.configure(replies)
        await queue.maintainSession()
        guard queue.sessionQueue.upcoming.count == 3 else { throw DemoError.missingFixture }

        // Keep the thinking state pending for the deterministic render timeline.
        SpotifyMockProtocol.server.configure([try json(["received_prompt": prompt], delay: 3_600)])
        loading.submit(prompt)
        try await waitUntil { !SpotifyMockProtocol.server.requests().isEmpty }

        let width = 840, height = 560, fps = 12, count = 168
        guard let gif = CGImageDestinationCreateWithURL(output.appendingPathComponent("mochi-demo.gif") as CFURL,
            UTType.gif.identifier as CFString, count, nil) else { throw DemoError.encoding }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let host = NSHostingView(rootView: DemoFrame(time: 0, composer: composer, loading: loading, picks: picks, queue: queue, search: search))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        for index in 0..<count {
            let time = Double(index) / Double(fps)
            if time >= 2 && time < 5 {
                composer.draft = String(prompt.prefix(min(prompt.count, Int((time - 2) * 12))))
            }
            host.rootView = DemoFrame(time: time, composer: composer, loading: loading, picks: picks, queue: queue, search: search)
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            try autoreleasepool {
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw DemoError.encoding }
                bitmap.size = NSSize(width: width, height: height)
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let image = bitmap.cgImage else { throw DemoError.encoding }
                // GIF stores hundredths of a second: 8/8/9 totals three frames
                // per quarter-second, preserving the intended 12 fps average.
                CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary:
                    [kCGImagePropertyGIFDelayTime: index % 3 == 2 ? 0.09 : 0.08]] as CFDictionary)
                if index == 126 {
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw DemoError.encoding }
                    try png.write(to: output.appendingPathComponent("mochi-demo.png"))
                }
            }
        }
        guard CGImageDestinationFinalize(gif) else { throw DemoError.encoding }
        print("Rendered 14-second native UI demo (fixture data, no real playback) to \(output.path)")
    }
    private enum DemoError: Error { case timedOut, missingFixture, encoding }
}

@MainActor private struct DemoFrame: View {
    let time: Double
    let composer: MochiRequestModel
    let loading: MochiRequestModel
    let picks: MochiRequestModel
    let queue: MochiRequestModel
    let search: SpotifySearchModel

    private var phase: Int { time < 2 ? 0 : time < 5 ? 1 : time < 6.5 ? 2 : time < 9 ? 3 : 4 }
    private var fade: Double { time > 13.2 ? max(0, (14 - time) / 0.8) : 1 }
    private var entry: Double { min(1, max(0, (time - 1.7) / 0.6)) }
    private var cardAlpha: Double { phase == 0 ? 0 : min(1, (time - 2) * 4) * fade }
    private var pose: MochiMascotPose {
        var activity = MochiMascotActivityMotion()
        if phase == 1 { activity.set(.curious, at: 0) }
        if phase == 2 { activity.set(.thinking, at: 0) }
        return MochiMascotPose.at(time: time + 100, isMusicPlaying: phase >= 3,
            isHovered: phase == 0, isEngaged: phase == 1 || phase == 2,
            hoverStartedAt: phase == 0 ? 100.25 : nil, idleStartedAt: 100,
            activityMotion: activity, celebrationStartedAt: phase == 3 ? 106.5 : nil)
    }
    private var title: String {
        switch phase {
        case 0: "A little music\ncompany."
        case 1: "Start with\na mood."
        case 2: "Mochi gets\nto work."
        case 3: "Find your\nnext listen."
        default: "Keep the\nmusic going."
        }
    }
    private var detail: String {
        switch phase {
        case 0: "A small companion.\nRight on your desktop."
        case 1: "A genre, an artist,\nor a feeling."
        case 2: "Discovery and ranking,\nbehind the scenes."
        case 3: "Explore the picks.\nMake them your own."
        default: "Your session,\none song at a time."
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.957, green: 0.965, blue: 0.945)
            Circle().fill(Color(red: 0.86, green: 0.91, blue: 0.86).opacity(0.65))
                .frame(width: 540, height: 540).blur(radius: 60).offset(x: 380, y: 100)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(Color(red: 0.45, green: 0.57, blue: 0.48)).frame(width: 7, height: 7)
                    Text("MOCHI").font(.system(size: 11, weight: .semibold, design: .rounded)).tracking(3)
                }.foregroundStyle(Color.black.opacity(0.5))
                Spacer()
                Text(title).font(.system(size: 39, weight: .medium, design: .rounded)).tracking(-1.4).lineSpacing(1)
                    .foregroundStyle(Color(red: 0.22, green: 0.29, blue: 0.25))
                Text(detail).font(.system(size: 15)).lineSpacing(5).foregroundStyle(Color.black.opacity(0.5)).padding(.top, 18)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<5) { index in
                        Capsule().fill(Color.black.opacity(index == phase ? 0.4 : 0.1)).frame(width: index == phase ? 23 : 6, height: 4)
                    }
                }
                Text("NATIVE UI PREVIEW · DEMO DATA").font(.system(size: 9, weight: .medium)).tracking(1.0)
                    .foregroundStyle(Color.black.opacity(0.36)).padding(.top, 18)
            }.frame(width: 330, height: 450, alignment: .leading).padding(.leading, 48).padding(.top, 48)
                .opacity(min(1, time * 4) * fade)

            if phase > 0 {
                MochiCompanionCard(request: phase == 1 ? composer : phase == 2 ? loading : phase == 3 ? picks : queue,
                    search: search, onClose: {})
                    .id(phase)
                    .environment(\.colorScheme, .light)
                    .fixedSize()
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.06), radius: 20, y: 8)
                    .opacity(cardAlpha)
                    .position(x: 590, y: phase < 3 ? 320 : 225)
            }
            MochiMascotArtwork(pose: pose)
                .frame(width: 265 - 85 * entry, height: 235 - 75 * entry)
                .position(x: 595 + 90 * entry, y: 290 + 173 * entry)
                .opacity(min(1, time * 4) * fade)
        }
        .frame(width: 840, height: 560)
        .environment(\.colorScheme, .light)
        .transaction { $0.animation = nil }
    }
}
