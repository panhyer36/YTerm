import XCTest
@testable import YTerm

final class TwoWayPlannerTests: XCTestCase {
    private func file(_ size: Int64, _ mtime: Double) -> SyncItem { SyncItem(kind: .file, size: size, mtime: mtime) }
    private let dir = SyncItem(kind: .directory, size: 0, mtime: 0)

    /// Both sides identical and recorded, the way a finished sync leaves them.
    private func synced(_ tree: SyncTree, remoteShift: Double = 0) -> (SyncTree, SyncTree, SyncBaseline) {
        let remote = tree.mapValues { SyncItem(kind: $0.kind, size: $0.size, mtime: $0.mtime + remoteShift) }
        var baseline: SyncBaseline = [:]
        for (path, item) in tree { baseline[path] = SyncBaselineEntry(local: item, remote: remote[path]!) }
        return (tree, remote, baseline)
    }

    func testNewFilesGoToTheOtherSide() {
        let plan = TwoWayPlanner.plan(local: ["a.txt": file(1, 100)], remote: ["b.txt": file(2, 50)], baseline: [:])
        XCTAssertEqual(plan.push, ["a.txt"])
        XCTAssertEqual(plan.pull, ["b.txt"])
        XCTAssertTrue(plan.conflicts.isEmpty)
    }

    func testInSyncNeedsNothing() {
        let (local, remote, baseline) = synced(["src": dir, "src/a.txt": file(3, 100)], remoteShift: 0.4)
        XCTAssertTrue(TwoWayPlanner.plan(local: local, remote: remote, baseline: baseline).isEmpty)
        // Without a baseline the quick check still sees them as equal.
        XCTAssertTrue(TwoWayPlanner.plan(local: local, remote: remote, baseline: [:]).isEmpty)
    }

    func testTheChangedSideWinsEvenWhenTheOtherClockIsAhead() {
        // Remote clock runs 1 hour ahead, so the remote copy always *looks* newer.
        let (local, remote, baseline) = synced(["a.txt": file(3, 100)], remoteShift: 3600)
        var edited = local
        edited["a.txt"] = file(4, 200)
        let plan = TwoWayPlanner.plan(local: edited, remote: remote, baseline: baseline)
        XCTAssertEqual(plan.push, ["a.txt"])
        XCTAssertTrue(plan.pull.isEmpty)

        var remoteEdited = remote
        remoteEdited["a.txt"] = file(5, 4000)
        XCTAssertEqual(TwoWayPlanner.plan(local: local, remote: remoteEdited, baseline: baseline).pull, ["a.txt"])
    }

    func testBothChangedNewestWinsAndIsAConflict() {
        let (local, remote, baseline) = synced(["a.txt": file(3, 100), "b.txt": file(3, 100)])
        var l = local, r = remote
        l["a.txt"] = file(4, 300); r["a.txt"] = file(5, 200)
        l["b.txt"] = file(4, 200); r["b.txt"] = file(5, 300)
        let plan = TwoWayPlanner.plan(local: l, remote: r, baseline: baseline)
        XCTAssertEqual(plan.pushOverwriting, ["a.txt"])
        XCTAssertEqual(plan.pullOverwriting, ["b.txt"])
        XCTAssertEqual(plan.conflicts.map(\.localWon), [true, false])
    }

    func testDifferentFilesWithoutBaselineAreConflicts() {
        let plan = TwoWayPlanner.plan(local: ["a.txt": file(1, 100)], remote: ["a.txt": file(2, 500)], baseline: [:])
        XCTAssertEqual(plan.pullOverwriting, ["a.txt"])
        XCTAssertEqual(plan.conflicts.count, 1)
    }

    func testDeletionsPropagateUnlessTheOtherSideEdited() {
        let (local, remote, baseline) = synced(["a.txt": file(1, 100), "b.txt": file(1, 100), "c.txt": file(1, 100)])
        var l = local, r = remote
        l["a.txt"] = nil                 // deleted locally -> delete remote
        r["b.txt"] = nil                 // deleted remotely -> delete local
        l["c.txt"] = file(9, 900)        // edited locally ...
        r["c.txt"] = nil                 // ... but deleted remotely -> keep the edit
        let plan = TwoWayPlanner.plan(local: l, remote: r, baseline: baseline)
        XCTAssertEqual(plan.deleteRemote, ["a.txt"])
        XCTAssertEqual(plan.deleteLocal, ["b.txt"])
        XCTAssertEqual(plan.push, ["c.txt"])
    }

    func testDeletedFolderOnlyGoesWhenEverythingInsideGoes() {
        let tree: SyncTree = ["d": dir, "d/x.txt": file(1, 1), "d/sub": dir, "d/sub/y.txt": file(1, 1), "e": dir, "e/z.txt": file(1, 1)]
        let (local, remote, baseline) = synced(tree)
        var l = local
        // Whole of d deleted locally; e deleted locally while a new file appeared remotely in e.
        for path in ["d", "d/x.txt", "d/sub", "d/sub/y.txt", "e", "e/z.txt"] { l[path] = nil }
        var r = remote
        r["e/new.txt"] = file(2, 2)
        let plan = TwoWayPlanner.plan(local: l, remote: r, baseline: baseline)
        XCTAssertEqual(plan.deleteRemote, ["d", "e/z.txt"])
        XCTAssertEqual(plan.pull, ["e/new.txt"])
    }

    func testTypeMismatchIsSkipped() {
        let plan = TwoWayPlanner.plan(local: ["x": dir], remote: ["x": file(1, 1)], baseline: [:])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.skipped, ["x"])
    }

    func testNextBaselineRecordsOnlyStableTransfers() {
        let localBefore: SyncTree = ["a": file(1, 100), "b": file(1, 100)]
        let remoteBefore: SyncTree = [:]
        let plan = TwoWayPlanner.plan(local: localBefore, remote: remoteBefore, baseline: [:])
        var localAfter = localBefore
        localAfter["b"] = file(2, 150)   // edited while the upload ran
        // Remote times are not preserved exactly (e.g. openrsync): still a valid record for "a".
        let remoteAfter: SyncTree = ["a": file(1, 107), "b": file(1, 100)]
        let next = TwoWayPlanner.nextBaseline(
            plan: plan, localBefore: localBefore, remoteBefore: remoteBefore,
            localAfter: localAfter, remoteAfter: remoteAfter, previous: [:]
        )
        XCTAssertEqual(Set(next.keys), ["a"])
        // The recorded pair stays quiet on the next pass even though the times differ by 7s.
        XCTAssertTrue(TwoWayPlanner.plan(local: ["a": file(1, 100)], remote: ["a": file(1, 107)], baseline: next).isEmpty)
        // "b" is out of sync and comes back as a push.
        XCTAssertEqual(TwoWayPlanner.plan(local: localAfter, remote: remoteAfter, baseline: next).pushOverwriting, ["b"])
    }
}

final class SyncExcludesTests: XCTestCase {
    func testRsyncLikeMatching() {
        let excludes = SyncExcludes([".git", "*.pyc", "build/", "/top.log", "docs/*.tmp"])
        XCTAssertTrue(excludes.excludes(".git", isDirectory: true))
        XCTAssertTrue(excludes.excludes("pkg/x.pyc", isDirectory: false))
        XCTAssertTrue(excludes.excludes("a/build", isDirectory: true))
        XCTAssertFalse(excludes.excludes("a/build", isDirectory: false))
        XCTAssertTrue(excludes.excludes("top.log", isDirectory: false))
        XCTAssertFalse(excludes.excludes("sub/top.log", isDirectory: false))
        XCTAssertTrue(excludes.excludes("x/docs/a.tmp", isDirectory: false))
        XCTAssertFalse(excludes.excludes("docs/deep/a.tmp", isDirectory: false))

        let filtered = excludes.filter([".git": SyncItem(kind: .directory, size: 0, mtime: 0), ".git/HEAD": SyncItem(kind: .file, size: 1, mtime: 0), "ok": SyncItem(kind: .file, size: 1, mtime: 0)])
        XCTAssertEqual(Array(filtered.keys), ["ok"])
        XCTAssertEqual(excludes.inotifyRegex, "(^|/)(\\.git|[^/]*\\.pyc|build)(/|$)")
    }
}

final class SyncListingTests: XCTestCase {
    private func makeTree() throws -> String {
        let root = NSTemporaryDirectory() + "yterm-2way-\(UUID().uuidString.prefix(6))"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/sub dir/deep", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/node_modules/pkg", withIntermediateDirectories: true)
        try "hello".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        try "x".write(toFile: root + "/sub dir/it's.txt", atomically: true, encoding: .utf8)
        try "y".write(toFile: root + "/node_modules/pkg/i.js", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: root + "/link", withDestinationPath: "sub dir")
        return root
    }

    func testLocalListing() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let tree = try SyncListing.local(root: root, excludes: SyncExcludes(["node_modules"]))
        XCTAssertEqual(Set(tree.keys), ["a.txt", "sub dir", "sub dir/deep", "sub dir/it's.txt", "link"])
        XCTAssertEqual(tree["a.txt"]?.size, 5)
        XCTAssertEqual(tree["link"]?.kind, .symlink)
        XCTAssertEqual(tree["sub dir"]?.kind, .directory)
        XCTAssertThrowsError(try SyncListing.local(root: root + "/missing", excludes: SyncExcludes([])))
    }

    /// The remote script runs here too (BSD find on macOS) and must agree with the local walker.
    func testRemoteScriptMatchesLocalListing() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let excludes = SyncExcludes(["node_modules"])
        let result = try await ShellRunner.run("/bin/sh", ["-c", SyncListing.remoteScript(root: root, excludes: excludes)])
        XCTAssertEqual(result.exitCode, 0, result.stderrText)
        let parsed = SyncListing.parseRemote(result.stdout)
        let local = try SyncListing.local(root: root, excludes: excludes)
        XCTAssertEqual(Set(parsed.tree.keys), Set(local.keys))
        for (path, item) in local {
            XCTAssertTrue(parsed.tree[path]!.matches(item), path)
        }
        let poll = try await ShellRunner.run("/bin/sh", ["-c", SyncListing.pollScript(root: root, excludes: excludes)])
        XCTAssertEqual(SyncListing.parsePoll(poll.stdoutText).fingerprint, parsed.fingerprint)

        let missing = try await ShellRunner.run("/bin/sh", ["-c", SyncListing.remoteScript(root: root + "/nope", excludes: excludes)])
        XCTAssertEqual(missing.exitCode, 3)
    }

    func testParsesGNUListing() {
        let data = Data("G\tf\t5\t1700000000.250000000\ta b.txt\0G\td\t4096\t1700000000.0\tsub\0G\tl\t3\t1.0\tlink\0G\tp\t0\t1.0\tfifo\0S\t123 45\0".utf8)
        let parsed = SyncListing.parseRemote(data)
        XCTAssertEqual(parsed.tree["a b.txt"], SyncItem(kind: .file, size: 5, mtime: 1_700_000_000.25))
        XCTAssertEqual(parsed.tree["sub"]?.size, 0)
        XCTAssertEqual(parsed.tree["link"]?.kind, .symlink)
        XCTAssertNil(parsed.tree["fifo"])
        XCTAssertEqual(parsed.fingerprint, "123 45")
    }
}

final class InotifySupportTests: XCTestCase {
    func testPackageManagerAndScripts() {
        var info = RemoteInfo()
        info.osName = "Linux"
        info.tools = ["apt-get", "sudo", "yum"]
        XCTAssertEqual(InotifySupport.packageManager(for: info), "apt-get")
        info.osName = "Darwin"
        XCTAssertNil(InotifySupport.packageManager(for: info))
        XCTAssertNil(InotifySupport.installScript(packageManager: "brew"))
        let script = InotifySupport.installScript(packageManager: "apt-get")!
        XCTAssertTrue(script.contains("apt-get install -y inotify-tools"))
        XCTAssertFalse(script.contains("$1"))
        let watch = InotifySupport.watchScript(root: "/home/u/my project", excludes: SyncExcludes([".git"]))
        XCTAssertTrue(watch.contains("cd -- '/home/u/my project'"))
        XCTAssertTrue(watch.contains("--exclude '(^|/)(\\.git)(/|$)'"))
    }

    func testInstallScriptAsksForPasswordWithoutOne() async throws {
        // Run locally with fake sudo/apt-get to check the exit codes the app relies on.
        let bin = NSTemporaryDirectory() + "yterm-fake-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: bin) }
        let sudo = """
        #!/bin/sh
        # Needs the password "pw" (read from stdin with -S); -n always fails; "out" is not a sudoer.
        case "$1" in -n) exit 1;; esac
        IFS= read -r p
        [ "$p" = out ] && { echo "Sorry, user out may not run sudo on box." >&2; exit 1; }
        [ "$p" = pw ] || { echo "Sorry, try again." >&2; exit 1; }
        shift 3; [ "$1" = -v ] && exit 0; exec "$@"
        """
        let id = "#!/bin/sh\ncase \"$1\" in -u) echo 501;; -Gn) echo \"$FAKE_GROUPS\";; esac\n"
        let apt = "#!/bin/sh\nprintf '#!/bin/sh\\n' > \"\(bin)/inotifywait\"; chmod +x \"\(bin)/inotifywait\"\n"
        try sudo.write(toFile: bin + "/sudo", atomically: true, encoding: .utf8)
        try id.write(toFile: bin + "/id", atomically: true, encoding: .utf8)
        try apt.write(toFile: bin + "/apt-get", atomically: true, encoding: .utf8)
        for name in ["sudo", "id", "apt-get"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/" + name)
        }
        let script = InotifySupport.installScript(packageManager: "apt-get")!
        var env = LocalEnvironment.base
        env["PATH"] = bin + ":/usr/bin:/bin"
        func run(_ input: String, groups: String = "staff sudo") async throws -> Int32 {
            env["FAKE_GROUPS"] = groups
            return try await ShellRunner.run("/bin/sh", ["-c", script], options: .init(environment: env, stdin: Data(input.utf8))).exitCode
        }
        let noPassword = try await run("\n")
        XCTAssertEqual(noPassword, InotifySupport.InstallExit.needsPassword.rawValue)
        let notAdmin = try await run("\n", groups: "staff users")
        XCTAssertEqual(notAdmin, InotifySupport.InstallExit.needsPasswordNotAdmin.rawValue)
        let wrong = try await run("nope\n")
        XCTAssertEqual(wrong, InotifySupport.InstallExit.wrongPassword.rawValue)
        let notSudoer = try await run("out\n")
        XCTAssertEqual(notSudoer, InotifySupport.InstallExit.notSudoer.rawValue)
        let right = try await run("pw\n")
        XCTAssertEqual(right, 0)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bin + "/inotifywait"))
    }
}

final class SyncRuleModeTests: XCTestCase {
    func testOldRulesDecodeAsPush() throws {
        let json = """
        {"id":"6B29FC40-CA47-1067-B31D-00DD010662DA","localPath":"/Users/me/p","profileID":"6B29FC40-CA47-1067-B31D-00DD010662DB","remotePath":"/home/me/p","enabled":true}
        """
        let rule = try JSONDecoder().decode(SyncRule.self, from: Data(json.utf8))
        XCTAssertEqual(rule.mode, .push)
        XCTAssertEqual(rule.pollSeconds, 10)
        var twoWay = rule
        twoWay.mode = .twoWay
        XCTAssertNotEqual(twoWay.syncIdentity, rule.syncIdentity)
        XCTAssertEqual(try JSONDecoder().decode(SyncRule.self, from: try JSONEncoder().encode(twoWay)), twoWay)
    }
}
