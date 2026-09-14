import XCTest
@testable import YTerm

final class HostResourcesTests: XCTestCase {
    func testParse() {
        let text = """
        uptime\t 14:02:11 up 12 days,  3:40,  2 users,  load average: 1.52, 1.10, 0.98
        nproc\t8
        loadavg\t1.52 1.10 0.98
        mem\t16384000 4096000
        df\t/dev/sda1 100000000 60000000 40000000 60% /
        gpu\t0, NVIDIA A100, 87, 20480, 40960, 61
        gpu\t1, NVIDIA A100, 0, 0, 40960, 30
        ps\t1234 alice 95.0 12.5 python
        ps\t99 root 0.5 0.1 sshd: some thing
        """
        let r = HostResources.parse(text, diskPath: "/home/alice")
        XCTAssertEqual(r.cpuCount, 8)
        XCTAssertEqual(r.load, [1.52, 1.10, 0.98])
        XCTAssertEqual(r.cpuFraction!, 1.52 / 8, accuracy: 0.0001)
        XCTAssertEqual(r.memoryUsedFraction!, 0.75, accuracy: 0.0001)
        XCTAssertEqual(r.diskUsedFraction!, 0.6, accuracy: 0.0001)
        XCTAssertEqual(r.diskMount, "/")
        XCTAssertEqual(r.gpus.count, 2)
        XCTAssertEqual(r.gpus[0].utilization, 87)
        XCTAssertEqual(r.gpus[1].name, "NVIDIA A100")
        XCTAssertEqual(r.topProcesses.map(\.pid), [1234, 99])
        XCTAssertEqual(r.topProcesses[1].command, "sshd: some thing")
    }

    func testScriptRunsLocally() async throws {
        let result = try await ShellRunner.run("/bin/sh", ["-c", HostResources.script(diskPath: NSHomeDirectory())])
        XCTAssertEqual(result.exitCode, 0, result.stderrText)
        let r = HostResources.parse(result.stdoutText, diskPath: NSHomeDirectory())
        XCTAssertGreaterThan(r.cpuCount, 0)
        XCTAssertEqual(r.load.count, 3)
        XCTAssertGreaterThan(r.diskTotalKB, 0)
        XCTAssertFalse(r.topProcesses.isEmpty)
    }
}

final class SyncRuleTests: XCTestCase {
    func testValidationAndRoundTrip() throws {
        var rule = SyncRule()
        XCTAssertFalse(rule.isValid)
        rule.localPath = "/Users/me/project"
        rule.profileID = UUID()
        rule.remotePath = "/"
        XCTAssertFalse(rule.isValid, "root must not be a sync target")
        rule.remotePath = "/home/me/project"
        XCTAssertTrue(rule.isValid)
        XCTAssertEqual(rule.displayName, "project")
        let data = try JSONEncoder().encode([rule])
        XCTAssertEqual(try JSONDecoder().decode([SyncRule].self, from: data), [rule])
    }

    @MainActor
    func testManagerPersistsRules() {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yterm-syncs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let manager = SyncManager(fileURL: file)
        var rule = SyncRule()
        rule.localPath = NSTemporaryDirectory()
        rule.profileID = UUID()
        rule.remotePath = "/tmp/x"
        rule.enabled = false
        manager.upsert(rule)
        XCTAssertEqual(SyncManager(fileURL: file).sessions.map(\.rule), [rule])
        manager.remove(rule.id)
        XCTAssertTrue(SyncManager(fileURL: file).sessions.isEmpty)
    }

    func testDirectoryWatcherSeesNestedChanges() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yterm-watch-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = LockedBox<[String]>([])
        let watcher = DirectoryWatcher(path: root.path) { paths in seen.mutate { $0 += paths } }
        watcher.start()
        try await Task.sleep(for: .milliseconds(300))
        try "x".write(to: root.appendingPathComponent("nested/file.txt"), atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(8)
        while seen.value.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        watcher.stop()
        XCTAssertTrue(seen.value.contains { $0.contains("nested") }, "\(seen.value)")
    }
}

final class BookmarkStoreTests: XCTestCase {
    @MainActor
    func testAddDedupeRecents() {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yterm-bookmarks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = BookmarkStore(fileURL: file)
        let host = UUID()
        store.add(name: "", kind: .remote, profileID: host, path: "/srv/data")
        store.add(name: "資料", kind: .remote, profileID: host, path: "/srv/data")
        store.add(name: "home", kind: .local, profileID: nil, path: "/Users/me")
        XCTAssertEqual(store.bookmarks.count, 2)
        XCTAssertEqual(store.bookmarks[0].name, "資料", "adding the same path again renames instead of duplicating")

        let pane = PaneModel(kind: .remote, title: "h", profileID: host)
        XCTAssertEqual(store.bookmarks(for: pane).map(\.path), ["/srv/data"])
        XCTAssertEqual(store.bookmarksElsewhere(for: pane).map(\.path), ["/Users/me"])

        let reloaded = BookmarkStore(fileURL: file)
        XCTAssertEqual(reloaded.bookmarks, store.bookmarks)
        store.remove(store.bookmarks[0].id)
        XCTAssertEqual(store.bookmarks.count, 1)
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}

final class SyncRuleCompatibilityTests: XCTestCase {
    func testRulesDecodeAcrossVersions() throws {
        let json = """
        [{"id":"6B29FC40-CA47-1067-B31D-00DD010662DA","name":"","localPath":"/Users/me/p","profileID":"6B29FC40-CA47-1067-B31D-00DD010662DB","remotePath":"/home/me/p","enabled":true,"mirror":false,"excludes":[]}]
        """
        let rules = try JSONDecoder().decode([SyncRule].self, from: Data(json.utf8))
        XCTAssertEqual(rules.count, 1)
        XCTAssertTrue(rules[0].enabled)
        let legacyPull = json.replacingOccurrences(of: "\"excludes\":[]", with: "\"excludes\":[],\"direction\":\"pull\",\"mirror\":true")
        let pull = try JSONDecoder().decode([SyncRule].self, from: Data(legacyPull.utf8))
        XCTAssertFalse(pull[0].enabled, "a rule saved as a pull rule must not start pushing")
        XCTAssertFalse(pull[0].mirror)
        let roundTrip = try JSONDecoder().decode(SyncRule.self, from: try JSONEncoder().encode(rules[0]))
        XCTAssertEqual(roundTrip, rules[0])
    }
}

final class PullPreviewParserTests: XCTestCase {
    func testParsesItemizedDryRun() {
        let text = """
        cd+++++++++\t4096\tnewdir/
        >f+++++++++\t120\tnewdir/fresh.txt
        >f.st......\t9\tchanged.txt
        .f...p.....\t9\tperms-only.txt
        .d..t......\t4096\t./
        *deleting  \t0\told.txt
        >f..t......\t5\ttime-only.txt
        """
        let changes = PullPreviewParser.parse(text)
        XCTAssertEqual(changes.map(\.kind), [.newDirectory, .added, .modified, .deleted, .modified])
        XCTAssertEqual(changes.map(\.relativePath), ["newdir", "newdir/fresh.txt", "changed.txt", "old.txt", "time-only.txt"])
        XCTAssertEqual(changes[1].size, 120)
        XCTAssertNil(changes[3].size)
        XCTAssertFalse(changes[3].isDownloadable)
    }

    func testToleratesLinesWithoutSizes() {
        let changes = PullPreviewParser.parse(">f+++++++++\tdocs/readme.md\n")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].relativePath, "docs/readme.md")
        XCTAssertNil(changes[0].size)
    }
}

final class PullPreviewParserProgressTests: XCTestCase {
    func testIgnoresCarriageReturnFragments() {
        let text = "receiving file list ... 5 files to consider\n 0 files...\r*deleting  \t0\told.txt\n                    \r>f+++++++++\t3\ta.txt\n"
        let changes = PullPreviewParser.parse(text)
        XCTAssertEqual(changes.map(\.relativePath), ["old.txt", "a.txt"])
    }
}
