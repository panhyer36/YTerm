import AppKit
import SwiftUI

@main
struct YTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup("YTerm") {
            ContentView()
                .environment(app)
                .frame(minWidth: 980, minHeight: 560)
        }
        .defaultSize(width: 1200, height: 720)
        .commands {
            AppCommands(app: app)
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched from `swift run` there is no bundle; make sure we still behave like a GUI app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct AppCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandMenu("檔案操作") {
            Button("上傳選取項目到遠端") { app.transferSelection(direction: .upload) }
                .keyboardShortcut("u", modifiers: .command)
            Button("下載選取項目到本機") { app.transferSelection(direction: .download) }
                .keyboardShortcut("d", modifiers: .command)
            Button("複製到另一側面板") { app.transferToCounterpart(from: app.activePane) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("移動到另一側面板") { app.transferToCounterpart(from: app.activePane, moveAfter: true) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("在本機編輯遠端檔案") {
                app.openRemoteFilesForEditing(app.activePane.selectedEntries, from: app.activePane)
            }
            .keyboardShortcut("o", modifiers: .command)
            Divider()
            Button("新增資料夾…") { app.sheet = .newFolder(app.activePane.id) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("重新命名…") {
                if let entry = app.activePane.selectedEntries.first { app.sheet = .rename(app.activePane.id, entry) }
            }
            Button("變更權限…") {
                let entries = app.activePane.selectedEntries
                if !entries.isEmpty { app.sheet = .chmod(app.activePane.id, entries) }
            }
            Button("壓縮…") {
                let entries = app.activePane.selectedEntries
                if !entries.isEmpty { app.sheet = .compress(app.activePane.id, entries) }
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("解壓縮…") {
                if let entry = app.activePane.selectedEntries.first, entry.isArchive { app.sheet = .extract(app.activePane.id, entry) }
            }
            Divider()
            Button("刪除選取項目") { app.requestDelete(app.activePane.selectedEntries, in: app.activePane) }
                .keyboardShortcut(.delete, modifiers: .command)
            Divider()
            Button("重新整理") { app.refresh(app.activePane) }
                .keyboardShortcut("r", modifiers: .command)
            Button("執行指令…") { app.sheet = .runCommand(app.activePane.id) }
                .keyboardShortcut("e", modifiers: .command)
            Button("在終端機開啟目前資料夾") { app.openTerminal(for: app.activePane) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("在 \(app.ideName) 開啟目前資料夾") { app.openInIDE(app.activePane) }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Divider()
            Button("新增自動同步規則…") { app.sheet = .syncRule(nil) }
        }

        CommandMenu("連線") {
            ForEach(app.profiles.profiles) { profile in
                Button(profile.displayName) { app.connectPreferringRemotePane(profile) }
            }
            if app.profiles.profiles.isEmpty {
                Text("尚未新增主機")
            }
            Divider()
            Button("新增主機…") { app.sheet = .hostEditor(nil) }
            Button("從 ~/.ssh/config 匯入…") { app.sheet = .importSSHConfig }
            Divider()
            Button("中斷所有連線") { app.disconnectAll() }
                .disabled(!app.isConnected)
        }

        CommandMenu("面板") {
            Button("左右分割") { app.splitPane(app.activePane, axis: .horizontal) }
                .keyboardShortcut("\\", modifiers: .command)
            Button("上下分割") { app.splitPane(app.activePane, axis: .vertical) }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
            Button("關閉此面板") { app.closePane(app.activePane) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(app.panes.count == 1)
            Button("切換到下一個面板") { app.activateNextPane() }
                .keyboardShortcut("]", modifiers: .command)
            Divider()
            Button("這個面板改為本機") { app.setPaneLocal(app.activePane) }
            Divider()
            Button("加入目前路徑為書籤…") { app.sheet = .addBookmark(app.activePane.id) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("管理書籤…") { app.sheet = .bookmarks }
            Divider()
            Toggle("顯示隱藏檔（目前面板）", isOn: Binding(
                get: { app.activePane.showHidden },
                set: { app.activePane.showHidden = $0 }
            ))
            .keyboardShortcut(".", modifiers: [.command, .shift])
            Toggle("顯示底部面板", isOn: Binding(
                get: { app.showBottomPanel },
                set: { app.showBottomPanel = $0 }
            ))
            .keyboardShortcut("b", modifiers: [.command, .option])
        }
    }
}
