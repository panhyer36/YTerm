import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VSplitView {
            PaneLayoutView(layout: app.layout)
                .frame(minHeight: 260)
                .layoutPriority(1)

            if app.showBottomPanel {
                BottomPanelView()
                    .frame(minHeight: 160, idealHeight: 230)
            }
        }
        .toolbar { MainToolbar() }
        .sheet(item: $app.sheet) { kind in
            SheetRouter(kind: kind)
                .environment(app)
        }
        .alert(
            app.alert?.title ?? "",
            isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } }),
            presenting: app.alert
        ) { _ in
            Button("好", role: .cancel) {}
        } message: { info in
            Text(info.message)
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { app.deleteRequest != nil }, set: { if !$0 { app.deleteRequest = nil } }),
            titleVisibility: .visible,
            presenting: app.deleteRequest
        ) { request in
            Button(app.pane(request.paneID)?.kind == .local ? "移到垃圾桶" : "永久刪除", role: .destructive) {
                app.performDelete(request)
            }
            Button("取消", role: .cancel) {}
        } message: { request in
            Text(deleteMessage(request))
        }
        .confirmationDialog(
            "鏡像同步會刪除目的端多餘的檔案",
            isPresented: Binding(get: { app.mirrorRequest != nil }, set: { if !$0 { app.mirrorRequest = nil } }),
            titleVisibility: .visible,
            presenting: app.mirrorRequest
        ) { request in
            Button("開始鏡像同步", role: .destructive) { app.performMirror(request) }
            Button("取消", role: .cancel) {}
        } message: { request in
            Text(mirrorMessage(request))
        }
    }

    private var deleteTitle: String {
        guard let request = app.deleteRequest else { return "" }
        let count = request.entries.count
        return app.pane(request.paneID)?.kind == .local
            ? "要把 \(count) 個項目移到垃圾桶嗎？"
            : "要永久刪除遠端的 \(count) 個項目嗎？"
    }

    private func deleteMessage(_ request: DeleteRequest) -> String {
        let names = request.entries.prefix(8).map(\.name).joined(separator: "\n")
        let more = request.entries.count > 8 ? "\n…還有 \(request.entries.count - 8) 個" : ""
        let note = app.pane(request.paneID)?.kind == .remote ? "\n\n遠端刪除會執行 rm -rf，無法復原。" : ""
        return names + more + note
    }

    private func mirrorMessage(_ request: MirrorRequest) -> String {
        let names = request.entries.map(\.name).joined(separator: "、")
        let target = app.pane(request.targetPaneID)?.locationText ?? "另一側"
        return "將以 rsync --delete 同步「\(names)」的內容到「\(target)」，目的端資料夾中不存在於來源的檔案會被刪除。"
    }
}

/// Renders the split tree; each leaf is a file pane.
struct PaneLayoutView: View {
    @Environment(AppState.self) private var app
    let layout: PaneLayout

    var body: some View {
        switch layout {
        case let .pane(id):
            if let pane = app.pane(id) {
                FilePaneView(pane: pane)
                    .frame(minWidth: 320, minHeight: 140)
            } else {
                Color.clear
            }
        case let .split(axis, first, second):
            if axis == .horizontal {
                HSplitView {
                    AnyView(PaneLayoutView(layout: first))
                    AnyView(PaneLayoutView(layout: second))
                }
            } else {
                VSplitView {
                    AnyView(PaneLayoutView(layout: first))
                    AnyView(PaneLayoutView(layout: second))
                }
            }
        }
    }
}

// MARK: - Toolbar

struct MainToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ConnectionMenu()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ToolbarActions()
        }
    }
}

struct ConnectionMenu: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Menu {
            ForEach(app.profiles.profiles) { profile in
                Button {
                    app.connectPreferringRemotePane(profile)
                } label: {
                    Label(profile.displayName + "  " + profile.summary, systemImage: app.connections[profile.id] != nil ? "network" : "server.rack")
                }
            }
            if app.profiles.profiles.isEmpty {
                Text("尚未新增主機")
            }
            Divider()
            Button("新增主機…") { app.sheet = .hostEditor(nil) }
            Button("從 ~/.ssh/config 匯入…") { app.sheet = .importSSHConfig }
            if !app.connections.isEmpty {
                Divider()
                ForEach(Array(app.connections.keys), id: \.self) { profileID in
                    if let profile = app.profiles.profile(id: profileID) {
                        Button("中斷「\(profile.displayName)」") { app.disconnect(profileID: profileID) }
                    }
                }
                Button("中斷所有連線") { app.disconnectAll() }
            }
        } label: {
            Label(label, systemImage: app.isConnected ? "network" : "network.slash")
        }
        .help("選擇主機：在目前的遠端面板開啟（沒有遠端面板時會自動分割一個）")
    }

    private var label: String {
        let names = app.connections.values.map(\.profile.displayName).sorted()
        switch names.count {
        case 0: return "連線"
        case 1: return names[0]
        default: return "\(names.count) 台主機"
        }
    }
}

struct ToolbarActions: View {
    @Environment(AppState.self) private var app

    private var pane: PaneModel { app.activePane }
    private var selection: [FileEntry] { pane.selectedEntries }

    var body: some View {
        Group {
            actions
        }
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private var actions: some View {
        Button {
            app.transferSelection(direction: .upload)
        } label: {
            Label("上傳", systemImage: "arrow.up.doc")
        }
        .help("把本機面板選取的項目上傳到最近使用的遠端面板（⌘U）")
        .disabled(app.mostRecentPane(kind: .local)?.selectedEntries.isEmpty ?? true || app.mostRecentPane(kind: .remote, connectedOnly: true) == nil)

        Button {
            app.transferSelection(direction: .download)
        } label: {
            Label("下載", systemImage: "arrow.down.doc")
        }
        .help("把遠端面板選取的項目下載到最近使用的本機面板（⌘D）")
        .disabled(app.mostRecentPane(kind: .remote, connectedOnly: true)?.selectedEntries.isEmpty ?? true || app.mostRecentPane(kind: .local) == nil)

        Button {
            app.sheet = .newFolder(pane.id)
        } label: {
            Label("新資料夾", systemImage: "folder.badge.plus")
        }
        .help("在目前面板建立資料夾（⇧⌘N）")
        .disabled(!pane.isAvailable)

        Button {
            if !selection.isEmpty { app.sheet = .compress(pane.id, selection) }
        } label: {
            Label("壓縮", systemImage: "doc.zipper")
        }
        .help("把選取項目壓縮成 tar.gz / zip…")
        .disabled(selection.isEmpty)

        Button {
            if let entry = selection.first, entry.isArchive { app.sheet = .extract(pane.id, entry) }
        } label: {
            Label("解壓縮", systemImage: "shippingbox")
        }
        .help("解壓縮選取的壓縮檔")
        .disabled(!(selection.count == 1 && selection[0].isArchive))

        Menu {
            Button("在本機編輯遠端檔案（儲存後自動上傳）") {
                app.openRemoteFilesForEditing(selection, from: pane)
            }
            .disabled(pane.kind != .remote || !selection.contains(where: { !$0.isDirectoryLike }))
            Button("重新命名…") {
                if let entry = selection.first { app.sheet = .rename(pane.id, entry) }
            }
            .disabled(selection.count != 1)
            Button("變更權限…") {
                app.sheet = .chmod(pane.id, selection)
            }
            .disabled(selection.isEmpty)
            Button("複製路徑") { app.copyPaths(selection) }
                .disabled(selection.isEmpty)
            Divider()
            if let counterpart = app.counterpart(of: pane) {
                Button("複製到另一側「\(counterpart.locationText)」") {
                    app.transferToCounterpart(from: pane)
                }
                .disabled(selection.isEmpty || !counterpart.isAvailable)
                Button("移動到另一側「\(counterpart.locationText)」") {
                    app.transferToCounterpart(from: pane, moveAfter: true)
                }
                .disabled(selection.isEmpty || !counterpart.isAvailable)
                Button("鏡像同步資料夾到另一側…") {
                    app.requestMirror(selection, from: pane, to: counterpart)
                }
                .disabled(selection.isEmpty || !selection.allSatisfy(\.isDirectoryLike) || !counterpart.isAvailable)
            }
            Divider()
            Button(pane.kind == .local ? "移到垃圾桶" : "刪除…", role: .destructive) {
                app.requestDelete(selection, in: pane)
            }
            .disabled(selection.isEmpty)
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }

        Menu {
            Button("左右分割") { app.splitPane(pane, axis: .horizontal) }
            Button("上下分割") { app.splitPane(pane, axis: .vertical) }
            Divider()
            Button("關閉此面板") { app.closePane(pane) }
                .disabled(app.panes.count == 1)
        } label: {
            Label("分割", systemImage: "rectangle.split.2x1")
        }
        .help("把目前面板分成兩個，各自可以顯示本機或不同主機")

        Button {
            app.sheet = .runCommand(pane.id)
        } label: {
            Label("執行指令", systemImage: "terminal")
        }
        .help("在目前資料夾執行一行指令（⌘E）")
        .disabled(!pane.isAvailable)

        Button {
            app.openTerminal(for: pane)
        } label: {
            Label("終端機", systemImage: "apple.terminal")
        }
        .help("在 Terminal.app 開啟目前資料夾（⇧⌘T）")
        .disabled(!pane.isAvailable)

        Button {
            app.openInIDE(pane)
        } label: {
            Label(app.ideName, systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .help("在 \(app.ideName) 開啟目前資料夾；遠端面板會透過 Remote-SSH 開啟（⌥⌘O）")
        .disabled(!pane.isAvailable)

        Button {
            app.showBottomPanel.toggle()
        } label: {
            Label("面板", systemImage: app.showBottomPanel ? "rectangle.bottomthird.inset.filled" : "rectangle")
        }
        .help("顯示／隱藏傳輸與指令紀錄面板")
    }
}

// MARK: - Sheets

struct SheetRouter: View {
    @Environment(AppState.self) private var app
    let kind: SheetKind

    var body: some View {
        switch kind {
        case let .hostEditor(profile):
            HostEditorView(profile: profile)
        case let .password(profile, message, paneID):
            PasswordPromptView(profile: profile, message: message, paneID: paneID)
        case .importSSHConfig:
            ImportSSHConfigView()
        case let .newFolder(paneID):
            if let pane = app.pane(paneID) {
                NameInputSheet(title: "在「\(pane.title)」建立資料夾", prompt: "資料夾名稱", initialValue: "", submitLabel: "建立") { name in
                    app.createFolder(named: name, in: pane)
                }
            }
        case let .rename(paneID, entry):
            if let pane = app.pane(paneID) {
                NameInputSheet(title: "重新命名「\(entry.name)」", prompt: "新名稱", initialValue: entry.name, submitLabel: "重新命名") { name in
                    app.rename(entry, to: name, in: pane)
                }
            }
        case let .chmod(paneID, entries):
            if let pane = app.pane(paneID) {
                ChmodSheet(entries: entries) { mode, recursive in
                    app.chmod(entries, mode: mode, recursive: recursive, in: pane)
                }
            }
        case let .compress(paneID, entries):
            if let pane = app.pane(paneID) {
                CompressSheet(entries: entries, tools: pane.provider?.availableTools ?? []) { kind, name in
                    app.compress(entries, kind: kind, archiveName: name, in: pane)
                }
            }
        case let .extract(paneID, entry):
            if let pane = app.pane(paneID) {
                ExtractSheet(entry: entry) { intoSubfolder in
                    app.extract(entry, intoSubfolder: intoSubfolder, in: pane)
                }
            }
        case let .runCommand(paneID):
            if let pane = app.pane(paneID) {
                RunCommandSheet(pane: pane)
            }
        case let .syncRule(rule):
            SyncRuleEditorSheet(rule: rule)
        case let .addBookmark(paneID):
            if let pane = app.pane(paneID) {
                NameInputSheet(title: "加入書籤：\(pane.locationText)", prompt: "書籤名稱", initialValue: PathUtil.name(pane.path), submitLabel: "加入") { name in
                    app.bookmarks.add(pane: pane, name: name)
                }
            }
        case .bookmarks:
            BookmarkManagerSheet()
        case let .pullReview(request):
            PullReviewSheet(request: request)
        }
    }
}
