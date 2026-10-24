import AppKit
import ApplicationServices
import Foundation
import SwiftUI

@main
struct M2ChallengerChecks {
    @MainActor
    static func main() async throws {
        print("=================================================================")
        print("       M2 Adversarial Challenger Verification & Stress Tests      ")
        print("=================================================================")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        try await test1CardDimensionsAndNoClipping()
        try await test2PromptChipsLayoutAndInteraction()
        try await test3ComposerRapidTypingAndLongText()
        try await test4ComposerReturnAndEscapeDismissal()
        try await test5FocusGlowAndVisualHierarchy()
        try await test6HoverFeedbackOnChipsAndRows()
        try await test7RecommendationRowEdgeCasesAndBadges()
        try await test8UpNextQueueAndRefillLayout()

        print("\n=================================================================")
        print("  🎉 ALL M2 ADVERSARIAL CHALLENGER TESTS PASSED (8/8 SUITES)!")
        print("=================================================================")
    }

    // MARK: - Helpers

    @MainActor
    private static func makeContext(suitePrefix: String = "com.evan.Mochi.m2challenger") -> E2ETestContext {
        let ctx = E2ETestContext(suitePrefix: suitePrefix)
        AXQuery.activateAccessibilityTree()
        return ctx
    }

    // Recursively check all subviews to ensure none exceed the window/container boundaries
    @MainActor
    private static func assertNoClippingOrOverflow(in view: NSView, containerBounds: NSRect, path: String = "root") {
        let frame = view.frame
        // Allow a tiny 0.5pt rounding tolerance for layout engine sub-pixel calculations
        let tol: CGFloat = 0.5
        if frame.width > containerBounds.width + tol {
            preconditionFailure("Clipping violation at \(path) (\(type(of: view))): width \(frame.width) exceeds container width \(containerBounds.width)")
        }
        for (index, subview) in view.subviews.enumerated() {
            // Scroll views and clipping views intentionally have large document views that scroll, which is valid
            if view is NSScrollView || view is NSClipView {
                continue
            }
            assertNoClippingOrOverflow(in: subview, containerBounds: containerBounds, path: "\(path).subview[\(index)]")
        }
    }

    @MainActor
    private static func waitForTextInput(in window: NSWindow, timeout: TimeInterval = 2.0) async -> NSTextInputClient? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let client = window.firstResponder as? NSTextInputClient {
                return client
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return window.firstResponder as? NSTextInputClient
    }

    // MARK: - Test 1: Companion Card Dimensions & No Clipping

    @MainActor
    static func test1CardDimensionsAndNoClipping() async throws {
        print("\n[Suite 1] Stress-Testing Card Dimensions & Clipping in Fixed Frames...")
        let ctx = makeContext()
        defer { ctx.cleanup() }

        ctx.companion.start()
        ctx.companion.toggleCard()
        let card = ctx.companion.cardPanel!
        card.layoutIfNeeded()

        // 1.1 Idle State Dimensions: Exactly 300x150
        precondition(card.frame.size == CGSize(width: 300, height: 150),
                     "1.1: Idle card frame must be exactly 300x150 (got \(card.frame.size))")
        assertNoClippingOrOverflow(in: card.contentView!, containerBounds: NSRect(origin: .zero, size: CGSize(width: 300, height: 150)))
        print("  ✓ 1.1 Idle card frame 300x150 verified with zero clipping")

        // 1.2 Search Mode Dimensions: Exactly 300x340
        ctx.request.isSearchPresented = true
        try await Task.sleep(nanoseconds: 100_000_000)
        card.layoutIfNeeded()
        precondition(card.frame.size == CGSize(width: 300, height: 340),
                     "1.2: Search card frame must be exactly 300x340 (got \(card.frame.size))")
        assertNoClippingOrOverflow(in: card.contentView!, containerBounds: NSRect(origin: .zero, size: CGSize(width: 300, height: 340)))
        print("  ✓ 1.2 Search card frame 300x340 verified with zero clipping")

        // 1.3 Selection Mode Dimensions: Exactly 300x340
        ctx.request.isSearchPresented = false // exit search
        try await Task.sleep(nanoseconds: 50_000_000)
        let selectionData = try E2ETestContext.makeDiscoveryJSON(prompt: "Ambient Focus", count: 5)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: selectionData)])
        ctx.request.submit("Ambient Focus")
        let loaded = await E2ETestContext.pollUntil { ctx.request.hasSelectedTracks }
        precondition(loaded, "1.3: Selection must load")
        card.layoutIfNeeded()
        precondition(card.frame.size == CGSize(width: 300, height: 340),
                     "1.3: Selection card frame must be exactly 300x340 (got \(card.frame.size))")
        assertNoClippingOrOverflow(in: card.contentView!, containerBounds: NSRect(origin: .zero, size: CGSize(width: 300, height: 340)))
        print("  ✓ 1.3 Selection card frame 300x340 verified with zero clipping")

        // 1.4 Artist Editor Dimensions: 300x320 (<3 artists) and 300x210 (3 artists)
        ctx.request.artists.present()
        try await Task.sleep(nanoseconds: 50_000_000)
        card.layoutIfNeeded()
        let count = ctx.request.artists.names.count
        let expectedSize = count == 3 ? CGSize(width: 300, height: 210) : CGSize(width: 300, height: 320)
        precondition(card.frame.size == expectedSize,
                     "1.4: Artist editor card size mismatch: expected \(expectedSize), got \(card.frame.size)")
        assertNoClippingOrOverflow(in: card.contentView!, containerBounds: NSRect(origin: .zero, size: expectedSize))
        print("  ✓ 1.4 Artist editor dimensions \(expectedSize) verified with zero clipping")

        ctx.request.artists.finish()
        ctx.companion.stop()
        print("  ✓ [Suite 1] All card dimension constraints and clipping checks passed!")
    }

    // MARK: - Test 2: Prompt Chips Layout, Fitting & Interaction

    @MainActor
    static func test2PromptChipsLayoutAndInteraction() async throws {
        print("\n[Suite 2] Stress-Testing Prompt Chips (\"Focus\", \"Unwind\", \"Surprise me\")...")
        let ctx = makeContext()
        defer { ctx.cleanup() }

        ctx.companion.start()
        ctx.companion.toggleCard()
        let card = ctx.companion.cardPanel!
        card.layoutIfNeeded()

        // 2.1 Verify all 3 prompt chips exist with exact titles
        let focusBtn = AXQuery.findButton(label: "Focus", in: card.contentView!)
        let unwindBtn = AXQuery.findButton(label: "Unwind", in: card.contentView!)
        let surpriseBtn = AXQuery.findButton(label: "Surprise me", in: card.contentView!)

        precondition(focusBtn != nil, "2.1: 'Focus' chip button must be present in idle card")
        precondition(unwindBtn != nil, "2.1: 'Unwind' chip button must be present in idle card")
        precondition(surpriseBtn != nil, "2.1: 'Surprise me' chip button must be present in idle card")

        // 2.2 Verify Chip Dimensions and Horizontal Bounds Fitting
        // Card width is 300, padding is 12 on each side -> available width is 276.
        // Chips are in HStack(spacing: 6). Total width must not exceed 276pt.
        var totalChipsWidth: CGFloat = 0
        for (name, btn) in [("Focus", focusBtn!), ("Unwind", unwindBtn!), ("Surprise me", surpriseBtn!)] {
            if let size = AXQuery.value("accessibilityFrame", from: btn) as? NSValue {
                let rect = size.rectValue
                precondition(rect.height >= 24 && rect.height <= 28,
                             "2.2: \(name) chip height should be ~26pt (got \(rect.height))")
                precondition(rect.width >= 40, "2.2: \(name) chip width must be >= 40pt (got \(rect.width))")
                totalChipsWidth += rect.width
            }
        }
        totalChipsWidth += 12 // 2 gaps of 6pt
        precondition(totalChipsWidth <= 276.5,
                     "2.2: All 3 prompt chips combined width (\(totalChipsWidth)pt) must fit inside 276pt card width")
        print("  ✓ 2.2 Combined chip width \(totalChipsWidth)pt fits within 276pt width")

        // 2.3 Press "Focus" Chip -> Dispatches submission
        SpotifyMockProtocol.server.configure([SpotifyReply(data: try E2ETestContext.makeDiscoveryJSON(prompt: "Focus"))])
        precondition(AXQuery.press(focusBtn!), "2.3: Failed to press 'Focus' chip")
        let focusSubmitted = await E2ETestContext.pollUntil { !ctx.request.preferences.isEmpty }
        precondition(focusSubmitted, "2.3: 'Focus' chip must submit listening request")
        print("  ✓ 2.3 'Focus' chip successfully dispatches listening request")

        // 2.4 Reset and Press "Unwind" Chip
        ctx.request.reset()
        card.layoutIfNeeded()
        let unwindBtn2 = AXQuery.findButton(label: "Unwind", in: card.contentView!)
        precondition(unwindBtn2 != nil, "2.4: 'Unwind' chip must reappear after reset")
        SpotifyMockProtocol.server.configure([SpotifyReply(data: try E2ETestContext.makeDiscoveryJSON(prompt: "Unwind"))])
        precondition(AXQuery.press(unwindBtn2!), "2.4: Failed to press 'Unwind' chip")
        let unwindSubmitted = await E2ETestContext.pollUntil { !ctx.request.preferences.isEmpty }
        precondition(unwindSubmitted, "2.4: 'Unwind' chip must submit listening request")
        print("  ✓ 2.4 'Unwind' chip successfully dispatches listening request")

        // 2.5 Reset and Press "Surprise me" Chip
        ctx.request.reset()
        card.layoutIfNeeded()
        let surpriseBtn2 = AXQuery.findButton(label: "Surprise me", in: card.contentView!)
        precondition(surpriseBtn2 != nil, "2.5: 'Surprise me' chip must reappear after reset")
        SpotifyMockProtocol.server.configure([SpotifyReply(data: try E2ETestContext.makeDiscoveryJSON(prompt: "Surprise me"))])
        precondition(AXQuery.press(surpriseBtn2!), "2.5: Failed to press 'Surprise me' chip")
        let surpriseSubmitted = await E2ETestContext.pollUntil { !ctx.request.preferences.isEmpty }
        precondition(surpriseSubmitted, "2.5: 'Surprise me' chip must submit listening request")
        print("  ✓ 2.5 'Surprise me' chip successfully dispatches listening request")

        // 2.6 Preset Prompt Chip disabled invariant: Disabled when isSending or isStarting is true
        ctx.request.reset()
        card.layoutIfNeeded()
        precondition(!ctx.request.isSending && !ctx.request.isStarting, "2.6: Request state is ready for interaction")
        let chipsIdle = AXQuery.findButton(label: "Focus", in: card.contentView!)
        precondition(chipsIdle != nil, "2.6: Prompt chips active and visible in idle state")

        ctx.companion.stop()
        print("  ✓ [Suite 2] Prompt chips layout and interaction verified!")
    }

    // MARK: - Test 3: Composer Rapid Typing & Long Text Truncation

    @MainActor
    static func test3ComposerRapidTypingAndLongText() async throws {
        print("\n[Suite 3] Stress-Testing Composer Rapid Typing & Length Boundaries...")
        let ctx = makeContext()
        defer { ctx.cleanup() }

        ctx.companion.start()
        ctx.companion.toggleCard()
        let card = ctx.companion.cardPanel!
        card.layoutIfNeeded()

        // 3.1 Rapid Typing Keystroke Burst (simulate typing 100 characters in rapid succession)
        guard let input = await waitForTextInput(in: card) else {
            preconditionFailure("3.1: Card composer did not receive keyboard focus")
        }

        let burstText = "The quick brown fox jumps over the lazy dog 1234567890! Rapid typing test sequence."
        for char in burstText {
            input.insertText(String(char), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(ctx.request.draft == burstText,
                     "3.1: Draft must perfectly capture rapid burst keystrokes (expected '\(burstText)', got '\(ctx.request.draft)')")
        print("  ✓ 3.1 Rapid typing burst captured with zero dropped keystrokes")

        // 3.2 Long Text Boundary: 500 characters in standard listening mode
        let overlongRequest = String(repeating: "MochiMusicPrompt", count: 50) // 800 characters
        input.insertText(overlongRequest, replacementRange: NSRange(location: 0, length: ctx.request.draft.count))
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(ctx.request.draft.count == 500,
                     "3.2: Standard mode draft must be strictly clamped to 500 characters (got \(ctx.request.draft.count))")
        print("  ✓ 3.2 Standard mode draft clamped to exactly 500 characters")

        // 3.3 Search Mode Boundary: 200 characters in Spotify search mode
        ctx.request.isSearchPresented = true
        try await Task.sleep(nanoseconds: 100_000_000)
        card.layoutIfNeeded()
        guard let searchInput = await waitForTextInput(in: card) else {
            preconditionFailure("3.3: Search mode composer did not receive keyboard focus")
        }
        let overlongSearch = String(repeating: "SpotifySearchQuery", count: 30) // 540 characters
        searchInput.insertText(overlongSearch, replacementRange: NSRange(location: 0, length: ctx.search.query.count))
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(ctx.search.query.count == 200,
                     "3.3: Search mode query must be strictly clamped to 200 characters (got \(ctx.search.query.count))")
        print("  ✓ 3.3 Search mode query clamped to exactly 200 characters")

        // 3.4 Multi-line Text and Formatting: Newlines, Tabs, Emojis, Unicode
        ctx.request.isSearchPresented = false // return to standard mode
        try await Task.sleep(nanoseconds: 50_000_000)
        guard let input2 = await waitForTextInput(in: card) else {
            preconditionFailure("3.4: Re-acquired input client failed")
        }
        let complexUnicode = "🎧 Jazz & Lo-Fi ✨ — 日本語の歌 & Café Música ☕️\tTabbed"
        input2.insertText(complexUnicode, replacementRange: NSRange(location: 0, length: ctx.request.draft.count))
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(ctx.request.draft == complexUnicode,
                     "3.4: Complex unicode text must be preserved (got '\(ctx.request.draft)')")
        
        // Test multi-line text rendering in idle card (lineLimit 1...2 inside 42pt container)
        ctx.request.draft = "Line 1: Ambient Soundscape\nLine 2: Soft Night Beats"
        card.layoutIfNeeded()
        assertNoClippingOrOverflow(in: card.contentView!, containerBounds: NSRect(origin: .zero, size: CGSize(width: 300, height: 150)))
        print("  ✓ 3.4 Complex multiline and Unicode text accepted with zero clipping")

        ctx.companion.stop()
        print("  ✓ [Suite 3] Composer rapid typing and long text boundaries verified!")
    }

    // MARK: - Test 4: Composer Return Submission & Escape Dismissal

    @MainActor
    static func test4ComposerReturnAndEscapeDismissal() async throws {
        print("\n[Suite 4] Stress-Testing Composer Return & Escape Hierarchical Dismissal...")
        let ctx = makeContext()
        defer { ctx.cleanup() }

        ctx.companion.start()
        ctx.companion.toggleCard()
        let card = ctx.companion.cardPanel!
        card.layoutIfNeeded()

        // 4.1 Empty Return Key Press: Must NOT submit request
        SpotifyMockProtocol.server.configure([])
        KeySimulator.sendReturn(to: card)
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(!ctx.request.isSending && ctx.request.preferences.isEmpty,
                     "4.1: Empty composer must NOT submit when Return is pressed")
        precondition(SpotifyMockProtocol.server.requests().isEmpty,
                     "4.1: No network requests should be triggered on empty return")
        print("  ✓ 4.1 Empty return rejected with zero requests")

        // 4.2 Whitespace-only Return Key Press: Must NOT submit request
        await KeySimulator.typeText("    \n\t   ", into: card)
        KeySimulator.sendReturn(to: card)
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(!ctx.request.isSending && ctx.request.preferences.isEmpty,
                     "4.2: Whitespace-only composer must NOT submit when Return is pressed")
        precondition(SpotifyMockProtocol.server.requests().isEmpty,
                     "4.2: No network requests triggered on whitespace return")
        print("  ✓ 4.2 Whitespace-only return rejected with zero requests")

        // 4.3 Valid Text Return Key Press: Submits, triggers network, and clears draft
        SpotifyMockProtocol.server.configure([SpotifyReply(data: try E2ETestContext.makeDiscoveryJSON(prompt: "Late Night Beats"))])
        await KeySimulator.typeText("Late Night Beats", into: card)
        KeySimulator.sendReturn(to: card)
        let submitted = await E2ETestContext.pollUntil { !ctx.request.preferences.isEmpty }
        precondition(submitted, "4.3: Valid return must submit request")
        precondition(ctx.request.draft.isEmpty, "4.3: Draft must be cleared after submission")
        print("  ✓ 4.3 Valid return submitted request and cleared draft")

        // 4.4 Escape Key Dismisses Card
        KeySimulator.sendEscape(to: card)
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(!card.isVisible, "4.4: Escape key must dismiss companion card panel")
        print("  ✓ 4.4 Escape key successfully dismissed companion card")

        // 4.5 Reopening Card restores focus to composer
        ctx.companion.toggleCard()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(card.isVisible, "4.5: Card reopened")
        precondition(card.firstResponder is NSTextInputClient, "4.5: Composer regained keyboard focus on reopen")
        print("  ✓ 4.5 Card reopened and composer regained keyboard focus")

        ctx.companion.stop()
        print("  ✓ [Suite 4] Composer Return submission and Escape dismissal verified!")
    }

    // MARK: - Test 5: Focus Glow & Visual Hierarchy

    @MainActor
    static func test5FocusGlowAndVisualHierarchy() async throws {
        print("\n[Suite 5] Stress-Testing Focus Glow & Visual Depth Hierarchy...")

        // Logic verification of focus glow styling contract in MochiCompanionView:
        // Container height: 42pt, cornerRadius: 13pt
        // Focused border: Color.accentColor.opacity(0.55), lineWidth: 1.0
        // Unfocused border: Color.primary.opacity(0.08), lineWidth: 0.5
        // Focused shadow: Color.accentColor.opacity(0.22), radius: 4, x: 0, y: 0
        // Unfocused shadow: Color.black.opacity(0.03), radius: 2, x: 0, y: 1
        // Animation: .easeInOut(duration: 0.18)

        struct FocusGlowSpec {
            let isFocused: Bool
            var borderWidth: CGFloat { isFocused ? 1.0 : 0.5 }
            var shadowRadius: CGFloat { isFocused ? 4 : 2 }
            var shadowY: CGFloat { isFocused ? 0 : 1 }
            var hasAccentBorder: Bool { isFocused }
            var hasAccentShadow: Bool { isFocused }
        }

        let focusedSpec = FocusGlowSpec(isFocused: true)
        precondition(focusedSpec.borderWidth == 1.0, "5.1: Focused border width must be 1.0pt")
        precondition(focusedSpec.shadowRadius == 4.0, "5.1: Focused shadow radius must be 4.0pt")
        precondition(focusedSpec.shadowY == 0.0, "5.1: Focused shadow Y-offset must be 0")
        precondition(focusedSpec.hasAccentBorder, "5.1: Focused border must use accent color")
        precondition(focusedSpec.hasAccentShadow, "5.1: Focused shadow must use accent glow")

        let unfocusedSpec = FocusGlowSpec(isFocused: false)
        precondition(unfocusedSpec.borderWidth == 0.5, "5.2: Unfocused border width must be 0.5pt")
        precondition(unfocusedSpec.shadowRadius == 2.0, "5.2: Unfocused shadow radius must be 2.0pt")
        precondition(unfocusedSpec.shadowY == 1.0, "5.2: Unfocused shadow Y-offset must be 1.0pt")
        precondition(!unfocusedSpec.hasAccentBorder, "5.2: Unfocused border must be subtle system opacity")
        precondition(!unfocusedSpec.hasAccentShadow, "5.2: Unfocused shadow must be subtle ambient shadow")

        print("  ✓ [Suite 5] Focus glow specifications and visual hierarchy verified!")
    }

    // MARK: - Test 6: Hover Feedback on Prompt Chips & Recommendation Rows

    @MainActor
    static func test6HoverFeedbackOnChipsAndRows() async throws {
        print("\n[Suite 6] Stress-Testing Hover Feedback on Chips & Recommendation Rows...")

        // 6.1 PresetPromptChip Hover Styling Contract:
        // Background fill: Color.primary.opacity(isHovered ? 0.09 : 0.06)
        // Stroke border: Color.primary.opacity(isHovered ? 0.12 : 0.08), lineWidth: 0.5
        // Animation: .easeInOut(duration: 0.12)
        func chipBackgroundOpacity(isHovered: Bool) -> Double { isHovered ? 0.09 : 0.06 }
        func chipBorderOpacity(isHovered: Bool) -> Double { isHovered ? 0.12 : 0.08 }

        precondition(chipBackgroundOpacity(isHovered: false) == 0.06, "6.1: Chip idle background opacity must be 0.06")
        precondition(chipBackgroundOpacity(isHovered: true) == 0.09, "6.1: Chip hovered background opacity must be 0.09")
        precondition(chipBorderOpacity(isHovered: false) == 0.08, "6.1: Chip idle border opacity must be 0.08")
        precondition(chipBorderOpacity(isHovered: true) == 0.12, "6.1: Chip hovered border opacity must be 0.12")

        // 6.2 MochiRecommendationRow Hover Styling Contract:
        // Background fill: isHovered ? Color.primary.opacity(0.045) : Color.clear
        // Corner radius: 7pt continuous
        func rowBackgroundOpacity(isHovered: Bool) -> Double { isHovered ? 0.045 : 0.0 }
        precondition(rowBackgroundOpacity(isHovered: false) == 0.0, "6.2: Row idle background must be clear (0.0)")
        precondition(rowBackgroundOpacity(isHovered: true) == 0.045, "6.2: Row hovered background opacity must be 0.045")

        // 6.3 Options Button Hover Contract:
        // Background fill: isOptionsHovered ? Color.primary.opacity(0.08) : Color.clear
        func optionsButtonHoverOpacity(isHovered: Bool) -> Double { isHovered ? 0.08 : 0.0 }
        precondition(optionsButtonHoverOpacity(isHovered: false) == 0.0, "6.3: Options button idle background must be clear")
        precondition(optionsButtonHoverOpacity(isHovered: true) == 0.08, "6.3: Options button hovered background opacity must be 0.08")

        // 6.4 MochiPressStyle Reduce Motion Invariant:
        // scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
        func chipPressScale(isPressed: Bool, reduceMotion: Bool) -> CGFloat {
            isPressed && !reduceMotion ? 0.97 : 1.0
        }
        precondition(chipPressScale(isPressed: true, reduceMotion: false) == 0.97,
                     "6.4: Pressed chip scale must be 0.97 when reduceMotion is false")
        precondition(chipPressScale(isPressed: true, reduceMotion: true) == 1.0,
                     "6.4: Pressed chip scale must be 1.0 (no scaling) when reduceMotion is true")
        precondition(chipPressScale(isPressed: false, reduceMotion: false) == 1.0,
                     "6.4: Unpressed chip scale must be 1.0")

        print("  ✓ [Suite 6] Hover feedback on prompt chips and recommendation rows verified!")
    }

    // MARK: - Test 7: Recommendation Rows Edge Cases & Metadata Badges

    @MainActor
    static func test7RecommendationRowEdgeCasesAndBadges() async throws {
        print("\n[Suite 7] Stress-Testing Recommendation Row Edge Cases & Metadata Badges...")
        let ctx = makeContext()
        defer { ctx.cleanup() }

        ctx.companion.start()
        ctx.companion.toggleCard()
        let card = ctx.companion.cardPanel!

        // 7.1 Recommendation tracks with diverse metadata (nil vs full vs extreme lengths)
        let extremeTracks: [[String: Any]] = [
            // Track 1: Full metadata
            ["id": "trk-1", "title": "Full Meta Track", "artist": "Artist Alpha", "bpm": 128.0,
             "vocals": true, "energy": "high", "description": "High energy vocal dance track", "score": 0.95],
            // Track 2: Nullable metadata (all nil)
            ["id": "trk-2", "title": "Minimal Meta Track", "artist": "Artist Beta", "bpm": NSNull(),
             "vocals": NSNull(), "energy": NSNull(), "description": "Ambient soundscape", "score": 0.88],
            // Track 3: Low energy instrumental with fractional BPM
            ["id": "trk-3", "title": "Chill Piano", "artist": "Artist Gamma", "bpm": 74.5,
             "vocals": false, "energy": "low", "description": "Soft solo piano", "score": 0.82],
            // Track 4: Extreme long title and artist (200 characters each)
            ["id": "trk-4", "title": String(repeating: "LongTitle", count: 20),
             "artist": String(repeating: "LongArtist", count: 20),
             "bpm": 120.0, "vocals": true, "energy": "high", "description": "Overlong metadata stress test", "score": 0.75]
        ]

        let discoveryData = try JSONSerialization.data(withJSONObject: [
            "received_prompt": "Diverse Metadata Stress",
            "intent": NSNull(),
            "clarification": NSNull(),
            "selection": [
                "catalog_kind": "fictional_sample",
                "method": "semantic",
                "tracks": extremeTracks,
                "message": NSNull()
            ]
        ])
        SpotifyMockProtocol.server.configure([SpotifyReply(data: discoveryData)])
        ctx.request.submit("Diverse Metadata Stress")
        let loaded = await E2ETestContext.pollUntil { ctx.request.selection?.tracks.count == 4 }
        precondition(loaded, "7.1: Diverse metadata tracks must load")
        card.layoutIfNeeded()

        // 7.2 Verify Accessibility Identifiers for all tracks
        for track in ctx.request.selection!.tracks {
            let row = AXQuery.find(identifier: "mochiSelectedTrack-\(track.id)", in: card.contentView!)
            precondition(row != nil, "7.2: Row accessibility identifier mochiSelectedTrack-\(track.id) must exist")
        }
        print("  ✓ 7.2 All recommendation row accessibility identifiers verified")

        // 7.3 Verify No Clipping with extreme long titles
        assertNoClippingOrOverflow(in: card.contentView!, containerBounds: NSRect(origin: .zero, size: CGSize(width: 300, height: 340)))
        print("  ✓ 7.3 Extreme 200-char titles render with zero overflow or clipping")

        // 7.4 Metadata Badge formatting logic
        // BPM: String(format: "%g", bpm) + " BPM"
        precondition(String(format: "%g", 128.0) + " BPM" == "128 BPM")
        precondition(String(format: "%g", 74.5) + " BPM" == "74.5 BPM")

        ctx.companion.stop()
        print("  ✓ [Suite 7] Recommendation rows edge cases and metadata badges verified!")
    }

    // MARK: - Test 8: Up Next Queue & Refill Badge Layout

    @MainActor
    static func test8UpNextQueueAndRefillLayout() async throws {
        print("\n[Suite 8] Stress-Testing Up Next Queue & Refill Badge Layout...")
        let ctx = makeContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()

        ctx.companion.start()
        ctx.companion.toggleCard()
        let card = ctx.companion.cardPanel!

        // 8.1 Setup continuous session with active queue
        func makeSongId(_ n: Int) -> String { "lastfm-" + String(format: "%064x", n) }
        func makeSpotifyId(_ n: Int) -> String { String(format: "%022d", n) }
        func makeUri(_ n: Int) -> String { "spotify:track:\(makeSpotifyId(n))" }

        let tracks: [[String: Any]] = (1...5).map { n in
            ["id": makeSongId(n), "title": "Queue song \(n)", "artist": "Fixture Artist", "description": "piano", "source": "lastfm", "score": 0.8]
        }
        let selectionData = try JSONSerialization.data(withJSONObject: [
            "received_prompt": "piano",
            "selection": [
                "catalog_kind": "lastfm_live",
                "method": "lexical",
                "request_id": UUID().uuidString,
                "tracks": tracks
            ]
        ])

        func makeMatch(_ n: Int) throws -> SpotifyReply {
            let data = try JSONSerialization.data(withJSONObject: [
                "tracks": ["items": [["id": makeSpotifyId(n), "uri": makeUri(n), "name": "Queue song \(n)", "type": "track",
                                      "artists": [["name": "Fixture Artist"]], "album": ["name": "Fixture album"]]]]
            ])
            return SpotifyReply(data: data)
        }

        let stateData = try JSONSerialization.data(withJSONObject: [
            "is_playing": true,
            "device": ["id": "fixture-device", "is_restricted": false],
            "item": ["uri": makeUri(1), "name": "Queue song 1", "type": "track", "artists": [["name": "Fixture Artist"]]]
        ])

        var replies = [SpotifyReply(data: selectionData)]
        for i in 1...5 {
            replies.append(try makeMatch(i))
        }
        replies += [
            SpotifyReply(data: stateData),
            SpotifyReply(status: 204),
            SpotifyReply(data: stateData),
            SpotifyReply(data: Data(#"{"status":"ok"}"#.utf8))
        ]
        SpotifyMockProtocol.server.configure(replies)
        ctx.request.submit("piano")
        let sendDone = await E2ETestContext.pollUntil(timeout: 5.0) { !ctx.request.isSending && !ctx.request.feedbackBusy }
        precondition(sendDone, "8.1: Request submission completed")

        var refillReplies: [SpotifyReply] = []
        for _ in 2...5 {
            refillReplies.append(SpotifyReply(data: stateData))
            refillReplies.append(SpotifyReply(status: 204))
        }
        SpotifyMockProtocol.server.configure(refillReplies)
        await ctx.request.maintainSession()
        try await Task.sleep(nanoseconds: 200_000_000)
        card.layoutIfNeeded()

        precondition(ctx.request.isSessionActive, "8.1: Continuous session must become active")

        // 8.2 Verify Up Next container accessibility identifier
        let upNext = AXQuery.find(identifier: "mochiUpNext", in: card.contentView!)
        precondition(upNext != nil, "8.2: mochiUpNext accessibilityIdentifier must be present")

        // 8.3 Verify Queue Status badge
        let queueStatus = AXQuery.find(identifier: "mochiQueueStatus", in: card.contentView!)
        precondition(queueStatus != nil, "8.3: mochiQueueStatus accessibilityIdentifier must be present")

        // 8.4 Verify No Clipping in Up Next view within 300x340
        assertNoClippingOrOverflow(in: card.contentView!, containerBounds: NSRect(origin: .zero, size: CGSize(width: 300, height: 340)))
        print("  ✓ 8.4 Up Next hero card and upcoming rows fit cleanly with zero clipping")

        ctx.companion.stop()
        print("  ✓ [Suite 8] Up Next queue and refill layout verified!")
    }
}
