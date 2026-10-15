import XCTest
@testable import YTerm

/// End-to-end checks against a disposable sshd (see scripts/test-server). Skipped unless
/// YTERM_IT_HOST is set, e.g.:
///   YTERM_IT_HOST=127.0.0.1 YTERM_IT_PORT=2223 YTERM_IT_USER=tester YTERM_IT_PASSWORD=testpass \
///   YTERM_IT_IDENTITY=/path/key YTERM_IT_KNOWN_HOSTS=/path/known_hosts swift test --filter RemoteIntegrationTests
final class RemoteIntegrationTests: XCTestCase {
    struct TestEnvironment {
        var host: String
        var port: Int?
        var user: String
        var password: String?
        var identity: String?
        var knownHosts: String?

        static var current: TestEnvironment? {
            let env = ProcessInfo.processInfo.environment
            guard let host = env["YTERM_IT_HOST"], let user = env["YTERM_IT_USER"] else { return nil }
            return TestEnvironment(
                host: host,
                port: env["YTERM_IT_PORT"].flatMap { Int($0) },
                user: user,
                password: env["YTERM_IT_PASSWORD"],
                identity: env["YTERM_IT_IDENTITY"],
                knownHosts: env["YTERM_IT_KNOWN_HOSTS"]
            )
        }

        func profile(usePassword: Bool) -> HostProfile {
            var profile = HostProfile()
            profile.name = "integration"
            profile.host = host
            profile.user = user
            profile.port = port
            var extra: [String] = []
            if let knownHosts { extra.append("-o UserKnownHostsFile=\(knownHosts)") }
            if usePassword {
                extra.append("-o PubkeyAuthentication=no")
            } else if let identity {
                profile.identityFile = identity
            }
            profile.extraOptions = extra.joined(separator: " ")
            return profile
        }
    }

    private func requireEnvironment() throws -> TestEnvironment {
        guard let env = TestEnvironment.current else {
            throw XCTSkip("YTERM_IT_HOST not set; skipping integration tests")
        }
        return env
    }

    @MainActor
    func testPasswordAuthenticationViaAskpass() async throws {
        let env = try requireEnvironment()
        guard let password = env.password else { throw XCTSkip("YTERM_IT_PASSWORD not set") }
        let connection = RemoteConnection(profile: env.profile(usePassword: true), password: password, log: CommandLog())
        let info = try await connection.bootstrap()
        XCTAssertEqual(info.userName, env.user)
        XCTAssertTrue(info.home.hasPrefix("/"))
        await connection.disconnect()
    }

    @MainActor
    func testWrongPasswordIsReportedAsAuthenticationFailure() async throws {
        let env = try requireEnvironment()
        guard env.password != nil else { throw XCTSkip("YTERM_IT_PASSWORD not set") }
        let connection = RemoteConnection(profile: env.profile(usePassword: true), password: "definitely-wrong", log: CommandLog())
        do {
            _ = try await connection.bootstrap()
            XCTFail("expected authentication failure")
        } catch {
            XCTAssertTrue(RemoteConnection.isAuthenticationFailure(error), "\(error)")
        }
    }

    @MainActor
    func testFileOperationsAndRsyncRoundTrip() async throws {
        let env = try requireEnvironment()
        let log = CommandLog()
        let connection = RemoteConnection(profile: env.profile(usePassword: false), password: nil, log: log)
        let info = try await connection.bootstrap()
        XCTAssertTrue(info.has("rsync"), "remote rsync required")
        guard let flavor = await RsyncLocator.detect(customPath: "") else {
            throw XCTSkip("no local rsync")
        }

        let fs = RemoteFileSystem(connection: connection)
        let base = info.home + "/yterm-it-\(UUID().uuidString.prefix(8))"
        try await fs.makeDirectory(base)
        defer { Task { try? await fs.delete([base]); await connection.disconnect() } }

        // Remote listing picks up the new directory.
        let homeEntries = try await fs.list(info.home)
        XCTAssertTrue(homeEntries.contains { $0.name == PathUtil.name(base) && $0.isDirectoryLike })

        // Prepare a local tree with awkward names.
        let localRoot = NSTemporaryDirectory() + "yterm-it-\(UUID().uuidString.prefix(8))"
        let localDir = localRoot + "/測試 上傳"
        try FileManager.default.createDirectory(atPath: localDir + "/nested", withIntermediateDirectories: true)
        try "hello".write(toFile: localDir + "/a b.txt", atomically: true, encoding: .utf8)
        try "world".write(toFile: localDir + "/nested/it's.txt", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: localRoot) }

        // Upload with the exact arguments the app builds.
        let parser = RsyncProgressParser(style: RsyncBuilder.progressStyle(flavor: flavor, remoteIsOpenrsync: info.remoteRsyncIsOpenrsync))
        let uploadArgs = RsyncBuilder.arguments(
            flavor: flavor, direction: .upload, localPath: localDir, remotePath: base,
            remoteDestination: connection.destination, rsh: connection.rshCommand, options: RsyncOptions(),
            remoteIsOpenrsync: info.remoteRsyncIsOpenrsync
        )
        let upload = try await ShellRunner.run(flavor.path, uploadArgs, options: .init(environment: connection.environment, onStdout: { data in _ = parser.feed(data) }))
        XCTAssertEqual(upload.exitCode, 0, upload.stderrText)
        XCTAssertGreaterThan(parser.snapshot.filesDone, 0)

        let uploaded = try await fs.list(base + "/測試 上傳")
        XCTAssertEqual(Set(uploaded.map(\.name)), ["a b.txt", "nested"])
        let nested = try await fs.list(base + "/測試 上傳/nested")
        XCTAssertEqual(nested.map(\.name), ["it's.txt"])
        XCTAssertEqual(nested.first?.size, 5)

        // Compress, extract, rename, chmod on the remote side.
        try await fs.compress(["測試 上傳"], in: base, kind: .tarGz, archiveName: "pack.tar.gz")
        try await fs.extract(base + "/pack.tar.gz", into: base + "/out")
        let extracted = try await fs.list(base + "/out/測試 上傳")
        XCTAssertTrue(extracted.contains { $0.name == "a b.txt" })

        if fs.hasTools(ArchiveKind.zip.requiredTools) {
            try await fs.compress(["測試 上傳"], in: base, kind: .zip, archiveName: "pack.zip")
            try await fs.extract(base + "/pack.zip", into: base + "/outzip")
            let unzipped = try await fs.list(base + "/outzip/測試 上傳/nested")
            XCTAssertEqual(unzipped.map(\.name), ["it's.txt"])
        }

        try await fs.rename(base + "/pack.tar.gz", to: base + "/renamed.tar.gz")
        let exists = try await fs.exists(base + "/renamed.tar.gz")
        XCTAssertTrue(exists)
        try await fs.chmod([base + "/renamed.tar.gz"], mode: "600", recursive: false)
        let afterChmod = try await fs.list(base)
        XCTAssertEqual(afterChmod.first { $0.name == "renamed.tar.gz" }?.mode, 0o600)

        // Run an arbitrary command in the directory.
        let du = try await fs.runCommand("ls | wc -l", in: base)
        XCTAssertEqual(du.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), fs.hasTools(["zip"]) ? "5" : "3")

        // Download the extracted tree back.
        let downloadDir = localRoot + "/download"
        try FileManager.default.createDirectory(atPath: downloadDir, withIntermediateDirectories: true)
        let downloadArgs = RsyncBuilder.arguments(
            flavor: flavor, direction: .download, localPath: downloadDir, remotePath: base + "/out/測試 上傳",
            remoteDestination: connection.destination, rsh: connection.rshCommand, options: RsyncOptions(),
            remoteIsOpenrsync: info.remoteRsyncIsOpenrsync
        )
        let download = try await ShellRunner.run(flavor.path, downloadArgs, options: .init(environment: connection.environment))
        XCTAssertEqual(download.exitCode, 0, download.stderrText)
        XCTAssertEqual(try String(contentsOfFile: downloadDir + "/測試 上傳/nested/it's.txt", encoding: .utf8), "world")

        // Mirror mode deletes extraneous files on the destination.
        try FileManager.default.removeItem(atPath: localDir + "/a b.txt")
        let mirrorArgs = RsyncBuilder.arguments(
            flavor: flavor, direction: .upload, localPath: localDir, remotePath: base + "/測試 上傳",
            remoteDestination: connection.destination, rsh: connection.rshCommand, options: RsyncOptions(mirror: true),
            remoteIsOpenrsync: info.remoteRsyncIsOpenrsync
        )
        let mirror = try await ShellRunner.run(flavor.path, mirrorArgs, options: .init(environment: connection.environment))
        XCTAssertEqual(mirror.exitCode, 0, mirror.stderrText)
        let mirrored = try await fs.list(base + "/測試 上傳")
        XCTAssertEqual(mirrored.map(\.name), ["nested"])

        // Safety: refuse to delete home.
        do {
            try await fs.delete([info.home])
            XCTFail("expected refusal")
        } catch {
            XCTAssertTrue(error is AppError)
        }

        try await fs.delete([base])
        let gone = try await fs.exists(base)
        XCTAssertFalse(gone)
        XCTAssertFalse(log.entries.isEmpty)
    }

    /// Two-way passes against the real host: new files both ways, edits, conflicts with backups,
    /// deletions both ways, then inotify-tools installed through sudo and the watcher reporting changes.
    @MainActor
    func testTwoWaySyncAndInotify() async throws {
        let env = try requireEnvironment()
        let connection = RemoteConnection(profile: env.profile(usePassword: false), password: nil, log: CommandLog())
        let info = try await connection.bootstrap()
        guard let flavor = await RsyncLocator.detect(customPath: "") else { throw XCTSkip("no local rsync") }
        let fs = RemoteFileSystem(connection: connection)
        let remoteRoot = info.home + "/yterm-2way-\(UUID().uuidString.prefix(6))"
        let localRoot = NSTemporaryDirectory() + "yterm-2way-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: localRoot + "/sub", withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: localRoot)
            try? FileManager.default.removeItem(atPath: AppPaths.supportDirectory + "/sync-backup/it")
            Task { try? await fs.delete([remoteRoot, info.home + "/" + SyncRule.backupFolderName]); await connection.disconnect() }
        }
        let excludes = SyncExcludes([SyncRule.backupFolderName])
        let engine = TwoWaySyncEngine(
            connection: connection, localRoot: localRoot, remoteRoot: remoteRoot, excludes: excludes, backupName: "it",
            transfer: { direction, listFile, backup in
                var options = RsyncOptions(contentsOnly: true)
                options.filesFrom = listFile
                options.filesFromRecursive = false
                options.backupDirectory = backup
                let args = RsyncBuilder.arguments(
                    flavor: flavor, direction: direction, localPath: localRoot, remotePath: remoteRoot,
                    remoteDestination: connection.destination, rsh: connection.rshCommand, options: options,
                    remoteIsOpenrsync: info.remoteRsyncIsOpenrsync
                )
                let result = try await ShellRunner.run(flavor.path, args, options: .init(environment: connection.environment))
                guard result.succeeded else { throw AppError.general(result.stderrText) }
            }
        )
        func remote(_ script: String) async throws -> String {
            try await connection.runChecked("cd \(Shell.quote(remoteRoot)) && " + script).stdoutText
        }
        func local(_ name: String) -> String? { try? String(contentsOfFile: localRoot + "/" + name, encoding: .utf8) }
        func write(_ text: String, _ name: String, mtime: Date = Date()) throws {
            try text.write(toFile: localRoot + "/" + name, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: localRoot + "/" + name)
        }

        // 1. First pass creates the remote folder and uploads.
        try write("one", "a.txt")
        try write("deep", "sub/b.txt")
        var outcome = try await engine.run(baseline: [:])
        XCTAssertEqual(Set(outcome.plan.push), ["a.txt", "sub", "sub/b.txt"])
        let b1 = try await remote("cat sub/b.txt")
        XCTAssertEqual(b1, "deep")
        var baseline = outcome.baseline
        XCTAssertEqual(baseline.count, 3)

        // 2. Nothing changed: nothing to do.
        outcome = try await engine.run(baseline: baseline)
        XCTAssertTrue(outcome.plan.isEmpty)

        // 3. Remote edit and a new remote file come down; a local edit goes up.
        _ = try await remote("printf remote-edit > a.txt && printf new > r.txt")
        try write("local-edit", "sub/b.txt")
        outcome = try await engine.run(baseline: outcome.baseline)
        XCTAssertEqual(Set(outcome.plan.pull), ["a.txt", "r.txt"])
        XCTAssertEqual(outcome.plan.push, ["sub/b.txt"])
        XCTAssertEqual(local("a.txt"), "remote-edit")
        let b2 = try await remote("cat sub/b.txt")
        XCTAssertEqual(b2, "local-edit")
        baseline = outcome.baseline

        // 4. Both sides edit a.txt: the newer remote copy wins, the local one is backed up.
        try write("older-local", "a.txt", mtime: Date().addingTimeInterval(-60))
        _ = try await remote("printf newer-remote > a.txt")
        outcome = try await engine.run(baseline: baseline)
        XCTAssertEqual(outcome.plan.conflicts.map(\.path), ["a.txt"])
        XCTAssertEqual(local("a.txt"), "newer-remote")
        let backup = try XCTUnwrap(outcome.localBackupDirectory)
        XCTAssertEqual(try String(contentsOfFile: backup + "/a.txt", encoding: .utf8), "older-local")
        baseline = outcome.baseline

        // 5. Deletions: r.txt removed locally, sub/ removed remotely.
        try FileManager.default.removeItem(atPath: localRoot + "/r.txt")
        _ = try await remote("rm -rf sub")
        outcome = try await engine.run(baseline: baseline)
        XCTAssertEqual(outcome.plan.deleteRemote, ["r.txt"])
        XCTAssertEqual(outcome.plan.deleteLocal, ["sub"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: localRoot + "/sub"))
        let listing = try await remote("ls")
        XCTAssertEqual(listing, "a.txt\n")
        let moved = try await connection.run("ls ~/\(SyncRule.backupFolderName)/it/*/r.txt").exitCode
        XCTAssertEqual(moved, 0, "remote deletions are moved into the backup folder")
        XCTAssertFalse(outcome.needsAnotherPass)

        // Backups on the host: usage, then expired-only cleanup keeps them, full cleanup removes them.
        let usageText = try await connection.runChecked(SyncBackups.remoteUsageScript(home: info.home, ruleFolder: "it")).stdoutText
        XCTAssertGreaterThanOrEqual(SyncBackups.parseRemoteUsage(usageText).snapshots, 1)
        let keep = try await connection.runChecked(SyncBackups.remotePruneScript(home: info.home, before: "20000101-000000", ruleFolder: "it")).stdoutText
        XCTAssertEqual(keep.trimmingCharacters(in: .whitespacesAndNewlines), "0")
        let all = try await connection.runChecked(SyncBackups.remotePruneScript(home: info.home, before: SyncBackups.everything, ruleFolder: "it")).stdoutText
        XCTAssertGreaterThanOrEqual(Int(all.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, 1)
        let gone = try await connection.run("test -e ~/\(SyncRule.backupFolderName)").exitCode
        XCTAssertNotEqual(gone, 0, "empty backup root is removed")

        // 6. Poll fingerprint matches the last listing until something changes.
        let pollScript = SyncListing.pollScript(root: remoteRoot, excludes: excludes)
        var poll = SyncListing.parsePoll(try await connection.runChecked(pollScript).stdoutText)
        XCTAssertEqual(poll.fingerprint, outcome.fingerprint)
        _ = try await remote("printf x > poll.txt")
        poll = SyncListing.parsePoll(try await connection.runChecked(pollScript).stdoutText)
        XCTAssertNotEqual(poll.fingerprint, outcome.fingerprint)

        // 7. The test account cannot use sudo; install through another account and watch for a change.
        guard let password = env.password, info.has("sudo"), InotifySupport.packageManager(for: info) != nil else {
            await connection.disconnect()
            return
        }
        let probe = try await InotifySupport.install(on: connection, sudoPassword: nil)
        if probe.exitCode != 0 {
            XCTAssertEqual(probe.exitCode, InotifySupport.InstallExit.needsPasswordNotAdmin.rawValue, probe.combinedText)
            let asTester = try await InotifySupport.install(on: connection, sudoPassword: password)
            XCTAssertEqual(asTester.exitCode, InotifySupport.InstallExit.notSudoer.rawValue, asTester.combinedText)
            let environment = ProcessInfo.processInfo.environment
            guard let adminUser = environment["YTERM_IT_ADMIN_USER"], let adminPassword = environment["YTERM_IT_ADMIN_PASSWORD"] else {
                throw XCTSkip("YTERM_IT_ADMIN_USER not set")
            }
            do {
                _ = try await InotifySupport.install(on: connection.profile, asUser: adminUser, password: "wrong", log: CommandLog())
                XCTFail("expected login failure")
            } catch {
                XCTAssertTrue(error is InotifySupport.InstallError, "\(error)")
            }
            let installed = try await InotifySupport.install(on: connection.profile, asUser: adminUser, password: adminPassword, log: CommandLog())
            XCTAssertEqual(installed.exitCode, 0, installed.combinedText)
        }
        let afterInstall = try await connection.runChecked(pollScript).stdoutText
        XCTAssertTrue(SyncListing.parsePoll(afterInstall).hasInotify)

        let events = LockedBox<String>("")
        let watcher = Task {
            try await connection.watch(InotifySupport.watchScript(root: remoteRoot, excludes: excludes)) { data in
                events.mutate { $0 += String(decoding: data, as: UTF8.self) }
            }
        }
        try await Task.sleep(for: .seconds(1))
        _ = try await remote("printf y > watched.txt")
        let deadline = Date().addingTimeInterval(10)
        while !events.value.contains("watched.txt"), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(events.value.contains("watched.txt"), events.value)
        watcher.cancel()
        _ = try? await watcher.value
        try await Task.sleep(for: .seconds(1))
        let leftover = try await connection.run("pgrep -u \(info.userName) inotifywait").exitCode
        XCTAssertNotEqual(leftover, 0, "inotifywait must exit when the app hangs up")
        try await fs.delete([remoteRoot, info.home + "/" + SyncRule.backupFolderName])
        await connection.disconnect()
    }
}
