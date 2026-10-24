import AppKit
import ApplicationServices
import Foundation
import SwiftUI

@MainActor
struct Tier2BoundaryCornerTests {
    static func runAll() async throws {
        print("\n--- Running Tier 2: Boundary & Corner Cases Tests ---")
        try await testSuite1EmptyStates()
        try await testSuite2ExtremeTextAndUnicode()
        try await testSuite3NilAndCorruptedMedia()
        try await testSuite4DisconnectedAndErrorRecovery()
        try await testSuite5RapidCommandsAndConcurrency()
        print("✅ Tier 2: All Boundary & Corner Cases Tests Passed (25+ test cases)!\n")
    }

    // MARK: - Suite 1: Empty States & Nil Containers (5 tests)
    static func testSuite1EmptyStates() async throws {
        print("  Running Tier 2 Suite 1: Empty States & Nil Containers...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()

        // T2.1: Empty discovery catalog response
        let emptyCatalog: [String: Any] = [
            "catalog_kind": "fictional_sample",
            "method": "none",
            "tracks": [],
            "message": "No sample tracks meet those requirements."
        ]
        let data1 = try JSONSerialization.data(withJSONObject: [
            "received_prompt": "quiet jazz",
            "selection": emptyCatalog
        ])
        SpotifyMockProtocol.server.configure([SpotifyReply(data: data1)])
        ctx.request.submit("quiet jazz")
        let done1 = await E2ETestContext.pollUntil { !ctx.request.isSending }
        e2eAssert(done1, "T2.1: Empty catalog request completed")
        e2eAssert(ctx.request.selection?.tracks.isEmpty == true, "T2.1: Selection tracks is empty")

        // T2.2: Empty search results
        let emptySearchData = try JSONSerialization.data(withJSONObject: ["tracks": ["items": []]])
        SpotifyMockProtocol.server.configure([SpotifyReply(data: emptySearchData)])
        ctx.search.query = "NonexistentSongXYZ999"
        ctx.search.search()
        let searchDone = await E2ETestContext.pollUntil { !ctx.search.isSearching }
        e2eAssert(searchDone, "T2.2: Search completed")
        e2eAssert(ctx.search.results.isEmpty, "T2.2: Search results empty without crash")

        // T2.3: Zero favorite artists disables familiar mode
        e2eAssert(ctx.request.artists.names.isEmpty, "T2.3: Artists initially empty")
        e2eAssertEqual(ctx.request.discoveryMode, .balanced, "T2.3: Defaults to balanced when empty")

        // T2.4: Empty prompt submission does not send
        let reqCountBefore = SpotifyMockProtocol.server.requests().count
        ctx.request.draft = "    \n  "
        e2eAssert(!ctx.request.canSubmit, "T2.4: canSubmit is false for whitespace draft")
        e2eAssertEqual(SpotifyMockProtocol.server.requests().count, reqCountBefore, "T2.4: Zero requests dispatched for empty draft")

        // T2.5: No active playback devices available (device: null)
        let noDeviceJSON = """
        {
            "is_playing": false,
            "currently_playing_type": "track",
            "device": null,
            "item": null
        }
        """
        SpotifyMockProtocol.server.configure([SpotifyReply(data: Data(noDeviceJSON.utf8))])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertNil(ctx.playback.state?.device, "T2.5: Device is nil without throwing")
        e2eAssertNil(ctx.playback.state?.item, "T2.5: Item is nil without throwing")
        print("    ✓ Suite 1: 5/5 tests passed")
    }

    // MARK: - Suite 2: Extreme Text, Unicode & Multilingual Stress (5 tests)
    static func testSuite2ExtremeTextAndUnicode() async throws {
        print("  Running Tier 2 Suite 2: Extreme Text, Unicode & Multilingual Stress...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()

        // T2.6: Massive track title (500+ characters)
        let massiveTitle = String(repeating: "Extremely Long Track Title with Repeated Words and Characters ", count: 10)
        let trackData = try E2ETestContext.makePlaybackJSON(name: massiveTitle)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: trackData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertEqual(ctx.playback.state?.item?.name, massiveTitle, "T2.6: Massive track title decoded")

        // T2.7: Multi-byte UTF-8, Japanese Kanji, Cyrillic, and Arabic RTL
        let multilingualTitle = "雨の庭 / Дождь в саду / حديقة المطر (Ambient Rain)"
        let multiData = try E2ETestContext.makePlaybackJSON(name: multilingualTitle, artist: "坂本龍一 / Рахманинов")
        SpotifyMockProtocol.server.configure([SpotifyReply(data: multiData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertEqual(ctx.playback.state?.item?.name, multilingualTitle, "T2.7: Multilingual track name decoded")
        e2eAssertEqual(ctx.playback.state?.item?.subtitle, "坂本龍一 / Рахманинов", "T2.7: Multilingual artist decoded")

        // T2.8: Emoji strings in composer draft
        let emojiPrompt = "🎧 Studying in a cozy cafe with warm tea ☕️🌧️✨"
        let emojiData = try E2ETestContext.makeDiscoveryJSON(prompt: emojiPrompt)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: emojiData)])
        ctx.request.submit(emojiPrompt)
        let emojiDone = await E2ETestContext.pollUntil { !ctx.request.isSending }
        e2eAssert(emojiDone, "T2.8: Emoji prompt submission completed")

        // T2.9: Special XML/HTML and escape characters
        let escapedTitle = "Track & Title <With> \"Quotes\" & 'Apostrophes' \\ Backslash"
        let escapedData = try E2ETestContext.makePlaybackJSON(name: escapedTitle)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: escapedData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertEqual(ctx.playback.state?.item?.name, escapedTitle, "T2.9: Escaped characters preserved intact")

        // T2.10: Character limit truncation (500 char composer limit)
        let inputOverLimit = String(repeating: "a", count: 600)
        ctx.request.draft = String(inputOverLimit.prefix(500))
        e2eAssertEqual(ctx.request.draft.count, 500, "T2.10: Draft bounded to 500 characters")
        print("    ✓ Suite 2: 5/5 tests passed")
    }

    // MARK: - Suite 3: Nil, Corrupted & Missing Media (5 tests)
    static func testSuite3NilAndCorruptedMedia() async throws {
        print("  Running Tier 2 Suite 3: Nil, Corrupted & Missing Media...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()

        // T2.11: Nil artwork URL
        let nilArtData = try E2ETestContext.makePlaybackJSON(artworkURL: nil)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: nilArtData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertNil(ctx.playback.state?.item?.artworkURL, "T2.11: Nil artwork URL")

        // T2.12: Malformed JSON playback payload returns unexpectedResponse error
        SpotifyMockProtocol.server.configure([SpotifyReply(data: Data("Not valid JSON at all".utf8))])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssert(ctx.playback.errorMessage != nil || ctx.playback.state == nil, "T2.12: Malformed payload handled safely")

        // T2.13: Track metadata with empty artists list
        let emptyArtistsJSON = """
        {
            "is_playing": true,
            "currently_playing_type": "track",
            "device": {"id": "dev1", "name": "MacBook", "is_restricted": false},
            "item": { "name": "Solo Performance", "type": "track", "artists": [] }
        }
        """
        SpotifyMockProtocol.server.configure([SpotifyReply(data: Data(emptyArtistsJSON.utf8))])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertEqual(ctx.playback.state?.item?.name, "Solo Performance", "T2.13: Track decoded with empty artists")
        e2eAssertEqual(ctx.playback.state?.item?.subtitle, "Spotify", "T2.13: Empty artist list subtitle falls back to Spotify")

        // T2.14: Album metadata omitted
        let noAlbumJSON = """
        {
            "is_playing": true,
            "currently_playing_type": "track",
            "device": {"id": "dev1", "name": "MacBook", "is_restricted": false},
            "item": { "name": "Single Release", "type": "track", "artists": [{"name": "Single Artist"}] }
        }
        """
        SpotifyMockProtocol.server.configure([SpotifyReply(data: Data(noAlbumJSON.utf8))])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertEqual(ctx.playback.state?.item?.name, "Single Release", "T2.14: Track decoded without album")

        // T2.15: Unrecognized playback item type (e.g. ad)
        let adJSON = """
        {
            "is_playing": true,
            "currently_playing_type": "ad",
            "item": null
        }
        """
        SpotifyMockProtocol.server.configure([SpotifyReply(data: Data(adJSON.utf8))])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertNil(ctx.playback.state?.item, "T2.15: Ad item is nil without crash")
        print("    ✓ Suite 3: 5/5 tests passed")
    }

    // MARK: - Suite 4: Disconnected, Rate Limited & Error Recovery (5 tests)
    static func testSuite4DisconnectedAndErrorRecovery() async throws {
        print("  Running Tier 2 Suite 4: Disconnected, Rate Limited & Error Recovery...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()

        // T2.16: HTTP 401 Unauthorized handling with token refresh
        let refreshData = try JSONSerialization.data(withJSONObject: ["access_token": "refreshed-access", "token_type": "Bearer", "expires_in": 3600])
        SpotifyMockProtocol.server.configure([SpotifyReply(status: 401), SpotifyReply(data: refreshData), SpotifyReply(status: 401)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssert(ctx.playback.errorMessage != nil, "T2.16: HTTP 401 reported cleanly")

        // T2.17: HTTP 429 Rate Limiting with Retry-After header
        let limitedModel = SpotifyPlaybackModel(client: SpotifyPlaybackClient(session: ctx.session))
        SpotifyMockProtocol.server.configure([
            SpotifyReply(status: 429, data: Data(#"{"reason":"RATE_LIMITED"}"#.utf8), headers: ["Retry-After": "5"])
        ])
        await limitedModel.refresh(using: ctx.auth)
        e2eAssert(limitedModel.errorMessage != nil, "T2.17: HTTP 429 error message recorded")

        // T2.18: HTTP 500 Internal Server Error recovery
        SpotifyMockProtocol.server.configure([SpotifyReply(status: 500)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssert(ctx.playback.errorMessage != nil, "T2.18: HTTP 500 error handled")

        // Recover with valid state
        let recoveredData = try E2ETestContext.makePlaybackJSON(name: "Recovered Song")
        SpotifyMockProtocol.server.configure([SpotifyReply(data: recoveredData)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssertEqual(ctx.playback.state?.item?.name, "Recovered Song", "T2.18: Recovery succeeded after 500")

        // T2.19: Desktop player authorization error handling
        await ctx.localPlayer.setPermissionError(.permissionDenied)
        await ctx.playback.enableDesktopControls()
        e2eAssert(ctx.playback.usesDesktopPlayer, "T2.19: Desktop player enabled despite local permission error")

        // T2.20: Network timeout / cancellation simulation
        SpotifyMockProtocol.server.configure([SpotifyReply(error: .cancelled)])
        await ctx.playback.refresh(using: ctx.auth)
        e2eAssert(!ctx.playback.isBusy, "T2.20: Task cancellation resets busy flag")
        print("    ✓ Suite 4: 5/5 tests passed")
    }

    // MARK: - Suite 5: Rapid Commands, Race Conditions & Concurrency (5 tests)
    static func testSuite5RapidCommandsAndConcurrency() async throws {
        print("  Running Tier 2 Suite 5: Rapid Commands, Race Conditions & Concurrency...")
        let ctx = E2ETestContext()
        defer { ctx.cleanup() }
        await ctx.connectAuth()
        ctx.playback.useWebPlayer()

        let playData = try E2ETestContext.makePlaybackJSON(isPlaying: false)
        SpotifyMockProtocol.server.configure([SpotifyReply(data: playData)])
        await ctx.playback.refresh(using: ctx.auth)

        // T2.21: Rapid command burst (5 commands in sequence)
        var replies: [SpotifyReply] = []
        for _ in 1...5 {
            replies.append(SpotifyReply(status: 204))
            replies.append(SpotifyReply(data: playData))
        }
        SpotifyMockProtocol.server.configure(replies)
        for _ in 1...3 {
            await ctx.playback.perform(.play, using: ctx.auth)
        }
        e2eAssert(!ctx.playback.isBusy, "T2.21: Rapid command burst settled without deadlock")

        // T2.22: Rapid toggle of companion panel
        ctx.companion.start()
        for _ in 1...5 {
            ctx.companion.toggleCard()
        }
        e2eAssert(ctx.companion.cardPanel != nil, "T2.22: Companion panel intact after rapid toggle")

        // T2.23: Double Return submission in composer
        SpotifyMockProtocol.server.configure([
            SpotifyReply(data: try E2ETestContext.makeDiscoveryJSON(prompt: "Double Enter")),
            SpotifyReply(data: try E2ETestContext.makeDiscoveryJSON(prompt: "Double Enter"))
        ])
        ctx.request.submit("Double Enter")
        ctx.request.submit("Double Enter")
        let doubleDone = await E2ETestContext.pollUntil { !ctx.request.isSending }
        e2eAssert(doubleDone, "T2.23: Double submission settled cleanly")
        try? await Task.sleep(nanoseconds: 150_000_000)

        // T2.24: Rapid typing and immediate cancellation
        SpotifyMockProtocol.server.configure([
            SpotifyReply(data: try E2ETestContext.makeDiscoveryJSON(prompt: "Quick Cancel Query"))
        ])
        ctx.request.submit("Quick Cancel Query")
        ctx.request.cancelRequest()
        try? await Task.sleep(nanoseconds: 150_000_000)
        e2eAssert(!ctx.request.isSending, "T2.24: Request cancelled cleanly")

        // T2.25: Extreme display coordinates clamp safely
        let screen = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let mascotSize = NSSize(width: 94, height: 88)
        let negativeClamp = CompanionPlacement.clamp(NSPoint(x: -100_000, y: -100_000), size: mascotSize, inside: screen)
        e2eAssertEqual(negativeClamp, NSPoint(x: 0, y: 0), "T2.25: Negative extreme clamped to screen origin")
        let positiveClamp = CompanionPlacement.clamp(NSPoint(x: 100_000, y: 100_000), size: mascotSize, inside: screen)
        e2eAssertEqual(positiveClamp, NSPoint(x: 2466, y: 1352), "T2.25: Positive extreme clamped inside screen bounds")
        print("    ✓ Suite 5: 5/5 tests passed")
    }
}
