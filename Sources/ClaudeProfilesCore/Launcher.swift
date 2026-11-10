import AppKit
import Foundation

public enum LauncherError: LocalizedError {
    case claudeMissing(URL)
    case launchFailed(String)
    case didNotQuit(pid_t)

    public var errorDescription: String? {
        switch self {
        case .claudeMissing(let url): return "Claude is not installed at \(url.path)."
        case .launchFailed(let msg): return "Couldn't launch Claude: \(msg)"
        case .didNotQuit(let pid): return "Claude (pid \(pid)) did not quit in time."
        }
    }
}

/// Launches, focuses and quits Claude instances. Every profile runs the same official Claude.app;
/// non-default profiles get Chromium's `--user-data-dir` switch, which Electron uses as `userData`.
@MainActor
public final class Launcher {
    public var claudeAppURL: URL

    public init(claudeAppURL: URL = ClaudeConstants.defaultAppURL) {
        self.claudeAppURL = claudeAppURL
    }

    /// Starts a new Claude instance for `profile` and returns its PID.
    public func launch(_ profile: Profile, activate: Bool = true) async throws -> pid_t {
        guard FileManager.default.fileExists(atPath: claudeAppURL.appendingPathComponent("Contents/Info.plist").path) else {
            throw LauncherError.claudeMissing(claudeAppURL)
        }
        if !profile.isDefault {
            try FileManager.default.createDirectory(atPath: profile.dataDirectory, withIntermediateDirectories: true)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = activate
        config.addsToRecentItems = false
        config.arguments = profile.launchArguments
        // Informational only: lets tooling identify which profile started an instance.
        config.environment = ["CLAUDE_PROFILES_PROFILE_ID": profile.id]
        do {
            let app = try await NSWorkspace.shared.openApplication(at: claudeAppURL, configuration: config)
            return app.processIdentifier
        } catch {
            throw LauncherError.launchFailed(error.localizedDescription)
        }
    }

    /// Brings the instance to the front.
    @discardableResult
    public func focus(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        if app.isHidden { app.unhide() }
        // macOS 14+ cooperative activation: hand our activation to the target first.
        NSApp?.yieldActivation(to: app)
        return app.activate(options: [.activateAllWindows])
    }

    /// Asks the instance to quit like Cmd-Q does, then waits up to `timeout` seconds for it to exit.
    public func quit(pid: pid_t, timeout: TimeInterval = 30) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return true }
        if app.isTerminated { return true }
        _ = app.terminate()
        return await waitForExit(pid: pid, timeout: timeout)
    }

    /// Waits until no process (main or helper) still uses `dataDirectory`. Electron's single-instance lock
    /// lives in the data dir; launching again before helpers exit makes the new instance quit immediately.
    public func waitForDataDirectoryRelease(_ dataDirectory: String, timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ProcessScanner.processesUsing(dataDirectory: dataDirectory, appPath: claudeAppURL.path).isEmpty { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    public func forceQuit(pid: pid_t) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return true }
        _ = app.forceTerminate()
        return await waitForExit(pid: pid, timeout: 10)
    }

    public func waitForExit(pid: pid_t, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !ProcessScanner.isAlive(pid) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return !ProcessScanner.isAlive(pid)
    }
}
