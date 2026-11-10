import Foundation

public enum ProfileStoreError: LocalizedError, Equatable {
    case notFound(String)
    case cannotDeleteDefault
    case profileIsRunning(String)
    case invalidName
    case dataDirectoryOutsideStore(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "No profile with id \(id)."
        case .cannotDeleteDefault: return "The Default profile is Claude's own data folder and cannot be deleted."
        case .profileIsRunning(let name): return "\"\(name)\" is running. Quit it before deleting."
        case .invalidName: return "Profile names cannot be empty."
        case .dataDirectoryOutsideStore(let path): return "Refusing to delete a folder outside the Claude Profiles store: \(path)"
        }
    }
}

/// Persists profiles to profiles.json and manages their data directories.
/// Not thread-safe: use from one actor (the app uses it on the main actor).
public final class ProfileStore {
    public let paths: AppPaths
    public private(set) var profiles: [Profile] = []
    private let fileManager: FileManager
    private let now: () -> Date

    public init(paths: AppPaths, fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.paths = paths
        self.fileManager = fileManager
        self.now = now
    }

    // MARK: Loading / saving

    /// Loads profiles.json (if present) and guarantees the built-in Default profile exists and comes first.
    @discardableResult
    public func load() throws -> [Profile] {
        if fileManager.fileExists(atPath: paths.profilesFile.path) {
            let data = try Data(contentsOf: paths.profilesFile)
            let file = try Self.decoder.decode(ProfilesFile.self, from: data)
            profiles = file.profiles
        } else {
            profiles = []
        }
        let changed = ensureDefaultProfile()
        if changed || !fileManager.fileExists(atPath: paths.profilesFile.path) {
            try save()
        }
        return profiles
    }

    public func save() throws {
        try fileManager.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(ProfilesFile(version: 1, profiles: profiles))
        try data.write(to: paths.profilesFile, options: .atomic)
    }

    @discardableResult
    private func ensureDefaultProfile() -> Bool {
        let defaultDir = paths.defaultClaudeDataDirectory.path
        if let index = profiles.firstIndex(where: { $0.isDefault }) {
            var changed = false
            if profiles[index].dataDirectory != defaultDir {
                profiles[index].dataDirectory = defaultDir
                changed = true
            }
            if index != 0 {
                let p = profiles.remove(at: index)
                profiles.insert(p, at: 0)
                changed = true
            }
            return changed
        }
        let created = (try? fileManager.attributesOfItem(atPath: defaultDir)[.creationDate] as? Date) ?? now()
        profiles.insert(Profile(id: Profile.defaultProfileID, name: "Default", color: .orange,
                                dataDirectory: defaultDir, createdAt: created), at: 0)
        return true
    }

    // MARK: Queries

    public func profile(id: String) -> Profile? { profiles.first { $0.id == id } }

    /// Finds the profile whose data dir matches `userDataDir` (nil means the default data dir).
    public func profile(forUserDataDirectory userDataDir: String?) -> Profile? {
        guard let dir = userDataDir else { return profile(id: Profile.defaultProfileID) }
        let wanted = canonicalPath(dir)
        return profiles.first { canonicalPath($0.dataDirectory) == wanted }
    }

    // MARK: Mutations

    @discardableResult
    public func create(name: String, color: ProfileColor? = nil, emoji: String? = nil) throws -> Profile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileStoreError.invalidName }
        let id = Self.makeID()
        let dir = paths.dataDirectory(forProfileID: id)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let chosenColor = color ?? nextColor()
        let profile = Profile(id: id, name: trimmed, color: chosenColor, emoji: emoji?.nilIfBlank,
                              dataDirectory: dir.path, createdAt: now())
        profiles.append(profile)
        try save()
        return profile
    }

    public func rename(id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileStoreError.invalidName }
        try mutate(id) { $0.name = trimmed }
    }

    public func setColor(id: String, color: ProfileColor) throws {
        try mutate(id) { $0.color = color }
    }

    public func setEmoji(id: String, emoji: String?) throws {
        try mutate(id) { $0.emoji = emoji?.nilIfBlank }
    }

    public func markLaunched(id: String) throws {
        let date = now()
        try mutate(id) { $0.lastLaunchedAt = date }
    }

    /// Creates a new, empty profile with the same name (plus "Copy") and appearance. No data is copied.
    @discardableResult
    public func duplicateAsEmpty(id: String) throws -> Profile {
        guard let source = profile(id: id) else { throw ProfileStoreError.notFound(id) }
        return try create(name: uniqueName(base: "\(source.name) Copy"), color: source.color, emoji: source.emoji)
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        var items = profiles
        let moving = source.map { items[$0] }
        for index in source.sorted(by: >) { items.remove(at: index) }
        let adjusted = destination - source.filter { $0 < destination }.count
        items.insert(contentsOf: moving, at: max(0, min(adjusted, items.count)))
        profiles = items
        ensureDefaultProfile()
        try save()
    }

    /// Deletes a profile and moves its data directory to the Trash.
    /// - Parameter isRunning: whether a Claude instance for this profile is currently running.
    /// - Returns: the URL of the trashed data directory, if one existed.
    @discardableResult
    public func delete(id: String, isRunning: Bool) throws -> URL? {
        guard let profile = profile(id: id) else { throw ProfileStoreError.notFound(id) }
        guard !profile.isDefault else { throw ProfileStoreError.cannotDeleteDefault }
        guard !isRunning else { throw ProfileStoreError.profileIsRunning(profile.name) }
        let dir = URL(fileURLWithPath: profile.dataDirectory)
        // Safety net: only ever trash folders inside our own Profiles root, never Claude's default dir.
        let root = canonicalPath(paths.profilesDataRoot.path) + "/"
        let target = canonicalPath(dir.path)
        guard target.hasPrefix(root), target != canonicalPath(paths.defaultClaudeDataDirectory.path) else {
            throw ProfileStoreError.dataDirectoryOutsideStore(dir.path)
        }
        var trashed: NSURL?
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.trashItem(at: dir, resultingItemURL: &trashed)
        }
        profiles.removeAll { $0.id == id }
        try save()
        return trashed as URL?
    }

    // MARK: Helpers

    private func mutate(_ id: String, _ body: (inout Profile) -> Void) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ProfileStoreError.notFound(id) }
        body(&profiles[index])
        try save()
    }

    func nextColor() -> ProfileColor {
        let used = Set(profiles.map(\.color))
        return ProfileColor.allCases.first { !used.contains($0) }
            ?? ProfileColor.allCases[profiles.count % ProfileColor.allCases.count]
    }

    func uniqueName(base: String) -> String {
        let names = Set(profiles.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    static func makeID() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12).description
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
