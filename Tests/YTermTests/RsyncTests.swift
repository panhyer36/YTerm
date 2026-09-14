import XCTest
@testable import YTerm

final class RsyncProgressParserTests: XCTestCase {
    func testRealRsyncProgress2Line() {
        let parser = RsyncProgressParser(kind: .rsync)
        XCTAssertTrue(parser.parseLine("  1,234,567  45%   10.23MB/s    0:00:05 (xfr#3, to-chk=10/20)"))
        let progress = parser.snapshot
        XCTAssertEqual(progress.overallFraction, 0.45)
        XCTAssertNil(progress.fileFraction)
        XCTAssertEqual(progress.transferred, "1,234,567")
        XCTAssertEqual(progress.speed, "10.23MB/s")
        XCTAssertEqual(progress.eta, "0:00:05")
        XCTAssertEqual(progress.filesDone, 3)
        XCTAssertEqual(progress.filesTotal, 20)
    }

    func testHumanReadableAndIncrementalChk() {
        let parser = RsyncProgressParser(kind: .rsync)
        XCTAssertTrue(parser.parseLine("        1.23M  12%    3.00MB/s    0:00:10 (xfr#1, ir-chk=1005/1200)"))
        XCTAssertEqual(parser.snapshot.overallFraction, 0.12)
        XCTAssertEqual(parser.snapshot.transferred, "1.23M")
    }

    func testOpenrsyncProgress() {
        let parser = RsyncProgressParser(kind: .openrsync)
        XCTAssertTrue(parser.parseLine("Transfer starting: 3 files"))
        XCTAssertTrue(parser.parseLine("src/big.bin"))
        XCTAssertTrue(parser.parseLine("       20971520  50%  325.15MB/s   00:00:00"))
        var progress = parser.snapshot
        XCTAssertEqual(progress.currentFile, "src/big.bin")
        XCTAssertEqual(progress.fileFraction, 0.5)
        XCTAssertEqual(progress.filesTotal, 3)
        XCTAssertEqual(progress.overallFraction!, 0.5 / 3, accuracy: 0.0001)

        XCTAssertTrue(parser.parseLine("       41943040 100%  325.15MB/s   00:00:00 (xfer#1, to-check=1/3)"))
        XCTAssertTrue(parser.parseLine("src/small.bin"))
        XCTAssertTrue(parser.parseLine("          10240 100%  133.86MB/s   00:00:00 (xfer#2, to-check=2/3)"))
        progress = parser.snapshot
        XCTAssertEqual(progress.filesDone, 2)
        XCTAssertEqual(progress.overallFraction!, 2.0 / 3, accuracy: 0.0001)
        XCTAssertFalse(parser.parseLine("sent 41959k bytes  received 70 bytes  335M bytes/sec"))
        XCTAssertEqual(parser.snapshot.currentFile, "src/small.bin")
    }

    func testFeedSplitsOnCarriageReturns() {
        let parser = RsyncProgressParser(kind: .rsync)
        let chunk = Data("sending incremental file list\nfoo.bin\n          1,000   1%    1.00MB/s    0:01:00\r          5,000   5%    1.00MB/s    0:00:50\r".utf8)
        _ = parser.feed(chunk)
        XCTAssertEqual(parser.snapshot.overallFraction, 0.05)
        XCTAssertEqual(parser.snapshot.currentFile, "foo.bin")
        // Partial line stays buffered until terminated.
        _ = parser.feed(Data("         9,000   9".utf8))
        XCTAssertEqual(parser.snapshot.overallFraction, 0.05)
        _ = parser.feed(Data("%    1.00MB/s    0:00:40\r".utf8))
        XCTAssertEqual(parser.snapshot.overallFraction, 0.09)
    }
}

final class RsyncBuilderTests: XCTestCase {
    private let openrsync = RsyncFlavor(path: "/usr/bin/rsync", kind: .openrsync, version: "openrsync")
    private let rsync = RsyncFlavor(path: "/opt/homebrew/bin/rsync", kind: .rsync, version: "3.4.1")

    func testUploadWithOpenrsyncQuotesRemotePath() {
        let args = RsyncBuilder.arguments(
            flavor: openrsync, direction: .upload, localPath: "/Users/me/file.txt", remotePath: "/home/u/測試 資料夾",
            remoteDestination: "u@host", rsh: "/usr/bin/ssh -p 22", options: RsyncOptions()
        )
        XCTAssertEqual(args.prefix(5), ["-a", "-h", "--partial", "-v", "--progress"])
        XCTAssertTrue(args.contains("-e"))
        XCTAssertEqual(args.suffix(2), ["/Users/me/file.txt", "u@host:'/home/u/測試 資料夾/'"])
        XCTAssertFalse(args.contains("-s"))
    }

    func testOldRsyncQuotesRemotePathAndNewRsyncDoesNot() {
        let old = RsyncFlavor(path: "/usr/local/bin/rsync", kind: .rsync, version: "3.1.3")
        XCTAssertFalse(old.escapesRemoteArguments)
        XCTAssertTrue(rsync.escapesRemoteArguments)
        XCTAssertEqual(RsyncFlavor(path: "x", kind: .rsync, version: "3.2.4").versionTuple.2, 4)
        let args = RsyncBuilder.arguments(
            flavor: old, direction: .download, localPath: "/tmp/d", remotePath: "/home/u/a b.txt",
            remoteDestination: "u@host", rsh: "ssh", options: RsyncOptions()
        )
        XCTAssertEqual(args.suffix(2), ["u@host:'/home/u/a b.txt'", "/tmp/d/"])
    }

    func testDownloadWithRealRsyncPassesPathVerbatim() {
        let args = RsyncBuilder.arguments(
            flavor: rsync, direction: .download, localPath: "/Users/me/Downloads", remotePath: "/home/u/a b.txt",
            remoteDestination: "u@host", rsh: "/usr/bin/ssh", options: RsyncOptions(compress: true, excludes: [".DS_Store", ""])
        )
        XCTAssertFalse(args.contains("-s"), "remote openrsync rejects --secluded-args")
        XCTAssertTrue(args.contains("--info=progress2,name1"))
        XCTAssertTrue(args.contains("-z"))
        XCTAssertTrue(args.contains("--exclude=.DS_Store"))
        XCTAssertFalse(args.contains("--exclude="))
        XCTAssertEqual(args.suffix(2), ["u@host:/home/u/a b.txt", "/Users/me/Downloads/"])
    }

    func testMirrorAddsTrailingSlashAndDelete() {
        let args = RsyncBuilder.arguments(
            flavor: rsync, direction: .upload, localPath: "/Users/me/project", remotePath: "/home/u/project",
            remoteDestination: "u@host", rsh: "/usr/bin/ssh", options: RsyncOptions(mirror: true)
        )
        XCTAssertTrue(args.contains("--delete"))
        XCTAssertEqual(args.suffix(2), ["/Users/me/project/", "u@host:/home/u/project/"])
    }
}

final class UnixCommandsTests: XCTestCase {
    func testCompressAndExtract() {
        XCTAssertEqual(
            UnixCommands.compress(kind: .tarGz, names: ["a b", "c"], in: "/x", archiveName: "out.tar.gz"),
            "cd -- /x && tar -czf out.tar.gz -- 'a b' c"
        )
        XCTAssertEqual(
            UnixCommands.extract(kind: .zip, archivePath: "/x/it's.zip", into: "/x/it's"),
            "mkdir -p -- '/x/it'\\''s' && unzip -q -o '/x/it'\\''s.zip' -d '/x/it'\\''s'"
        )
        XCTAssertEqual(
            UnixCommands.extract(kind: .gz, archivePath: "/x/log.gz", into: "/x/out"),
            "mkdir -p -- /x/out && gzip -dc /x/log.gz > /x/out/log"
        )
        XCTAssertNil(UnixCommands.compress(kind: .gz, names: ["a"], in: "/x", archiveName: "a.gz"))
    }

    func testBasicCommands() {
        XCTAssertEqual(UnixCommands.remove(["/a/b c"]), "rm -rf -- '/a/b c'")
        XCTAssertEqual(UnixCommands.move(["/a/x"], into: "/dest"), "mv -- /a/x /dest/")
        XCTAssertEqual(UnixCommands.chmod(["/a"], mode: "755", recursive: true), "chmod -R -- 755 /a")
        XCTAssertEqual(UnixCommands.runInDirectory("/p q", "ls -la"), "cd -- '/p q' && ls -la")
    }
}

final class RsyncRemoteFlavorTests: XCTestCase {
    func testOpenrsyncRemoteForcesPerFileProgressEvenWithRealLocalRsync() {
        let rsync = RsyncFlavor(path: "/opt/homebrew/bin/rsync", kind: .rsync, version: "3.5.0")
        XCTAssertEqual(RsyncBuilder.progressStyle(flavor: rsync, remoteIsOpenrsync: false), .overall)
        XCTAssertEqual(RsyncBuilder.progressStyle(flavor: rsync, remoteIsOpenrsync: true), .perFile)
        let args = RsyncBuilder.arguments(
            flavor: rsync, direction: .upload, localPath: "/tmp/a", remotePath: "/home/u",
            remoteDestination: "u@mac", rsh: "ssh", options: RsyncOptions(), remoteIsOpenrsync: true
        )
        XCTAssertFalse(args.contains { $0.hasPrefix("--info") })
        XCTAssertFalse(args.contains("--no-inc-recursive"))
        XCTAssertTrue(args.contains("--progress"))
        var info = RemoteInfo()
        info.rsyncVersionLine = "openrsync: protocol version 29"
        XCTAssertTrue(info.remoteRsyncIsOpenrsync)
        info.rsyncVersionLine = "rsync  version 3.2.7  protocol version 31"
        XCTAssertFalse(info.remoteRsyncIsOpenrsync)
    }
}
