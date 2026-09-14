import AppKit
import SwiftUI

// MARK: - Auto sync

struct SyncListView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.syncs.sessions.isEmpty {
            VStack(spacing: 6) {
                Text("自動同步會監看本機資料夾，內容一有變動就用 rsync 推到指定主機的資料夾。")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Text("按「新增規則…」，或在本機面板對資料夾按右鍵選「監看此資料夾並自動同步到另一側…」。")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(app.syncs.sessions) { session in
                    SyncSessionRow(session: session)
                }
            }
            .listStyle(.inset)
        }
    }
}

struct SyncSessionRow: View {
    @Environment(AppState.self) private var app
    let session: SyncSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { session.rule.enabled },
                    set: { app.syncs.setEnabled(session, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.title2)
                    .foregroundStyle(stateColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.rule.displayName)
                        .bold()
                    Text("\(session.rule.localPath) → \(hostName)：\(session.rule.remotePath)" + (session.rule.mirror ? "（鏡像，--delete）" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(session.statusText)
                        .font(.caption)
                        .foregroundStyle(stateColor)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                if session.state == .syncing {
                    ProgressView().controlSize(.small)
                }
                Button("立即同步") { app.syncs.syncNow(session) }
                    .disabled(!session.rule.enabled || session.state == .syncing)
                Button("檢查遠端變更…") { review() }
                    .disabled(session.rule.profileID == nil || app.connections[session.rule.profileID!] == nil)
                    .help("列出遠端新增／修改而本機沒有的檔案，勾選後才下載回本機")
                Button("編輯…") { app.sheet = .syncRule(session.rule) }
                Button {
                    app.syncs.remove(session.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("刪除這條規則（不會刪除任何檔案）")
            }
            .controlSize(.small)
            if let job = session.job, job.state == .running, let fraction = job.progress.overallFraction {
                ProgressView(value: fraction)
                    .padding(.leading, 56)
            }
        }
        .padding(.vertical, 3)
    }

    private var hostName: String {
        session.rule.profileID.flatMap { app.profiles.profile(id: $0)?.displayName } ?? "（主機已刪除）"
    }

    private func review() {
        guard let profileID = session.rule.profileID else { return }
        app.sheet = .pullReview(PullReviewRequest(
            profileID: profileID, remotePath: session.rule.remotePath, localPath: session.rule.localPath,
            mirror: false, excludes: session.rule.excludes, ruleID: session.rule.id
        ))
    }

    private var stateColor: Color {
        switch session.state {
        case .disabled: return .gray
        case .waitingForConnection: return .orange
        case .idle: return session.pendingSync ? .orange : .green
        case .syncing: return .accentColor
        case .failed: return .red
        }
    }
}

struct SyncRuleEditorSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var rule: SyncRule
    @State private var excludesText: String
    @State private var submitted = false
    private let isNew: Bool

    init(rule: SyncRule?) {
        let initial = rule ?? SyncRule()
        _rule = State(initialValue: initial)
        _excludesText = State(initialValue: initial.excludes.joined(separator: "\n"))
        isNew = rule == nil
    }

    private var localPanes: [PaneModel] { app.panes.filter { $0.kind == .local && $0.isAvailable } }
    private var remotePanes: [PaneModel] { app.panes.filter { $0.kind == .remote && $0.isAvailable && $0.profileID == rule.profileID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "新增自動同步規則" : "編輯自動同步規則")
                .font(.title2)
                .bold()
            Form {
                TextField("名稱", text: $rule.name, prompt: Text("可留空，預設用資料夾名稱"))
                HStack {
                    TextField("本機資料夾", text: $rule.localPath, prompt: Text("/Users/…/project"))
                    Button("選擇…") { pickLocalFolder() }
                    if !localPanes.isEmpty {
                        Menu("用面板路徑") {
                            ForEach(localPanes) { pane in
                                Button(pane.path) { rule.localPath = pane.path }
                            }
                        }
                        .fixedSize()
                    }
                }
                Picker("主機", selection: $rule.profileID) {
                    Text("請選擇").tag(UUID?.none)
                    ForEach(app.profiles.profiles) { profile in
                        Text(profile.displayName + "  " + profile.summary).tag(UUID?.some(profile.id))
                    }
                }
                HStack {
                    TextField("遠端資料夾", text: $rule.remotePath, prompt: Text("/home/user/project（內容會同步到這裡）"))
                    if !remotePanes.isEmpty {
                        Menu("用面板路徑") {
                            ForEach(remotePanes) { pane in
                                Button(pane.path) { rule.remotePath = pane.path }
                            }
                        }
                        .fixedSize()
                    }
                }
                Toggle("鏡像：刪除遠端多出來的檔案（rsync --delete）", isOn: $rule.mirror)
                if rule.mirror {
                    Text("遠端資料夾內不存在於本機的檔案會被刪除，請確認遠端路徑正確。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("額外排除樣式（每行一個；設定中的全域排除也會套用）")
                    TextEditor(text: $excludesText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 70)
                }
                Toggle("啟用", isOn: $rule.enabled)
            }
            .formStyle(.grouped)
            .frame(height: 400)
            Text("儲存後會先做一次完整同步，之後本機資料夾內任何變動（含子資料夾）約 1 秒後自動推送。遠端的變更不會自動拉回：按規則列的「檢查遠端變更…」列出遠端新增或修改的檔案，勾選後才下載。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "建立並同步" : "儲存") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!normalized.isValid)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private var normalized: SyncRule {
        var result = rule
        result.name = rule.name.trimmingCharacters(in: .whitespaces)
        result.localPath = PathUtil.expandTilde(rule.localPath.trimmingCharacters(in: .whitespaces))
        while result.localPath.count > 1, result.localPath.hasSuffix("/") { result.localPath.removeLast() }
        result.remotePath = rule.remotePath.trimmingCharacters(in: .whitespaces)
        while result.remotePath.count > 1, result.remotePath.hasSuffix("/") { result.remotePath.removeLast() }
        result.excludes = excludesText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return result
    }

    private func submit() {
        guard !submitted, normalized.isValid else { return }
        // Push needs the watched folder itself; pull only needs its parent (rsync creates the folder).
        let required = normalized.localPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: required, isDirectory: &isDirectory), isDirectory.boolValue else {
            app.presentAlert(title: "本機資料夾不存在", message: required)
            return
        }
        submitted = true
        dismiss()
        app.syncs.upsert(normalized)
        app.showBottomPanel = true
        app.bottomTab = .syncs
    }

    private func pickLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "選擇要監看的本機資料夾"
        if panel.runModal() == .OK, let url = panel.url {
            rule.localPath = url.path
        }
    }
}

// MARK: - Host resources

struct ResourcesView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var monitor = app.resources
        if app.connections.isEmpty {
            VStack {
                Text("連上主機後，這裡會顯示負載、記憶體、磁碟、GPU 與最耗 CPU 的程序。")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(app.connections.values.sorted { $0.profile.displayName < $1.profile.displayName }, id: \.profile.id) { connection in
                        HostResourceCard(connection: connection)
                    }
                }
                .padding(10)
            }
            .task(id: monitor.autoRefresh) {
                guard monitor.autoRefresh else { return }
                while !Task.isCancelled {
                    await app.resources.refreshAll()
                    try? await Task.sleep(for: .seconds(max(app.resources.interval, 1)))
                }
            }
        }
    }
}

struct HostResourceCard: View {
    @Environment(AppState.self) private var app
    let connection: RemoteConnection

    private var profileID: UUID { connection.profile.id }

    var body: some View {
        let snapshot = app.resources.snapshots[profileID]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "server.rack")
                Text(connection.profile.displayName).font(.headline)
                Text(connection.profile.summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let snapshot {
                    Text("更新 \(snapshot.sampledAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("計算目前資料夾大小") { app.resources.measureFolder(profileID: profileID) }
                    .controlSize(.small)
            }
            if let error = app.resources.errors[profileID] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let snapshot {
                if !snapshot.uptime.isEmpty {
                    Text(snapshot.uptime.trimmingCharacters(in: .whitespaces))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("CPU")
                        MeterView(fraction: snapshot.cpuFraction, color: .blue)
                        Text(loadText(snapshot)).monospacedDigit()
                    }
                    GridRow {
                        Text("記憶體")
                        MeterView(fraction: snapshot.memoryUsedFraction, color: .purple)
                        Text(memoryText(snapshot)).monospacedDigit()
                    }
                    GridRow {
                        Text("磁碟")
                        MeterView(fraction: snapshot.diskUsedFraction, color: .orange)
                        Text(diskText(snapshot)).monospacedDigit().lineLimit(1)
                    }
                    ForEach(snapshot.gpus) { gpu in
                        GridRow {
                            Text("GPU \(gpu.index)")
                            VStack(spacing: 3) {
                                MeterView(fraction: Double(gpu.utilization) / 100, color: .green)
                                MeterView(fraction: gpu.memoryTotalMB > 0 ? Double(gpu.memoryUsedMB) / Double(gpu.memoryTotalMB) : nil, color: .teal)
                            }
                            Text("\(gpu.name)  使用率 \(gpu.utilization)%  記憶體 \(gpu.memoryUsedMB)/\(gpu.memoryTotalMB) MB  \(gpu.temperature)°C")
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                }
                .font(.caption)
                if let size = app.resources.folderSizes[profileID] {
                    Text("資料夾大小：\(size)").font(.caption)
                }
                if !snapshot.topProcesses.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("最耗 CPU 的程序").font(.caption).bold()
                        ForEach(snapshot.topProcesses) { process in
                            Text(String(format: "%6d  %-10@  CPU %5.1f%%  MEM %5.1f%%  %@", process.pid, process.user as NSString, process.cpu, process.memory, process.command as NSString))
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                        }
                    }
                }
            } else if app.resources.errors[profileID] == nil {
                HStack { ProgressView().controlSize(.small); Text("讀取中…").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func loadText(_ snapshot: HostResources) -> String {
        let load = snapshot.load.map { String(format: "%.2f", $0) }.joined(separator: " / ")
        return snapshot.cpuCount > 0 ? "負載 \(load)（\(snapshot.cpuCount) 核）" : "負載 \(load)"
    }

    private func memoryText(_ snapshot: HostResources) -> String {
        guard snapshot.memoryTotalKB > 0 else { return "—" }
        let total = FileEntry.byteFormatter.string(fromByteCount: snapshot.memoryTotalKB * 1024)
        guard snapshot.memoryAvailableKB >= 0 else { return "總計 \(total)" }
        let used = FileEntry.byteFormatter.string(fromByteCount: (snapshot.memoryTotalKB - snapshot.memoryAvailableKB) * 1024)
        return "\(used) / \(total)"
    }

    private func diskText(_ snapshot: HostResources) -> String {
        guard snapshot.diskTotalKB > 0 else { return "—" }
        let used = FileEntry.byteFormatter.string(fromByteCount: snapshot.diskUsedKB * 1024)
        let total = FileEntry.byteFormatter.string(fromByteCount: snapshot.diskTotalKB * 1024)
        return "\(used) / \(total)  \(snapshot.diskMount)"
    }
}

struct MeterView: View {
    let fraction: Double?
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                if let fraction {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(fraction > 0.9 ? Color.red : color)
                        .frame(width: max(2, geometry.size.width * min(max(fraction, 0), 1)))
                }
            }
        }
        .frame(width: 160, height: 8)
    }
}

// MARK: - Bookmarks

struct BookmarkMenu: View {
    @Environment(AppState.self) private var app
    let pane: PaneModel

    var body: some View {
        Menu {
            let mine = app.bookmarks.bookmarks(for: pane)
            let elsewhere = app.bookmarks.bookmarksElsewhere(for: pane)
            let recents = app.bookmarks.recents(for: pane)
            Section("書籤") {
                if mine.isEmpty {
                    Text("這個位置還沒有書籤")
                }
                ForEach(mine) { bookmark in
                    Button {
                        app.openBookmark(bookmark, in: pane)
                    } label: {
                        Label("\(bookmark.name)  \(bookmark.path)", systemImage: "bookmark.fill")
                    }
                }
            }
            if !elsewhere.isEmpty {
                Section("其他位置") {
                    ForEach(elsewhere) { bookmark in
                        Button {
                            app.openBookmark(bookmark, in: pane)
                        } label: {
                            Label("\(bookmarkLocation(bookmark))：\(bookmark.name)  \(bookmark.path)", systemImage: bookmark.kind == .local ? "desktopcomputer" : "server.rack")
                        }
                    }
                }
            }
            if !recents.isEmpty {
                Section("最近位置") {
                    ForEach(recents, id: \.self) { recent in
                        Button(recent.path) { pane.navigate(to: recent.path) }
                    }
                }
            }
            Divider()
            Button("加入目前路徑為書籤…") { app.sheet = .addBookmark(pane.id) }
                .disabled(!pane.isAvailable)
            Button("管理書籤…") { app.sheet = .bookmarks }
        } label: {
            Image(systemName: app.bookmarks.isBookmarked(pane) ? "bookmark.fill" : "bookmark")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("書籤與最近位置")
    }

    private func bookmarkLocation(_ bookmark: Bookmark) -> String {
        switch bookmark.kind {
        case .local: return "本機"
        case .remote: return bookmark.profileID.flatMap { app.profiles.profile(id: $0)?.displayName } ?? "已刪除的主機"
        }
    }
}

struct BookmarkManagerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("管理書籤").font(.headline)
            if app.bookmarks.bookmarks.isEmpty {
                Text("尚無書籤。在面板路徑列的書籤選單選「加入目前路徑為書籤…」。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List {
                    ForEach(app.bookmarks.bookmarks) { bookmark in
                        HStack {
                            Image(systemName: bookmark.kind == .local ? "desktopcomputer" : "server.rack")
                            TextField("名稱", text: Binding(
                                get: { bookmark.name },
                                set: { app.bookmarks.rename(bookmark.id, to: $0) }
                            ))
                            .frame(width: 160)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(locationName(bookmark)).font(.caption).foregroundStyle(.secondary)
                                Text(bookmark.path).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button {
                                app.bookmarks.remove(bookmark.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onMove { app.bookmarks.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(height: 300)
            }
            HStack {
                Button("清除最近位置") { app.bookmarks.clearRecents() }
                    .disabled(app.bookmarks.recents.isEmpty)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func locationName(_ bookmark: Bookmark) -> String {
        switch bookmark.kind {
        case .local: return "本機"
        case .remote: return bookmark.profileID.flatMap { app.profiles.profile(id: $0)?.displayName } ?? "已刪除的主機"
        }
    }
}
