import AppKit
import CoreServices

/// Uses Spotify's installed scripting dictionary, without a shell or generated script.
/// Only these fixed events can leave Mochi; Spotify identifiers are data parameters.
protocol LocalSpotifyControlling: Sendable {
    func authorize() async throws
    func fetchState() async throws -> SpotifyPlaybackState?
    func send(_ command: SpotifyPlaybackCommand) async throws
    func startTrack(uri: String) async throws
}

struct LocalSpotifyClient: LocalSpotifyControlling {
    static let bundleID = "com.spotify.client"

    func authorize() async throws {
        try await Self.inWorker {
            try Self.requireRunning()
            try Self.checkPermission(ask: true)
        }
        try Task.checkCancellation()
    }

    func fetchState() async throws -> SpotifyPlaybackState? {
        let state = try await Self.inWorker {
            try Self.requireRunning()
            try Self.checkPermission(ask: false)
            do { return try Self.decodeSnapshot(Self.send(Self.snapshotEvent())) }
            catch LocalSpotifyError.noTrack { return nil }
        }
        try Task.checkCancellation()
        return state
    }

    func send(_ command: SpotifyPlaybackCommand) async throws {
        try await Self.inWorker {
            try Task.checkCancellation()
            try Self.requireRunning()
            try Self.checkPermission(ask: false)
            _ = try Self.send(Self.commandEvent(command))
        }
        try Task.checkCancellation()
    }

    func startTrack(uri: String) async throws {
        guard let uri = Self.trackURI(from: uri), uri.hasPrefix("spotify:track:") else {
            throw LocalSpotifyError.invalidTrack
        }
        try await Self.inWorker {
            try Task.checkCancellation()
            try Self.requireRunning()
            try Self.checkPermission(ask: false)
            _ = try Self.send(Self.trackEvent(uri))
        }
        try Task.checkCancellation()
    }

    /// Accept track URIs and canonical Spotify track links; never accept script text.
    static func trackURI(from input: String) -> String? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: String
        if input.hasPrefix("spotify:track:") {
            id = String(input.dropFirst("spotify:track:".count))
        } else {
            guard let url = URLComponents(string: input), url.scheme == "https",
                  url.host == "open.spotify.com", url.user == nil, url.password == nil, url.port == nil,
                  url.fragment == nil else { return nil }
            let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].isEmpty, parts[1] == "track" else { return nil }
            id = String(parts[2])
        }
        guard id.count == 22, id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return "spotify:track:\(id)"
    }

    private static func inWorker<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private static func requireRunning() throws {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            throw LocalSpotifyError.notRunning
        }
    }

    private static func checkPermission(ask: Bool) throws {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let address = target.aeDesc else { throw LocalSpotifyError.unexpectedResponse }
        let status = AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, ask)
        guard status == noErr else { throw LocalSpotifyError.from(status: Int(status)) }
    }

    private static func event(_ eventClass: String, _ eventID: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: code(eventClass), eventID: code(eventID),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    static func commandEvent(_ command: SpotifyPlaybackCommand) -> NSAppleEventDescriptor {
        let id: String
        switch command {
        case .play: id = "Play"
        case .pause: id = "Paus"
        case .next: id = "Next"
        case .previous: id = "Prev"
        }
        return event("spfy", id)
    }

    static func trackEvent(_ uri: String) -> NSAppleEventDescriptor {
        let result = event("spfy", "PCtx")
        result.setParam(NSAppleEventDescriptor(string: uri), forKeyword: keyDirectObject)
        return result
    }

    private static func property(_ name: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: typeProperty), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(name)), forKeyword: AEKeyword(keyAEKeyData))
        return record.coerce(toDescriptorType: typeObjectSpecifier)!
    }

    static func snapshotEvent() -> NSAppleEventDescriptor {
        let current = property("pTrk")
        let properties = NSAppleEventDescriptor.list()
        for (index, descriptor) in [property("pPlS"), property("pnam", of: current),
                                    property("pArt", of: current), property("ID  ", of: current)].enumerated() {
            properties.insert(descriptor, at: index + 1)
        }
        let result = event("core", "getd")
        result.setParam(properties, forKeyword: keyDirectObject)
        return result
    }

    static func decodeSnapshot(_ result: NSAppleEventDescriptor) throws -> SpotifyPlaybackState? {
        guard result.descriptorType == typeAEList, [3, 4].contains(result.numberOfItems),
              let status = result.atIndex(1)?.enumCodeValue,
              [code("kPSP"), code("kPSp"), code("kPSS")].contains(status) else {
            throw LocalSpotifyError.unexpectedResponse
        }
        if status == code("kPSS") { return nil }
        guard let name = result.atIndex(2)?.stringValue, !name.isEmpty, name.count <= 500,
              let artist = result.atIndex(3)?.stringValue, artist.count <= 500 else {
            throw LocalSpotifyError.unexpectedResponse
        }
        return SpotifyPlaybackState(isPlaying: status == code("kPSP"),
            item: SpotifyPlaybackItem(name: name, type: "track", artists: [SpotifyPlaybackArtist(name: artist)], show: nil,
                                      uri: result.atIndex(4)?.stringValue.flatMap(Self.trackURI)),
            device: SpotifyPlaybackDevice(id: nil, name: "Spotify desktop", isRestricted: false),
            actions: nil, currentlyPlayingType: "track")
    }

    private static func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        do {
            try Task.checkCancellation()
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                throw LocalSpotifyError.notRunning
            }
            // A process address cannot relaunch Spotify if it exits between the check and send.
            event.setAttribute(NSAppleEventDescriptor(processIdentifier: app.processIdentifier), forKeyword: keyAddressAttr)
            let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 2)
            if let error = reply.paramDescriptor(forKeyword: keyErrorNumber), error.int32Value != 0 {
                if error.int32Value == -1728 { throw LocalSpotifyError.noTrack }
                throw LocalSpotifyError.from(status: Int(error.int32Value))
            }
            return reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null()
        } catch is CancellationError { throw CancellationError() }
        catch let error as LocalSpotifyError { throw error }
        catch { throw LocalSpotifyError.from(status: (error as NSError).code) }
    }

    static func code(_ text: String) -> FourCharCode {
        precondition(text.utf8.count == 4)
        return text.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}

enum LocalSpotifyError: LocalizedError {
    case notRunning, permissionDenied, permissionNeeded, timeout, noTrack, invalidTrack, queueUnsupported, unexpectedResponse

    static func from(status: Int) -> Self {
        switch status {
        case -1743: .permissionDenied
        case -1744: .permissionNeeded
        case -600, -609: .notRunning
        case -1712: .timeout
        case -1728: .noTrack
        default: .unexpectedResponse
        }
    }

    var errorDescription: String? {
        switch self {
        case .notRunning: "Open the Spotify desktop app, start a song, then refresh."
        case .permissionDenied: "Allow Mochi to control Spotify in System Settings → Privacy & Security → Automation, then try again."
        case .permissionNeeded: "Choose Use desktop controls to allow Mochi to control Spotify."
        case .timeout: "Spotify desktop did not respond. Refresh before retrying; the control may have been received."
        case .noTrack: "Start a song in Spotify, then refresh."
        case .invalidTrack: "Paste a Spotify track link or track URI. Album and playlist links aren't supported here."
        case .queueUnsupported: "Desktop controls play one track at a time. Use an individual play button."
        case .unexpectedResponse: "Mochi couldn't read Spotify desktop. Open Spotify and try refreshing."
        }
    }
}
