import AppKit
import Foundation

@main
struct CompanionChecks {
    @MainActor
    static func main() async throws {
        let screen = NSRect(x: 0, y: 40, width: 1200, height: 800)
        let mascotSize = NSSize(width: 94, height: 88)
        let cardSize = MochiCompanionCard.size
        precondition(CompanionPlacement.clamp(NSPoint(x: -200, y: -300), size: mascotSize, inside: screen) == NSPoint(x: 0, y: 40))
        precondition(CompanionPlacement.clamp(NSPoint(x: 9000, y: 9000), size: mascotSize, inside: screen) == NSPoint(x: 1106, y: 752))
        let bottom = NSRect(x: 1080, y: 50, width: 94, height: 88)
        let above = CompanionPlacement.cardOrigin(near: bottom, size: cardSize, inside: screen)
        precondition(screen.contains(NSRect(origin: above, size: cardSize)) && above.y > bottom.maxY)
        let top = NSRect(x: 1080, y: 700, width: 94, height: 88)
        let below = CompanionPlacement.cardOrigin(near: top, size: cardSize, inside: screen)
        precondition(screen.contains(NSRect(origin: below, size: cardSize)) && below.y + cardSize.height < top.minY)
        let leftDisplay = NSRect(x: -1600, y: 0, width: 1600, height: 900)
        precondition(CompanionPlacement.closestFrame(to: NSPoint(x: -400, y: 200), frames: [screen, leftDisplay]) == leftDisplay)
        precondition(CompanionPlacement.closestFrame(to: NSPoint(x: -400, y: 200), frames: [screen]) == screen)
        precondition(CompanionPlacement.closestFrame(to: .zero, frames: []) == nil)
        print("PASS: screen-edge clamping, above/below card placement, and removed/negative-coordinate displays")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let suite = "com.evan.Mochi.companion-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Simulate a remembered display that is no longer connected.
        defaults.set(["x": -100_000.0, "y": -100_000.0], forKey: "mochi.companion.position")
        let companion = MochiCompanionController(defaults: defaults)
        companion.start()
        defer { companion.stop() }
        let mascot = companion.mascotPanel!
        let card = companion.cardPanel!
        precondition(mascot.isVisible && !card.isVisible)
        precondition(!mascot.canBecomeKey && card.canBecomeKey)
        precondition(mascot.styleMask.contains(.nonactivatingPanel) && mascot.collectionBehavior.contains(.canJoinAllSpaces))
        precondition(NSScreen.screens.contains { $0.visibleFrame.contains(mascot.frame) })
        precondition(mascot.contentView!.accessibilityPerformPress())
        precondition(card.isVisible && NSScreen.screens.contains { $0.visibleFrame.contains(card.frame) })
        try await Task.sleep(for: .milliseconds(300))

        if let previewDirectory = CommandLine.arguments.dropFirst().first {
            let directory = URL(fileURLWithPath: previewDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, panel) in [("card", card), ("mascot", mascot)] {
                let view = panel.contentView!
                view.layoutSubtreeIfNeeded()
                let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: image)
                try image.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name).png"))
            }
            print("Rendered native companion previews to \(directory.path)")
        }

        guard let input = card.firstResponder as? NSTextInputClient else {
            fatalError("The companion composer did not receive keyboard focus")
        }
        input.insertText("Soft piano for studying", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        precondition(companion.request.draft == "Soft piano for studying")
        companion.closeCard()
        companion.toggleCard()
        precondition(card.isVisible && companion.request.draft == "Soft piano for studying")
        try await Task.sleep(for: .milliseconds(50))
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: card.windowNumber, context: nil, characters: "\r",
                                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        card.sendEvent(enter)
        try await Task.sleep(for: .milliseconds(50))
        precondition(companion.request.summary == "Soft piano for studying" && companion.request.draft.isEmpty)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: card.windowNumber, context: nil, characters: "\u{1b}",
                                     charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        card.sendEvent(escape)
        try await Task.sleep(for: .milliseconds(50))
        precondition(!card.isVisible)
        companion.closeCard()
        precondition(mascot.contentView!.accessibilityPerformPress())
        precondition(companion.request.summary == "Soft piano for studying")
        print("PASS: native panel creation, accessible toggle, keyboard typing/Return/Escape, and request retention")

        companion.moveMascot(to: NSPoint(x: 100_000, y: 100_000))
        precondition(NSScreen.screens.contains { $0.visibleFrame.contains(mascot.frame) })
        precondition(NSScreen.screens.contains { $0.visibleFrame.contains(card.frame) })
        companion.savePosition()
        let savedOrigin = mascot.frame.origin
        companion.setVisible(false)
        precondition(!mascot.isVisible && !card.isVisible)
        companion.stop()

        let restored = MochiCompanionController(defaults: defaults)
        restored.start()
        defer { restored.stop() }
        precondition(!restored.isVisible && restored.mascotPanel?.isVisible == false)
        precondition(restored.mascotPanel?.frame.origin == savedOrigin)
        restored.setVisible(true)
        precondition(restored.mascotPanel?.isVisible == true)
        restored.toggleCard()
        restored.setVisible(false)
        precondition(restored.cardPanel?.isVisible == false)
        print("PASS: moving both windows, saved placement, hidden-state restoration, and show/hide cleanup")
    }
}
