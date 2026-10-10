import AppKit
import Combine
import SwiftUI

// MARK: - Listening request

@MainActor
final class MochiRequestModel: ObservableObject {
    @Published var isSearchPresented = false
    @Published var draft = ""
    @Published private(set) var preferences: [String] = []
    @Published private(set) var reply = "What do you feel like\nlistening to?"
    @Published private(set) var isSending = false

    private let backend: MochiBackendClient
    private var sendTask: Task<Void, Never>?
    private var requestGeneration = UUID()

    init(backend: MochiBackendClient? = nil) {
        self.backend = backend ?? MochiBackendClient()
    }

    var canSubmit: Bool { !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var summary: String { preferences.joined(separator: " · ") }

    func submit(_ choice: String? = nil) {
        let text = (choice ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        if choice != nil { draft = text }
        isSending = true
        reply = "Sending your request…"
        let generation = requestGeneration
        sendTask = Task { [weak self, backend] in
            do {
                let response = try await backend.send(prompt: text)
                try Task.checkCancellation()
                guard let self, self.requestGeneration == generation else { return }
                self.preferences.append(response.receivedPrompt)
                if self.draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { self.draft = "" }
                if let question = response.clarification {
                    self.reply = question
                } else if let summary = response.intent?.summary, !summary.isEmpty {
                    self.reply = "Request received.\n\(summary)"
                } else {
                    self.reply = "Request received.\nRecommendations are coming next."
                }
                self.isSending = false
                self.sendTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.requestGeneration == generation else { return }
                self.reply = (error as? MochiBackendError)?.errorDescription ?? "Couldn't send your request. Try again."
                self.isSending = false
                self.sendTask = nil
            }
        }
    }

    func reset() {
        requestGeneration = UUID()
        sendTask?.cancel()
        sendTask = nil
        isSending = false
        draft = ""
        preferences = []
        reply = "What do you feel like\nlistening to?"
    }
}

// MARK: - Companion card

struct MochiCompanionCard: View {
    static let size = CGSize(width: 300, height: 180)
    static let searchSize = CGSize(width: 300, height: 340)
    @ObservedObject var request: MochiRequestModel
    @ObservedObject var search: SpotifySearchModel
    var onClose: () -> Void
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                Text(request.isSearchPresented ? "Search Spotify" : request.reply)
                    .font(.system(size: 13)).lineSpacing(2)
                    .lineLimit(3)
                    .help(request.isSearchPresented ? "Search Spotify" : request.reply)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("mochiReply")
                Button { request.isSearchPresented.toggle(); composerFocused = true } label: {
                    Image(systemName: request.isSearchPresented ? "bubble.left" : "magnifyingglass")
                        .frame(width: 20, height: 20)
                }
                .help(request.isSearchPresented ? "Back to listening request" : "Search songs and artists")
                .accessibilityLabel(request.isSearchPresented ? "Back to listening request" : "Search songs and artists")
                .accessibilityIdentifier("mochiSearchToggle")
                if request.isSearchPresented ? !search.query.isEmpty : (!request.preferences.isEmpty || request.isSending) {
                    Button {
                        if request.isSearchPresented { search.reset() } else { request.reset() }
                        composerFocused = true
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(width: 20, height: 20)
                    }
                    .help(request.isSearchPresented ? "Clear search" : "New listening request")
                    .accessibilityLabel(request.isSearchPresented ? "Clear search" : "New listening request")
                    .disabled(request.isSearchPresented && search.isStarting)
                }
                Button(action: onClose) { Image(systemName: "xmark").frame(width: 20, height: 20) }
                    .help("Close Mochi")
                    .accessibilityLabel("Close Mochi")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))

            if request.isSearchPresented {
                searchContent
            } else if request.preferences.isEmpty {
                HStack(spacing: 6) {
                    choice("Focus")
                    choice("Unwind")
                    choice("Surprise me")
                }
            } else {
                Text(request.summary)
                    .font(.system(size: 11)).foregroundStyle(Color.mochiMuted)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .help(request.summary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                TextField("", text: composerText, axis: .vertical)
                    .id(request.isSearchPresented)
                    .font(.system(size: 11))
                    .textFieldStyle(.plain)
                    .lineLimit(1...2)
                    .focused($composerFocused)
                    .onSubmit { submit() }
                    .onChange(of: composerText.wrappedValue) { _, text in
                        let limit = request.isSearchPresented ? 200 : 500
                        if text.count > limit { composerText.wrappedValue = String(text.prefix(limit)) }
                    }
                    .overlay(alignment: .leading) {
                        if composerText.wrappedValue.isEmpty {
                            Text(request.isSearchPresented
                                 ? (search.kind == .song ? "Song title…" : "Artist name…") : "Mood, artist, or song…")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.mochiMuted)
                                .fixedSize(horizontal: false, vertical: true)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(request.isSearchPresented ? "Search query" : "Describe what you want to listen to")
                    .accessibilityIdentifier("mochiComposer")

                Button { submit() } label: {
                    Group {
                        if !request.isSearchPresented && request.isSending {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: request.isSearchPresented ? "magnifyingglass" : "arrow.up")
                        }
                    }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(hex: 0x60705E))
                        .frame(width: 26, height: 26)
                        .background(Color(hex: 0xDCE8D9).opacity(0.65), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(request.isSearchPresented ? !search.canSubmit : !request.canSubmit)
                .help(request.isSearchPresented ? "Search Spotify" : "Send listening request")
                .accessibilityLabel(request.isSearchPresented ? "Search Spotify" : "Send listening request")
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(Color.white.opacity(0.3), in: RoundedRectangle(cornerRadius: 11))
        }
        .padding(14)
        .frame(width: Self.size.width, height: request.isSearchPresented ? Self.searchSize.height : Self.size.height)
        .foregroundStyle(Color.mochiInk)
        .background {
            if reduceTransparency {
                Color(hex: 0xEFF3EC)
            } else {
                CompanionGlass().overlay(Color(hex: 0xEFF3EC).opacity(0.22))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
        .environment(\.colorScheme, .light)
        .onExitCommand(perform: onClose)
        .task(id: request.isSearchPresented) {
            composerFocused = false
            await Task.yield()
            composerFocused = true
        }
    }

    private var composerText: Binding<String> { request.isSearchPresented ? $search.query : $request.draft }

    private func submit() {
        if request.isSearchPresented { search.search() } else { request.submit() }
    }

    private var searchContent: some View {
        VStack(spacing: 8) {
            Picker("Search by", selection: $search.kind) {
                ForEach(SpotifySearchKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
            }
            .pickerStyle(.segmented).controlSize(.small).labelsHidden()
            .disabled(search.isStarting)

            if search.isSearching {
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    ProgressView().controlSize(.small)
                    Text("Searching Spotify…").font(.system(size: 11))
                    Button("Cancel search") { search.cancelSearch() }.font(.system(size: 11))
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if search.results.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Image(systemName: "music.note.list").font(.system(size: 22)).foregroundStyle(Color.mochiMuted)
                    Text(search.isConnected
                         ? "Find a song, or choose Artists\nto find tracks by an artist."
                         : "Connect Spotify from the menu bar\nto find and play songs.")
                        .font(.system(size: 11)).multilineTextAlignment(.center).foregroundStyle(Color.mochiMuted)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(search.results) { track in resultRow(track) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let message = search.message {
                Text(message).font(.system(size: 11)).foregroundStyle(Color.mochiMuted)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).help(message)
                    .accessibilityIdentifier("mochiSearchMessage")
            }
        }.frame(maxHeight: .infinity)
    }

    private func resultRow(_ track: SpotifySearchTrack) -> some View {
        HStack(spacing: 4) {
            Button { search.play(track) } label: {
                HStack(spacing: 8) {
                    AsyncImage(url: track.artworkURL) { image in image.resizable().scaledToFit() } placeholder: {
                        Image(systemName: "music.note").foregroundStyle(Color.mochiMuted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white.opacity(0.3))
                    }.frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(track.artistNames).font(.system(size: 10)).lineLimit(1)
                        Text(track.canPlay ? track.album.name : "Unavailable in your account")
                            .font(.system(size: 9)).foregroundStyle(Color.mochiMuted).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if search.startingTrackID == track.id {
                        ProgressView().controlSize(.mini).frame(width: 16)
                    } else {
                        Image(systemName: "play.fill").font(.system(size: 9)).frame(width: 16)
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!search.canPlay(track))
            .opacity(track.canPlay ? 1 : 0.55)
            .help("\(track.name)\n\(track.artistNames)\n\(track.album.name)")
            .accessibilityLabel("Play \(track.name) by \(track.artistNames)")
            Link(destination: track.spotifyURL) {
                Image(systemName: "arrow.up.right").font(.system(size: 9)).frame(width: 18, height: 28)
            }
            .foregroundStyle(Color.mochiMuted)
            .help("Open in Spotify")
            .accessibilityLabel("Open \(track.name) in Spotify")
        }
        .padding(6)
        .background(Color.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func choice(_ title: String) -> some View {
        Button { request.submit(title); composerFocused = true } label: {
            Text(title).font(.system(size: 11))
                .padding(.horizontal, 12).frame(height: 26)
                .background(Color.white.opacity(0.3), in: Capsule())
                .overlay(Capsule().strokeBorder(Color(hex: 0xA5BCB6).opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(request.isSending)
    }
}

private struct CompanionGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .aqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Native vector rendering of design/mochi.svg

struct MochiMascotView: View {
    var isAnimating = true
    var isHovered = false
    var isHeld = false
    var isEngaged = false
    var isMusicPlaying = false
    var dragLean: CGFloat = 0
    var hoverStartedAt: TimeInterval?
    var releasedAt: TimeInterval?
    var idleStartedAt = Date.timeIntervalSinceReferenceDate
    var wakeStartedAt: TimeInterval?
    var wakeStrength: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30, paused: !isAnimating)) { timeline in
            MochiMascotArtwork(pose: isAnimating
                ? MochiMascotPose.at(time: timeline.date.timeIntervalSinceReferenceDate, isMusicPlaying: isMusicPlaying,
                                    isHovered: isHovered, isHeld: isHeld, isEngaged: isEngaged, dragLean: dragLean,
                                    hoverStartedAt: hoverStartedAt, releasedAt: releasedAt,
                                    idleStartedAt: idleStartedAt, wakeStartedAt: wakeStartedAt,
                                    wakeStrength: wakeStrength, animate: !reduceMotion)
                : MochiMascotPose())
        }
        .accessibilityHidden(true)
    }
}

// Each pose changes the body, face and hands independently. All motion stays inside the panel.
struct MochiMascotPose {
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var tilt: CGFloat = 0
    var lift: CGFloat = 0
    var lookX: CGFloat = 0
    var eyeHeight: CGFloat = 1
    var eyeWidth: CGFloat = 1
    var happyEyes: CGFloat = 0
    var smileDepth: CGFloat = 5
    var mouthOpen: CGFloat = 0
    var cheeks: CGFloat = 0
    var leftWave: CGFloat = 0
    var rightWave: CGFloat = 0
    var closedEyes: CGFloat = 0
    var sleepAmount: CGFloat = 0
    var sleepPhase: CGFloat = 0

    static let sleepDelay: TimeInterval = 90

    static func at(time: TimeInterval, isMusicPlaying: Bool = false,
                   isHovered: Bool = false, isHeld: Bool = false, isEngaged: Bool = false,
                   dragLean: CGFloat = 0, hoverStartedAt: TimeInterval? = nil,
                   releasedAt: TimeInterval? = nil, idleStartedAt: TimeInterval? = nil,
                   wakeStartedAt: TimeInterval? = nil, wakeStrength: CGFloat = 0, animate: Bool = true) -> Self {
        var pose = Self()
        let idleDuration = idleStartedAt.map { max(0, time - $0) } ?? 0
        let sleep = !isHovered && !isHeld && !isEngaged
            ? keyframe(idleDuration, [(0, 0), (sleepDelay, 0), (sleepDelay + 3, 1)]) : 0
        if !animate {
            // Reduce Motion still permits the sleep state, with a static pose and static z's.
            if isMusicPlaying { pose.happyEyes = 1; pose.smileDepth = 17 }
            if sleep > 0 {
                pose.scaleX = 1.07
                pose.scaleY = 0.85
                pose.closedEyes = 1
                pose.sleepAmount = 1
                pose.happyEyes = 0
                pose.smileDepth = 5
            }
            return pose
        }
        let reacting = isActive(hoverStartedAt, at: time, duration: 1.5)
            || isActive(releasedAt, at: time, duration: 0.7)
            || isActive(wakeStartedAt, at: time, duration: 1.2)
        let listening = isMusicPlaying && !isHovered && !isHeld && !isEngaged && !reacting
        let breath = CGFloat(sin(time * .pi / 2.4))
        pose.scaleX = 1 - breath * 0.045
        pose.scaleY = 1 + breath * 0.055
        pose.tilt = CGFloat(sin(time * .pi / 4.5)) * 2
        // A short glance left and right, then back to the center.
        pose.lookX = keyframe(time.truncatingRemainder(dividingBy: 11),
                             [(0, 0), (4, 0), (4.5, -8), (5.5, -8), (6.1, 8), (7.1, 8), (7.7, 0), (11, 0)])
        let blinkPhase = time.truncatingRemainder(dividingBy: 5.5)
        pose.eyeHeight = keyframe(blinkPhase, [(0, 1), (0.09, 0.08), (0.18, 1), (5.5, 1)])
        if listening {
            // A steady party rhythm: two squash-and-stretch bounces per side-to-side sway.
            let beat = time * 2 * .pi / 1.8
            let landing = CGFloat(cos(beat * 2))
            pose.scaleX = 1 + landing * 0.1
            pose.scaleY = 1 - landing * 0.14
            pose.tilt = CGFloat(sin(beat)) * 14
            pose.lift = (1 - landing) * 9
            pose.lookX = 0
            pose.happyEyes = 1
            pose.smileDepth = 17
            pose.cheeks = 0.22
            let sway = CGFloat(sin(beat))
            pose.leftWave = 45 + sway * 35
            pose.rightWave = -(45 - sway * 35)
        }

        if sleep > 0 {
            let slowBreath = CGFloat(sin(time * .pi / 4))
            pose.scaleX += (1.07 - slowBreath * 0.012 - pose.scaleX) * sleep
            pose.scaleY += (0.85 + slowBreath * 0.018 - pose.scaleY) * sleep
            pose.tilt += (-3 + slowBreath * 0.5 - pose.tilt) * sleep
            pose.lookX *= 1 - sleep
            pose.eyeHeight *= 1 - sleep * 0.9
            pose.closedEyes = sleep
            pose.sleepAmount = sleep
            pose.sleepPhase = CGFloat(time / 2.8)
            pose.lift *= 1 - sleep
            pose.happyEyes *= 1 - sleep
            pose.cheeks *= 1 - sleep
            pose.leftWave *= 1 - sleep
            pose.rightWave *= 1 - sleep
            pose.smileDepth += (5 - pose.smileDepth) * sleep
            return pose
        }

        if !isMusicPlaying, !isHovered, !isHeld, !isEngaged, let idleStartedAt, time - idleStartedAt >= 26 {
            let age = (time - idleStartedAt).truncatingRemainder(dividingBy: 26)
            if age <= 1.2 {
                // A brief spontaneous hop: crouch, stretch into the air, squash on landing.
                let reaction = keyframe(age, [(0, 0), (0.06, 1), (0.95, 1), (1.2, 0)])
                let width = keyframe(age, [(0, 1), (0.16, 1.18), (0.3, 0.9), (0.55, 0.98), (0.75, 1.2), (1, 1)])
                let height = keyframe(age, [(0, 1), (0.16, 0.78), (0.3, 1.16), (0.55, 1.04), (0.75, 0.8), (1, 1)])
                pose.scaleX += (width - pose.scaleX) * reaction
                pose.scaleY += (height - pose.scaleY) * reaction
                pose.lift = keyframe(age, [(0, 0), (0.18, 0), (0.43, 30), (0.7, 0), (1.2, 0)])
                pose.lookX *= 1 - reaction
                pose.happyEyes = keyframe(age, [(0, 0), (0.2, 0), (0.35, 1), (0.65, 1), (0.9, 0), (1.2, 0)])
                pose.smileDepth += 10 * reaction
            }
        }

        if isHovered {
            pose.lookX = 0
            pose.eyeWidth = 1.3
            pose.eyeHeight *= 1.12
            pose.smileDepth = 15
            pose.cheeks = 0.38
        }
        if let hoverStartedAt {
            let age = time - hoverStartedAt
            if (0...1.5).contains(age) {
                // Crouch, stretch upward, land softly, then wave with a happy expression.
                let reaction = keyframe(age, [(0, 0), (0.06, 1), (1.1, 1), (1.5, 0)])
                let width = keyframe(age, [(0, 1), (0.12, 1.24), (0.25, 0.85), (0.45, 1.04), (0.58, 1.15), (0.8, 1)])
                let height = keyframe(age, [(0, 1), (0.12, 0.74), (0.25, 1.22), (0.45, 0.96), (0.58, 0.84), (0.8, 1)])
                pose.scaleX += (width - pose.scaleX) * reaction
                pose.scaleY += (height - pose.scaleY) * reaction
                pose.lift = keyframe(age, [(0, 0), (0.12, 0), (0.3, 12), (0.48, 0), (1.5, 0)])
                pose.tilt += keyframe(age, [(0, 0), (0.4, 0), (0.6, -7), (0.9, 5), (1.5, 0)])
                pose.happyEyes = keyframe(age, [(0, 0), (0.45, 0), (0.65, 1), (1.1, 1), (1.5, 0)])
                pose.smileDepth = 5 + 12 * keyframe(age, [(0, 0), (0.4, 1), (1.1, 1), (1.5, 0)])
                if age > 0.45 {
                    let wave = (age - 0.45) / 1.05
                    pose.rightWave = -CGFloat(sin(wave * .pi) * (65 + 20 * sin(wave * 4 * .pi)))
                }
            }
        }
        if let releasedAt {
            let age = time - releasedAt
            if (0...0.7).contains(age) {
                pose.scaleX *= keyframe(age, [(0, 1.22), (0.22, 0.94), (0.45, 1.045), (0.7, 1)])
                pose.scaleY *= keyframe(age, [(0, 0.75), (0.22, 1.08), (0.45, 0.96), (0.7, 1)])
            }
        }
        if !isHeld, let wakeStartedAt {
            let age = time - wakeStartedAt
            if (0...1.2).contains(age) {
                let reaction = wakeStrength * keyframe(age, [(0, 1), (0.95, 1), (1.2, 0)])
                let width = keyframe(age, [(0, 1.07), (0.3, 0.88), (0.5, 0.88), (0.8, 1.1), (1.2, 1)])
                let height = keyframe(age, [(0, 0.85), (0.3, 1.16), (0.5, 1.16), (0.8, 0.92), (1.2, 1)])
                pose.scaleX += (width - pose.scaleX) * reaction
                pose.scaleY += (height - pose.scaleY) * reaction
                pose.closedEyes = wakeStrength * keyframe(age, [(0, 1), (0.45, 0.7), (0.65, 0), (0.82, 1), (0.95, 0), (1.2, 0)])
                pose.sleepAmount = wakeStrength * keyframe(age, [(0, 1), (0.3, 0), (1.2, 0)])
                pose.sleepPhase = CGFloat(time / 2.8)
                pose.lift = 0
                pose.rightWave = 0
            }
        }
        if isHeld {
            pose.scaleX = 0.88
            pose.scaleY = 1.16
            pose.tilt = dragLean * 9
            pose.lift = 0
            pose.lookX = dragLean * 8
            pose.eyeHeight = 1.4
            pose.eyeWidth = 1.35
            pose.happyEyes = 0
            pose.mouthOpen = 1
            pose.cheeks = 0
            pose.rightWave = 0
        }
        return pose
    }

    private static func isActive(_ startedAt: TimeInterval?, at time: TimeInterval, duration: TimeInterval) -> Bool {
        guard let startedAt else { return false }
        return (0..<duration).contains(time - startedAt)
    }

    private static func keyframe(_ time: TimeInterval, _ frames: [(TimeInterval, CGFloat)]) -> CGFloat {
        guard let first = frames.first, let last = frames.last else { return 0 }
        if time <= first.0 { return first.1 }
        for (left, right) in zip(frames, frames.dropFirst()) where time <= right.0 {
            let progress = CGFloat((time - left.0) / (right.0 - left.0))
            let eased = progress * progress * (3 - 2 * progress)
            return left.1 + (right.1 - left.1) * eased
        }
        return last.1
    }
}

struct MochiMascotArtwork: View {
    let pose: MochiMascotPose

    var body: some View {
        Canvas { context, size in
            // Extra margin contains stretched poses and the waving hand, without changing the hit area.
            let scale = min(size.width / 420, size.height / 360)
            context.translateBy(x: (size.width - 420 * scale) / 2, y: (size.height - 360 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -30, y: -30)
            let markers = context
            context.translateBy(x: 0, y: -pose.lift)
            context.translateBy(x: 240, y: 350)
            context.rotate(by: .degrees(Double(pose.tilt)))
            context.scaleBy(x: pose.scaleX, y: pose.scaleY)
            context.translateBy(x: -240, y: -350)

            // Rotate from roots inside the body, then cover them with the body fill.
            // The hidden overlap keeps large waves attached instead of exposing an open seam.
            for (hand, anchor, angle) in [(MochiArt.leftHand, MochiArt.leftHandRoot, pose.leftWave),
                                          (MochiArt.rightHand, MochiArt.rightHandRoot, pose.rightWave)] {
                var handContext = context
                handContext.translateBy(x: anchor.x, y: anchor.y)
                handContext.rotate(by: .degrees(Double(angle)))
                let handScale = 1 + min(abs(angle) / 65, 1) * 0.6
                handContext.scaleBy(x: handScale, y: handScale)
                handContext.translateBy(x: -anchor.x, y: -anchor.y)
                handContext.fill(hand, with: .color(Color(hex: 0xC8DACE)))
                handContext.stroke(hand, with: .color(Color(hex: 0x8EA69D)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            context.fill(MochiArt.body, with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(hex: 0xE1EADF), location: 0),
                    .init(color: Color(hex: 0xD9E5D9), location: 0.43),
                    .init(color: Color(hex: 0xC8DACE), location: 0.68),
                    .init(color: Color(hex: 0xB6CEC3), location: 0.88),
                    .init(color: Color(hex: 0xA5BCB6), location: 1)
                ]), startPoint: CGPoint(x: 97.9254, y: 109.838), endPoint: CGPoint(x: 126.788, y: 372.605)))
            context.fill(MochiArt.base, with: .color(Color(hex: 0x9DAFAF).opacity(0.3)))

            var face = context
            face.translateBy(x: pose.lookX, y: 0)
            // Keep the sleeping face readable even as the body flattens and breathes.
            let sleepStroke = 5 / min(pose.scaleX, pose.scaleY)
            for x: CGFloat in [190, 290] {
                if pose.closedEyes == 0 {
                    // Preserve the existing awake eyes and happy expression.
                    let height = 22 * pose.eyeHeight
                    let width = 14 * pose.eyeWidth
                    face.fill(Path(ellipseIn: CGRect(x: x - width / 2, y: 244 - height / 2, width: width, height: height)),
                              with: .color(Color.mochiInk.opacity(Double(1 - pose.happyEyes))))
                    let happyEye = Path { p in
                        p.move(to: CGPoint(x: x - 10, y: 245))
                        p.addQuadCurve(to: CGPoint(x: x + 10, y: 245), control: CGPoint(x: x, y: 229))
                    }
                    face.stroke(happyEye, with: .color(Color.mochiInk.opacity(Double(pose.happyEyes))),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    continue
                }
                // One solid contour morphs from an oval to a curved lid; no translucent overlap.
                let closure = pose.closedEyes
                let width = 14 * pose.eyeWidth * (1 - closure) + 20 * closure
                let height = max(sleepStroke, 22 * pose.eyeHeight) * (1 - closure)
                let bend = 3 * pose.closedEyes - 7 * pose.happyEyes * (1 - pose.closedEyes)
                let radiusX = width / 2, radiusY = height / 2
                let curve: CGFloat = 0.5522848
                let eye = Path { p in
                    p.move(to: CGPoint(x: x - radiusX, y: 244))
                    p.addCurve(to: CGPoint(x: x, y: 244 + bend - radiusY),
                               control1: CGPoint(x: x - radiusX, y: 244 + bend / 2 - radiusY * curve),
                               control2: CGPoint(x: x - radiusX * curve, y: 244 + bend - radiusY))
                    p.addCurve(to: CGPoint(x: x + radiusX, y: 244),
                               control1: CGPoint(x: x + radiusX * curve, y: 244 + bend - radiusY),
                               control2: CGPoint(x: x + radiusX, y: 244 + bend / 2 - radiusY * curve))
                    p.addCurve(to: CGPoint(x: x, y: 244 + bend + radiusY),
                               control1: CGPoint(x: x + radiusX, y: 244 + bend / 2 + radiusY * curve),
                               control2: CGPoint(x: x + radiusX * curve, y: 244 + bend + radiusY))
                    p.addCurve(to: CGPoint(x: x - radiusX, y: 244),
                               control1: CGPoint(x: x - radiusX * curve, y: 244 + bend + radiusY),
                               control2: CGPoint(x: x - radiusX, y: 244 + bend / 2 + radiusY * curve))
                    p.closeSubpath()
                }
                face.fill(eye, with: .color(Color.mochiInk))
                if closure > 0 {
                    face.stroke(eye, with: .color(Color.mochiInk),
                                style: StrokeStyle(lineWidth: sleepStroke * closure, lineCap: .round, lineJoin: .round))
                }
            }
            for x: CGFloat in [173, 291] {
                face.fill(Path(ellipseIn: CGRect(x: x, y: 263, width: 20, height: 9)),
                          with: .color(Color(hex: 0xDBAFA9).opacity(Double(pose.cheeks))))
            }
            let smile = Path { p in
                p.move(to: CGPoint(x: 231, y: 243))
                p.addQuadCurve(to: CGPoint(x: 251, y: 243), control: CGPoint(x: 241, y: 243 + pose.smileDepth))
            }
            let sleepWeight = max(pose.sleepAmount, pose.closedEyes)
            let mouthStroke = 3 + (sleepStroke - 3) * sleepWeight
            face.stroke(smile, with: .color(Color.mochiInk.opacity(Double(1 - pose.mouthOpen))),
                        style: StrokeStyle(lineWidth: mouthStroke, lineCap: .round))
            face.fill(Path(ellipseIn: CGRect(x: 235, y: 240, width: 12, height: 14)),
                      with: .color(Color.mochiInk.opacity(Double(pose.mouthOpen))))
            if pose.sleepAmount > 0 {
                for index in 0..<3 {
                    let phase = (pose.sleepPhase + CGFloat(index) / 3 + 0.15).truncatingRemainder(dividingBy: 1)
                    let opacity = pose.sleepAmount * sin(phase * .pi) * 0.8
                    let letter = Text("z").font(.system(size: 20 + phase * 8, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.mochiInk.opacity(Double(opacity)))
                    markers.draw(letter, at: CGPoint(x: 315 + phase * 48, y: 128 - phase * 70))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private enum MochiArt {
    static let body = Path { p in
        p.move(to: CGPoint(x: 236, y: 110))
        p.addCurve(to: CGPoint(x: 367, y: 200), control1: CGPoint(x: 302, y: 107), control2: CGPoint(x: 349, y: 146))
        p.addCurve(to: CGPoint(x: 380, y: 330), control1: CGPoint(x: 379, y: 238), control2: CGPoint(x: 391, y: 294))
        p.addCurve(to: CGPoint(x: 240, y: 372), control1: CGPoint(x: 371, y: 361), control2: CGPoint(x: 336, y: 372))
        p.addCurve(to: CGPoint(x: 104, y: 332), control1: CGPoint(x: 155, y: 372), control2: CGPoint(x: 115, y: 362))
        p.addCurve(to: CGPoint(x: 114, y: 208), control1: CGPoint(x: 91, y: 297), control2: CGPoint(x: 101, y: 248))
        p.addCurve(to: CGPoint(x: 236, y: 110), control1: CGPoint(x: 133, y: 147), control2: CGPoint(x: 173, y: 112))
        p.closeSubpath()
    }
    static let base = Path { p in
        p.move(to: CGPoint(x: 105, y: 340))
        p.addCurve(to: CGPoint(x: 240, y: 361), control1: CGPoint(x: 144, y: 355), control2: CGPoint(x: 184, y: 360))
        p.addCurve(to: CGPoint(x: 376, y: 340), control1: CGPoint(x: 297, y: 362), control2: CGPoint(x: 340, y: 355))
        p.addCurve(to: CGPoint(x: 240, y: 372), control1: CGPoint(x: 363, y: 364), control2: CGPoint(x: 320, y: 372))
        p.addCurve(to: CGPoint(x: 105, y: 340), control1: CGPoint(x: 169, y: 372), control2: CGPoint(x: 124, y: 363))
        p.closeSubpath()
    }
    static let leftHandRoot = CGPoint(x: 112, y: 284)
    static let rightHandRoot = CGPoint(x: 370, y: 284)
    static let leftHand = hand(root: leftHandRoot, angle: atan2(15, -12))
    static let rightHand = hand(root: rightHandRoot, angle: atan2(15, 12))

    private static func hand(root: CGPoint, angle: CGFloat) -> Path {
        // One convex outline avoids a second lobe as the arm rotates.
        // Its six-point root stays covered by the body even at maximum hand scale.
        let shape = Path(roundedRect: CGRect(x: -6, y: -6, width: 32, height: 12), cornerRadius: 6)
        let transform = CGAffineTransform(translationX: root.x, y: root.y).rotated(by: angle)
        return shape.applying(transform)
    }

}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
    static let mochiInk = Color(hex: 0x514951)
    static let mochiMuted = Color(hex: 0x637167)
}

#Preview("Companion") {
    MochiCompanionCard(request: MochiRequestModel(), search: SpotifySearchModel(), onClose: {})
}
