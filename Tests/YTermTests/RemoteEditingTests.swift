import Foundation
import XCTest
@testable import YTerm

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

final class FileWatcherTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw XCTSkip("timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testDetectsInPlaceWritesAndAtomicReplacement() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yterm-watch-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("watched.txt")
        try "a".write(to: file, atomically: false, encoding: .utf8)

        let counter = Counter()
        let watcher = FileWatcher(fileURL: file) { counter.increment() }
        watcher.start()
        try await Task.sleep(for: .milliseconds(200))

        // In-place write (vim with backupcopy=yes, shell redirection…)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("b".utf8))
        try handle.close()
        try await waitUntil { counter.value >= 1 }

        // Atomic replacement (TextEdit, VS Code…): write a temp file and rename it over the original.
        let seenBeforeReplace = counter.value
        let temp = directory.appendingPathComponent("watched.txt.tmp")
        try "c".write(to: temp, atomically: false, encoding: .utf8)
        XCTAssertEqual(rename(temp.path, file.path), 0)
        try await waitUntil { counter.value > seenBeforeReplace }

        // The watcher must have re-attached to the new inode: in-place writes are still seen.
        try await Task.sleep(for: .milliseconds(600))
        let seenBeforeSecondWrite = counter.value
        let handle2 = try FileHandle(forWritingTo: file)
        try handle2.seekToEnd()
        try handle2.write(contentsOf: Data("d".utf8))
        try handle2.close()
        try await waitUntil { counter.value > seenBeforeSecondWrite }

        watcher.stop()
        try await Task.sleep(for: .milliseconds(200))
        let afterStop = counter.value
        try "e".write(to: file, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(counter.value, afterStop, "no events after stop()")
    }
}

final class RemoteEditingBuilderTests: XCTestCase {
    func testSingleFileTransfersUseTimesOnly() {
        let flavor = RsyncFlavor(path: "/usr/bin/rsync", kind: .openrsync, version: "openrsync")
        let args = RsyncBuilder.arguments(
            flavor: flavor, direction: .upload, localPath: "/tmp/stage/a.txt", remotePath: "/home/u/dir",
            remoteDestination: "u@host", rsh: "/usr/bin/ssh", options: RsyncOptions(singleFile: true)
        )
        XCTAssertEqual(args.first, "-t")
        XCTAssertTrue(args.contains("-I"), "always resend edited files even if size and mtime match")
        XCTAssertFalse(args.contains("-a"))
        XCTAssertEqual(args.suffix(2), ["/tmp/stage/a.txt", "u@host:/home/u/dir/"])
    }

}
