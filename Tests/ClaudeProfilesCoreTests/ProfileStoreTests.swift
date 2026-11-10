import XCTest
@testable import ClaudeProfilesCore

final class ProfileStoreTests: XCTestCase {
    var root: URL!
    var paths: AppPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fakeDefault = root.appendingPathComponent("FakeClaudeDefault")
        try FileManager.default.createDirectory(at: fakeDefault, withIntermediateDirectories: true)
        try "keep".write(to: fakeDefault.appendingPathComponent("sentinel"), atomically: true, encoding: .utf8)
        paths = AppPaths(supportDirectory: root.appendingPathComponent("Support"), defaultClaudeDataDirectory: fakeDefault)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFirstLoadCreatesDefaultProfile() throws {
        let store = ProfileStore(paths: paths)
        let profiles = try store.load()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertTrue(profiles[0].isDefault)
        XCTAssertEqual(profiles[0].name, "Default")
        XCTAssertEqual(profiles[0].dataDirectory, paths.defaultClaudeDataDirectory.path)
        XCTAssertEqual(profiles[0].launchArguments, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.profilesFile.path))
    }

    func testCreatePersistsAndCreatesDataDir() throws {
        let store = ProfileStore(paths: paths)
        try store.load()
        let p = try store.create(name: "  Work  ", color: .blue, emoji: "💼")
        XCTAssertEqual(p.name, "Work")
        XCTAssertEqual(p.emoji, "💼")
        XCTAssertTrue(p.dataDirectory.hasPrefix(paths.profilesDataRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.dataDirectory))
        XCTAssertEqual(p.launchArguments, ["--user-data-dir=\(p.dataDirectory)"])

        let reloaded = ProfileStore(paths: paths)
        try reloaded.load()
        XCTAssertEqual(reloaded.profiles.map(\.name), ["Default", "Work"])
        XCTAssertEqual(reloaded.profile(id: p.id)?.color, .blue)
    }

    func testRejectsEmptyName() throws {
        let store = ProfileStore(paths: paths)
        try store.load()
        XCTAssertThrowsError(try store.create(name: "   ")) { XCTAssertEqual($0 as? ProfileStoreError, .invalidName) }
    }

    func testRenameRecolorEmoji() throws {
        let store = ProfileStore(paths: paths)
        try store.load()
        let p = try store.create(name: "A")
        try store.rename(id: p.id, to: "Personal")
        try store.setColor(id: p.id, color: .green)
        try store.setEmoji(id: p.id, emoji: " ")
        let r = ProfileStore(paths: paths); try r.load()
        XCTAssertEqual(r.profile(id: p.id)?.name, "Personal")
        XCTAssertEqual(r.profile(id: p.id)?.color, .green)
        XCTAssertNil(r.profile(id: p.id)?.emoji)
        XCTAssertEqual(r.profile(id: p.id)?.initials, "PE")
    }

    func testDuplicateAsEmptyMakesNewDirAndUniqueName() throws {
        let store = ProfileStore(paths: paths)
        try store.load()
        let p = try store.create(name: "Work", color: .purple)
        try "secret".write(to: URL(fileURLWithPath: p.dataDirectory).appendingPathComponent("Cookies"), atomically: true, encoding: .utf8)
        let d1 = try store.duplicateAsEmpty(id: p.id)
        let d2 = try store.duplicateAsEmpty(id: p.id)
        XCTAssertEqual(d1.name, "Work Copy")
        XCTAssertEqual(d2.name, "Work Copy 2")
        XCTAssertEqual(d1.color, .purple)
        XCTAssertNotEqual(d1.dataDirectory, p.dataDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: d1.dataDirectory), [])
    }

    func testDeleteRules() throws {
        let store = ProfileStore(paths: paths)
        try store.load()
        XCTAssertThrowsError(try store.delete(id: Profile.defaultProfileID, isRunning: false)) {
            XCTAssertEqual($0 as? ProfileStoreError, .cannotDeleteDefault)
        }
        let p = try store.create(name: "Temp")
        XCTAssertThrowsError(try store.delete(id: p.id, isRunning: true)) {
            XCTAssertEqual($0 as? ProfileStoreError, .profileIsRunning("Temp"))
        }
        let trashed = try store.delete(id: p.id, isRunning: false)
        XCTAssertNil(store.profile(id: p.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.dataDirectory))
        if let trashed { try? FileManager.default.removeItem(at: trashed) }
        // The default data dir is never touched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.defaultClaudeDataDirectory.appendingPathComponent("sentinel").path))
    }

    func testDeleteRefusesDataDirOutsideStore() throws {
        let store = ProfileStore(paths: paths)
        try store.load()
        let p = try store.create(name: "Evil")
        // Simulate a hand-edited profiles.json pointing at Claude's default folder.
        var file = try ProfileStore.decoder.decode(ProfilesFile.self, from: Data(contentsOf: paths.profilesFile))
        file.profiles[1].dataDirectory = paths.defaultClaudeDataDirectory.path
        try ProfileStore.encoder.encode(file).write(to: paths.profilesFile)
        try store.load()
        XCTAssertThrowsError(try store.delete(id: p.id, isRunning: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.defaultClaudeDataDirectory.appendingPathComponent("sentinel").path))
    }

    func testDefaultIsRestoredAndFirstAfterTampering() throws {
        try FileManager.default.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        let json = """
        {"version":1,"profiles":[{"id":"abc","name":"X","color":"teal","dataDirectory":"/tmp/x","createdAt":"2026-01-01T00:00:00Z"}]}
        """
        try json.write(to: paths.profilesFile, atomically: true, encoding: .utf8)
        let store = ProfileStore(paths: paths)
        try store.load()
        XCTAssertEqual(store.profiles.map(\.id), ["default", "abc"])
    }

    func testResolveByUserDataDir() throws {
        let store = ProfileStore(paths: paths)
        try store.load()
        let p = try store.create(name: "Work")
        XCTAssertEqual(store.profile(forUserDataDirectory: nil)?.id, "default")
        XCTAssertEqual(store.profile(forUserDataDirectory: p.dataDirectory + "/")?.id, p.id)
        XCTAssertNil(store.profile(forUserDataDirectory: "/nowhere"))
    }

    func testMoveKeepsDefaultFirst() throws {
        let store = ProfileStore(paths: paths)
        try store.load()
        let a = try store.create(name: "A")
        let b = try store.create(name: "B")
        try store.move(fromOffsets: IndexSet(integer: 2), toOffset: 1)
        XCTAssertEqual(store.profiles.map(\.id), ["default", b.id, a.id])
        try store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(store.profiles.first?.id, "default")
    }

    func testColorsCycleWithoutRepeatsFirst() throws {
        let store = ProfileStore(paths: paths)
        try store.load()
        var colors: [ProfileColor] = [store.profiles[0].color]
        for i in 0..<5 { colors.append(try store.create(name: "P\(i)").color) }
        XCTAssertEqual(Set(colors).count, colors.count)
    }
}
