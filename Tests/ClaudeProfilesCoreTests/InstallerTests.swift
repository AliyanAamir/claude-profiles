import XCTest
@testable import ClaudeProfilesCore

/// Fake verifier: a bundle is "valid" when Contents/Info.plist exists and it has no BROKEN marker.
struct FakeVerifier: BundleVerifying {
    func verify(appAt url: URL) throws -> VerifiedBundle {
        guard let inst = ClaudeInstallation.read(at: url) else { throw VerificationError.notABundle(url.path) }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/BROKEN").path) {
            throw VerificationError.signatureInvalid("broken marker")
        }
        if inst.bundleIdentifier != ClaudeConstants.bundleIdentifier { throw VerificationError.wrongBundleIdentifier(inst.bundleIdentifier) }
        return VerifiedBundle(bundleIdentifier: inst.bundleIdentifier!, version: inst.version, teamIdentifier: ClaudeConstants.teamIdentifier)
    }
}

final class InstallerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cp-inst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func makeApp(at url: URL, version: String, bundleID: String = ClaudeConstants.bundleIdentifier, broken: Bool = false) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleIdentifier": bundleID]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try "bin-\(version)".write(to: contents.appendingPathComponent("MacOS/Claude"), atomically: true, encoding: .utf8)
        if broken { try "x".write(to: contents.appendingPathComponent("BROKEN"), atomically: true, encoding: .utf8) }
    }

    func testSuccessfulSwapReplacesAndRemovesBackup() throws {
        let target = root.appendingPathComponent("Claude.app")
        let staged = root.appendingPathComponent("stage/Claude.app")
        try makeApp(at: target, version: "1.0")
        try makeApp(at: staged, version: "1.1")
        let installer = UpdateInstaller(verifier: FakeVerifier(), workDirectory: root.appendingPathComponent("work"))
        let v = try installer.install(staged: staged, over: target, expectedVersion: AppVersion("1.1"))
        XCTAssertEqual(v.version, AppVersion("1.1"))
        XCTAssertEqual(ClaudeInstallation.read(at: target)?.version, AppVersion("1.1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Claude.app.claude-profiles-backup").path))
    }

    func testRejectsBadStagedBundleWithoutTouchingTarget() throws {
        let target = root.appendingPathComponent("Claude.app")
        try makeApp(at: target, version: "1.0")
        let installer = UpdateInstaller(verifier: FakeVerifier(), workDirectory: root)

        let broken = root.appendingPathComponent("b/Claude.app")
        try makeApp(at: broken, version: "1.1", broken: true)
        XCTAssertThrowsError(try installer.install(staged: broken, over: target, expectedVersion: AppVersion("1.1")))

        let wrongVersion = root.appendingPathComponent("v/Claude.app")
        try makeApp(at: wrongVersion, version: "1.2")
        XCTAssertThrowsError(try installer.install(staged: wrongVersion, over: target, expectedVersion: AppVersion("1.1")))

        let impostor = root.appendingPathComponent("i/Claude.app")
        try makeApp(at: impostor, version: "1.1", bundleID: "com.example.fake")
        XCTAssertThrowsError(try installer.install(staged: impostor, over: target, expectedVersion: AppVersion("1.1")))

        XCTAssertEqual(ClaudeInstallation.read(at: target)?.version, AppVersion("1.0"))
    }

    func testRollsBackWhenPostSwapVerificationFails() throws {
        let target = root.appendingPathComponent("Claude.app")
        let staged = root.appendingPathComponent("stage/Claude.app")
        try makeApp(at: target, version: "1.0")
        try makeApp(at: staged, version: "1.1")
        let originalInode = try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? Int
        let installer = UpdateInstaller(verifier: FakeVerifier(), workDirectory: root)
        installer.afterSwapHook = { app in
            try "x".write(to: app.appendingPathComponent("Contents/BROKEN"), atomically: true, encoding: .utf8)
        }
        XCTAssertThrowsError(try installer.install(staged: staged, over: target, expectedVersion: AppVersion("1.1"))) { error in
            guard case InstallerError.rolledBack = error else { return XCTFail("expected rollback, got \(error)") }
        }
        XCTAssertEqual(ClaudeInstallation.read(at: target)?.version, AppVersion("1.0"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? Int, originalInode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Claude.app.claude-profiles-backup").path))
    }

    func testChecksum() throws {
        let f = root.appendingPathComponent("a.bin")
        try Data("hello".utf8).write(to: f)
        let installer = UpdateInstaller(verifier: FakeVerifier(), workDirectory: root)
        XCTAssertNoThrow(try installer.verifyChecksum(of: f, expected: "2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824"))
        XCTAssertThrowsError(try installer.verifyChecksum(of: f, expected: "00"))
        XCTAssertNoThrow(try installer.verifyChecksum(of: f, expected: nil))
    }

    func testExtractFindsApp() throws {
        let app = root.appendingPathComponent("src/Claude.app")
        try makeApp(at: app, version: "3.0")
        let zip = root.appendingPathComponent("c.zip")
        XCTAssertEqual(try Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path]).status, 0)
        let installer = UpdateInstaller(verifier: FakeVerifier(), workDirectory: root.appendingPathComponent("w"))
        let out = try installer.extract(zip)
        XCTAssertEqual(out.lastPathComponent, "Claude.app")
        XCTAssertEqual(try installer.verify(app: out, expectedVersion: AppVersion("3.0")).version, AppVersion("3.0"))
    }

    func testRealVerifierRejectsUnsignedBundle() throws {
        let app = root.appendingPathComponent("Fake.app")
        try makeApp(at: app, version: "1.0")
        XCTAssertThrowsError(try ClaudeSignatureVerifier().verify(appAt: app))
    }

    func testRealVerifierAcceptsInstalledClaudeIfPresent() throws {
        let claude = ClaudeConstants.defaultAppURL
        try XCTSkipUnless(FileManager.default.fileExists(atPath: claude.path), "Claude.app not installed")
        let v = try ClaudeSignatureVerifier().verify(appAt: claude)
        XCTAssertEqual(v.teamIdentifier, "Q6L2SF6YDW")
    }
}
