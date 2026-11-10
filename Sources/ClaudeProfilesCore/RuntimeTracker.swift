import Foundation

/// What we know about one running Claude instance.
public struct RunningInstance: Hashable, Sendable, Identifiable {
    public var id: pid_t { pid }
    public let pid: pid_t
    /// Profile id, or nil for an instance whose data dir doesn't match any profile.
    public let profileID: String?
    public let userDataDirectory: String?
    public let startTime: Date
    /// The Claude version this instance was started with, when known.
    public let launchedVersion: AppVersion?
    /// True when the instance started before the bundle on disk was last replaced.
    public let startedBeforeCurrentBundle: Bool
}

/// Persisted record of the version each PID was started with, so the mapping survives manager restarts.
public struct LaunchRecord: Codable, Hashable, Sendable {
    public var pid: Int32
    public var startTime: Date
    public var version: AppVersion?
    public var profileID: String?
}

/// Maps Claude main processes to profiles and remembers the version each was launched with.
public final class RuntimeTracker {
    private let paths: AppPaths
    private var records: [Int32: LaunchRecord] = [:]

    public init(paths: AppPaths) {
        self.paths = paths
        loadRecords()
    }

    /// Records that `pid` was launched while `version` was installed.
    public func recordLaunch(pid: pid_t, startTime: Date, version: AppVersion?, profileID: String?) {
        records[pid] = LaunchRecord(pid: pid, startTime: startTime, version: version, profileID: profileID)
        saveRecords()
    }

    /// Builds the current list of running instances.
    /// - Parameters:
    ///   - processes: main Claude processes found by `ProcessScanner`.
    ///   - resolveProfile: maps a user data dir (nil = default) to a profile id.
    ///   - installation: the bundle currently on disk.
    public func reconcile(processes: [ClaudeProcess],
                          resolveProfile: (String?) -> String?,
                          installation: ClaudeInstallation?) -> [RunningInstance] {
        var result: [RunningInstance] = []
        var live: Set<Int32> = []
        var dirty = false
        for proc in processes {
            live.insert(proc.pid)
            let profileID = resolveProfile(proc.userDataDirectory)
            let bundleDate = installation?.infoPlistModified
            // Small tolerance: a process launched right after the swap may report a start time a hair earlier.
            let startedBefore = bundleDate.map { proc.startTime < $0.addingTimeInterval(-2) } ?? false
            var record = records[proc.pid]
            // A recycled PID has a different start time: discard the stale record.
            if let r = record, abs(r.startTime.timeIntervalSince(proc.startTime)) > 2 { record = nil }
            if record == nil {
                // First time we see this process: if it started after the current bundle was installed,
                // it is running the current version; otherwise its version is unknown (older).
                record = LaunchRecord(pid: proc.pid, startTime: proc.startTime,
                                      version: startedBefore ? nil : installation?.version,
                                      profileID: profileID)
                records[proc.pid] = record
                dirty = true
            }
            result.append(RunningInstance(pid: proc.pid, profileID: profileID,
                                          userDataDirectory: proc.userDataDirectory,
                                          startTime: proc.startTime,
                                          launchedVersion: record?.version,
                                          startedBeforeCurrentBundle: startedBefore))
        }
        let stale = records.keys.filter { !live.contains($0) }
        if !stale.isEmpty {
            stale.forEach { records.removeValue(forKey: $0) }
            dirty = true
        }
        if dirty { saveRecords() }
        return result.sorted { $0.startTime < $1.startTime }
    }

    private func loadRecords() {
        guard let data = try? Data(contentsOf: paths.runtimeFile),
              let list = try? ProfileStore.decoder.decode([LaunchRecord].self, from: data) else { return }
        records = Dictionary(list.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func saveRecords() {
        try? FileManager.default.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        if let data = try? ProfileStore.encoder.encode(Array(records.values).sorted { $0.pid < $1.pid }) {
            try? data.write(to: paths.runtimeFile, options: .atomic)
        }
    }
}
