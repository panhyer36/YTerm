import SwiftUI
import UniformTypeIdentifiers

struct FilePaneView: View {
    @Environment(AppState.self) private var app
    @Bindable var pane: PaneModel
    @State private var pathDraft = ""
    @State private var isDropTargeted = false

    private var isActive: Bool { app.activePaneID == pane.id }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            if pane.isAvailable {
                navigationBar
                Divider()
                tableArea
                Divider()
                statusBar
            } else {
                RemotePlaceholderView(pane: pane)
            }
        }
        .onAppear { pathDraft = pane.path }
        .onChange(of: pane.path) { _, newValue in
            pathDraft = newValue
            app.bookmarks.recordRecent(pane)
        }
        .onChange(of: pane.selection) { _, newValue in
            if !newValue.isEmpty { app.activate(pane) }
        }
    }

    // MARK: Title

    private var titleBar: some View {
        HStack(spacing: 6) {
            PaneLocationMenu(pane: pane)
            if pane.kind == .remote, let profileID = pane.profileID, let profile = app.profiles.profile(id: profileID) {
                Text(profile.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if pane.kind == .local {
                Text(Host.current().localizedName ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                app.splitPane(pane, axis: .horizontal)
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .help("左右分割（⌘\\）")
            Button {
                app.splitPane(pane, axis: .vertical)
            } label: {
                Image(systemName: "rectangle.split.1x2")
            }
            .help("上下分割（⇧⌘\\）")
            Button {
                app.closePane(pane)
            } label: {
                Image(systemName: "xmark")
            }
            .disabled(app.panes.count == 1)
            .help("關閉此面板（⇧⌘W）")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { app.activate(pane) }
    }

    // MARK: Navigation

    private var navigationBar: some View {
        HStack(spacing: 6) {
            Button { pane.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!pane.canGoBack)
                .help("上一頁")
            Button { pane.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!pane.canGoForward)
                .help("下一頁")
            Button { pane.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(!pane.canGoUp)
                .help("上一層")
            Button { pane.goHome() } label: { Image(systemName: "house") }
                .help("家目錄")
            BookmarkMenu(pane: pane)
            TextField("路徑", text: $pathDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit {
                    app.activate(pane)
                    pane.navigate(to: pathDraft)
                }
            Button { pane.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("重新整理（⌘R）")
            Toggle(isOn: $pane.showHidden) {
                Image(systemName: pane.showHidden ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .help("顯示隱藏檔")
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    // MARK: Table

    private var tableArea: some View {
        Table(of: FileEntry.self, selection: $pane.selection, sortOrder: $pane.sortOrder) {
            TableColumn("名稱", sortUsing: KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)) { entry in
                NameCell(entry: entry)
            }
            .width(min: 160, ideal: 260)

            TableColumn("大小", sortUsing: KeyPathComparator(\FileEntry.sizeSortKey)) { entry in
                Text(entry.sizeText)
                    .foregroundStyle(entry.isDirectoryLike ? .secondary : .primary)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 80)

            TableColumn("修改時間", sortUsing: KeyPathComparator(\FileEntry.modified)) { entry in
                Text(entry.modifiedText)
                    .monospacedDigit()
            }
            .width(min: 110, ideal: 130)

            TableColumn("權限", sortUsing: KeyPathComparator(\FileEntry.mode)) { entry in
                Text(entry.permissionText)
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 80, ideal: 92)

            TableColumn("擁有者", sortUsing: KeyPathComparator(\FileEntry.owner)) { entry in
                Text(entry.ownerText)
            }
            .width(min: 60, ideal: 110)
        } rows: {
            ForEach(pane.visibleEntries) { entry in
                TableRow(entry)
                    .itemProvider { app.dragItemProvider(for: entry, in: pane) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            PaneContextMenu(pane: pane, ids: ids)
        } primaryAction: { ids in
            app.activate(pane)
            app.open(ids, in: pane)
        }
        .onDrop(of: [UTType.fileURL, RemoteDragPayload.type], isTargeted: $isDropTargeted) { providers in
            app.handleDrop(providers, onto: pane)
            return true
        }
        .simultaneousGesture(TapGesture().onEnded { app.activate(pane) })
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if pane.isLoading && pane.entries.isEmpty && pane.errorMessage == nil {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .overlay {
            if let message = pane.errorMessage {
                errorOverlay(message)
            }
        }
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 360)
            HStack {
                Button("上一層") { pane.goUp() }.disabled(!pane.canGoUp)
                Button("家目錄") { pane.goHome() }
                Button("重試") { pane.reload() }
            }
            .controlSize(.small)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding()
    }

    // MARK: Status

    private var statusBar: some View {
        HStack {
            Text(pane.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if pane.isLoading {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// The pane's location: the local disk or one of the saved hosts.
struct PaneLocationMenu: View {
    @Environment(AppState.self) private var app
    let pane: PaneModel

    var body: some View {
        Menu {
            Button {
                app.setPaneLocal(pane)
            } label: {
                Label("本機", systemImage: "desktopcomputer")
            }
            Divider()
            ForEach(app.profiles.profiles) { profile in
                Button {
                    app.connect(to: profile, in: pane)
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
            if let profileID = pane.profileID, let profile = app.profiles.profile(id: profileID) {
                Divider()
                Button("編輯「\(profile.displayName)」…") { app.sheet = .hostEditor(profile) }
                if app.connections[profileID] != nil {
                    Button("中斷「\(profile.displayName)」") { app.disconnect(profileID: profileID) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: pane.kind == .local ? "desktopcomputer" : (pane.isAvailable ? "network" : "server.rack"))
                    .foregroundStyle(app.activePaneID == pane.id ? Color.accentColor : Color.secondary)
                Text(pane.title)
                    .font(.headline)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("切換這個面板顯示本機或哪一台主機")
    }
}

struct NameCell: View {
    let entry: FileEntry

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: IconCache.shared.icon(for: entry))
                .resizable()
                .frame(width: 16, height: 16)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if let target = entry.linkTarget {
                Text("→ \(target)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct PaneContextMenu: View {
    @Environment(AppState.self) private var app
    let pane: PaneModel
    let ids: Set<String>

    var body: some View {
        let entries = pane.entries(for: ids)
        let counterpart = app.counterpart(of: pane)
        if entries.isEmpty {
            Button("新增資料夾…") { app.sheet = .newFolder(pane.id) }
            Button("重新整理") { pane.reload() }
            Button("執行指令…") { app.sheet = .runCommand(pane.id) }
            Button("在終端機開啟此資料夾") { app.openTerminal(for: pane) }
            Button("在 \(app.ideName) 開啟此資料夾") { app.openInIDE(pane) }
            if pane.kind == .local {
                Button("在 Finder 顯示") { app.revealInFinder([], in: pane) }
            }
            if pane.kind == .local {
                Button("把目前資料夾設為自動同步來源…") { app.sheet = .syncRule(syncRule(for: pane.path)) }
            }
            Divider()
            Button("左右分割") { app.splitPane(pane, axis: .horizontal) }
            Button("上下分割") { app.splitPane(pane, axis: .vertical) }
        } else {
            if entries.count == 1, entries[0].isDirectoryLike {
                Button("進入資料夾") { pane.enter(entries[0]) }
                if let counterpart {
                    Button("在另一側開啟此資料夾") {
                        if counterpart.kind == pane.kind, counterpart.profileID == pane.profileID, counterpart.isAvailable {
                            counterpart.navigate(to: entries[0].path)
                        } else {
                            let newPane = app.splitPane(pane, axis: .horizontal)
                            newPane.navigate(to: entries[0].path)
                        }
                    }
                }
            }
            if pane.kind == .local, entries.contains(where: { !$0.isDirectoryLike }) {
                Button("用預設程式開啟") { app.open(ids, in: pane) }
            }
            if pane.kind == .local, entries.count == 1, entries[0].isDirectoryLike {
                Button("監看此資料夾並自動同步到另一側…") { app.sheet = .syncRule(syncRule(for: entries[0].path)) }
            }
            if pane.kind == .remote, entries.count == 1, entries[0].isDirectoryLike {
                Button("檢查變更並選擇下載到本機…") { app.sheet = .pullReview(pullRequest(for: entries[0].path)) }
            }
            if pane.kind == .remote, entries.contains(where: { !$0.isDirectoryLike }) {
                Button("在本機編輯（儲存後自動上傳）") { app.openRemoteFilesForEditing(entries, from: pane) }
            }
            if let counterpart, counterpart.isAvailable {
                Divider()
                Button("\(transferVerb(to: counterpart))到「\(counterpart.locationText)」") {
                    app.transfer(entries, from: pane, to: counterpart)
                }
                Button("移動到「\(counterpart.locationText)」") {
                    app.transfer(entries, from: pane, to: counterpart, moveAfter: true)
                }
                if entries.allSatisfy(\.isDirectoryLike) {
                    Button("鏡像同步資料夾內容到「\(counterpart.locationText)」…") {
                        app.requestMirror(entries, from: pane, to: counterpart)
                    }
                }
            }
            Divider()
            if entries.count == 1 {
                Button("重新命名…") { app.sheet = .rename(pane.id, entries[0]) }
            }
            Button("變更權限…") { app.sheet = .chmod(pane.id, entries) }
            Button("壓縮…") { app.sheet = .compress(pane.id, entries) }
            if entries.count == 1, entries[0].isArchive {
                Button("解壓縮…") { app.sheet = .extract(pane.id, entries[0]) }
            }
            Divider()
            Button("複製路徑") { app.copyPaths(entries) }
            if pane.kind == .local {
                Button("在 Finder 顯示") { app.revealInFinder(entries, in: pane) }
            }
            Button("在終端機開啟此資料夾") { app.openTerminal(for: pane) }
            Divider()
            Button(pane.kind == .local ? "移到垃圾桶" : "刪除…", role: .destructive) {
                app.requestDelete(entries, in: pane)
            }
        }
    }

    /// Pre-fills a sync rule: this local folder → the counterpart remote pane's directory.
    private func syncRule(for localPath: String) -> SyncRule {
        var rule = SyncRule()
        rule.localPath = localPath
        if let remote = app.mostRecentPane(kind: .remote, connectedOnly: true) {
            rule.profileID = remote.profileID
            rule.remotePath = PathUtil.join(remote.path, PathUtil.name(localPath))
        } else {
            rule.profileID = app.profiles.profiles.first?.id
        }
        return rule
    }

    /// Compare this remote folder with a same-named folder in the most recent local pane.
    private func pullRequest(for remotePath: String) -> PullReviewRequest {
        let localBase = app.mostRecentPane(kind: .local)?.path ?? NSHomeDirectory()
        return PullReviewRequest(
            profileID: pane.profileID ?? UUID(), remotePath: remotePath,
            localPath: PathUtil.join(localBase, PathUtil.name(remotePath)), mirror: false, excludes: [], ruleID: nil
        )
    }

    private func transferVerb(to target: PaneModel) -> String {
        switch (pane.kind, target.kind) {
        case (.local, .remote): return "上傳"
        case (.remote, .local): return "下載"
        default: return "複製"
        }
    }
}

/// Shown in a remote pane that is not connected: pick a host (or turn the pane into a local one).
struct RemotePlaceholderView: View {
    @Environment(AppState.self) private var app
    let pane: PaneModel

    var body: some View {
        VStack(spacing: 14) {
            if app.isConnecting(pane), let profileID = pane.profileID, let profile = app.profiles.profile(id: profileID) {
                ProgressView()
                Text("正在連線到 \(profile.displayName)…")
                Button("取消") { app.cancelConnect(pane) }
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("選擇這個面板要顯示的主機")
                    .font(.title3)
                if app.profiles.profiles.isEmpty {
                    Text("尚未新增任何主機。可以手動新增，或從 ~/.ssh/config 匯入。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(app.profiles.profiles) { profile in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text(profile.displayName).bold()
                                            if app.connections[profile.id] != nil {
                                                Text("已連線")
                                                    .font(.caption2)
                                                    .padding(.horizontal, 4)
                                                    .background(Color.green.opacity(0.2), in: Capsule())
                                            }
                                        }
                                        Text(profile.summary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("編輯") { app.sheet = .hostEditor(profile) }
                                        .controlSize(.small)
                                    Button(app.connections[profile.id] != nil ? "開啟" : "連線") { app.connect(to: profile, in: pane) }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                }
                                .padding(8)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(maxWidth: 460, maxHeight: 260)
                }
                HStack {
                    Button("新增主機…") { app.sheet = .hostEditor(nil) }
                    Button("從 ~/.ssh/config 匯入…") { app.sheet = .importSSHConfig }
                    Button("改為本機") { app.setPaneLocal(pane) }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { app.activate(pane) }
    }
}
