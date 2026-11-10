import Foundation

/// Colors available for profile badges. Stored by name so the file format is UI-framework independent.
public enum ProfileColor: String, Codable, CaseIterable, Sendable {
    case orange, red, pink, purple, indigo, blue, teal, green, yellow, gray

    public var displayName: String { rawValue.capitalized }
}

public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public static let defaultProfileID = "default"

    public var id: String
    public var name: String
    public var color: ProfileColor
    /// Optional emoji shown in the badge; when nil the badge shows the name's initials.
    public var emoji: String?
    /// Absolute path of this profile's Claude data directory.
    public var dataDirectory: String
    public var createdAt: Date
    public var lastLaunchedAt: Date?

    public var isDefault: Bool { id == Profile.defaultProfileID }

    public init(id: String, name: String, color: ProfileColor, emoji: String? = nil,
                dataDirectory: String, createdAt: Date = Date(), lastLaunchedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.emoji = emoji
        self.dataDirectory = dataDirectory
        self.createdAt = createdAt
        self.lastLaunchedAt = lastLaunchedAt
    }

    /// Up to two initials derived from the profile name ("Work Account" -> "WA", "personal" -> "PE").
    public var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).filter { !$0.isEmpty }
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        if let first = words.first {
            return String(first.prefix(2)).uppercased()
        }
        return "?"
    }

    /// Command-line arguments passed to Claude.app when launching this profile.
    /// The Default profile launches exactly like the official app (no arguments).
    public var launchArguments: [String] {
        isDefault ? [] : ["--user-data-dir=\(dataDirectory)"]
    }
}

/// On-disk format of profiles.json.
struct ProfilesFile: Codable {
    var version: Int
    var profiles: [Profile]
}
