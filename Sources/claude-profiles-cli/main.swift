import ClaudeProfilesCore
import Foundation

// Maintainer / diagnostics tool for Claude Profiles. Shares all logic with the app via ClaudeProfilesCore.

let usage = """
usage: claude-profiles-cli <command> [options]

  status                      Installed Claude version and running instances mapped to profiles
  profiles                    List profiles (creates the Default entry on first run)
  create <name>               Create a profile
  delete <id>                 Delete a profile (data dir goes to Trash; refused while running)
  launch <id>                 Launch a profile as a new Claude instance
  quit <id>                   Gracefully quit a profile's running instance(s)
  check-update                Query Claude's official update feed (read-only)
  verify <app>                Verify an app's code signature, Team ID and bundle id
  install-test --target <app> (--artifact <zip> | --download) [--sha256 <hex>] [--version <v>] [--inject-failure]
                              Run the download/verify/swap/rollback path against a COPY of Claude.app.
                              Refuses to touch /Applications/Claude.app.
  route <pid> <url>           Send a GURL Apple Event with <url> to one specific process
"""

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(2) }

func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let paths = AppPaths.standard()
let store = ProfileStore(paths: paths)
do { try store.load() } catch { fail("Couldn't load profiles: \(error)") }
let installation = ClaudeInstallation.read()

func runningInstances() -> [RunningInstance] {
    let procs = ProcessScanner.claudeMainProcesses(executablePath: ClaudeConstants.defaultAppURL.appendingPathComponent("Contents/MacOS/Claude").path)
    return RuntimeTracker(paths: paths).reconcile(processes: procs, resolveProfile: { store.profile(forUserDataDirectory: $0)?.id }, installation: installation)
}

func resolve(_ key: String) -> Profile {
    if let p = store.profile(id: key) ?? store.profiles.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) { return p }
    fail("No profile \(key)")
}

switch command {
case "status":
    print("Claude: \(installation.map { "\($0.version?.string ?? "?") at \($0.appURL.path)" } ?? "not installed")")
    for inst in runningInstances() {
        let name = inst.profileID.flatMap { store.profile(id: $0)?.name } ?? "unmanaged"
        print("pid \(inst.pid)\tprofile=\(inst.profileID ?? "-") (\(name))\tversion=\(inst.launchedVersion?.string ?? "older/unknown")\tdataDir=\(inst.userDataDirectory ?? "<default>")")
    }

case "profiles":
    for p in store.profiles {
        print("\(p.id)\t\(p.name)\t\(p.color.rawValue)\t\(p.dataDirectory)")
    }

case "create":
    guard args.count >= 2 else { fail(usage) }
    let p = try store.create(name: args[1])
    print(p.id)

case "delete":
    guard args.count >= 2 else { fail(usage) }
    let p = resolve(args[1])
    let running = runningInstances().contains { $0.profileID == p.id }
    do { let trashed = try store.delete(id: p.id, isRunning: running); print("deleted; data dir in Trash at \(trashed?.path ?? "-")") }
    catch { fail(error.localizedDescription) }

case "launch":
    guard args.count >= 2 else { fail(usage) }
    let p = resolve(args[1])
    let pid = try await Launcher().launch(p, activate: false)
    try store.markLaunched(id: p.id)
    RuntimeTracker(paths: paths).recordLaunch(pid: pid, startTime: Date(), version: installation?.version, profileID: p.id)
    print(pid)

case "quit":
    guard args.count >= 2 else { fail(usage) }
    let p = resolve(args[1])
    let launcher = Launcher()
    for inst in runningInstances() where inst.profileID == p.id {
        let ok = await launcher.quit(pid: inst.pid)
        print("pid \(inst.pid) quit: \(ok)")
    }

case "check-update":
    let feed = UpdateFeed(deviceID: "claude-profiles-cli")
    let current = installation?.version?.string ?? "0.0.0"
    let latest = try await feed.fetchLatest(currentVersion: current)
    let status = UpdateLogic.status(installed: installation, latest: latest, checked: true)
    print("installed: \(current)")
    print("feed latest: \(latest?.version.string ?? "none") \(latest?.downloadURL.absoluteString ?? "")")
    print("sha256: \(latest?.sha256 ?? "-") size: \(latest?.size.map(String.init) ?? "-")")
    switch status {
    case .available: print("status: update available")
    case .upToDate: print("status: up to date")
    default: print("status: \(status)")
    }

case "verify":
    guard args.count >= 2 else { fail(usage) }
    do {
        let v = try ClaudeSignatureVerifier().verify(appAt: URL(fileURLWithPath: args[1]))
        print("OK team=\(v.teamIdentifier) id=\(v.bundleIdentifier) version=\(v.version?.string ?? "?")")
    } catch { fail("FAILED: \(error.localizedDescription)") }

case "install-test":
    guard let targetPath = value("--target") else { fail(usage) }
    let target = URL(fileURLWithPath: targetPath).standardizedFileURL
    if canonicalPath(target.path) == canonicalPath(ClaudeConstants.defaultAppURL.path) {
        fail("Refusing: install-test never touches /Applications/Claude.app. Copy it somewhere first.")
    }
    let work = target.deletingLastPathComponent().appendingPathComponent("claude-profiles-work")
    let installer = UpdateInstaller(workDirectory: work)
    var expected = value("--version").flatMap(AppVersion.init)
    var sha = value("--sha256")
    let archive: URL
    if let a = value("--artifact") {
        archive = URL(fileURLWithPath: a)
    } else if args.contains("--download") {
        guard let latest = try await UpdateFeed(deviceID: "claude-profiles-cli").fetchLatest(currentVersion: installation?.version?.string ?? "0.0.0") else { fail("feed has no release") }
        expected = expected ?? latest.version
        sha = sha ?? latest.sha256
        print("downloading \(latest.downloadURL) …")
        let printer = ProgressPrinter()
        archive = try await installer.download(latest.downloadURL, expectedSize: latest.size) { p in printer.report(p) }
    } else { fail(usage) }
    let started = Date()
    do {
        try installer.verifyChecksum(of: archive, expected: sha)
        print("checksum: \(sha == nil ? "skipped (none given)" : "OK")")
        let staged = try installer.extract(archive)
        print("extracted: \(staged.path)")
        if args.contains("--inject-failure") {
            installer.afterSwapHook = { app in
                // Simulate a corrupted install: break the signature of the moved-in bundle.
                let f = app.appendingPathComponent("Contents/Resources/claude-profiles-tamper.txt")
                try "tampered".write(to: f, atomically: true, encoding: .utf8)
            }
        }
        let before = ClaudeInstallation.read(at: target)?.version?.string ?? "none"
        let verified = try installer.install(staged: staged, over: target, expectedVersion: expected)
        print("installed OK: \(before) -> \(verified.version?.string ?? "?") team=\(verified.teamIdentifier) in \(Int(Date().timeIntervalSince(started)))s")
    } catch {
        let after = ClaudeInstallation.read(at: target)?.version?.string ?? "none"
        print("install failed: \(error.localizedDescription)")
        print("target after failure: version=\(after); signature: \((try? ClaudeSignatureVerifier().verify(appAt: target)) != nil ? "valid" : "INVALID")")
        installer.cleanWorkDirectory()
        exit(3)
    }
    installer.cleanWorkDirectory()

case "route":
    guard args.count >= 3, let pid = Int32(args[1]) else { fail(usage) }
    do { try URLForwarder.sendGetURL(args[2], to: pid); print("delivered to \(pid)") }
    catch { fail("failed: \(error)") }

default:
    print(usage)
    exit(2)
}

final class ProgressPrinter: @unchecked Sendable {
    private var last = -1
    private let lock = NSLock()
    func report(_ p: Double) {
        lock.lock(); defer { lock.unlock() }
        let bucket = Int(p * 10)
        if bucket != last { last = bucket; print("  \(bucket * 10)%") }
    }
}
