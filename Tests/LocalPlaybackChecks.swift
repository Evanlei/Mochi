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
        precondition(readEvent.paramDescriptor(forKeyword: keyDirectObject)?.numberOfItems == 3)
        print("PASS: commands target Spotify alone and URI travels as data; snapshot uses three fixed properties")

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
    }
}
