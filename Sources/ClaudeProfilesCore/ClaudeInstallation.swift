import Foundation

/// Facts about the official Claude Desktop install that Claude Profiles depends on.
public enum ClaudeConstants {
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"
    public static let teamIdentifier = "Q6L2SF6YDW"
    public static let defaultAppURL = URL(fileURLWithPath: "/Applications/Claude.app")
    public static let downloadPageURL = URL(string: "https://claude.ai/download")!
    public static let urlScheme = "claude"
}

/// A snapshot of the Claude.app bundle on disk.
public struct ClaudeInstallation: Equatable, Sendable {
    public let appURL: URL
    public let version: AppVersion?
    public let bundleIdentifier: String?
    /// Modification date of Contents/Info.plist: changes whenever the bundle is replaced by an update.
    public let infoPlistModified: Date?

    public var executableURL: URL { appURL.appendingPathComponent("Contents/MacOS/Claude") }

    /// Reads the bundle at `appURL`. Returns nil when Claude.app is not installed there.
    public static func read(at appURL: URL = ClaudeConstants.defaultAppURL,
                            fileManager: FileManager = .default) -> ClaudeInstallation? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let version = (plist["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        let modified = (try? fileManager.attributesOfItem(atPath: plistURL.path)[.modificationDate]) as? Date
        return ClaudeInstallation(appURL: appURL, version: version,
                                  bundleIdentifier: plist["CFBundleIdentifier"] as? String,
                                  infoPlistModified: modified)
    }
}
