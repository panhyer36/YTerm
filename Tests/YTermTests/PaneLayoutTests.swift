import XCTest
@testable import YTerm

final class PaneLayoutTests: XCTestCase {
    func testSplitAndRemove() {
        let a = UUID(), b = UUID(), c = UUID()
        var layout: PaneLayout = .split(axis: .horizontal, first: .pane(a), second: .pane(b))
        layout = layout.splitting(b, axis: .vertical, newPane: c)
        XCTAssertEqual(layout, .split(axis: .horizontal, first: .pane(a), second: .split(axis: .vertical, first: .pane(b), second: .pane(c))))
        XCTAssertEqual(layout.paneIDs, [a, b, c])

        XCTAssertEqual(layout.removing(b), .split(axis: .horizontal, first: .pane(a), second: .pane(c)))
        XCTAssertEqual(layout.removing(a), .split(axis: .vertical, first: .pane(b), second: .pane(c)))
        XCTAssertNil(PaneLayout.pane(a).removing(a))
        XCTAssertEqual(PaneLayout.pane(a).removing(b), .pane(a))
        XCTAssertEqual(layout.splitting(UUID(), axis: .horizontal, newPane: UUID()), layout, "unknown pane leaves the layout untouched")
    }

    @MainActor
    func testAppStateSplitsAndClosesPanes() {
        let app = AppState()
        XCTAssertEqual(app.panes.count, 2)
        let local = app.localPane
        let newPane = app.splitPane(local, axis: .vertical)
        XCTAssertEqual(app.panes.count, 3)
        XCTAssertEqual(newPane.kind, .local)
        XCTAssertEqual(newPane.path, local.path, "a split pane starts at the same directory")
        XCTAssertEqual(app.activePaneID, newPane.id)
        XCTAssertEqual(app.counterpart(of: newPane)?.id, local.id, "the previously active pane is the counterpart")
        XCTAssertEqual(app.layout.paneIDs.count, 3)

        app.closePane(newPane)
        XCTAssertEqual(app.panes.count, 2)
        XCTAssertNil(app.pane(newPane.id))
        XCTAssertEqual(app.activePaneID, local.id)

        app.closePane(app.remotePane)
        app.closePane(app.localPane)
        XCTAssertEqual(app.panes.count, 1, "the last pane cannot be closed")
    }
}

final class IDELauncherTests: XCTestCase {
    func testRemoteFolderURI() {
        var profile = HostProfile()
        profile.host = "203.0.113.10"
        profile.user = "alice"
        profile.port = 2222
        XCTAssertEqual(
            IDELauncher.remoteFolderURI(profile: profile, path: "/home/alice/測試 資料夾"),
            "vscode-remote://ssh-remote+alice@203.0.113.10:2222/home/alice/%E6%B8%AC%E8%A9%A6%20%E8%B3%87%E6%96%99%E5%A4%BE"
        )
        var alias = HostProfile()
        alias.host = "lab-alias"
        XCTAssertEqual(IDELauncher.remoteFolderURI(profile: alias, path: "/srv"), "vscode-remote://ssh-remote+lab-alias/srv")
    }
}
