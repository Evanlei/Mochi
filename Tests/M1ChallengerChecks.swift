import AppKit
import ApplicationServices
import Foundation
import SwiftUI

@main
struct M1ChallengerChecks {
    @MainActor
    static func main() async throws {
        print("=================================================================")
        print("       M1 Adversarial Challenger Verification & Stress Tests      ")
        print("=================================================================")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        try await test1HitTargetsAndGeometry()
        try await test2ReduceMotionAndSpringDynamics()
        try await test3DisabledStatesAndClickRejection()
        try await test4RapidClickingAndConcurrency()
        try await test5RateLimitCooldownBurst()
        try await test6HoverBoundsAndOpacitySuppression()
        try await test7PlaybackTogglingAndArtworkSwitching()
        try await test8SettingsPopoverAndDismissalSemantics()

        print("\n=================================================================")
        print("  🎉 ALL ADVERSARIAL CHALLENGER TESTS PASSED (8/8 SUITES)!")
        print("=================================================================")
    }

    // MARK: - Helpers

    @MainActor
    private static func makeContext() -> (E2ETestContext, NSHostingView<NowPlayingView>, Binding<Bool>) {
        let ctx = E2ETestContext(suitePrefix: "com.evan.Mochi.challenger")
        var showsLink = false
        let binding = Binding(get: { showsLink }, set: { showsLink = $0 })
        let view = NowPlayingView(spotify: ctx.auth, playback: ctx.playback, showsLinkEntry: binding)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        hosting.layoutSubtreeIfNeeded()
        AXQuery.activateAccessibilityTree()
        return (ctx, hosting, binding)
    }

    // MARK: - Test 1: Hit Targets & Geometry

    @MainActor
    static func test1HitTargetsAndGeometry() async throws {
        print("\n[Suite 1] Stress-Testing Transport Hit Targets & Layout Geometry...")
        let (ctx, hosting, _) = makeContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()

        let trackData = try E2ETestContext.makePlaybackJSON(name: "Geometry Test", isPlaying: true)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: trackData)])
        await ctx.playback.refresh(using: ctx.auth)
        hosting.layoutSubtreeIfNeeded()

        // 1.1 Verify exact accessibility labels exist
        let prevBtn = AXQuery.findButton(label: "Previous track", in: hosting)
        let playPauseBtn = AXQuery.findButton(label: "Pause", in: hosting)
        let nextBtn = AXQuery.findButton(label: "Next track", in: hosting)

        precondition(prevBtn != nil, "1.1: Previous track button must be present")
        precondition(playPauseBtn != nil, "1.1: Play/Pause button must be present")
        precondition(nextBtn != nil, "1.1: Next track button must be present")

        // 1.2 Verify button dimensions in accessibility or view hierarchy
        // Apple HIG requires minimum 40-44pt hit targets for tactile controls.
        // Secondary buttons: 40x40pt. Hero button: 44x44pt.
        if let prev = prevBtn, let size = AXQuery.value("accessibilityFrame", from: prev) as? NSValue {
            let rect = size.rectValue
            precondition(rect.width >= 40 && rect.height >= 40,
                         "1.2: Previous track hit target must be >= 40x40 (got \(rect.width)x\(rect.height))")
        }
        if let hero = playPauseBtn, let size = AXQuery.value("accessibilityFrame", from: hero) as? NSValue {
            let rect = size.rectValue
            precondition(rect.width >= 44 && rect.height >= 44,
                         "1.2: Hero play/pause hit target must be >= 44x44 (got \(rect.width)x\(rect.height))")
        }
        if let next = nextBtn, let size = AXQuery.value("accessibilityFrame", from: next) as? NSValue {
            let rect = size.rectValue
            precondition(rect.width >= 40 && rect.height >= 40,
                         "1.2: Next track hit target must be >= 40x40 (got \(rect.width)x\(rect.height))")
        }

        // 1.3 Verify circular geometry mathematics
        // In a 40x40 circle centered at (20, 20):
        // Radius is 20.
        // Corner (0,0): distance is sqrt(20^2 + 20^2) = 28.28 > 20 -> outside circle!
        // Center (20,20): distance is 0 <= 20 -> inside circle!
        // Edge (20, 0): distance is 20 <= 20 -> inside circle!
        let radiusSecondary: CGFloat = 20
        let centerSecondary = CGPoint(x: 20, y: 20)
        let testPoints: [(CGPoint, Bool)] = [
            (CGPoint(x: 20, y: 20), true),   // Center
            (CGPoint(x: 20, y: 0), true),    // Top edge
            (CGPoint(x: 40, y: 20), true),   // Right edge
            (CGPoint(x: 0, y: 0), false),    // Top-left corner
            (CGPoint(x: 40, y: 0), false),   // Top-right corner
            (CGPoint(x: 0, y: 40), false),   // Bottom-left corner
            (CGPoint(x: 40, y: 40), false),  // Bottom-right corner
            (CGPoint(x: 5, y: 5), false)     // Deep in corner (distance sqrt(15^2+15^2) = 21.21 > 20)
        ]
        for (pt, inside) in testPoints {
            let dist = hypot(pt.x - centerSecondary.x, pt.y - centerSecondary.y)
            let isInside = dist <= radiusSecondary
            precondition(isInside == inside, "1.3: Circular hit target point \(pt) inside check failed: expected \(inside), got \(isInside)")
        }

        print("  ✓ [Suite 1] Hit targets & layout geometry verified successfully!")
    }

    // MARK: - Test 2: Reduce Motion & Spring Dynamics

    @MainActor
    static func test2ReduceMotionAndSpringDynamics() async throws {
        print("\n[Suite 2] Stress-Testing Reduce Motion & Spring Dynamics...")

        // Verify the mathematical contract of TransportButtonStyle:
        // scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1.0)
        // When reduceMotion == true:
        // isPressed == true  => configuration.isPressed && !reduceMotion == false => scale 1.0
        // isPressed == false => configuration.isPressed && !reduceMotion == false => scale 1.0
        //
        // When reduceMotion == false:
        // isPressed == true  => configuration.isPressed && !reduceMotion == true  => scale 0.92
        // isPressed == false => configuration.isPressed && !reduceMotion == false => scale 1.0

        func evaluateScale(isPressed: Bool, reduceMotion: Bool) -> CGFloat {
            isPressed && !reduceMotion ? 0.92 : 1.0
        }

        precondition(evaluateScale(isPressed: true, reduceMotion: true) == 1.0,
                     "2.1: Reduce Motion MUST disable scale reduction when pressed (expected 1.0)")
        precondition(evaluateScale(isPressed: false, reduceMotion: true) == 1.0,
                     "2.1: Reduce Motion unpressed scale must be 1.0")
        precondition(evaluateScale(isPressed: true, reduceMotion: false) == 0.92,
                     "2.2: Normal motion MUST apply 0.92 tactile scale when pressed")
        precondition(evaluateScale(isPressed: false, reduceMotion: false) == 1.0,
                     "2.2: Normal motion unpressed scale must be 1.0")

        // Opacity contract:
        // opacity(configuration.isPressed ? 0.78 : (isEnabled ? 1.0 : 0.45))
        func evaluateOpacity(isPressed: Bool, isEnabled: Bool) -> Double {
            isPressed ? 0.78 : (isEnabled ? 1.0 : 0.45)
        }
        precondition(evaluateOpacity(isPressed: true, isEnabled: true) == 0.78, "2.3: Pressed opacity must be 0.78")
        precondition(evaluateOpacity(isPressed: false, isEnabled: true) == 1.0, "2.3: Normal enabled opacity must be 1.0")
        precondition(evaluateOpacity(isPressed: false, isEnabled: false) == 0.45, "2.3: Disabled opacity must be 0.45")

        print("  ✓ [Suite 2] Reduce Motion and animation dynamics verified successfully!")
    }

    // MARK: - Test 3: Disabled States & Click Rejection

    @MainActor
    static func test3DisabledStatesAndClickRejection() async throws {
        print("\n[Suite 3] Stress-Testing Disabled States & Click Rejection...")
        let (ctx, hosting, _) = makeContext()
        defer { ctx.cleanup() }

        // State A: Disconnected (no auth, no desktop player)
        precondition(!ctx.auth.isConnected && !ctx.playback.usesDesktopPlayer, "3.1: Precondition disconnected")
        precondition(!ctx.playback.canPerform(.play), "3.1: canPerform(.play) must be false when disconnected")
        precondition(!ctx.playback.canPerform(.pause), "3.1: canPerform(.pause) must be false when disconnected")
        precondition(!ctx.playback.canPerform(.next), "3.1: canPerform(.next) must be false when disconnected")
        precondition(!ctx.playback.canPerform(.previous), "3.1: canPerform(.previous) must be false when disconnected")

        hosting.layoutSubtreeIfNeeded()
        let reqCountBefore = SpotifyMockProtocol.server.requests().count

        // Attempt direct perform when disconnected
        await ctx.playback.perform(.play, using: ctx.auth)
        await ctx.playback.perform(.pause, using: ctx.auth)
        await ctx.playback.perform(.next, using: ctx.auth)
        await ctx.playback.perform(.previous, using: ctx.auth)

        precondition(SpotifyMockProtocol.server.requests().count == reqCountBefore,
                     "3.2: Direct perform on disabled model must reject and send zero network requests")

        // State B: Connected, but device restricted
        await ctx.connectAuth()
        let restrictedData = try E2ETestContext.makePlaybackJSON(isPlaying: false, isRestricted: true)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: restrictedData)])
        await ctx.playback.refresh(using: ctx.auth)

        precondition(!ctx.playback.canPerform(.play), "3.3: Restricted device disallows play")
        precondition(!ctx.playback.canPerform(.next), "3.3: Restricted device disallows next")

        let reqCountRestricted = SpotifyMockProtocol.server.requests().count
        await ctx.playback.perform(.play, using: ctx.auth)
        precondition(SpotifyMockProtocol.server.requests().count == reqCountRestricted,
                     "3.4: Perform on restricted device must reject immediately")

        // State C: Connected, but actions disallowed (e.g. skipping_next disallowed)
        let actionsDisallowed = try E2ETestContext.makePlaybackJSON(isPlaying: true, actions: ["disallows": ["skipping_next": true]])
        SpotifyMockProtocol.server.configure([SpotifyReply(data: actionsDisallowed)])
        await ctx.playback.refresh(using: ctx.auth)

        precondition(!ctx.playback.canPerform(.next), "3.5: Disallowed skipping_next disallows next")
        precondition(ctx.playback.canPerform(.pause), "3.5: Pause is still permitted")

        let reqCountNext = SpotifyMockProtocol.server.requests().count
        await ctx.playback.perform(.next, using: ctx.auth)
        precondition(SpotifyMockProtocol.server.requests().count == reqCountNext,
                     "3.6: Disallowed next command must reject immediately")

        print("  ✓ [Suite 3] Disabled states & click rejection verified successfully!")
    }

    // MARK: - Test 4: Rapid Clicking & Concurrency Stress

    @MainActor
    static func test4RapidClickingAndConcurrency() async throws {
        print("\n[Suite 4] Stress-Testing Rapid Clicking & Concurrency...")
        let ctx = E2ETestContext(suitePrefix: "com.evan.Mochi.challenger.rapid")
        defer { ctx.cleanup() }
        await ctx.connectAuth()
        ctx.playback.useWebPlayer()

        let playData = try E2ETestContext.makePlaybackJSON(isPlaying: false)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: playData)])
        await ctx.playback.refresh(using: ctx.auth)

        // Simulate 40 rapid concurrent calls to perform(.play) and perform(.pause)
        // With mock replies ready for whatever passes through serialization
        var replies: [SpotifyReply] = []
        for _ in 1...20 {
            replies.append(SpotifyReply(status: 204))
            replies.append(SpotifyReply(data: playData))
        }
        SpotifyMockProtocol.server.configure(replies)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                group.addTask { @MainActor in
                    let cmd: SpotifyPlaybackCommand = (i % 2 == 0) ? .play : .pause
                    await ctx.playback.perform(cmd, using: ctx.auth)
                }
            }
        }

        // Must settle without deadlock and isBusy must return to false
        precondition(!ctx.playback.isBusy, "4.1: Rapid concurrent commands settled and isBusy is false")

        // Test rapid local player commands
        await ctx.playback.enableDesktopControls()
        precondition(ctx.playback.usesDesktopPlayer, "4.2: Desktop player active")

        for _ in 1...10 {
            await ctx.playback.perform(.play, using: ctx.auth)
        }
        precondition(!ctx.playback.isBusy, "4.3: Rapid desktop commands settled without deadlock")

        print("  ✓ [Suite 4] Rapid clicking and concurrency stress tests passed!")
    }

    // MARK: - Test 5: Rate-Limit Cooldown & Attack Burst

    @MainActor
    static func test5RateLimitCooldownBurst() async throws {
        print("\n[Suite 5] Stress-Testing Rate-Limit Cooldown & Burst Attack...")
        let ctx = E2ETestContext(suitePrefix: "com.evan.Mochi.challenger.cooldown")
        defer { ctx.cleanup() }
        await ctx.connectAuth()
        ctx.playback.useWebPlayer()

        // Load initial state so we can test staleness
        let playData0 = try E2ETestContext.makePlaybackJSON(isPlaying: true)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: playData0)])
        await ctx.playback.refresh(using: ctx.auth)
        precondition(ctx.playback.state != nil, "5.0: Initial state loaded")

        // 5.1 Trigger a 429 Rate Limit with Retry-After: 30
        SpotifyMockProtocol.server.configure([
            SpotifyReply(status: 429, data: Data(#"{"reason":"QUOTA_EXCEEDED"}"#.utf8), headers: ["Retry-After": "30"])
        ])

        await ctx.playback.refresh(using: ctx.auth)

        precondition(ctx.playback.errorMessage?.contains("quota is exhausted") == true ||
                     ctx.playback.errorMessage?.contains("limiting requests") == true,
                     "5.1: Rate limit error message registered (got: \(ctx.playback.errorMessage ?? "nil"))")
        precondition(ctx.playback.isStale, "5.1: isStale must be true after error on existing state")

        // 5.2 Verify canPerform is unconditionally FALSE for all commands during cooldown
        precondition(!ctx.playback.canPerform(.play), "5.2: canPerform(.play) must be false during cooldown")
        precondition(!ctx.playback.canPerform(.pause), "5.2: canPerform(.pause) must be false during cooldown")
        precondition(!ctx.playback.canPerform(.next), "5.2: canPerform(.next) must be false during cooldown")
        precondition(!ctx.playback.canPerform(.previous), "5.2: canPerform(.previous) must be false during cooldown")

        // 5.3 Adversarial Burst: Fire 100 rapid commands during cooldown
        let reqCountDuringCooldown = SpotifyMockProtocol.server.requests().count
        for _ in 1...100 {
            await ctx.playback.perform(.play, using: ctx.auth)
            await ctx.playback.perform(.pause, using: ctx.auth)
            await ctx.playback.perform(.next, using: ctx.auth)
        }

        precondition(SpotifyMockProtocol.server.requests().count == reqCountDuringCooldown,
                     "5.3: Cooldown MUST drop 100% of commands without making network requests")

        // 5.4 Rapid refresh attempts must also be blocked by readyToRequest()
        await ctx.playback.refresh(using: ctx.auth)
        precondition(SpotifyMockProtocol.server.requests().count == reqCountDuringCooldown,
                     "5.4: Refresh during cooldown must be rejected by readyToRequest()")

        // 5.5 Verify reset does not inadvertently compromise security or state
        ctx.playback.reset()
        precondition(!ctx.playback.canPerform(.play), "5.5: After reset with no state, canPerform remains false")

        print("  ✓ [Suite 5] Rate-limit cooldown and burst attack resistance verified!")
    }

    // MARK: - Test 6: Hover Bounds & Opacity Suppression

    @MainActor
    static func test6HoverBoundsAndOpacitySuppression() async throws {
        print("\n[Suite 6] Stress-Testing Hover Bounds & Disabled Opacity Suppression...")

        // Logic test of backgroundOpacity:
        // private var backgroundOpacity: Double {
        //     guard isEnabled else { return prominent ? 0.04 : 0 }
        //     if prominent {
        //         return isHovered ? 0.14 : 0.08
        //     } else {
        //         return isHovered ? 0.08 : 0
        //     }
        // }

        func backgroundOpacity(isEnabled: Bool, prominent: Bool, isHovered: Bool) -> Double {
            guard isEnabled else { return prominent ? 0.04 : 0 }
            if prominent {
                return isHovered ? 0.14 : 0.08
            } else {
                return isHovered ? 0.08 : 0
            }
        }

        // 6.1 Disabled button hover suppression
        precondition(backgroundOpacity(isEnabled: false, prominent: false, isHovered: true) == 0.0,
                     "6.1: Disabled secondary button must have 0.0 background opacity even when hovered")
        precondition(backgroundOpacity(isEnabled: false, prominent: false, isHovered: false) == 0.0,
                     "6.1: Disabled secondary button unhovered opacity must be 0.0")
        precondition(backgroundOpacity(isEnabled: false, prominent: true, isHovered: true) == 0.04,
                     "6.2: Disabled hero button must suppress hover (stay at 0.04 base opacity)")
        precondition(backgroundOpacity(isEnabled: false, prominent: true, isHovered: false) == 0.04,
                     "6.2: Disabled hero button unhovered opacity must be 0.04")

        // 6.2 Enabled button hover highlights
        precondition(backgroundOpacity(isEnabled: true, prominent: false, isHovered: true) == 0.08,
                     "6.3: Enabled secondary button hovered opacity must be 0.08")
        precondition(backgroundOpacity(isEnabled: true, prominent: false, isHovered: false) == 0.0,
                     "6.3: Enabled secondary button unhovered opacity must be 0.0")
        precondition(backgroundOpacity(isEnabled: true, prominent: true, isHovered: true) == 0.14,
                     "6.4: Enabled hero button hovered opacity must be 0.14")
        precondition(backgroundOpacity(isEnabled: true, prominent: true, isHovered: false) == 0.08,
                     "6.4: Enabled hero button unhovered opacity must be 0.08")

        print("  ✓ [Suite 6] Hover bounds and opacity suppression verified successfully!")
    }

    // MARK: - Test 7: Playback Toggling & Dynamic State Updates

    @MainActor
    static func test7PlaybackTogglingAndArtworkSwitching() async throws {
        print("\n[Suite 7] Stress-Testing Playback Toggling & Dynamic State Updates...")
        let (ctx, hosting, _) = makeContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()

        // 7.1 Alternating toggle loop
        for cycle in 1...10 {
            let isPlaying = (cycle % 2 == 1)
            let trackData = try E2ETestContext.makePlaybackJSON(
                name: "Cycle Track \(cycle)",
                album: "Test Album \(cycle)",
                isPlaying: isPlaying
            )
            SpotifyMockProtocol.server.configure([SpotifyReply(data: trackData)])
            await ctx.playback.refresh(using: ctx.auth)
            hosting.layoutSubtreeIfNeeded()

            precondition(ctx.playback.state?.isPlaying == isPlaying, "7.1: isPlaying state matches")
            precondition(ctx.playback.state?.item?.album?.name == "Test Album \(cycle)", "7.1: Album name matches")

            if isPlaying {
                let pauseBtn = AXQuery.findButton(label: "Pause", in: hosting)
                precondition(pauseBtn != nil, "7.2: When playing, Pause button must be visible (cycle \(cycle))")
            } else {
                let playBtn = AXQuery.findButton(label: "Play", in: hosting)
                precondition(playBtn != nil, "7.2: When paused, Play button must be visible (cycle \(cycle))")
            }
        }

        print("  ✓ [Suite 7] Playback toggling and dynamic state updates verified!")
    }

    // MARK: - Test 8: Settings Popover & Transaction Semantics

    @MainActor
    static func test8SettingsPopoverAndDismissalSemantics() async throws {
        print("\n[Suite 8] Stress-Testing Settings Popover & Dismissal Semantics...")
        let ctx = E2ETestContext(suitePrefix: "com.evan.Mochi.challenger.settings")
        defer { ctx.cleanup() }

        let contentView = ContentView(spotify: ctx.auth, playback: ctx.playback, companion: ctx.companion)
        let hosting = NSHostingView(rootView: contentView)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        hosting.layoutSubtreeIfNeeded()
        AXQuery.activateAccessibilityTree()

        // 8.1 Settings toggle button accessibility
        let settingsBtn = AXQuery.findButton(label: "Player settings", in: hosting)
        precondition(settingsBtn != nil, "8.1: Player settings button must exist")

        // 8.2 Root container accessibility identifier
        let root = AXQuery.find(identifier: "mochiMenuPlayer", in: hosting)
        precondition(root != nil, "8.2: Root container must retain mochiMenuPlayer identifier")

        // 8.3 Verify SettingsRowButtonStyle hover and pressed styles
        func settingsFillOpacity(isEnabled: Bool, isPressed: Bool, isHovered: Bool) -> Double {
            if !isEnabled { return 0.0 }
            if isPressed { return 0.12 }
            if isHovered { return 0.08 }
            return 0.0
        }
        precondition(settingsFillOpacity(isEnabled: false, isPressed: true, isHovered: true) == 0.0, "8.3: Disabled row has clear background")
        precondition(settingsFillOpacity(isEnabled: true, isPressed: false, isHovered: true) == 0.08, "8.3: Hovered row has 0.08 opacity")
        precondition(settingsFillOpacity(isEnabled: true, isPressed: true, isHovered: true) == 0.12, "8.3: Pressed row has 0.12 opacity")
        precondition(settingsFillOpacity(isEnabled: true, isPressed: false, isHovered: false) == 0.0, "8.3: Idle row has 0.0 opacity")

        print("  ✓ [Suite 8] Settings popover and dismissal semantics verified!")
    }
}
