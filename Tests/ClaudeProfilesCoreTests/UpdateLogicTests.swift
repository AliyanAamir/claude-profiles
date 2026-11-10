import XCTest
@testable import ClaudeProfilesCore

final class VersionTests: XCTestCase {
    func testParsingAndOrdering() {
        XCTAssertEqual(AppVersion("4.23118.1")?.components, [4, 23118, 1])
        XCTAssertNil(AppVersion("abc"))
        XCTAssertNil(AppVersion(""))
        XCTAssertLessThan(AppVersion("4.23118.1")!, AppVersion("4.23118.2")!)
        XCTAssertLessThan(AppVersion("4.9999.9")!, AppVersion("4.23118.0")!)
        XCTAssertLessThan(AppVersion("0.14.10")!, AppVersion("4.0")!)
        XCTAssertEqual(AppVersion("1.2")!, AppVersion("1.2.0")!)
        XCTAssertEqual(AppVersion("1.2.3-beta")!.components, [1, 2, 3])
        XCTAssertEqual(Set([AppVersion("1.2")!, AppVersion("1.2.0")!]).count, 1)
    }
}

final class UpdateFeedTests: XCTestCase {
    let sample = """
    {"currentRelease":"4.23118.1","releases":[{"version":"4.23118.1","updateTo":{"name":"Claude 4.23118.1","version":"4.23118.1","pub_date":"2026-11-09T18:38:42.913469","url":"https://downloads.claude.ai/releases/darwin/arm64/4.23118.1/Claude-e071.zip","notes":"Production Release - No Notes","sha256":"9EABB421","size":257486450}}]}
    """

    func testParsesSquirrelJSONFeed() throws {
        let r = try XCTUnwrap(UpdateFeed.parse(Data(sample.utf8)))
        XCTAssertEqual(r.version, AppVersion("4.23118.1"))
        XCTAssertEqual(r.downloadURL.host, "downloads.claude.ai")
        XCTAssertEqual(r.sha256, "9eabb421")
        XCTAssertEqual(r.size, 257486450)
    }

    func testPicksHighestWhenNoCurrentRelease() throws {
        let json = """
        {"releases":[{"version":"1.0.0","updateTo":{"version":"1.0.0","url":"https://x/a.zip"}},{"version":"1.2.0","updateTo":{"version":"1.2.0","url":"https://x/b.zip"}}]}
        """
        XCTAssertEqual(try UpdateFeed.parse(Data(json.utf8))?.version, AppVersion("1.2.0"))
    }

    func testParsesSingleReleaseFormat() throws {
        let json = #"{"url":"https://x/c.zip","name":"5.0.1"}"#
        XCTAssertEqual(try UpdateFeed.parse(Data(json.utf8))?.version, AppVersion("5.0.1"))
    }

    func testFeedURLMatchesClaudesFormat() {
        let feed = UpdateFeed(deviceID: "dev")
        let url = feed.feedURL(base: URL(string: "https://api.anthropic.com")!, arch: "arm64", currentVersion: "4.1.0", osVersion: "27.0.1")
        XCTAssertEqual(url.absoluteString,
                       "https://api.anthropic.com/api/desktop/darwin/arm64/squirrel/update?device_id=dev&version=4.1.0&os_version=27.0.1")
    }
}

final class UpdateLogicTests: XCTestCase {
    func install(_ v: String, modified: Date = Date(timeIntervalSince1970: 1000)) -> ClaudeInstallation {
        ClaudeInstallation(appURL: URL(fileURLWithPath: "/Applications/Claude.app"), version: AppVersion(v),
                           bundleIdentifier: ClaudeConstants.bundleIdentifier, infoPlistModified: modified)
    }

    func release(_ v: String) -> AvailableRelease {
        AvailableRelease(version: AppVersion(v)!, name: nil, downloadURL: URL(string: "https://x/y.zip")!, sha256: nil, size: nil, publishedAt: nil, notes: nil)
    }

    func instance(_ pid: Int32, _ profile: String?, version: String?, start: TimeInterval = 2000, before: Bool = false) -> RunningInstance {
        RunningInstance(pid: pid, profileID: profile, userDataDirectory: nil, startTime: Date(timeIntervalSince1970: start),
                        launchedVersion: version.flatMap(AppVersion.init), startedBeforeCurrentBundle: before)
    }

    func testStatus() {
        XCTAssertEqual(UpdateLogic.status(installed: nil, latest: nil, checked: true), .claudeMissing)
        XCTAssertEqual(UpdateLogic.status(installed: install("1.0"), latest: nil, checked: false), .unknown)
        XCTAssertEqual(UpdateLogic.status(installed: install("1.0"), latest: release("1.0"), checked: true), .upToDate(AppVersion("1.0")!))
        XCTAssertEqual(UpdateLogic.status(installed: install("2.0"), latest: release("1.5"), checked: true), .upToDate(AppVersion("2.0")!))
        XCTAssertEqual(UpdateLogic.status(installed: install("1.0"), latest: release("1.1"), checked: true),
                       .available(installed: AppVersion("1.0")!, latest: release("1.1")))
    }

    func testOutdatedInstances() {
        let list = [instance(1, "a", version: "1.0"), instance(2, "b", version: "1.1"),
                    instance(3, "c", version: nil, before: true), instance(4, "d", version: nil, before: false)]
        XCTAssertEqual(UpdateLogic.outdatedInstances(list, installedVersion: AppVersion("1.1")).map(\.pid), [1, 3])
        XCTAssertEqual(UpdateLogic.outdatedInstances(list, installedVersion: nil), [])
    }

    func testProfilesToRelaunchIsExactlyWhatWasRunningInOrder() {
        let list = [instance(9, "b", version: "1", start: 30), instance(5, "a", version: "1", start: 10),
                    instance(7, nil, version: "1", start: 20), instance(8, "a", version: "1", start: 40)]
        XCTAssertEqual(UpdateLogic.profilesToRelaunch(before: list), ["a", "b"])
        XCTAssertEqual(UpdateLogic.profilesToRelaunch(before: []), [])
    }

    func testIdleInstances() {
        let now = Date(timeIntervalSince1970: 10_000)
        let list = [instance(1, "a", version: "1", start: 0), instance(2, "b", version: "1", start: 0), instance(3, "c", version: "1", start: 9_900)]
        let idle = UpdateLogic.idleInstances(list, frontmostPID: 2, lastActivated: [1: Date(timeIntervalSince1970: 1_000)], now: now, idleInterval: 600)
        XCTAssertEqual(idle.map(\.pid), [1])
    }

    func testNextCheckDate() {
        let now = Date(timeIntervalSince1970: 5000)
        XCTAssertNil(UpdateLogic.nextCheckDate(lastCheck: nil, interval: 0, now: now))
        XCTAssertEqual(UpdateLogic.nextCheckDate(lastCheck: nil, interval: 3600, now: now), now)
        XCTAssertEqual(UpdateLogic.nextCheckDate(lastCheck: Date(timeIntervalSince1970: 4000), interval: 3600, now: now), Date(timeIntervalSince1970: 7600))
        XCTAssertEqual(UpdateLogic.nextCheckDate(lastCheck: Date(timeIntervalSince1970: 0), interval: 60, now: now), now)
    }

    func testRuntimeTrackerRecoversVersionsAcrossRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cp-rt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(supportDirectory: root, defaultClaudeDataDirectory: root.appendingPathComponent("d"))
        let bundleTime = Date(timeIntervalSince1970: 1000)
        let old = ClaudeProcess(pid: 100, executablePath: "/x", arguments: ["/x"], startTime: Date(timeIntervalSince1970: 500))
        let new = ClaudeProcess(pid: 101, executablePath: "/x", arguments: ["/x", "--user-data-dir=/p/w"], startTime: Date(timeIntervalSince1970: 1500))

        let t1 = RuntimeTracker(paths: paths)
        t1.recordLaunch(pid: 101, startTime: new.startTime, version: AppVersion("1.0"), profileID: "w")
        let r1 = t1.reconcile(processes: [old, new], resolveProfile: { $0 == nil ? "default" : "w" }, installation: install("1.1", modified: bundleTime))
        XCTAssertEqual(r1.map(\.pid), [100, 101])
        XCTAssertNil(r1[0].launchedVersion)                 // started before the bundle: unknown/older
        XCTAssertTrue(r1[0].startedBeforeCurrentBundle)
        XCTAssertEqual(r1[1].launchedVersion, AppVersion("1.0"))

        // A fresh tracker (manager restarted) reads runtime.json and keeps the recorded version.
        let t2 = RuntimeTracker(paths: paths)
        let r2 = t2.reconcile(processes: [new], resolveProfile: { _ in "w" }, installation: install("1.1", modified: bundleTime))
        XCTAssertEqual(r2.first?.launchedVersion, AppVersion("1.0"))
        XCTAssertEqual(UpdateLogic.outdatedInstances(r2, installedVersion: AppVersion("1.1")).count, 1)

        // Recycled PID with a different start time: stale record discarded.
        let recycled = ClaudeProcess(pid: 101, executablePath: "/x", arguments: ["/x"], startTime: Date(timeIntervalSince1970: 3000))
        let r3 = RuntimeTracker(paths: paths).reconcile(processes: [recycled], resolveProfile: { _ in "default" }, installation: install("1.1", modified: bundleTime))
        XCTAssertEqual(r3.first?.launchedVersion, AppVersion("1.1"))
    }
}

final class RoutingTests: XCTestCase {
    func c(_ pid: Int32, _ profile: String?, activated: TimeInterval?, start: TimeInterval) -> URLRoutingPolicy.Candidate {
        .init(pid: pid, profileID: profile, lastActivated: activated.map { Date(timeIntervalSince1970: $0) }, startTime: Date(timeIntervalSince1970: start))
    }

    func testSigningInProfileWins() {
        let list = [c(1, "default", activated: 100, start: 1), c(2, "work", activated: nil, start: 2)]
        XCTAssertEqual(URLRoutingPolicy.decide(signingInProfileID: "work", candidates: list), .forward(2))
    }

    func testMostRecentlyActivatedOtherwise() {
        let list = [c(1, "default", activated: 100, start: 1), c(2, "work", activated: 200, start: 2), c(3, "x", activated: nil, start: 150)]
        XCTAssertEqual(URLRoutingPolicy.decide(signingInProfileID: nil, candidates: list), .forward(2))
        // Signing-in profile not running -> fall back to most recent.
        XCTAssertEqual(URLRoutingPolicy.decide(signingInProfileID: "gone", candidates: list), .forward(2))
    }

    func testLaunchWhenNothingRuns() {
        XCTAssertEqual(URLRoutingPolicy.decide(signingInProfileID: nil, candidates: []), .launch(profileID: "default"))
        XCTAssertEqual(URLRoutingPolicy.decide(signingInProfileID: "work", candidates: []), .launch(profileID: "work"))
    }
}

final class ProcessArgsTests: XCTestCase {
    func testUserDataDirParsing() {
        XCTAssertNil(ClaudeProcess.userDataDirectory(from: ["/Applications/Claude.app/Contents/MacOS/Claude"]))
        XCTAssertEqual(ClaudeProcess.userDataDirectory(from: ["c", "--user-data-dir=/a b/c"]), "/a b/c")
        XCTAssertEqual(ClaudeProcess.userDataDirectory(from: ["c", "--user-data-dir", "/x"]), "/x")
    }

    func testProcArgs2Parsing() {
        var bytes: [UInt8] = [2, 0, 0, 0]
        bytes += Array("/exec/path".utf8) + [0, 0, 0]
        bytes += Array("/exec/path".utf8) + [0] + Array("--user-data-dir=/p q".utf8) + [0]
        bytes += Array("HOME=/x".utf8) + [0]
        XCTAssertEqual(ProcessScanner.parseProcArgs2(bytes), ["/exec/path", "--user-data-dir=/p q"])
    }

    func testScannerFindsItself() {
        let me = ProcessInfo.processInfo.processIdentifier
        let path = ProcessScanner.executablePath(of: me)
        XCTAssertNotNil(path)
        let found = ProcessScanner.claudeMainProcesses(executablePath: path!)
        XCTAssertTrue(found.contains { $0.pid == me })
    }
}
