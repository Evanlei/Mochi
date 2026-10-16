import Foundation
import CoreServices

@main
struct LocalPlaybackChecks {
    @MainActor
    static func main() async throws {
        let id = "0000000000000000000001"
        let uri = "spotify:track:\(id)"
        for input in [uri, " \(uri)\n", "https://open.spotify.com/track/\(id)", "https://open.spotify.com/track/\(id)?si=test"] {
            precondition(LocalSpotifyClient.trackURI(from: input) == uri)
        }
        for input in ["spotify:album:\(id)", "spotify:track:short", "spotify:track:\(id)\" & do shell script \"oops",
                      "http://open.spotify.com/track/\(id)", "https://open.spotify.com.evil/track/\(id)",
                      "https://user@open.spotify.com/track/\(id)", "https://open.spotify.com:443/track/\(id)",
                      "https://open.spotify.com/track/\(id)/", "https://open.spotify.com/track/\(id)#fragment",
                      "https://open.spotify.com/playlist/\(id)", "https://open.spotify.com/track/00000000000000000000%2F1"] {
            precondition(LocalSpotifyClient.trackURI(from: input) == nil, "Accepted \(input)")
        }
        print("PASS: canonical track links/URIs accepted; malformed links, other resources and script input rejected")

        for (command, id) in [(SpotifyPlaybackCommand.play, "Play"), (.pause, "Paus"), (.next, "Next"), (.previous, "Prev")] {
            let event = LocalSpotifyClient.commandEvent(command)
            precondition(event.eventClass == LocalSpotifyClient.code("spfy"))
            precondition(event.eventID == LocalSpotifyClient.code(id))
            let address = event.attributeDescriptor(forKeyword: keyAddressAttr)!
            precondition(address.descriptorType == typeApplicationBundleID)
            precondition(String(data: address.data, encoding: .utf8) == LocalSpotifyClient.bundleID)
            precondition(event.paramDescriptor(forKeyword: keyDirectObject) == nil)
        }
        let play = LocalSpotifyClient.trackEvent(uri)
        precondition(play.eventID == LocalSpotifyClient.code("PCtx"))
        precondition(play.paramDescriptor(forKeyword: keyDirectObject)?.stringValue == uri)
        let readEvent = LocalSpotifyClient.snapshotEvent()
        precondition(readEvent.eventClass == LocalSpotifyClient.code("core") && readEvent.eventID == LocalSpotifyClient.code("getd"))
        precondition(readEvent.paramDescriptor(forKeyword: keyDirectObject)?.numberOfItems == 4)
        print("PASS: commands target Spotify alone and URI travels as data; snapshot uses four fixed properties")

        func snapshot(_ status: String, name: String = "Test song", artist: String = "Test artist") -> NSAppleEventDescriptor {
            let result = NSAppleEventDescriptor.list()
            result.insert(NSAppleEventDescriptor(enumCode: LocalSpotifyClient.code(status)), at: 1)
            result.insert(NSAppleEventDescriptor(string: name), at: 2)
            result.insert(NSAppleEventDescriptor(string: artist), at: 3)
            return result
        }
        let state = try LocalSpotifyClient.decodeSnapshot(snapshot("kPSP"))!
        precondition(state.isPlaying && state.item?.name == "Test song" && state.item?.subtitle == "Test artist")
        precondition(state.device?.name == "Spotify desktop" && state.permits(.pause) && state.permits(.next))
        let identified = snapshot("kPSP")
        identified.insert(NSAppleEventDescriptor(string: uri), at: 4)
        let identifiedState = try LocalSpotifyClient.decodeSnapshot(identified)
        precondition(identifiedState?.item?.uri == uri)
        let paused = try LocalSpotifyClient.decodeSnapshot(snapshot("kPSp"))!
        precondition(!paused.isPlaying && paused.permits(.play))
        let stopped = try LocalSpotifyClient.decodeSnapshot(snapshot("kPSS"))
        precondition(stopped == nil)
        for malformed in [NSAppleEventDescriptor.null(), snapshot("oops"), snapshot("kPSP", name: "")] {
            do { _ = try LocalSpotifyClient.decodeSnapshot(malformed); fatalError("Accepted malformed snapshot") }
            catch LocalSpotifyError.unexpectedResponse { }
        }
        precondition(LocalSpotifyError.from(status: -1743) == .permissionDenied)
        precondition(LocalSpotifyError.from(status: -1744) == .permissionNeeded)
        precondition(LocalSpotifyError.from(status: -1712) == .timeout)
        precondition(LocalSpotifyError.from(status: -600) == .notRunning)
        print("PASS: playing/paused/stopped snapshots and permission/timeout errors; no real player touched")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let session = URLSession(configuration: configuration)
        SpotifyMockProtocol.server.configure([])
        let auth = SpotifyAuthModel(tokenClient: SpotifyTokenClient(session: session), tokenStore: SpotifyMemoryStore())
        let local = LocalPlayerFixture(state: state)
        let model = SpotifyPlaybackModel(client: SpotifyPlaybackClient(session: session), localClient: local)
        await model.enableDesktopControls()
        precondition(model.usesDesktopPlayer && model.state?.isPlaying == true && !auth.isConnected)
        precondition(model.canPerform(.pause) && !model.isBusy)
        await local.setState(paused)
        await model.perform(.pause, using: auth)
        precondition(model.state?.isPlaying == false && model.canPerform(.play))
        let commands = await local.commands
        precondition(commands == [.pause] && SpotifyMockProtocol.server.requests().isEmpty)
        print("PASS: permission, Now Playing and pause work without OAuth or HTTP requests")

        let queued = await model.startTracks(uris: [uri, "spotify:track:0000000000000000000002"], using: auth)
        precondition(!queued && model.errorMessage == LocalSpotifyError.queueUnsupported.localizedDescription)
        let invalid = await model.startTrack(uri: "bad", using: auth)
        let invalidStarts = await local.startedTracks
        precondition(!invalid && invalidStarts.isEmpty)
        let accepted = await model.startTrack(uri: uri, using: auth)
        let starts = await local.startedTracks
        precondition(accepted && starts == [uri])
        print("PASS: local track start needs no token and multi-track queues are explicitly rejected")

        await local.setCommandError(.timeout)
        await model.perform(.next, using: auth)
        precondition(model.isStale && !model.canPerform(.next) && !model.isBusy)
        let afterTimeout = await local.commands
        precondition(afterTimeout == [.pause, .next])
        await local.setCommandError(nil)
        await model.refresh(using: auth)
        precondition(!model.isStale && model.errorMessage == nil)
        await local.setReadError(.notRunning)
        await model.perform(.next, using: auth)
        precondition(model.errorMessage?.contains("accepted") == true && model.isStale)
        let afterReadFailure = await local.commands
        precondition(afterReadFailure == [.pause, .next, .next])
        print("PASS: no replay after timeout; stale state disables controls; accepted-command/read failure stays honest")

        await local.setReadError(nil)
        await local.setReadDelay(200_000_000)
        let refresh = Task { await model.refresh(using: auth) }
        try await Task.sleep(for: .milliseconds(40))
        precondition(model.isBusy)
        model.useWebPlayer()
        await refresh.value
        precondition(!model.usesDesktopPlayer && model.state == nil && !model.isBusy)
        await local.setReadDelay(0)
        await local.setPermissionError(.permissionDenied)
        await model.enableDesktopControls()
        precondition(model.usesDesktopPlayer && model.state == nil && !model.isBusy)
        precondition(model.errorMessage == LocalSpotifyError.permissionDenied.localizedDescription)
        precondition(SpotifyMockProtocol.server.requests().isEmpty)
        print("PASS: switching routes discards late reads and denied permission never falls back to Web API")

        let suite = "mochi.local-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        await local.setPermissionError(nil)
        let saved = SpotifyPlaybackModel(localClient: local, defaults: defaults)
        await saved.enableDesktopControls()
        let restored = SpotifyPlaybackModel(localClient: local, defaults: defaults)
        precondition(restored.usesDesktopPlayer)
        restored.useWebPlayer()
        precondition(!SpotifyPlaybackModel(localClient: local, defaults: defaults).usesDesktopPlayer)
        print("PASS: chosen playback route persists independently of OAuth tokens")
    }
}
