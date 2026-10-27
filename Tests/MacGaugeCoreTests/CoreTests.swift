import XCTest
@testable import MacGaugeCore

final class CleanupTests: XCTestCase {
    var home: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacGaugeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        home = URL(fileURLWithPath: try XCTUnwrap(CleanupEngine.canonicalPath(home.path)))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    @discardableResult func file(_ relative: String, days: Int = 45) throws -> URL {
        let path = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test diagnostic output".utf8).write(to: path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(days) * 86400)], ofItemAtPath: path.path)
        return path
    }
    func candidates(open: Set<String> = []) throws -> [CleanupCandidate] {
        let scan = try CleanupEngine.scan(home: home, days: 30, knownOpenFiles: open)
        return scan.groups.flatMap(\.files)
    }
    func testOnlyOldLogsAndExplicitCachesAreSelected() throws {
        let old = try file("Library/Logs/app/old.log")
        let cache = try file(".dartServer/.analysis-driver/cache")
        try file("Library/Logs/app/recent.log", days: 2)
        try file("Library/Logs/app/source.swift")
        try file("Documents/source.log")
        try file("Library/Caches/JetBrains/IDE/LocalHistory/data")
        try file("Library/Caches/Google/Chrome/Default/Cookies")
        try file(".maestro/tests/old/flow.yaml")
        XCTAssertEqual(Set(try candidates().map(\.id)), Set([old.path, cache.path]))
    }
    func testConfirmedOldFileIsDeletedButChangedAndOpenFilesSurvive() throws {
        let clean = try file("Library/Logs/clean.log")
        let changed = try file("Library/Logs/changed.log")
        let open = try file("Library/Logs/open.log")
        let files = try candidates()
        try Data("new log contents, changed after scan".utf8).write(to: changed)
        let report = try CleanupEngine.delete(files, home: home, days: 30, knownOpenFiles: [open.path])
        XCTAssertEqual(report.deleted, [clean.path])
        XCTAssertEqual(report.skipped.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clean.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: changed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: open.path))
    }
    func testScannerDoesNotFollowSymlinks() throws {
        let outside = try file("outside/valuable.log")
        let logs = home.appendingPathComponent("Library/Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("linked"), withDestinationURL: outside.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("linked.log"), withDestinationURL: outside)
        XCTAssertTrue(try candidates().isEmpty)
    }
    func testParentDirectoryReplacedBySymlinkCannotRedirectDeletion() throws {
        let original = try file("Library/Logs/app/old.log")
        let files = try candidates()
        let outside = try file("outside/old.log")
        let parent = original.deletingLastPathComponent()
        try FileManager.default.moveItem(at: parent, to: home.appendingPathComponent("preserved"))
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside.deletingLastPathComponent())
        let report = try CleanupEngine.delete(files, home: home, knownOpenFiles: [])
        XCTAssertTrue(report.deleted.isEmpty)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("preserved/old.log").path))
    }
    func testOutOfScopeCandidateIsRejected() throws {
        let secret = try file("Documents/private.log")
        let candidate = CleanupCandidate(url: secret, ruleID: "logs", stamp: try FileStamp.read(secret.path))
        let report = try CleanupEngine.delete([candidate], home: home, knownOpenFiles: [])
        XCTAssertTrue(report.deleted.isEmpty)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))
    }
    func testOpenFilesExcludedDuringScan() throws {
        let open = try file("Library/Logs/open.log")
        XCTAssertTrue(try candidates(open: [open.path]).isEmpty)
    }
}

final class MetricsTests: XCTestCase {
    func testCPUUsesDeltasAndHandlesCounterWrap() {
        let old = CPUSample(user: 20, system: 10, idle: 70, nice: 0)
        let new = CPUSample(user: 40, system: 20, idle: 140, nice: 0)
        XCTAssertEqual(new.utilization(since: old), 0.3, accuracy: 0.001)
        let wrap = CPUSample(user: 1, system: 0, idle: 3, nice: 0)
        XCTAssertEqual(wrap.utilization(since: CPUSample(user: .max, system: 0, idle: 1, nice: 0)), 0.5, accuracy: 0.001)
    }
    func testChildProcessesAreAggregatedWithoutDoubleCounting() {
        let app = AppIdentity(pid: 100, name: "Browser", bundlePath: "/Applications/Browser.app")
        let old = [ProcessReading(pid: 100, parent: 1, cpuTime: 0, memory: 10, executable: "/Applications/Browser.app/main"), ProcessReading(pid: 101, parent: 100, cpuTime: 0, memory: 20, executable: "/helper")]
        let readings = [ProcessReading(pid: 100, parent: 1, cpuTime: 1_000_000_000, memory: 10, executable: "/Applications/Browser.app/main"), ProcessReading(pid: 101, parent: 100, cpuTime: 500_000_000, memory: 20, executable: "/helper")]
        let result = ProcessSampler.group(readings, previous: old, elapsed: 2, apps: [app])
        XCTAssertEqual(result[0].memory, 30)
        XCTAssertEqual(result[0].processCount, 2)
        XCTAssertEqual(result[0].cpu, 75, accuracy: 0.01)
    }
}
