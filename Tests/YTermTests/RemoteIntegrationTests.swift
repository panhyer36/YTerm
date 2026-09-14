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
}
