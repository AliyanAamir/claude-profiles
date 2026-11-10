import AppKit
import ClaudeProfilesCore
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

/// Settings keys (also used with @AppStorage in views).
enum SettingsKey {
    static let checkInterval = "checkInterval"          // seconds; 0 = never
    static let autoRestartIdle = "autoRestartIdle"      // Bool
    static let routeLinks = "routeLinks"                // Bool
    static let deviceID = "feedDeviceID"
}

struct UpdateProgress: Equatable {
    var title: String
    var detail: String?
    var fraction: Double?
    var cancellable: Bool = false
}

/// Central app state. All UI reads from here; long work runs in tasks and reports progress back.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let paths = AppPaths.standard()
    let store: ProfileStore
    let tracker: RuntimeTracker
    let launcher = Launcher()

    @Published private(set) var profiles: [Profile] = [] {
        didSet {
            // A warning about a profile that has since been added/removed/renamed is stale.
            if oldValue.map(\.id) != profiles.map(\.id) || oldValue.map(\.name) != profiles.map(\.name) { errorMessage = nil }
        }
    }
    /// Short, self-dismissing notice (e.g. an automation call that named an unknown profile).
    @Published private(set) var transientNotice: String?
    private var noticeTask: Task<Void, Never>?

    func showTransientNotice(_ text: String, seconds: Double = 4) {
        AppLog.write("notice: \(text)")
        transientNotice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.transientNotice = nil }
        }
    }
    @Published private(set) var instances: [RunningInstance] = []
    @Published private(set) var installation: ClaudeInstallation?
    @Published private(set) var latestRelease: AvailableRelease?
    @Published private(set) var lastCheck: Date?
    @Published private(set) var isChecking = false
    @Published private(set) var checkError: String?
    @Published private(set) var updateProgress: UpdateProgress?
    @Published private(set) var updateFailure: String?
    @Published private(set) var busyProfiles: Set<String> = []
    @Published private(set) var signingInProfileID: String?
    @Published private(set) var lastRoute: String?
    @Published var errorMessage: String? {
        didSet { if let e = errorMessage { AppLog.write("error: \(e)") } }
    }

    // UI coordination
    @Published var editorRequest: EditorRequest?
    @Published var profilePendingDelete: Profile?

    private(set) var lastActivated: [pid_t: Date] = [:]
    private var signingInUntil: Date?
    private var refreshTimer: Timer?
    private var checkTimer: Timer?
    private var updateTask: Task<Void, Never>?
    private var notifiedVersion: String?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private let defaults = UserDefaults.standard

    private init() {
        store = ProfileStore(paths: paths)
        tracker = RuntimeTracker(paths: paths)
        defaults.register(defaults: [SettingsKey.checkInterval: 3600.0,
                                     SettingsKey.autoRestartIdle: false,
                                     SettingsKey.routeLinks: true])
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        do { profiles = try store.load() } catch { errorMessage = "Couldn't read profiles.json: \(error.localizedDescription)" }
        installation = ClaudeInstallation.read(at: launcher.claudeAppURL)
        refresh()

        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == ClaudeConstants.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.lastActivated[app.processIdentifier] = Date() }
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == ClaudeConstants.bundleIdentifier else { return }
                MainActor.assumeIsolated { self?.refresh() }
            })
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        checkTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task { await checkForUpdates(userInitiated: false) }
    }

    // MARK: Derived state

    var claudeMissing: Bool { installation == nil }
    var updateStatus: UpdateStatus { UpdateLogic.status(installed: installation, latest: latestRelease, checked: lastCheck != nil) }
    var outdatedInstances: [RunningInstance] { UpdateLogic.outdatedInstances(instances, installedVersion: installation?.version) }
    var runningProfileCount: Int { Set(instances.compactMap(\.profileID)).count }
    var isUpdating: Bool { updateProgress != nil }

    func instances(for profile: Profile) -> [RunningInstance] { instances.filter { $0.profileID == profile.id } }
    func isRunning(_ profile: Profile) -> Bool { instances.contains { $0.profileID == profile.id } }
    func isBusy(_ profile: Profile) -> Bool { busyProfiles.contains(profile.id) }
    func isOutdated(_ profile: Profile) -> Bool { outdatedInstances.contains { $0.profileID == profile.id } }

    // MARK: Refresh

    private var profilesFileDate: Date?

    /// Picks up edits made by claude-profiles-cli (or by hand) to profiles.json.
    private func reloadProfilesIfChangedOnDisk() {
        let date = (try? FileManager.default.attributesOfItem(atPath: paths.profilesFile.path)[.modificationDate]) as? Date
        defer { profilesFileDate = date }
        guard let date, let previous = profilesFileDate, date > previous else { return }
        if let loaded = try? store.load(), loaded != profiles { profiles = loaded }
    }

    func refresh() {
        reloadProfilesIfChangedOnDisk()
        let newInstall = ClaudeInstallation.read(at: launcher.claudeAppURL)
        let oldVersion = installation?.version
        if newInstall != installation { installation = newInstall }
        let procs = ProcessScanner.claudeMainProcesses(executablePath: launcher.claudeAppURL.appendingPathComponent("Contents/MacOS/Claude").path)
        let store = self.store
        let next = tracker.reconcile(processes: procs, resolveProfile: { store.profile(forUserDataDirectory: $0)?.id }, installation: newInstall)
        if next != instances { instances = next }
        let live = Set(next.map(\.pid))
        lastActivated = lastActivated.filter { live.contains($0.key) }
        if let until = signingInUntil, until < Date() { signingInProfileID = nil; signingInUntil = nil }

        if let old = oldVersion, let new = newInstall?.version, new != old, !isUpdating {
            bundleChanged(from: old, to: new)
        }
    }

    private func bundleChanged(from old: AppVersion, to new: AppVersion) {
        let outdated = outdatedInstances
        if !outdated.isEmpty {
            notify(title: "Claude was updated to \(new)",
                   body: "\(outdated.count) profile\(outdated.count == 1 ? " is" : "s are") still running \(old). Restart to use the new version.")
            if defaults.bool(forKey: SettingsKey.autoRestartIdle) {
                Task { await restartIdleOutdated() }
            }
        }
    }

    // MARK: Profile actions

    func primaryAction(_ profile: Profile) {
        if let inst = instances(for: profile).last { launcher.focus(pid: inst.pid) } else { launch(profile) }
    }

    func launch(_ profile: Profile, activate: Bool = true) {
        Task { await launchAsync(profile, activate: activate) }
    }

    @discardableResult
    func launchAsync(_ profile: Profile, activate: Bool = true) async -> pid_t? {
        // The profile may have been deleted while a restart/relaunch was in flight.
        guard store.profile(id: profile.id) != nil else {
            AppLog.write("skip launch of \(profile.name): profile no longer exists")
            return nil
        }
        guard !isRunning(profile) else {
            if activate, let inst = instances(for: profile).last { launcher.focus(pid: inst.pid) }
            return instances(for: profile).last?.pid
        }
        busyProfiles.insert(profile.id)
        defer { busyProfiles.remove(profile.id) }
        do {
            // A just-quit instance may still hold the profile's single-instance lock via helper processes.
            _ = await launcher.waitForDataDirectoryRelease(profile.dataDirectory)
            var pid = try await launcher.launch(profile, activate: activate)
            // If Claude exits right away (lock race), try once more.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !ProcessScanner.isAlive(pid) {
                AppLog.write("\(profile.name) pid \(pid) exited immediately; retrying launch")
                _ = await launcher.waitForDataDirectoryRelease(profile.dataDirectory)
                pid = try await launcher.launch(profile, activate: activate)
            }
            AppLog.write("launched \(profile.name) (\(profile.id)) pid \(pid)")
            tracker.recordLaunch(pid: pid, startTime: Date(), version: installation?.version, profileID: profile.id)
            try? store.markLaunched(id: profile.id)
            profiles = store.profiles
            refresh()
            return pid
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func quit(_ profile: Profile) {
        Task { await quitAsync(profile) }
    }

    @discardableResult
    func quitAsync(_ profile: Profile) async -> Bool {
        busyProfiles.insert(profile.id)
        defer { busyProfiles.remove(profile.id) }
        var ok = true
        for inst in instances(for: profile) {
            let quit = await launcher.quit(pid: inst.pid, timeout: 30)
            AppLog.write("quit \(profile.name) pid \(inst.pid): \(quit ? "exited" : "still running")")
            if !quit { ok = false }
        }
        refresh()
        if !ok { errorMessage = "\(profile.name) didn't quit. It may be showing a dialog." }
        return ok
    }

    func restart(_ profile: Profile) {
        Task {
            guard await quitAsync(profile) else { return }
            await launchAsync(profile)
        }
    }

    func launchAll() {
        Task {
            for p in profiles where !isRunning(p) { await launchAsync(p, activate: false) }
        }
    }

    func quitAll() {
        Task {
            for p in profiles where isRunning(p) { await quitAsync(p) }
        }
    }

    func launchProfile(atIndex index: Int) {
        guard profiles.indices.contains(index) else { return }
        primaryAction(profiles[index])
    }

    func signIn(_ profile: Profile) {
        signingInProfileID = profile.id
        signingInUntil = Date().addingTimeInterval(15 * 60)
        Task {
            let wasRunning = isRunning(profile)
            if wasRunning, let inst = instances(for: profile).last { launcher.focus(pid: inst.pid) }
            else { await launchAsync(profile) }
            // Claude re-registers itself as the claude:// handler every time it starts, so claim the
            // scheme only now, after the profile is up. macOS may ask the user to confirm this once.
            if !wasRunning { try? await Task.sleep(nanoseconds: 4_000_000_000) }
            await ensureURLHandler()
        }
    }

    func cancelSignIn() {
        signingInProfileID = nil
        signingInUntil = nil
    }

    func revealDataDirectory(_ profile: Profile) {
        let url = URL(fileURLWithPath: profile.dataDirectory)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            errorMessage = "The data folder doesn't exist yet. Launch the profile once to create it."
        }
    }

    // MARK: Profile CRUD

    func createProfile(name: String, color: ProfileColor, emoji: String?) {
        do {
            _ = try store.create(name: name, color: color, emoji: emoji)
            profiles = store.profiles
        } catch { errorMessage = error.localizedDescription }
    }

    func updateProfile(id: String, name: String, color: ProfileColor, emoji: String?) {
        do {
            try store.rename(id: id, to: name)
            try store.setColor(id: id, color: color)
            try store.setEmoji(id: id, emoji: emoji)
            profiles = store.profiles
        } catch { errorMessage = error.localizedDescription }
    }

    func setColor(_ profile: Profile, _ color: ProfileColor) {
        do { try store.setColor(id: profile.id, color: color); profiles = store.profiles }
        catch { errorMessage = error.localizedDescription }
    }

    func duplicateAsEmpty(_ profile: Profile) {
        do { _ = try store.duplicateAsEmpty(id: profile.id); profiles = store.profiles }
        catch { errorMessage = error.localizedDescription }
    }

    func requestDelete(_ profile: Profile) {
        if profile.isDefault { errorMessage = ProfileStoreError.cannotDeleteDefault.localizedDescription; return }
        if isRunning(profile) { errorMessage = ProfileStoreError.profileIsRunning(profile.name).localizedDescription; return }
        profilePendingDelete = profile
    }

    func confirmDelete(_ profile: Profile) {
        refresh()
        do {
            try store.delete(id: profile.id, isRunning: isRunning(profile))
            profiles = store.profiles
        } catch { errorMessage = error.localizedDescription }
        profilePendingDelete = nil
    }

    func moveProfiles(from: IndexSet, to: Int) {
        do { try store.move(fromOffsets: from, toOffset: to); profiles = store.profiles }
        catch { errorMessage = error.localizedDescription }
    }

    // MARK: Update checking

    private var deviceID: String {
        if let id = defaults.string(forKey: SettingsKey.deviceID) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: SettingsKey.deviceID)
        return id
    }

    private func checkIfDue() {
        let interval = defaults.double(forKey: SettingsKey.checkInterval)
        guard let due = UpdateLogic.nextCheckDate(lastCheck: lastCheck, interval: interval, now: Date()), due <= Date() else { return }
        Task { await checkForUpdates(userInitiated: false) }
    }

    func checkForUpdates(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let current = installation?.version?.string ?? "0.0.0"
        do {
            let release = try await UpdateFeed(deviceID: deviceID).fetchLatest(currentVersion: current)
            latestRelease = release
            lastCheck = Date()
            checkError = nil
            if case .available(let installed, let latest) = updateStatus, notifiedVersion != latest.version.string {
                notifiedVersion = latest.version.string
                notify(title: "Claude \(latest.version) is available",
                       body: "You have \(installed). Open Claude Profiles and choose “Update All Profiles”.")
            }
        } catch {
            checkError = error.localizedDescription
            if userInitiated { errorMessage = "Update check failed: \(error.localizedDescription)" }
        }
    }

    // MARK: Update all profiles

    func cancelUpdate() { updateTask?.cancel() }

    func updateAllProfiles() {
        guard updateTask == nil, case .available(_, let release) = updateStatus else { return }
        updateFailure = nil
        updateTask = Task { [weak self] in
            await self?.runUpdate(release)
            self?.updateTask = nil
        }
    }

    private func runUpdate(_ release: AvailableRelease) async {
        let installer = UpdateInstaller(workDirectory: paths.cachesDirectory.appendingPathComponent("updates/\(release.version)"))
        let target = launcher.claudeAppURL
        var toRelaunch: [String] = []
        var quitDone = false
        defer { installer.cleanWorkDirectory() }
        do {
            updateProgress = UpdateProgress(title: "Downloading Claude \(release.version)…", fraction: 0, cancellable: true)
            let archive = try await installer.download(release.downloadURL, expectedSize: release.size) { fraction in
                Task { @MainActor in
                    AppModel.shared.updateProgress?.fraction = fraction
                }
            }
            try Task.checkCancellation()
            updateProgress = UpdateProgress(title: "Verifying download…")
            let staged = try await Task.detached { () throws -> URL in
                try installer.verifyChecksum(of: archive, expected: release.sha256)
                let app = try installer.extract(archive)
                try installer.verify(app: app, expectedVersion: release.version)
                return app
            }.value
            try Task.checkCancellation()

            // Quit everything that runs the bundle, remembering what was running.
            refresh()
            let running = instances
            toRelaunch = UpdateLogic.profilesToRelaunch(before: running)
            updateProgress = UpdateProgress(title: "Quitting \(running.count) Claude instance\(running.count == 1 ? "" : "s")…")
            var failed: [pid_t] = []
            for inst in running where !(await launcher.quit(pid: inst.pid, timeout: 45)) { failed.append(inst.pid) }
            quitDone = true
            guard failed.isEmpty else {
                throw InstallerError.swapFailed("\(failed.count) Claude instance(s) didn't quit (maybe an unsaved-work dialog). Nothing was changed.")
            }

            updateProgress = UpdateProgress(title: "Installing Claude \(release.version)…")
            let verified = try await Task.detached { try installer.install(staged: staged, over: target, expectedVersion: release.version) }.value
            installation = ClaudeInstallation.read(at: target)

            updateProgress = UpdateProgress(title: "Relaunching \(toRelaunch.count) profile\(toRelaunch.count == 1 ? "" : "s")…")
            await relaunch(toRelaunch)
            updateProgress = nil
            notify(title: "All profiles updated", body: "Claude \(verified.version?.string ?? release.version.string) is installed and \(toRelaunch.count) profile(s) were relaunched.")
            refresh()
        } catch is CancellationError {
            updateProgress = nil
            if quitDone { await relaunch(toRelaunch) }
        } catch {
            updateProgress = nil
            updateFailure = error.localizedDescription
            if quitDone { await relaunch(toRelaunch) }
            refresh()
        }
    }

    private func relaunch(_ ids: [String]) async {
        for id in ids {
            if let p = store.profile(id: id) { await launchAsync(p, activate: false) }
        }
    }

    /// Fallback install path: let Claude's own Squirrel updater download and stage the update,
    /// then quit every instance so ShipIt swaps the bundle, wait for the new version, relaunch.
    func updateViaClaudeUpdater() {
        guard updateTask == nil else { return }
        updateFailure = nil
        updateTask = Task { [weak self] in
            await self?.runSquirrelFallback()
            self?.updateTask = nil
        }
    }

    private func runSquirrelFallback() async {
        guard let before = installation?.version else { return }
        refresh()
        let toRelaunch = UpdateLogic.profilesToRelaunch(before: instances)
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Claude/main.log")
        let startOffset = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
        do {
            if instances.isEmpty, let first = store.profile(id: toRelaunch.first ?? Profile.defaultProfileID) {
                updateProgress = UpdateProgress(title: "Starting Claude so it can download the update…")
                await launchAsync(first, activate: false)
            }
            updateProgress = UpdateProgress(title: "Waiting for Claude to download the update…", detail: "Claude's own updater is working. This can take a few minutes.", cancellable: true)
            let deadline = Date().addingTimeInterval(20 * 60)
            var staged = false
            while Date() < deadline, !staged {
                try Task.checkCancellation()
                if let handle = try? FileHandle(forReadingFrom: logURL) {
                    try? handle.seek(toOffset: UInt64(startOffset))
                    let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
                    try? handle.close()
                    staged = text.contains("Update downloaded and ready to install")
                }
                if !staged { try await Task.sleep(nanoseconds: 3_000_000_000) }
            }
            guard staged else { throw InstallerError.downloadFailed("Claude didn't finish downloading the update in time.") }
            updateProgress = UpdateProgress(title: "Quitting Claude so the update can be applied…")
            refresh()
            for inst in instances { _ = await launcher.quit(pid: inst.pid, timeout: 45) }
            updateProgress = UpdateProgress(title: "Waiting for the new version to be installed…")
            let installDeadline = Date().addingTimeInterval(5 * 60)
            while Date() < installDeadline {
                if let v = ClaudeInstallation.read(at: launcher.claudeAppURL)?.version, v > before { break }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            installation = ClaudeInstallation.read(at: launcher.claudeAppURL)
            updateProgress = UpdateProgress(title: "Relaunching profiles…")
            await relaunch(toRelaunch)
            updateProgress = nil
            refresh()
        } catch {
            updateProgress = nil
            if !(error is CancellationError) { updateFailure = error.localizedDescription }
            await relaunch(toRelaunch.filter { id in !instances.contains { $0.profileID == id } })
        }
    }

    func restartOutdated() {
        Task {
            let ids = UpdateLogic.profilesToRelaunch(before: outdatedInstances)
            for id in ids { if let p = store.profile(id: id) { if await quitAsync(p) { await launchAsync(p, activate: false) } } }
        }
    }

    private func restartIdleOutdated() async {
        let idle = UpdateLogic.idleInstances(outdatedInstances, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                             lastActivated: lastActivated, now: Date(), idleInterval: 10 * 60)
        for id in UpdateLogic.profilesToRelaunch(before: idle) {
            if let p = store.profile(id: id), await quitAsync(p) { await launchAsync(p, activate: false) }
        }
    }

    // MARK: Sign-in / link routing

    var routeLinksEnabled: Bool { defaults.bool(forKey: SettingsKey.routeLinks) }

    /// Claims claude:// for Claude Profiles. Called only when the user starts a sign-in, never on a timer:
    /// macOS can show a confirmation for each default-handler change, and Claude takes the scheme back
    /// on its next launch anyway (which is harmless: with Claude Profiles not involved, links simply go
    /// to the oldest Claude window, as they do without this app).
    func ensureURLHandler() async {
        guard routeLinksEnabled else { return }
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        if URLHandlerRegistration.currentHandlerBundleID() != Bundle.main.bundleIdentifier {
            do { try await URLHandlerRegistration.setHandler(appURL: Bundle.main.bundleURL) }
            catch { AppLog.write("could not become claude:// handler: \(error.localizedDescription)") }
        }
    }

    func restoreClaudeAsURLHandler() async {
        guard URLHandlerRegistration.currentHandlerBundleID() == Bundle.main.bundleIdentifier, !claudeMissing else { return }
        try? await URLHandlerRegistration.setHandler(appURL: launcher.claudeAppURL)
    }


    /// claudeprofiles://<action>[/<profile id or name>] for Shortcuts, Raycast, scripts.
    /// Actions: launch, open, quit, restart, signin, launch-all, quit-all, check-updates.
    func handleAutomation(_ url: URL) {
        start()
        let action = url.host ?? ""
        let key = url.pathComponents.dropFirst().first?.removingPercentEncoding
        AppLog.write("automation \(action) \(key ?? "")")
        // Resolve against the store as it is on disk right now (the CLI or another window may have just
        // created/renamed the profile), not against a list that is refreshed every 2 seconds.
        refresh()
        let profile = key.flatMap { k in
            store.profile(id: k) ?? store.profiles.first { $0.name.caseInsensitiveCompare(k) == .orderedSame }
        }
        let needsProfile = ["launch", "open", "quit", "restart", "signin"].contains(action)
        if needsProfile && profile == nil {
            showTransientNotice("No profile named “\(key ?? "")”. The link was ignored.")
            return
        }
        switch action {
        case "launch", "open": primaryAction(profile!)
        case "quit": quit(profile!)
        case "restart": restart(profile!)
        case "signin": signIn(profile!)
        case "launch-all": launchAll()
        case "quit-all": quitAll()
        case "check-updates": Task { await checkForUpdates(userInitiated: true) }
        case "snapshot":
            // Debug aid: claudeprofiles://snapshot?path=/tmp/window.png
            if let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value {
                AppDelegate.snapshotMainWindow(to: path)
            }
        default: showTransientNotice("Unknown claudeprofiles:// action “\(action)”.")
        }
    }

    /// Handles a claude:// URL delivered to Claude Profiles and forwards it to one specific instance.
    func route(_ urlString: String) {
        start()
        refresh()
        let candidates = instances.map {
            URLRoutingPolicy.Candidate(pid: $0.pid, profileID: $0.profileID, lastActivated: lastActivated[$0.pid], startTime: $0.startTime)
        }
        let decision = URLRoutingPolicy.decide(signingInProfileID: signingInProfileID, candidates: candidates)
        let redacted = AppLog.redact(urlString)
        Task {
            var pid: pid_t?
            switch decision {
            case .forward(let p): pid = p
            case .launch(let id):
                if let profile = store.profile(id: id) { pid = await launchAsync(profile) }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            guard let pid else { return }
            let name = instances.first { $0.pid == pid }?.profileID.flatMap { store.profile(id: $0)?.name } ?? "pid \(pid)"
            let result: String
            do {
                try await Task.detached { try URLForwarder.sendGetURL(urlString, to: pid) }.value
                result = "routed \(redacted) -> \(name) (pid \(pid))"
            } catch {
                result = "FAILED to route \(redacted) -> \(name) (pid \(pid)): \(error.localizedDescription)"
                errorMessage = "Couldn't hand the link to \(name). If macOS asked for permission to control Claude, allow it in System Settings → Privacy & Security → Automation."
            }
            lastRoute = result
            AppLog.write(result)
        }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { errorMessage = "Couldn't change Launch at Login: \(error.localizedDescription)" }
            objectWillChange.send()
        }
    }

    // MARK: Notifications

    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

struct EditorRequest: Identifiable {
    let id = UUID()
    let profile: Profile?   // nil = create
}

/// Append-only log (routing decisions, automation, errors) at ~/Library/Logs/ClaudeProfiles/ClaudeProfiles.log.
enum AppLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClaudeProfiles/ClaudeProfiles.log")

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Keeps scheme/host/path but drops query strings (which can carry auth codes).
    static func redact(_ s: String) -> String {
        guard var c = URLComponents(string: s) else { return "<url>" }
        if c.query != nil { c.query = "…" }
        c.fragment = nil
        return c.string ?? "<url>"
    }
}
