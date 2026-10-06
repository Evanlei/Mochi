import Combine
import SwiftUI

// MARK: - Listening request

@MainActor
final class MochiRequestModel: ObservableObject {
    @Published var draft = ""
    @Published private(set) var preferences: [String] = []
    @Published private(set) var reply = "What do you feel like\nlistening to?"

    var canSubmit: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var summary: String { preferences.joined(separator: " · ") }

    func submit(_ choice: String? = nil) {
        let text = (choice ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // These preferences belong to this app session; discovery will consume them later.
        preferences.append(String(text.prefix(500)))
        draft = ""
        reply = preferences.count == 1
            ? "Any artist, song, or sound you'd like me to include?"
            : "I've saved your preferences. Music discovery is coming next."
    }

    func reset() {
        draft = ""
        preferences = []
        reply = "What do you feel like\nlistening to?"
    }
}

// MARK: - Companion card

struct MochiCompanionCard: View {
    @ObservedObject var request: MochiRequestModel
    var onClose: () -> Void
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                MochiMascotView().frame(width: 27, height: 25)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("mochi").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.mochiInk)
                    HStack(spacing: 6) {
                        Circle().fill(Color.mochiAccent).frame(width: 5, height: 5)
                        Text("let’s find your next listen")
                            .font(.system(size: 10)).foregroundStyle(Color.mochiMuted)
                    }
                }
                Spacer()
                if !request.preferences.isEmpty {
                    Button { request.reset(); composerFocused = true } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .help("New listening request")
                    .accessibilityLabel("New listening request")
                }
                Button(action: onClose) { Image(systemName: "xmark") }
                    .help("Close Mochi")
                    .accessibilityLabel("Close Mochi")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.mochiMuted)

            Rectangle().fill(Color(hex: 0xECEEE7)).frame(height: 1).padding(.top, 18)

            Text(request.reply)
                .font(.system(size: 13))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 13)
                .background(Color(hex: 0xEFF3EC), in: RoundedRectangle(cornerRadius: 14))
                .padding(.top, 25)
                .accessibilityIdentifier("mochiReply")

            if request.preferences.isEmpty {
                HStack(spacing: 8) {
                    choice("Focus")
                    choice("Unwind")
                    choice("Surprise me")
                }
                .padding(.top, 18)
            } else {
                Text(request.summary)
                    .font(.system(size: 11)).foregroundStyle(Color.mochiMuted)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
                    .help(request.summary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                TextField("", text: $request.draft, axis: .vertical)
                    .font(.system(size: 11))
                    .textFieldStyle(.plain)
                    .lineLimit(2...2)
                    .focused($composerFocused)
                    .onSubmit { request.submit() }
                    .onChange(of: request.draft) { _, text in
                        if text.count > 500 { request.draft = String(text.prefix(500)) }
                    }
                    .overlay(alignment: .leading) {
                        if request.draft.isEmpty {
                            Text("Tell me a mood, artist,\nor song…")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.mochiMuted)
                                .fixedSize(horizontal: false, vertical: true)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("Describe what you want to listen to")

                Button { request.submit() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(hex: 0x60705E))
                        .frame(width: 30, height: 30)
                        .background(Color(hex: 0xDCE8D9), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!request.canSubmit)
                .help("Send listening request")
                .accessibilityLabel("Send listening request")
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(Color(hex: 0xF3F4EF), in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(20)
        .frame(width: 352, height: 337)
        .foregroundStyle(Color.mochiInk)
        .background(Color(hex: 0xFBFBF7), in: RoundedRectangle(cornerRadius: 20))
        .environment(\.colorScheme, .light)
        .onExitCommand(perform: onClose)
        .task { composerFocused = true }
    }

    private func choice(_ title: String) -> some View {
        Button { request.submit(title); composerFocused = true } label: {
            Text(title).font(.system(size: 11))
                .padding(.horizontal, 16).frame(height: 30)
                .background(Color(hex: 0xFBFBF7), in: Capsule())
                .overlay(Capsule().strokeBorder(Color(hex: 0xDCE4D8), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Native vector rendering of design/mochi.svg

struct MochiMascotView: View {
    var body: some View {
        Canvas { context, size in
            // Crop the SVG's empty margins, then scale its original coordinates uniformly.
            let scale = min(size.width / 310, size.height / 288)
            context.translateBy(x: (size.width - 310 * scale) / 2, y: (size.height - 288 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -85, y: -100)

            context.fill(Path(ellipseIn: CGRect(x: 100, y: 365, width: 280, height: 18)),
                         with: .color(Color(hex: 0xB7AFB9).opacity(0.4)))
            context.fill(MochiArt.body, with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(hex: 0xE1EADF), location: 0),
                    .init(color: Color(hex: 0xD9E5D9), location: 0.43),
                    .init(color: Color(hex: 0xC8DACE), location: 0.68),
                    .init(color: Color(hex: 0xB6CEC3), location: 0.88),
                    .init(color: Color(hex: 0xA5BCB6), location: 1)
                ]), startPoint: CGPoint(x: 97.9254, y: 109.838), endPoint: CGPoint(x: 126.788, y: 372.605)))
            context.fill(MochiArt.base, with: .color(Color(hex: 0x9DAFAF).opacity(0.3)))
            for hand in [MochiArt.leftHand, MochiArt.rightHand] {
                context.fill(hand, with: .color(Color(hex: 0xC8DACE)))
                context.stroke(hand, with: .color(Color(hex: 0x8EA69D)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            for x: CGFloat in [183, 283] {
                context.fill(Path(ellipseIn: CGRect(x: x, y: 233, width: 14, height: 22)), with: .color(Color.mochiInk))
            }
            context.stroke(MochiArt.smile, with: .color(Color.mochiInk), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
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
    static let leftHand = Path { p in
        p.move(to: CGPoint(x: 104, y: 284))
        p.addCurve(to: CGPoint(x: 96, y: 304), control1: CGPoint(x: 95, y: 290), control2: CGPoint(x: 89, y: 299))
        p.addCurve(to: CGPoint(x: 114, y: 299), control1: CGPoint(x: 101, y: 309), control2: CGPoint(x: 109, y: 306))
    }
    static let rightHand = Path { p in
        p.move(to: CGPoint(x: 378, y: 284))
        p.addCurve(to: CGPoint(x: 385, y: 304), control1: CGPoint(x: 387, y: 291), control2: CGPoint(x: 392, y: 299))
        p.addCurve(to: CGPoint(x: 371, y: 299), control1: CGPoint(x: 380, y: 308), control2: CGPoint(x: 375, y: 305))
    }
    static let smile = Path { p in
        p.move(to: CGPoint(x: 231, y: 243))
        p.addCurve(to: CGPoint(x: 251, y: 243), control1: CGPoint(x: 237.667, y: 247.667), control2: CGPoint(x: 244.333, y: 247.667))
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
    static let mochiInk = Color(hex: 0x514951)
    static let mochiMuted = Color(hex: 0x90978B)
    static let mochiAccent = Color(hex: 0x95AA98)
}

#Preview("Companion") {
    MochiCompanionCard(request: MochiRequestModel(), onClose: {})
}
