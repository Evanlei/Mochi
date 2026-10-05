import Foundation

struct SpotifyPlaybackState: Decodable, Sendable {
    let isPlaying: Bool
    let item: SpotifyPlaybackItem?
    let device: SpotifyPlaybackDevice?
    let actions: SpotifyPlaybackActions?
    let currentlyPlayingType: String?

    func permits(_ command: SpotifyPlaybackCommand) -> Bool {
        guard let device, device.isRestricted != true,
              let item, ["track", "episode"].contains(item.type) else { return false }
        if command == .play && isPlaying { return false }
        if command == .pause && !isPlaying { return false }
        return actions?.disallows(command) != true
    }

    enum CodingKeys: String, CodingKey {
        case isPlaying = "is_playing"
        case item
        case device
        case actions
        case currentlyPlayingType = "currently_playing_type"
    }
}

struct SpotifyPlaybackItem: Decodable, Sendable {
    let name: String
    let type: String
    let artists: [SpotifyPlaybackArtist]?
    let show: SpotifyPlaybackShow?

    var subtitle: String {
        if let artists, !artists.isEmpty { return artists.map(\.name).joined(separator: ", ") }
        return show?.name ?? (type == "episode" ? "Podcast episode" : "Spotify")
    }
}

struct SpotifyPlaybackArtist: Decodable, Sendable {
    let name: String
}

struct SpotifyPlaybackShow: Decodable, Sendable { let name: String }

struct SpotifyPlaybackDevice: Decodable, Sendable {
    let id: String?
    let name: String?
    let isRestricted: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name
        case isRestricted = "is_restricted"
    }
}

struct SpotifyPlaybackActions: Decodable, Sendable {
    private let restrictions: [String: Bool]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let nested = try container.decodeIfPresent([String: Bool].self, forKey: .disallows) {
            restrictions = nested
        } else {
            // Accept the flattened form shown in Spotify's reference schema too.
            var values: [String: Bool] = [:]
            for key in [Keys.pausing, .resuming, .skippingNext, .skippingPrevious] {
                values[key.rawValue] = try container.decodeIfPresent(Bool.self, forKey: key)
            }
            restrictions = values
        }
    }

    func disallows(_ command: SpotifyPlaybackCommand) -> Bool {
        let key: String
        switch command {
        case .play: key = "resuming"
        case .pause: key = "pausing"
        case .next: key = "skipping_next"
        case .previous: key = "skipping_prev"
        }
        return restrictions[key] == true
    }

    private enum Keys: String, CodingKey {
        case disallows, pausing, resuming
        case skippingNext = "skipping_next"
        case skippingPrevious = "skipping_prev"
    }
}
