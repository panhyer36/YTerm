import AppKit
import XCTest
@testable import YTerm

/// Drives AppState's drag & drop handler (the part below SwiftUI's `.onDrop`) against the test sshd.
/// Skipped unless YTERM_IT_HOST is set (see RemoteIntegrationTests).
final class DropIntegrationTests: XCTestCase {
    struct Timeout: Error {}

    @MainActor
    private func waitUntil(_ timeout: TimeInterval = 20, detail: () -> String = { "" }, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for condition \(detail())"); throw Timeout() }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    func testDroppingFilesTransfersInBothDirections() async throws {
        guard let env = RemoteIntegrationTests.TestEnvironment.current else {
            throw XCTSkip("YTERM_IT_HOST not set")
        }
        let profile = env.profile(usePassword: false)
        let app = AppState()
        app.connect(to: profile)
        try await waitUntil { app.isConnected && app.remotePane.isAvailable && !app.remotePane.isLoading }
        try await waitUntil { app.rsyncFlavor != nil }
        guard let fs = app.remotePane.provider else { return XCTFail("no remote provider") }

        let base = app.remotePane.path + "/yterm-drop-\(UUID().uuidString.prefix(8))"
        try await fs.makeDirectory(base)
        app.remotePane.navigate(to: base)
        try await waitUntil { !app.remotePane.isLoading }
        XCTAssertEqual(app.remotePane.path, base)

        // 1) Finder-style file URL dropped on the remote pane → upload into the current remote directory.
        let localName = "drop \(UUID().uuidString.prefix(6)).txt"
        let localPath = NSTemporaryDirectory() + localName
        try "dropped".write(toFile: localPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: localPath) }
        let fileProvider = try XCTUnwrap(NSItemProvider(contentsOf: URL(fileURLWithPath: localPath)))
        app.handleDrop([fileProvider], onto: .remote)
        try await waitUntil { app.transfers.jobs.count == 1 && !app.transfers.jobs[0].isActive }
        let upload = app.transfers.jobs[0]
        XCTAssertEqual(upload.state, .finished, upload.output)
        XCTAssertEqual(upload.direction, .upload)
        let uploaded = try await fs.list(base)
        XCTAssertEqual(uploaded.map(\.name), [localName])

        // 2) Remote payload (what the remote table row provides) dropped on the local pane → download.
        let downloadDir = NSTemporaryDirectory() + "yterm-dropdl-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: downloadDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: downloadDir) }
        app.localPane.navigate(to: downloadDir)
        try await waitUntil { !app.localPane.isLoading }
        let remoteEntry = try XCTUnwrap(uploaded.first)
        let remoteProvider = try XCTUnwrap(app.dragItemProvider(for: remoteEntry, in: .remote))
        XCTAssertTrue(remoteProvider.hasItemConformingToTypeIdentifier(RemoteDragPayload.typeIdentifier))
        app.handleDrop([remoteProvider], onto: .local)
        try await waitUntil { app.transfers.jobs.count == 2 && !app.transfers.jobs[1].isActive }
        let download = app.transfers.jobs[1]
        XCTAssertEqual(download.state, .finished, download.output)
        XCTAssertEqual(download.direction, .download)
        XCTAssertEqual(try String(contentsOfFile: downloadDir + "/" + localName, encoding: .utf8), "dropped")

        // The panes refresh after transfers.
        try await waitUntil { app.localPane.entries.contains { $0.name == localName } }
        try await fs.delete([base])
        app.disconnect()
    }
}

extension DropIntegrationTests {
    /// Double-click flow without the editor window: download to the staging area, save locally, auto-upload.
    @MainActor
    func testEditingRemoteFileUploadsEverySave() async throws {
        guard let env = RemoteIntegrationTests.TestEnvironment.current else {
            throw XCTSkip("YTERM_IT_HOST not set")
        }
        let app = AppState()
        app.edits.launchesEditor = false
        app.edits.debounceInterval = .milliseconds(200)
        app.connect(to: env.profile(usePassword: false))
        try await waitUntil { app.isConnected && app.remotePane.isAvailable && !app.remotePane.isLoading }
        try await waitUntil { app.rsyncFlavor != nil }
        guard let fs = app.remotePane.provider else { return XCTFail("no remote provider") }

        let base = app.remotePane.path + "/yterm-edit-\(UUID().uuidString.prefix(8))"
        try await fs.makeDirectory(base)
        let created = try await fs.runCommand("printf 'version1\\n' > script.sh && chmod 755 script.sh", in: base)
        XCTAssertTrue(created.succeeded, created.combinedText)
        app.remotePane.navigate(to: base)
        try await waitUntil { !app.remotePane.isLoading }
        let entry = try XCTUnwrap(app.remotePane.entries.first { $0.name == "script.sh" })

        app.open([entry.id], in: .remote)
        try await waitUntil(detail: { app.transfers.jobs.map { "\($0.title): \($0.state) \($0.output)" }.joined(separator: " | ") + " sessions=\(app.edits.sessions.map(\.state))" }) { app.edits.sessions.first?.state == .watching }
        let session = try XCTUnwrap(app.edits.sessions.first)
        XCTAssertEqual(try String(contentsOf: session.localURL, encoding: .utf8), "version1\n")
        XCTAssertEqual(session.remotePath, base + "/script.sh")

        // Atomic save (TextEdit / VS Code style).
        let temp = session.localURL.deletingLastPathComponent().appendingPathComponent("save.tmp")
        try "version2\n".write(to: temp, atomically: false, encoding: .utf8)
        XCTAssertEqual(rename(temp.path, session.localURL.path), 0)
        try await waitUntil(detail: { app.transfers.jobs.map { "\($0.title): \($0.state) \($0.output)" }.joined(separator: " | ") + " session=\(session.state) count=\(session.uploadCount)" }) { session.uploadCount >= 1 && session.state == .watching }
        var remote = try await fs.runCommand("cat script.sh; stat -c %a script.sh 2>/dev/null || stat -f %OLp script.sh", in: base)
        XCTAssertEqual(remote.stdoutText, "version2\n755\n", "content uploaded, remote permissions preserved")

        // In-place save (vim style).
        let handle = try FileHandle(forWritingTo: session.localURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("version3\n".utf8))
        try handle.close()
        try await waitUntil(detail: { app.transfers.jobs.map { "\($0.title): \($0.state) \($0.output)" }.joined(separator: " | ") + " session=\(session.state) count=\(session.uploadCount)" }) { session.uploadCount >= 2 && session.state == .watching }
        remote = try await fs.runCommand("cat script.sh", in: base)
        XCTAssertEqual(remote.stdoutText, "version3\n")

        // Opening the same remote file again reuses the session instead of downloading twice.
        app.openRemoteFilesForEditing([entry])
        XCTAssertEqual(app.edits.sessions.count, 1)

        let stagingDirectory = session.localURL.deletingLastPathComponent()
        app.edits.stop(session, deleteLocalCopy: !session.hasUnsyncedChanges)
        XCTAssertTrue(app.edits.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path), "synced copy is removed, no local backup")

        try await fs.delete([base])
        app.disconnect()
    }
}

extension DropIntegrationTests {
    @MainActor
    func testAutoSyncRulePushesChanges() async throws {
        guard let env = RemoteIntegrationTests.TestEnvironment.current else { throw XCTSkip("YTERM_IT_HOST not set") }
        let app = AppState()
        app.syncs.debounceInterval = .milliseconds(200)
        let profile = env.profile(usePassword: false)
        app.profiles.upsert(profile)
        defer { app.profiles.remove(profile) }
        app.connect(to: profile)
        try await waitUntil { app.isConnected && app.remotePane.isAvailable && !app.remotePane.isLoading }
        try await waitUntil { app.rsyncFlavor != nil }
        guard let fs = app.remotePane.provider else { return XCTFail("no provider") }

        let localRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yterm-sync-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: localRoot.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "one".write(to: localRoot.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: localRoot) }
        let remoteRoot = app.remotePane.path + "/yterm-sync-\(UUID().uuidString.prefix(6))"

        var rule = SyncRule()
        rule.localPath = localRoot.path
        rule.profileID = profile.id
        rule.remotePath = remoteRoot
        rule.mirror = true
        app.syncs.upsert(rule)
        defer { app.syncs.remove(rule.id); Task { try? await fs.delete([remoteRoot]) } }
        let session = try XCTUnwrap(app.syncs.session(rule.id))
        try await waitUntil(detail: { "\(session.state) \(session.job?.output ?? "")" }) { session.syncCount >= 1 && session.state == .idle }
        let firstListing = try await fs.list(remoteRoot).map(\.name).sorted()
        XCTAssertEqual(firstListing, ["a.txt", "sub"])

        // A nested change is picked up by the watcher and pushed; mirror removes the deleted file.
        try "two".write(to: localRoot.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: localRoot.appendingPathComponent("a.txt"))
        try await waitUntil(15, detail: { "\(session.state) count=\(session.syncCount)" }) { session.syncCount >= 2 && session.state == .idle && !session.pendingSync }
        let afterChange = try await fs.list(remoteRoot).map(\.name)
        XCTAssertEqual(afterChange, ["sub"])
        let nested = try await fs.list(remoteRoot + "/sub").map(\.name)
        XCTAssertEqual(nested, ["b.txt"])
        app.disconnect()
    }
}

extension DropIntegrationTests {
    @MainActor
    func testPullReviewDownloadsOnlySelectedChanges() async throws {
        guard let env = RemoteIntegrationTests.TestEnvironment.current else { throw XCTSkip("YTERM_IT_HOST not set") }
        let app = AppState()
        let profile = env.profile(usePassword: false)
        app.profiles.upsert(profile)
        defer { app.profiles.remove(profile) }
        app.connect(to: profile)
        try await waitUntil { app.isConnected && app.remotePane.isAvailable && !app.remotePane.isLoading }
        try await waitUntil { app.rsyncFlavor != nil }
        guard let fs = app.remotePane.provider else { return XCTFail("no provider") }

        let remoteRoot = app.remotePane.path + "/yterm-pull-\(UUID().uuidString.prefix(6))"
        try await fs.makeDirectory(remoteRoot + "/sub")
        _ = try await fs.runCommand("printf one > a.txt && printf two > sub/b.txt && printf three > c.txt", in: remoteRoot)
        let localRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yterm-pull-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        try "stale".write(to: localRoot.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: localRoot.appendingPathComponent("c.txt").path)
        try "gone".write(to: localRoot.appendingPathComponent("local-only.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: localRoot); Task { try? await fs.delete([remoteRoot]) } }

        let request = PullReviewRequest(profileID: profile.id, remotePath: remoteRoot, localPath: localRoot.path, mirror: false, excludes: [], ruleID: nil)
        let preview = try await app.previewPull(request, includeDeletions: true)
        let byPath = Dictionary(uniqueKeysWithValues: preview.map { ($0.relativePath, $0.kind) })
        XCTAssertEqual(byPath["a.txt"], .added)
        XCTAssertEqual(byPath["sub/b.txt"], .added)
        XCTAssertEqual(byPath["c.txt"], .modified)
        XCTAssertEqual(byPath["local-only.txt"], .deleted)

        // Pull only the nested file and the modified one; leave a.txt and the local leftover alone.
        let chosen = preview.filter { ["sub/b.txt", "c.txt"].contains($0.relativePath) }
        app.performPull(request, download: chosen, trash: [])
        try await waitUntil(detail: { app.transfers.jobs.map { "\($0.title): \($0.state) \($0.output)" }.joined(separator: " | ") }) {
            app.transfers.jobs.count == 1 && !app.transfers.jobs[0].isActive
        }
        XCTAssertEqual(app.transfers.jobs[0].state, .finished)
        XCTAssertEqual(try String(contentsOf: localRoot.appendingPathComponent("sub/b.txt"), encoding: .utf8), "two")
        XCTAssertEqual(try String(contentsOf: localRoot.appendingPathComponent("c.txt"), encoding: .utf8), "three")
        XCTAssertFalse(FileManager.default.fileExists(atPath: localRoot.appendingPathComponent("a.txt").path), "unselected file must not be downloaded")
        XCTAssertTrue(FileManager.default.fileExists(atPath: localRoot.appendingPathComponent("local-only.txt").path), "unselected deletion must stay")

        let again = try await app.previewPull(request, includeDeletions: false)
        XCTAssertEqual(again.map(\.relativePath), ["a.txt"])
        app.disconnect()
    }
}
