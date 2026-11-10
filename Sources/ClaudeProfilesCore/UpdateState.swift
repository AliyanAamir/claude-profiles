import Foundation

/// Pure decision logic for the update UI, kept free of I/O so it can be unit-tested.
public enum UpdateStatus: Equatable, Sendable {
    case claudeMissing
    case unknown
    case upToDate(AppVersion)
    case available(installed: AppVersion, latest: AvailableRelease)
}

public enum UpdateLogic {
    public static func status(installed: ClaudeInstallation?, latest: AvailableRelease?, checked: Bool) -> UpdateStatus {
        guard let installed else { return .claudeMissing }
        guard let current = installed.version else { return .unknown }
        guard checked else { return .unknown }
        if let latest, latest.version > current {
            return .available(installed: current, latest: latest)
        }
        return .upToDate(current)
    }

    /// Instances running a version older than what's on disk now (Claude updated itself from one
    /// profile, or Claude Profiles swapped the bundle while some instance kept running).
    public static func outdatedInstances(_ instances: [RunningInstance], installedVersion: AppVersion?) -> [RunningInstance] {
        guard let installedVersion else { return [] }
        return instances.filter { inst in
            if let v = inst.launchedVersion { return v < installedVersion }
            return inst.startedBeforeCurrentBundle
        }
    }

    /// Profiles to relaunch after an update: exactly the ones running before, de-duplicated, in launch order.
    public static func profilesToRelaunch(before instances: [RunningInstance]) -> [String] {
        var seen = Set<String>()
        return instances.sorted { $0.startTime < $1.startTime }.compactMap { $0.profileID }.filter { seen.insert($0).inserted }
    }

    /// "Idle" for auto-restart purposes: not frontmost and not activated within `idleInterval`.
    public static func idleInstances(_ instances: [RunningInstance], frontmostPID: pid_t?,
                                     lastActivated: [pid_t: Date], now: Date,
                                     idleInterval: TimeInterval) -> [RunningInstance] {
        instances.filter { inst in
            if inst.pid == frontmostPID { return false }
            let last = lastActivated[inst.pid] ?? inst.startTime
            return now.timeIntervalSince(last) >= idleInterval
        }
    }

    public static func nextCheckDate(lastCheck: Date?, interval: TimeInterval, now: Date) -> Date? {
        guard interval > 0 else { return nil }
        guard let lastCheck else { return now }
        return max(now, lastCheck.addingTimeInterval(interval))
    }
}
