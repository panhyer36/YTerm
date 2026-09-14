import XCTest
@testable import YTerm

final class ShellTests: XCTestCase {
    func testSafeValuesAreNotQuoted() {
        XCTAssertEqual(Shell.quote("abc/def-1.txt"), "abc/def-1.txt")
        XCTAssertEqual(Shell.quote("/home/user"), "/home/user")
    }

    func testValuesWithSpacesAreQuoted() {
        XCTAssertEqual(Shell.quote("a b"), "'a b'")
        XCTAssertEqual(Shell.quote("測試 資料夾"), "'測試 資料夾'")
    }

    func testSingleQuotesAreEscaped() {
        XCTAssertEqual(Shell.quote("it's"), "'it'\\''s'")
    }

    func testEmptyValue() {
        XCTAssertEqual(Shell.quote(""), "''")
    }

    func testSplitArguments() {
        XCTAssertEqual(Shell.splitArguments("-J jump -o \"Foo=b ar\" 'x y'"), ["-J", "jump", "-o", "Foo=b ar", "x y"])
        XCTAssertEqual(Shell.splitArguments("   "), [])
    }

    func testQuotedValuesRoundTripThroughSh() async throws {
        let samples = ["plain", "with space", "it's \"quoted\"", "$HOME `date` \\ ; | &", "測試 資料夾/檔案.txt", "-dash"]
        for sample in samples {
            let script = "printf '%s' " + Shell.quote(sample)
            let result = try await ShellRunner.run("/bin/sh", ["-c", script])
            XCTAssertEqual(result.stdoutText, sample)
        }
    }

    func testNestedQuotingThroughShDashC() async throws {
        // The remote side wraps scripts as `sh -c '<script>'`; make sure double quoting survives.
        let inner = "printf '%s' " + Shell.quote("it's a test")
        let outer = "sh -c " + Shell.quote(inner)
        let result = try await ShellRunner.run("/bin/sh", ["-c", outer])
        XCTAssertEqual(result.stdoutText, "it's a test")
    }
}

final class PathUtilTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(PathUtil.normalize("~", relativeTo: "/x", home: "/home/u"), "/home/u")
        XCTAssertEqual(PathUtil.normalize("~/a/../b", relativeTo: "/x", home: "/home/u"), "/home/u/b")
        XCTAssertEqual(PathUtil.normalize("sub", relativeTo: "/x", home: "/home/u"), "/x/sub")
        XCTAssertEqual(PathUtil.normalize("/a//b/./c/", relativeTo: "/x", home: "/home/u"), "/a/b/c")
        XCTAssertEqual(PathUtil.normalize("/../..", relativeTo: "/x", home: "/home/u"), "/")
        XCTAssertEqual(PathUtil.normalize("", relativeTo: "/x", home: "/home/u"), "/x")
    }

    func testParentAndName() {
        XCTAssertEqual(PathUtil.parent("/a/b/c"), "/a/b")
        XCTAssertEqual(PathUtil.parent("/a"), "/")
        XCTAssertEqual(PathUtil.parent("/"), "/")
        XCTAssertEqual(PathUtil.name("/a/b/c"), "c")
        XCTAssertEqual(PathUtil.name("/a/b/"), "b")
        XCTAssertEqual(PathUtil.join("/", "x"), "/x")
        XCTAssertEqual(PathUtil.join("/a", "x"), "/a/x")
    }

    func testAncestor() {
        XCTAssertTrue(PathUtil.isSameOrAncestor("/a", of: "/a/b"))
        XCTAssertFalse(PathUtil.isSameOrAncestor("/a", of: "/ab"))
        XCTAssertTrue(PathUtil.isSameOrAncestor("/", of: "/anything"))
    }

    func testStripArchiveExtension() {
        XCTAssertEqual(PathUtil.stripArchiveExtension("backup.tar.gz"), "backup")
        XCTAssertEqual(PathUtil.stripArchiveExtension("data.zip"), "data")
        XCTAssertEqual(PathUtil.stripArchiveExtension("x.tgz"), "x")
        XCTAssertEqual(ArchiveKind.detect(fileName: "a.TAR.XZ"), .tarXz)
        XCTAssertEqual(ArchiveKind.detect(fileName: "a.gz"), .gz)
        XCTAssertNil(ArchiveKind.detect(fileName: "a.txt"))
    }
}
