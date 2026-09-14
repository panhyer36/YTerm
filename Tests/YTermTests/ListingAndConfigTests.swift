import XCTest
@testable import YTerm

final class RemoteListingTests: XCTestCase {
    func testParseGNUFindOutput() {
        let records = [
            "G\tf\tf\t1234\t1694000000.5\t644\tuser\tgroup\t\tfile name.txt",
            "G\td\td\t4096\t1694000000\t755\tu\tg\t\tdir",
            "G\tl\td\t5\t1\t777\tu\tg\ttarget dir\tlink",
            "G\tl\tN\t5\t1\t777\tu\tg\t/nonexistent\tbroken",
            "G\tf\tf\t10\t2\t4755\troot\troot\t\tsetuid",
        ]
        let data = Data((records.joined(separator: "\u{0}") + "\u{0}").utf8)
        let entries = RemoteListing.parse(data, directory: "/home/u")
        XCTAssertEqual(entries.count, 5)

        let file = entries[0]
        XCTAssertEqual(file.name, "file name.txt")
        XCTAssertEqual(file.path, "/home/u/file name.txt")
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(file.size, 1234)
        XCTAssertEqual(file.mode, 0o644)
        XCTAssertEqual(file.owner, "user")
        XCTAssertEqual(file.permissionText, "-rw-r--r--")
        XCTAssertNil(file.linkTarget)

        XCTAssertTrue(entries[1].isDirectoryLike)
        XCTAssertEqual(entries[1].permissionText, "drwxr-xr-x")

        let link = entries[2]
        XCTAssertEqual(link.kind, .symlink)
        XCTAssertTrue(link.isDirectoryLike)
        XCTAssertEqual(link.linkTarget, "target dir")

        XCTAssertFalse(entries[3].isDirectoryLike)
        XCTAssertEqual(entries[4].mode, 0o4755)
        XCTAssertEqual(entries[4].permissionText, "-rwsr-xr-x")
    }

    func testParseBSDStatOutput() {
        let records = [
            "B\tDirectory\t192\t1789018332\t40755\tuser\tstaff\t\t.",
            "B\tDirectory\t4352\t1789018357\t41777\troot\twheel\t\t..",
            "B\tSymbolic Link\t6\t1789018332\t120755\tuser\tstaff\tsubdir\tlinkdir",
            "B\tRegular File\t0\t1789018332\t100644\tuser\tstaff\t\tplain file.txt",
            "B\tDirectory\t64\t1789018332\t40755\tuser\tstaff\t\tsubdir",
            "L\tlinkdir",
        ]
        let data = Data((records.joined(separator: "\u{0}") + "\u{0}").utf8)
        let entries = RemoteListing.parse(data, directory: "/tmp/t")
        XCTAssertEqual(entries.map(\.name), ["linkdir", "plain file.txt", "subdir"])
        XCTAssertEqual(entries[0].kind, .symlink)
        XCTAssertTrue(entries[0].isDirectoryLike)
        XCTAssertEqual(entries[0].linkTarget, "subdir")
        XCTAssertEqual(entries[1].mode, 0o644)
        XCTAssertEqual(entries[1].size, 0)
        XCTAssertEqual(entries[2].mode, 0o755)
        XCTAssertTrue(entries[2].isDirectoryLike)
    }

    func testScriptQuotesDirectory() {
        let script = RemoteListing.script(for: "/home/u/測試 資料夾")
        XCTAssertTrue(script.contains("cd -- '/home/u/測試 資料夾' || exit 2"))
        XCTAssertTrue(script.contains("-printf"))
        XCTAssertTrue(script.contains("stat -f"))
    }

    func testBSDBranchRunsLocally() async throws {
        let dir = NSTemporaryDirectory() + "yterm-listing-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/sub dir", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/it's.txt", contents: Data("x".utf8))
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: "sub dir")
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let result = try await ShellRunner.run("/bin/sh", ["-c", RemoteListing.script(for: dir)])
        XCTAssertEqual(result.exitCode, 0, result.stderrText)
        let entries = RemoteListing.parse(result.stdout, directory: dir)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["sub dir", "it's.txt", "link"])
        XCTAssertTrue(byName["sub dir"]!.isDirectoryLike)
        XCTAssertEqual(byName["it's.txt"]!.size, 1)
        XCTAssertEqual(byName["link"]!.kind, .symlink)
        XCTAssertTrue(byName["link"]!.isDirectoryLike)
    }
}

final class SSHConfigParserTests: XCTestCase {
    func testParse() {
        let text = """
        # comment
        Host *
            ServerAliveInterval 30

        Host lab lab2
          HostName 10.0.0.5
          User me
          Port 2222
          IdentityFile ~/.ssh/lab_key

        Host ssh.example.com
          User root

        Match host foo
          User bar

        Host wild-*
          User nope
        """
        let hosts = SSHConfigParser.parse(text)
        XCTAssertEqual(hosts.map(\.alias), ["lab", "lab2", "ssh.example.com"])
        XCTAssertEqual(hosts[0].hostName, "10.0.0.5")
        XCTAssertEqual(hosts[0].user, "me")
        XCTAssertEqual(hosts[0].port, 2222)
        XCTAssertEqual(hosts[0].identityFile, "~/.ssh/lab_key")
        XCTAssertEqual(hosts[1].port, 2222)
        XCTAssertEqual(hosts[2].user, "root")
        XCTAssertNil(hosts[2].port)
        XCTAssertEqual(hosts[0].summary, "me@10.0.0.5:2222")
        XCTAssertEqual(hosts[0].makeProfile().host, "lab")
    }
}
