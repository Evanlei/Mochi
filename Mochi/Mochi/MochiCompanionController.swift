import AppKit
import Combine
import SwiftUI

// MARK: - App lifetime

@MainActor
final class MochiAppDelegate: NSObject, NSApplicationDelegate {
    let companion = MochiCompanionController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        companion.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companion.stop()
    }
}

// MARK: - Desktop windows

@MainActor
final class MochiCompanionController: ObservableObject {
    @Published private(set) var isVisible: Bool
    let request = MochiRequestModel()
    private(set) var mascotPanel: NSPanel?
    private(set) var cardPanel: NSPanel?

    private let defaults: UserDefaults
    private var screenObserver: NSObjectProtocol?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private let mascotSize = NSSize(width: 108, height: 100)
    private let cardSize = MochiCompanionCard.size

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isVisible = defaults.object(forKey: "mochi.companion.visible") as? Bool ?? true
    }

    func start() {
        guard mascotPanel == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let mascot = CompanionPanel(contentRect: NSRect(origin: .zero, size: mascotSize), acceptsKeyboard: false)
        mascot.title = "Mochi companion"
        mascot.hasShadow = false
        let interaction = MascotInteractionView(frame: NSRect(origin: .zero, size: mascotSize))
        interaction.onClick = { [weak self] in self?.toggleCard() }
        interaction.onMove = { [weak self] origin in self?.moveMascot(to: origin) }
        interaction.onDragEnd = { [weak self] in self?.savePosition() }
        interaction.setAnimating(isVisible)
        mascot.contentView = interaction
        mascotPanel = mascot

        let card = CompanionPanel(contentRect: NSRect(origin: .zero, size: cardSize), acceptsKeyboard: true)
        card.title = "Talk to Mochi"
        card.contentView = NSHostingView(rootView: MochiCompanionCard(request: request) { [weak self] in self?.closeCard() })
        cardPanel = card

        let saved = defaults.dictionary(forKey: "mochi.companion.position")
        let origin: NSPoint
        if let x = saved?["x"] as? Double, let y = saved?["y"] as? Double, x.isFinite, y.isFinite {
            origin = NSPoint(x: x, y: y)
        } else {
            origin = NSPoint(x: screen.visibleFrame.maxX - mascotSize.width - 28, y: screen.visibleFrame.minY + 28)
        }
        moveMascot(to: origin)
        if isVisible { mascot.orderFrontRegardless() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let origin = self.mascotPanel?.frame.origin else { return }
                self.moveMascot(to: origin)
                self.savePosition()
            }
        }
    }

    func setVisible(_ visible: Bool) {
        if mascotPanel == nil { start() }
        isVisible = visible
        defaults.set(visible, forKey: "mochi.companion.visible")
        (mascotPanel?.contentView as? MascotInteractionView)?.setAnimating(visible)
        if visible { mascotPanel?.orderFrontRegardless() }
        else { closeCard(); mascotPanel?.orderOut(nil) }
    }

    func toggleCard() {
        guard isVisible, let cardPanel else { return }
        if cardPanel.isVisible { closeCard(); return }
        positionCard()
        (mascotPanel?.contentView as? MascotInteractionView)?.setEngaged(true)
        cardPanel.makeKeyAndOrderFront(nil)
        monitorOutsideClicks()
    }

    func closeCard() {
        (mascotPanel?.contentView as? MascotInteractionView)?.setEngaged(false)
        cardPanel?.orderOut(nil)
        removeMouseMonitors()
    }

    func moveMascot(to origin: NSPoint) {
        guard let mascotPanel else { return }
        let center = NSPoint(x: origin.x + mascotSize.width / 2, y: origin.y + mascotSize.height / 2)
        guard let frame = CompanionPlacement.closestFrame(to: center, frames: NSScreen.screens.map(\.visibleFrame)) else { return }
        mascotPanel.setFrameOrigin(CompanionPlacement.clamp(origin, size: mascotSize, inside: frame))
        if cardPanel?.isVisible == true { positionCard() }
    }

    func savePosition() {
        guard let origin = mascotPanel?.frame.origin else { return }
        defaults.set(["x": Double(origin.x), "y": Double(origin.y)], forKey: "mochi.companion.position")
    }

    func stop() {
        savePosition()
        closeCard()
        (mascotPanel?.contentView as? MascotInteractionView)?.setAnimating(false)
        mascotPanel?.orderOut(nil)
        mascotPanel = nil
        cardPanel = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private func positionCard() {
        guard let mascotPanel, let cardPanel,
              let frame = CompanionPlacement.closestFrame(to: NSPoint(x: mascotPanel.frame.midX, y: mascotPanel.frame.midY),
                                                           frames: NSScreen.screens.map(\.visibleFrame)) else { return }
        cardPanel.setFrameOrigin(CompanionPlacement.cardOrigin(near: mascotPanel.frame, size: cardSize, inside: frame))
    }

    private func monitorOutsideClicks() {
        removeMouseMonitors()
        // Mouse clicks only: no keyboard monitoring or Accessibility permission required.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closeIfOutside() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.mascotPanel && event.window !== self?.cardPanel { self?.closeCard() }
            return event
        }
    }

    private func closeIfOutside() {
        let point = NSEvent.mouseLocation
        guard cardPanel?.frame.contains(point) != true, mascotPanel?.frame.contains(point) != true else { return }
        closeCard()
    }

    private func removeMouseMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }
}

private final class CompanionPanel: NSPanel {
    private let acceptsKeyboard: Bool
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect, acceptsKeyboard: Bool) {
        self.acceptsKeyboard = acceptsKeyboard
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }
}

private final class MascotInteractionView: NSView {
    var onClick: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    private var initialMouse = NSPoint.zero
    private var initialOrigin = NSPoint.zero
    private var previousMouse = NSPoint.zero
    private var dragged = false
    private let artwork = NSHostingView(rootView: MochiMascotView())
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        artwork.frame = bounds
        artwork.autoresizingMask = [.width, .height]
        addSubview(artwork)
        toolTip = "Click to talk to Mochi. Drag to move."
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Talk to Mochi")
        setAccessibilityHelp("Click to open or close. Drag to move around the screen.")
    }

    required init?(coder: NSCoder) { nil }
    func setEngaged(_ engaged: Bool) {
        recordInteraction()
        artwork.rootView.isEngaged = engaged
    }

    private func recordInteraction() {
        let now = Date.timeIntervalSinceReferenceDate
        let pose = artwork.rootView
        if !pose.isHovered, !pose.isHeld, !pose.isEngaged {
            let sleep = min(max((now - pose.idleStartedAt - MochiMascotPose.sleepDelay) / 3, 0), 1)
            if sleep > 0 {
                artwork.rootView.wakeStartedAt = now
                artwork.rootView.wakeStrength = sleep
            }
        }
        artwork.rootView.idleStartedAt = now
    }

    func setAnimating(_ active: Bool) {
        if active {
            artwork.rootView.isAnimating = true
            artwork.rootView.idleStartedAt = Date.timeIntervalSinceReferenceDate
        }
        else { artwork.rootView = MochiMascotView(isAnimating: false) }
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard artwork.rootView.isAnimating, window?.isVisible == true else { return }
        recordInteraction()
        artwork.rootView.isHovered = true
        if !artwork.rootView.isHeld {
            let now = Date.timeIntervalSinceReferenceDate
            let waking = artwork.rootView.wakeStartedAt.map { now - $0 < 1.2 } ?? false
            artwork.rootView.hoverStartedAt = now + (waking ? 1.2 : 0)
        }
    }

    override func mouseExited(with event: NSEvent) {
        artwork.rootView.isHovered = false
        artwork.rootView.idleStartedAt = Date.timeIntervalSinceReferenceDate
    }

    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func mouseDown(with event: NSEvent) {
        initialMouse = NSEvent.mouseLocation
        previousMouse = initialMouse
        initialOrigin = window?.frame.origin ?? .zero
        dragged = false
        recordInteraction()
        artwork.rootView.hoverStartedAt = nil
        artwork.rootView.releasedAt = nil
        artwork.rootView.isHeld = true
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - initialMouse.x, dy = mouse.y - initialMouse.y
        guard dragged || hypot(dx, dy) >= 4 else { return }
        dragged = true
        artwork.rootView.dragLean = min(max((mouse.x - previousMouse.x) / 12, -1), 1)
        previousMouse = mouse
        NSCursor.closedHand.set()
        onMove?(NSPoint(x: initialOrigin.x + dx, y: initialOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.openHand.set()
        setAnimating(window?.isVisible == true)
        artwork.rootView.isHeld = false
        artwork.rootView.dragLean = 0
        artwork.rootView.isHovered = window?.frame.contains(NSEvent.mouseLocation) == true
        artwork.rootView.releasedAt = Date.timeIntervalSinceReferenceDate
        if dragged { onDragEnd?() }
        else { onClick?() }
    }
}

// MARK: - Placement on one or multiple displays

enum CompanionPlacement {
    nonisolated static func clamp(_ origin: NSPoint, size: NSSize, inside frame: NSRect) -> NSPoint {
        NSPoint(x: min(max(origin.x, frame.minX), max(frame.minX, frame.maxX - size.width)),
                y: min(max(origin.y, frame.minY), max(frame.minY, frame.maxY - size.height)))
    }

    nonisolated static func cardOrigin(near mascot: NSRect, size: NSSize, inside frame: NSRect) -> NSPoint {
        let above = mascot.maxY + 8
        let y = above + size.height <= frame.maxY ? above : mascot.minY - size.height - 8
        return clamp(NSPoint(x: mascot.maxX - size.width, y: y), size: size, inside: frame)
    }

    nonisolated static func closestFrame(to point: NSPoint, frames: [NSRect]) -> NSRect? {
        frames.min { distance(point, to: $0) < distance(point, to: $1) }
    }

    nonisolated private static func distance(_ point: NSPoint, to frame: NSRect) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return dx * dx + dy * dy
    }
}
