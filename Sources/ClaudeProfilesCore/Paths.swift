import Foundation

/// Well-known locations used by Claude Profiles.
public struct AppPaths: Sendable {
    /// Root folder for Claude Profiles' own state (profiles.json, runtime.json, profile data dirs).
    public let supportDirectory: URL
    /// The official Claude Desktop default data directory. Never moved, modified or deleted by this app.
    public let defaultClaudeDataDirectory: URL

    public init(supportDirectory: URL, defaultClaudeDataDirectory: URL) {
        self.supportDirectory = supportDirectory
        self.defaultClaudeDataDirectory = defaultClaudeDataDirectory
    }

    /// Standard paths. `CLAUDE_PROFILES_HOME` overrides the support directory (used by tests and tooling).
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let support: URL
        if let override = environment["CLAUDE_PROFILES_HOME"], !override.isEmpty {
            support = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            support = appSupport.appendingPathComponent("ClaudeProfiles", isDirectory: true)
        }
        return AppPaths(supportDirectory: support,
                        defaultClaudeDataDirectory: appSupport.appendingPathComponent("Claude", isDirectory: true))
    }

    public var profilesFile: URL { supportDirectory.appendingPathComponent("profiles.json") }
    public var runtimeFile: URL { supportDirectory.appendingPathComponent("runtime.json") }
    public var profilesDataRoot: URL { supportDirectory.appendingPathComponent("Profiles", isDirectory: true) }

    public func dataDirectory(forProfileID id: String) -> URL {
        profilesDataRoot.appendingPathComponent(id, isDirectory: true)
    }

    public var cachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeProfiles", isDirectory: true)
    }
}

extension URL {
    /// Canonical path string used to compare data directories (resolves symlinks like /tmp -> /private/tmp).
    var canonicalPath: String {
        let std = standardizedFileURL.resolvingSymlinksInPath().path
        return std.hasSuffix("/") && std.count > 1 ? String(std.dropLast()) : std
    }
}

public func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).canonicalPath
}
