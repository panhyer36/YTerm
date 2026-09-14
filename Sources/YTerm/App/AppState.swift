import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

typealias PaneID = UUID

enum SplitAxis: String, Hashable, Sendable {
    /// Panes side by side.
    case horizontal
    /// Panes stacked.
    case vertical
}

/// Binary tree describing how the window is divided into panes.
indirect enum PaneLayout: Hashable {
    case pane(PaneID)
    case split(axis: SplitAxis, first: PaneLayout, second: PaneLayout)

    var paneIDs: [PaneID] {
        switch self {
        case let .pane(id): return [id]
        case let .split(_, first, second): return first.paneIDs + second.paneIDs
        }
    }

    func splitting(_ target: PaneID, axis: SplitAxis, newPane: PaneID) -> PaneLayout {
        switch self {
        case let .pane(id):
            return id == target ? .split(axis: axis, first: .pane(id), second: .pane(newPane)) : self
        case let .split(existingAxis, first, second):
            return .split(
                axis: existingAxis,
                first: first.splitting(target, axis: axis, newPane: newPane),
                second: second.splitting(target, axis: axis, newPane: newPane)
            )
        }
    }

    func removing(_ target: PaneID) -> PaneLayout? {
        switch self {
        case let .pane(id):
            return id == target ? nil : self
        case let .split(axis, first, second):
            switch (first.removing(target), second.removing(target)) {
            case (nil, nil): return nil
            case (nil, let remaining?), (let remaining?, nil): return remaining
            case let (newFirst?, newSecond?): return .split(axis: axis, first: newFirst, second: newSecond)
            }
        }
    }
}

enum BottomTab: String, CaseIterable, Identifiable {
    case transfers = "傳輸"
    case log = "指令紀錄"
    case edits = "遠端編輯"
    case syncs = "自動同步"
    case resources = "主機資源"
    var id: String { rawValue }
}

enum SheetKind: Identifiable {
    case hostEditor(HostProfile?)
    case password(HostProfile, message: String?, paneID: PaneID)
    case importSSHConfig
    case newFolder(PaneID)
    case rename(PaneID, FileEntry)
    case chmod(PaneID, [FileEntry])
    case compress(PaneID, [FileEntry])
    case extract(PaneID, FileEntry)
    case runCommand(PaneID)
    case syncRule(SyncRule?)
    case addBookmark(PaneID)
    case bookmarks
    case pullReview(PullReviewRequest)

    var id: String {
        switch self {
        case let .hostEditor(profile): return "hostEditor-\(profile?.id.uuidString ?? "new")"
        case let .password(profile, _, _): return "password-\(profile.id.uuidString)"
        case .importSSHConfig: return "importSSHConfig"
        case let .newFolder(pane): return "newFolder-\(pane)"
        case let .rename(pane, entry): return "rename-\(pane)-\(entry.path)"
        case let .chmod(pane, _): return "chmod-\(pane)"
        case let .compress(pane, _): return "compress-\(pane)"
        case let .extract(pane, entry): return "extract-\(pane)-\(entry.path)"
        case let .runCommand(pane): return "runCommand-\(pane)"
        case let .syncRule(rule): return "syncRule-\(rule?.id.uuidString ?? "new")"
        case let .addBookmark(pane): return "addBookmark-\(pane)"
        case .bookmarks: return "bookmarks"
        case let .pullReview(request): return "pullReview-\(request.id)"
        }
    }
}

struct DeleteRequest: Identifiable {
    let id = UUID()
    let paneID: PaneID
    let entries: [FileEntry]
}

struct MirrorRequest: Identifiable {
    let id = UUID()
    let sourcePaneID: PaneID
    let targetPaneID: PaneID
    let entries: [FileEntry]
}

/// Payload used when dragging rows out of a remote pane.
struct RemoteDragPayload: Codable {
    static let typeIdentifier = "com.yterm.remote-items"
    static let type = UTType(exportedAs: "com.yterm.remote-items")

    struct Item: Codable {
        var path: String
        var name: String
        var isDirectory: Bool
    }

    var profileID: UUID
    var sourcePaneID: UUID?
    var items: [Item]
}

/// Added next to the file URL when dragging rows out of a local pane, so an internal drag
/// (move) can be told apart from files dropped in from Finder (copy).
struct LocalDragPayload: Codable {
    static let typeIdentifier = "com.yterm.local-items"
    static let type = UTType(exportedAs: "com.yterm.local-items")

    var sourcePaneID: UUID
    var paths: [String]
}

extension NSItemProvider {
    func loadData(type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? AppError.general("無法讀取拖放資料"))
                }
            }
        }
    }
}

@MainActor @Observable
final class AppState {
    let log = CommandLog()
    let transfers = TransferManager()
    let profiles = ProfileStore()
    let edits = EditSessionManager()
    let bookmarks = BookmarkStore()
    let syncs = SyncManager()
    let resources = ResourceMonitor()
    let localFileSystem: LocalFileSystem

    private(set) var panes: [PaneModel] = []
    var layout: PaneLayout
    var activePaneID: PaneID
    /// Panes in the order they were last used (most recent last).
    private var activationOrder: [PaneID] = []

    /// Open ssh connections keyed by host profile id; several panes may share one.
    private(set) var connections: [UUID: RemoteConnection] = [:]
    private(set) var connectingProfiles: Set<UUID> = []

    var rsyncFlavor: RsyncFlavor?
    var sheet: SheetKind?
    var alert: AlertInfo?
    var deleteRequest: DeleteRequest?
    var mirrorRequest: MirrorRequest?
    var showBottomPanel = true
    var bottomTab: BottomTab = .transfers

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var connectTasks: [PaneID: Task<Void, Never>] = [:]

    init() {
        AppSettings.registerDefaults()
        localFileSystem = LocalFileSystem(log: log)
        let local = PaneModel(kind: .local, title: "本機")
        let remote = PaneModel(kind: .remote, title: "遠端")
        panes = [local, remote]
        layout = .split(axis: .horizontal, first: .pane(local.id), second: .pane(remote.id))
        activePaneID = local.id
        activationOrder = [remote.id, local.id]
        for pane in panes { pane.showHidden = AppSettings.showHiddenFiles }
        local.attach(provider: localFileSystem, startPath: localStartPath)
        transfers.maxConcurrent = AppSettings.maxConcurrentTransfers
        transfers.onJobFinished = { [weak self] _ in self?.scheduleRefresh() }
        edits.app = self
        syncs.app = self
        resources.app = self
        syncs.activate()
        Task.detached(priority: .background) { EditSessionManager.removeStaleDirectories(olderThan: 2 * 24 * 3600) }
        Task { await localFileSystem.detectTools() }
        Task { await detectRsync() }
    }

    private var localStartPath: String {
        let start = AppSettings.localStartPath
        return start.isEmpty ? NSHomeDirectory() : PathUtil.expandTilde(start)
    }

    func detectRsync() async {
        rsyncFlavor = await RsyncLocator.detect(customPath: AppSettings.rsyncPath)
    }

    // MARK: - Panes and layout

    func pane(_ id: PaneID) -> PaneModel? {
        panes.first { $0.id == id }
    }

    var activePane: PaneModel {
        pane(activePaneID) ?? panes[0]
    }

    func activate(_ pane: PaneModel) {
        if activePaneID != pane.id { activePaneID = pane.id }
        if activationOrder.last != pane.id {
            activationOrder.removeAll { $0 == pane.id }
            activationOrder.append(pane.id)
        }
    }

    /// The pane "on the other side": the most recently used pane other than `pane`.
    func counterpart(of pane: PaneModel) -> PaneModel? {
        for id in activationOrder.reversed() where id != pane.id {
            if let other = self.pane(id) { return other }
        }
        return panes.first { $0.id != pane.id }
    }

    func mostRecentPane(kind: PaneSide, connectedOnly: Bool = false) -> PaneModel? {
        for id in activationOrder.reversed() {
            if let candidate = pane(id), candidate.kind == kind, !connectedOnly || candidate.isAvailable {
                return candidate
            }
        }
        return panes.first { $0.kind == kind && (!connectedOnly || $0.isAvailable) }
    }

    /// Splits `pane`; the new pane shows the same location.
    @discardableResult
    func splitPane(_ pane: PaneModel, axis: SplitAxis) -> PaneModel {
        let newPane = PaneModel(kind: pane.kind, title: pane.title, profileID: pane.profileID)
        newPane.showHidden = pane.showHidden
        panes.append(newPane)
        layout = layout.splitting(pane.id, axis: axis, newPane: newPane.id)
        if let provider = pane.provider {
            newPane.attach(provider: provider, startPath: pane.path)
        }
        activate(newPane)
        return newPane
    }

    func closePane(_ pane: PaneModel) {
        guard panes.count > 1, let newLayout = layout.removing(pane.id) else { return }
        connectTasks[pane.id]?.cancel()
        connectTasks[pane.id] = nil
        layout = newLayout
        pane.detach()
        panes.removeAll { $0.id == pane.id }
        activationOrder.removeAll { $0 == pane.id }
        if activePaneID == pane.id {
            activePaneID = activationOrder.last ?? panes[0].id
        }
        releaseUnusedConnections()
    }

    func activateNextPane() {
        let ids = layout.paneIDs
        guard let index = ids.firstIndex(of: activePaneID), let next = pane(ids[(index + 1) % ids.count]) else { return }
        activate(next)
    }

    /// Turns a pane into a local browser.
    func setPaneLocal(_ pane: PaneModel) {
        connectTasks[pane.id]?.cancel()
        connectTasks[pane.id] = nil
        let previousProfile = pane.profileID
        pane.kind = .local
        pane.profileID = nil
        pane.title = "本機"
        pane.attach(provider: localFileSystem, startPath: localStartPath)
        activate(pane)
        if previousProfile != nil { releaseUnusedConnections() }
    }

    // MARK: - Connections

    func connection(for pane: PaneModel) -> RemoteConnection? {
        pane.profileID.flatMap { connections[$0] }
    }

    func isConnecting(_ pane: PaneModel) -> Bool {
        pane.profileID.map { connectingProfiles.contains($0) } ?? false
    }

    var isConnected: Bool { !connections.isEmpty }

    /// Connect `pane` to `profile`, reusing an open connection to the same host when there is one.
    func connect(to profile: HostProfile, in pane: PaneModel, password: String? = nil, rememberPassword: Bool = false) {
        connectTasks[pane.id]?.cancel()
        connectTasks[pane.id] = nil
        let previousProfile = pane.profileID
        pane.kind = .remote
        pane.profileID = profile.id
        pane.title = profile.displayName
        pane.detach()
        activate(pane)
        if previousProfile != nil, previousProfile != profile.id { releaseUnusedConnections() }

        if let existing = connections[profile.id] {
            attach(pane, to: existing)
            return
        }

        var effectivePassword = password
        if effectivePassword == nil, profile.usesPassword {
            effectivePassword = KeychainStore.load(account: profile.id.uuidString)
            if effectivePassword == nil {
                sheet = .password(profile, message: "鑰匙圈中找不到已儲存的密碼，請重新輸入。", paneID: pane.id)
                return
            }
        }
        if let password, !password.isEmpty, rememberPassword {
            do {
                try KeychainStore.save(password: password, account: profile.id.uuidString)
                var updated = profile
                updated.usesPassword = true
                profiles.upsert(updated)
            } catch {
                presentError(error, title: "無法儲存密碼")
            }
        }

        if connectingProfiles.contains(profile.id) {
            // Another pane is already establishing this connection; this pane attaches when it is ready.
            return
        }
        connectingProfiles.insert(profile.id)
        let connection = RemoteConnection(profile: profile, password: effectivePassword, log: log)
        let paneID = pane.id

        connectTasks[paneID] = Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await connection.bootstrap()
                guard !Task.isCancelled else { return }
                self.connectingProfiles.remove(profile.id)
                self.connections[profile.id] = connection
                for waiting in self.panes where waiting.kind == .remote && waiting.profileID == profile.id && waiting.provider == nil {
                    self.attach(waiting, to: connection)
                }
                if let requester = self.pane(paneID) { self.activate(requester) }
                self.syncs.connectionDidOpen(profileID: profile.id)
                if !info.has("rsync") {
                    self.presentAlert(
                        title: "遠端主機沒有 rsync",
                        message: "已連線，但遠端找不到 rsync，將無法上傳／下載。請在遠端安裝：sudo apt install rsync"
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.connectingProfiles.remove(profile.id)
                if RemoteConnection.isAuthenticationFailure(error) {
                    let hint = effectivePassword == nil ? "金鑰驗證失敗，請輸入這台主機的密碼。" : "密碼或金鑰驗證失敗，請再試一次。"
                    self.sheet = .password(profile, message: hint, paneID: paneID)
                } else {
                    self.presentError(error, title: "連線失敗")
                }
            }
            self.connectTasks[paneID] = nil
        }
    }

    private func attach(_ pane: PaneModel, to connection: RemoteConnection) {
        let profile = connection.profile
        let info = connection.info
        let start = pane.pendingPath ?? (profile.initialPath.isEmpty
            ? info.home
            : PathUtil.normalize(profile.initialPath, relativeTo: info.home, home: info.home))
        pane.pendingPath = nil
        pane.kind = .remote
        pane.profileID = profile.id
        pane.title = profile.displayName
        pane.attach(provider: RemoteFileSystem(connection: connection), startPath: start)
    }

    /// Picks the pane a host chosen from a menu should open in: the active pane if it is a remote
    /// pane, otherwise the most recent remote pane, otherwise a new split next to the active pane.
    func connectPreferringRemotePane(_ profile: HostProfile, password: String? = nil, rememberPassword: Bool = false) {
        let target: PaneModel
        if activePane.kind == .remote {
            target = activePane
        } else if let recent = mostRecentPane(kind: .remote) {
            target = recent
        } else {
            target = splitPane(activePane, axis: .horizontal)
        }
        connect(to: profile, in: target, password: password, rememberPassword: rememberPassword)
    }

    func cancelConnect(_ pane: PaneModel) {
        connectTasks[pane.id]?.cancel()
        connectTasks[pane.id] = nil
        if let profileID = pane.profileID {
            connectingProfiles.remove(profileID)
        }
    }

    /// Closes the connection to one host; panes showing it fall back to the host chooser.
    func disconnect(profileID: UUID) {
        connectingProfiles.remove(profileID)
        for (paneID, task) in connectTasks where pane(paneID)?.profileID == profileID {
            task.cancel()
            connectTasks[paneID] = nil
        }
        transfers.cancel(connectionID: profileID)
        syncs.connectionDidClose(profileID: profileID)
        let kept = edits.stopAll(profileID: profileID)
        if !kept.isEmpty {
            presentAlert(
                title: "有尚未上傳回遠端的編輯",
                message: "已中斷連線，以下檔案的本機副本保留在暫存區：\n" + kept.map { $0.localURL.path }.joined(separator: "\n")
            )
        }
        for pane in panes where pane.kind == .remote && pane.profileID == profileID {
            pane.detach()
        }
        guard let connection = connections.removeValue(forKey: profileID) else { return }
        Task { await connection.disconnect() }
    }

    func disconnectAll() {
        for profileID in Array(connections.keys) { disconnect(profileID: profileID) }
        for profileID in Array(connectingProfiles) { disconnect(profileID: profileID) }
    }

    /// Drops connections no pane and no edit session uses any more.
    private func releaseUnusedConnections() {
        for profileID in Array(connections.keys) {
            let inUse = panes.contains { $0.kind == .remote && $0.profileID == profileID }
                || edits.sessions.contains { $0.profileID == profileID }
                || syncs.usesConnection(profileID)
            if !inUse { disconnect(profileID: profileID) }
        }
    }

    // MARK: - Alerts

    func presentError(_ error: Error, title: String = "發生錯誤") {
        alert = AlertInfo(title: title, message: error.localizedDescription)
    }

    func presentAlert(title: String, message: String) {
        alert = AlertInfo(title: title, message: message)
    }

    // MARK: - File operations

    private func perform(_ title: String, on pane: PaneModel, refreshAlso other: PaneModel? = nil, _ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                presentError(error, title: title)
            }
            pane.reload()
            other?.reload()
        }
    }

    func refreshLocalPanes() {
        for pane in panes where pane.kind == .local { pane.reload() }
    }

    func refreshPanes(profileID: UUID) {
        for pane in panes where pane.kind == .remote && pane.profileID == profileID { pane.reload() }
    }

    /// Jump to a bookmark, switching the pane to the bookmark's host or the local disk when needed.
    func openBookmark(_ bookmark: Bookmark, in pane: PaneModel) {
        if bookmark.matches(pane), pane.isAvailable {
            pane.navigate(to: bookmark.path)
            return
        }
        switch bookmark.kind {
        case .local:
            setPaneLocal(pane)
            pane.navigate(to: bookmark.path)
        case .remote:
            guard let profileID = bookmark.profileID, let profile = profiles.profile(id: profileID) else {
                presentAlert(title: "找不到主機", message: "這個書籤的主機設定已被刪除。")
                return
            }
            pane.pendingPath = bookmark.path
            connect(to: profile, in: pane)
        }
    }

    func refresh(_ pane: PaneModel? = nil) {
        if let pane { pane.reload() } else { panes.forEach { $0.reload() } }
    }

    func createFolder(named name: String, in pane: PaneModel) {
        guard let provider = pane.provider else { return }
        let target = PathUtil.join(pane.path, name)
        perform("無法建立資料夾", on: pane) {
            try await provider.makeDirectory(target)
        }
    }

    func rename(_ entry: FileEntry, to newName: String, in pane: PaneModel) {
        guard let provider = pane.provider, newName != entry.name, !newName.isEmpty else { return }
        let newPath = PathUtil.join(PathUtil.parent(entry.path), newName)
        perform("無法重新命名", on: pane) {
            if try await provider.exists(newPath) {
                throw AppError.refused("已經存在同名項目：\(newName)")
            }
            try await provider.rename(entry.path, to: newPath)
        }
    }

    func requestDelete(_ entries: [FileEntry], in pane: PaneModel) {
        guard !entries.isEmpty else { return }
        let request = DeleteRequest(paneID: pane.id, entries: entries)
        if AppSettings.confirmDelete {
            deleteRequest = request
        } else {
            performDelete(request)
        }
    }

    func performDelete(_ request: DeleteRequest) {
        guard let pane = pane(request.paneID), let provider = pane.provider else { return }
        let paths = request.entries.map(\.path)
        perform("刪除失敗", on: pane) {
            try await provider.delete(paths)
        }
    }

    func chmod(_ entries: [FileEntry], mode: String, recursive: Bool, in pane: PaneModel) {
        guard let provider = pane.provider else { return }
        perform("無法變更權限", on: pane) {
            try await provider.chmod(entries.map(\.path), mode: mode, recursive: recursive)
        }
    }

    func compress(_ entries: [FileEntry], kind: ArchiveKind, archiveName: String, in pane: PaneModel) {
        guard let provider = pane.provider else { return }
        let directory = pane.path
        perform("壓縮失敗", on: pane) {
            try await provider.compress(entries.map(\.name), in: directory, kind: kind, archiveName: archiveName)
        }
    }

    func extract(_ entry: FileEntry, intoSubfolder: Bool, in pane: PaneModel) {
        guard let provider = pane.provider else { return }
        let target = intoSubfolder ? PathUtil.join(pane.path, PathUtil.stripArchiveExtension(entry.name)) : pane.path
        perform("解壓縮失敗", on: pane) {
            try await provider.extract(entry.path, into: target)
        }
    }

    /// Double-click: enter directories, open local files with their app, edit remote files locally.
    func open(_ ids: Set<String>, in pane: PaneModel) {
        let entries = pane.entries(for: ids)
        guard !entries.isEmpty else { return }
        if entries.count == 1, entries[0].isDirectoryLike {
            pane.enter(entries[0])
            return
        }
        let files = entries.filter { !$0.isDirectoryLike }
        switch pane.kind {
        case .local:
            for entry in files {
                NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
            }
        case .remote:
            openRemoteFilesForEditing(files, from: pane)
        }
    }

    func copyPaths(_ entries: [FileEntry]) {
        copyText(entries.map(\.path).joined(separator: "\n"))
    }

    func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func revealInFinder(_ entries: [FileEntry], in pane: PaneModel) {
        let urls = entries.map { URL(fileURLWithPath: $0.path) }
        if urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pane.path)])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func openTerminal(for pane: PaneModel) {
        let command: String
        switch pane.kind {
        case .local:
            command = "cd " + Shell.quote(pane.path)
        case .remote:
            guard let connection = connection(for: pane) else {
                presentError(AppError.notConnected)
                return
            }
            command = connection.interactiveCommand(path: pane.path)
        }
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = [
            "-e", "tell application \"Terminal\"",
            "-e", "do script \"\(escaped)\"",
            "-e", "activate",
            "-e", "end tell",
        ]
        Task {
            let start = Date()
            do {
                let result = try await ShellRunner.run("/usr/bin/osascript", script)
                log.record(target: "Terminal", command: command, exitCode: result.exitCode, output: result.combinedText, duration: Date().timeIntervalSince(start))
                if !result.succeeded {
                    presentAlert(title: "無法開啟終端機", message: result.combinedText)
                } else {
                    bringTerminalToFront()
                }
            } catch {
                presentError(error, title: "無法開啟終端機")
            }
        }
    }

    /// Our app is frontmost, so Terminal cannot steal focus on its own: hand activation over explicitly.
    private func bringTerminalToFront() {
        guard let terminal = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first else { return }
        NSApp.yieldActivation(to: terminal)
        terminal.activate(from: NSRunningApplication.current, options: [])
    }

    // MARK: - Transfers

    func requestMirror(_ entries: [FileEntry], from source: PaneModel, to target: PaneModel) {
        let directories = entries.filter(\.isDirectoryLike)
        guard !directories.isEmpty, source.id != target.id else { return }
        mirrorRequest = MirrorRequest(sourcePaneID: source.id, targetPaneID: target.id, entries: directories)
    }

    func performMirror(_ request: MirrorRequest) {
        guard let source = pane(request.sourcePaneID), let target = pane(request.targetPaneID) else { return }
        transfer(request.entries, from: source, to: target, mirror: true)
    }

    /// Upload: most recent local pane → most recent connected remote pane. Download: the reverse.
    func transferSelection(direction: TransferDirection, moveAfter: Bool = false) {
        switch direction {
        case .upload:
            guard let source = mostRecentPane(kind: .local), let target = mostRecentPane(kind: .remote, connectedOnly: true) else { return }
            transfer(source.selectedEntries, from: source, to: target, moveAfter: moveAfter)
        case .download:
            guard let source = mostRecentPane(kind: .remote, connectedOnly: true), let target = mostRecentPane(kind: .local) else { return }
            transfer(source.selectedEntries, from: source, to: target, moveAfter: moveAfter)
        }
    }

    /// Sends the selection of `pane` to its counterpart pane.
    func transferToCounterpart(from pane: PaneModel, moveAfter: Bool = false) {
        guard let target = counterpart(of: pane) else { return }
        transfer(pane.selectedEntries, from: pane, to: target, moveAfter: moveAfter)
    }

    /// Copies (or moves) `entries` from one pane into another pane's directory, whatever the two panes show.
    func transfer(_ entries: [FileEntry], from source: PaneModel, to target: PaneModel, destinationPath: String? = nil, moveAfter: Bool = false, mirror: Bool = false) {
        guard !entries.isEmpty, target.isAvailable else { return }
        let targetDirectory = destinationPath ?? target.path
        if mirror && !entries.contains(where: \.isDirectoryLike) { return }

        switch (source.kind, target.kind) {
        case (.local, .local):
            sameHostTransfer(entries, provider: localFileSystem, source: source, target: target, targetDirectory: targetDirectory, moveAfter: moveAfter, mirror: mirror)
        case (.remote, .remote) where source.profileID == target.profileID:
            guard let provider = source.provider else {
                presentError(AppError.notConnected)
                return
            }
            sameHostTransfer(entries, provider: provider, source: source, target: target, targetDirectory: targetDirectory, moveAfter: moveAfter, mirror: mirror)
        case (.local, .remote):
            guard let connection = connection(for: target), let flavor = requireRsync(connection) else { return }
            enqueueRsyncJobs(entries, direction: .upload, connection: connection, flavor: flavor, targetDirectory: targetDirectory, source: source, target: target, moveAfter: moveAfter, mirror: mirror)
        case (.remote, .local):
            guard let connection = connection(for: source), let flavor = requireRsync(connection) else { return }
            enqueueRsyncJobs(entries, direction: .download, connection: connection, flavor: flavor, targetDirectory: targetDirectory, source: source, target: target, moveAfter: moveAfter, mirror: mirror)
        case (.remote, .remote):
            guard let sourceConnection = connection(for: source), let targetConnection = connection(for: target),
                  let flavor = requireRsync(sourceConnection), requireRsync(targetConnection) != nil else { return }
            enqueueHostToHostJobs(entries, sourceConnection: sourceConnection, targetConnection: targetConnection, flavor: flavor, targetDirectory: targetDirectory, source: source, target: target, moveAfter: moveAfter, mirror: mirror)
        }
    }

    private func requireRsync(_ connection: RemoteConnection) -> RsyncFlavor? {
        guard let flavor = rsyncFlavor else {
            presentAlert(title: "找不到 rsync", message: "本機沒有可用的 rsync。請安裝：brew install rsync，或在設定中指定路徑。")
            return nil
        }
        guard connection.info.has("rsync") else {
            presentAlert(title: "「\(connection.profile.displayName)」沒有 rsync", message: "請先在遠端安裝：sudo apt install rsync")
            return nil
        }
        return flavor
    }

    /// Copy / move / mirror between two directories on the same machine (local↔local or one host).
    private func sameHostTransfer(_ entries: [FileEntry], provider: FileSystemProvider, source: PaneModel, target: PaneModel, targetDirectory: String, moveAfter: Bool, mirror: Bool) {
        let candidates = entries.filter { !PathUtil.isSameOrAncestor($0.path, of: targetDirectory) }
        let paths = candidates.filter { mirror || PathUtil.parent($0.path) != targetDirectory }.map(\.path)
        guard !paths.isEmpty else {
            presentAlert(title: "沒有需要處理的項目", message: "來源已經在目的資料夾中，或目的資料夾在來源裡面。")
            return
        }
        let verb = mirror ? "鏡像同步" : (moveAfter ? "移動" : "複製")
        perform("\(verb)失敗", on: target, refreshAlso: source) {
            if mirror {
                if !provider.availableTools.isEmpty, !provider.hasTools(["rsync"]) {
                    throw AppError.toolMissing("rsync（\(provider.label)）")
                }
                for entry in candidates where entry.isDirectoryLike {
                    let destination = PathUtil.join(targetDirectory, entry.name)
                    try await provider.executor.runChecked(
                        "rsync -a --delete " + Shell.quote(entry.path + "/") + " " + Shell.quote(destination + "/")
                    )
                }
            } else if moveAfter {
                try await provider.move(paths, into: targetDirectory)
            } else {
                try await provider.copy(paths, into: targetDirectory)
            }
        }
    }

    private func enqueueRsyncJobs(_ entries: [FileEntry], direction: TransferDirection, connection: RemoteConnection, flavor: RsyncFlavor, targetDirectory: String, source: PaneModel, target: PaneModel, moveAfter: Bool, mirror: Bool) {
        let sourceProvider = source.provider
        for entry in entries {
            if mirror && !entry.isDirectoryLike { continue }
            let verb = mirror ? "鏡像" : (moveAfter ? "移動" : direction.verb)
            let job = TransferJob(
                title: "\(verb) \(entry.name)",
                subtitle: "\(source.title)：\(entry.path) → \(target.title)：\(targetDirectory)",
                direction: direction
            ) { [weak self] job in
                guard let self else { return }
                try await self.runRsync(
                    job: job, entry: entry, direction: direction, destinationDirectory: targetDirectory,
                    connection: connection, flavor: flavor, mirror: mirror
                )
                if moveAfter, let sourceProvider {
                    try await sourceProvider.delete([entry.path])
                }
            }
            job.connectionID = connection.profile.id
            transfers.enqueue(job)
        }
        showBottomPanel = true
        bottomTab = .transfers
    }

    /// Host → host goes through a staging directory on this Mac (download, then upload).
    private func enqueueHostToHostJobs(_ entries: [FileEntry], sourceConnection: RemoteConnection, targetConnection: RemoteConnection, flavor: RsyncFlavor, targetDirectory: String, source: PaneModel, target: PaneModel, moveAfter: Bool, mirror: Bool) {
        let sourceProvider = source.provider
        for entry in entries {
            if mirror && !entry.isDirectoryLike { continue }
            let verb = mirror ? "鏡像" : (moveAfter ? "移動" : "複製")
            let job = TransferJob(
                title: "\(verb) \(entry.name)（經本機中轉）",
                subtitle: "\(source.title)：\(entry.path) → \(target.title)：\(targetDirectory)",
                direction: .upload
            ) { [weak self] job in
                guard let self else { return }
                let staging = URL(fileURLWithPath: AppPaths.supportDirectory)
                    .appendingPathComponent("transfers", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                job.appendOutput("階段 1/2：從 \(sourceConnection.profile.displayName) 下載到暫存區\n")
                try await self.runRsync(
                    job: job, entry: entry, direction: .download, destinationDirectory: staging.path,
                    connection: sourceConnection, flavor: flavor, mirror: false
                )
                let stagedEntry = FileEntry(
                    name: entry.name, path: staging.appendingPathComponent(entry.name).path,
                    kind: entry.isDirectoryLike ? .directory : .file, isDirectoryLike: entry.isDirectoryLike,
                    size: entry.size, modified: entry.modified, mode: entry.mode, owner: "", group: "", linkTarget: nil
                )
                job.appendOutput("階段 2/2：上傳到 \(targetConnection.profile.displayName)\n")
                job.progress = RsyncProgress()
                try await self.runRsync(
                    job: job, entry: stagedEntry, direction: .upload, destinationDirectory: targetDirectory,
                    connection: targetConnection, flavor: flavor, mirror: mirror
                )
                if moveAfter, let sourceProvider {
                    try await sourceProvider.delete([entry.path])
                }
            }
            job.connectionID = sourceConnection.profile.id
            transfers.enqueue(job)
        }
        showBottomPanel = true
        bottomTab = .transfers
    }

    func runRsync(
        job: TransferJob,
        entry: FileEntry,
        direction: TransferDirection,
        destinationDirectory: String,
        connection: RemoteConnection,
        flavor: RsyncFlavor,
        mirror: Bool,
        singleFile: Bool = false,
        contentsOnly: Bool = false,
        extraExcludes: [String] = [],
        filesFrom: String? = nil
    ) async throws {
        var options = RsyncOptions(compress: AppSettings.compress, mirror: mirror, excludes: singleFile ? [] : AppSettings.excludes + extraExcludes, singleFile: singleFile)
        options.contentsOnly = contentsOnly
        options.filesFrom = filesFrom
        let localPath: String
        let remotePath: String
        let syncTree = mirror || contentsOnly
        switch direction {
        case .upload:
            localPath = entry.path
            remotePath = syncTree ? PathUtil.join(destinationDirectory, entry.name) : destinationDirectory
        case .download:
            remotePath = entry.path
            localPath = syncTree ? PathUtil.join(destinationDirectory, entry.name) : destinationDirectory
        }
        let remoteIsOpenrsync = connection.info.remoteRsyncIsOpenrsync
        let args = RsyncBuilder.arguments(
            flavor: flavor, direction: direction, localPath: localPath, remotePath: remotePath,
            remoteDestination: connection.destination, rsh: connection.rshCommand, options: options,
            remoteIsOpenrsync: remoteIsOpenrsync
        )
        let commandLine = Shell.quoteAll([flavor.path] + args)
        job.commandLine = commandLine
        let parser = RsyncProgressParser(style: RsyncBuilder.progressStyle(flavor: flavor, remoteIsOpenrsync: remoteIsOpenrsync))
        let start = Date()
        let result = try await ShellRunner.run(
            flavor.path, args,
            options: .init(
                environment: connection.environment,
                onStdout: { data in
                    if let progress = parser.feed(data) {
                        Task { @MainActor in job.progress = progress }
                    }
                },
                onStderr: { data in
                    let text = String(decoding: data, as: UTF8.self)
                    Task { @MainActor in job.appendOutput(text) }
                }
            )
        )
        var final = parser.snapshot
        log.record(target: "rsync", command: commandLine, exitCode: result.exitCode, output: result.combinedText, duration: Date().timeIntervalSince(start))
        // 24 = some source files vanished during transfer; treat as success.
        guard result.exitCode == 0 || result.exitCode == 24 else {
            throw AppError.commandFailed(command: commandLine, exitCode: result.exitCode, output: result.stderrText)
        }
        final.overallFraction = 1
        final.fileFraction = nil
        job.progress = final
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.panes.forEach { $0.reload() }
        }
    }

    // MARK: - Drag & drop

    func dragItemProvider(for entry: FileEntry, in pane: PaneModel) -> NSItemProvider? {
        switch pane.kind {
        case .local:
            guard let provider = NSItemProvider(contentsOf: URL(fileURLWithPath: entry.path)) else { return nil }
            let payload = LocalDragPayload(sourcePaneID: pane.id, paths: [entry.path])
            if let data = try? JSONEncoder().encode(payload) {
                provider.registerDataRepresentation(forTypeIdentifier: LocalDragPayload.typeIdentifier, visibility: .ownProcess) { completion in
                    completion(data, nil)
                    return nil
                }
            }
            return provider
        case .remote:
            guard let profileID = pane.profileID else { return nil }
            let payload = RemoteDragPayload(
                profileID: profileID,
                sourcePaneID: pane.id,
                items: [RemoteDragPayload.Item(path: entry.path, name: entry.name, isDirectory: entry.isDirectoryLike)]
            )
            guard let data = try? JSONEncoder().encode(payload) else { return nil }
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: RemoteDragPayload.typeIdentifier, visibility: .ownProcess) { completion in
                completion(data, nil)
                return nil
            }
            return provider
        }
    }

    func handleDrop(_ providers: [NSItemProvider], onto target: PaneModel) {
        guard target.isAvailable else { return }
        let targetPath = target.path
        Task {
            var remoteItems: [RemoteDragPayload.Item] = []
            var remoteProfileID: UUID?
            var remoteSourcePane: PaneID?
            var localSourcePane: PaneID?
            var urls: [URL] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(RemoteDragPayload.typeIdentifier) {
                    if let data = try? await provider.loadData(type: RemoteDragPayload.typeIdentifier),
                       let payload = try? JSONDecoder().decode(RemoteDragPayload.self, from: data) {
                        remoteItems.append(contentsOf: payload.items)
                        remoteProfileID = payload.profileID
                        remoteSourcePane = payload.sourcePaneID
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    if provider.hasItemConformingToTypeIdentifier(LocalDragPayload.typeIdentifier),
                       let data = try? await provider.loadData(type: LocalDragPayload.typeIdentifier),
                       let payload = try? JSONDecoder().decode(LocalDragPayload.self, from: data) {
                        localSourcePane = payload.sourcePaneID
                    }
                    if let data = try? await provider.loadData(type: UTType.fileURL.identifier),
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
            }

            if !urls.isEmpty {
                let entries = urls.map { url -> FileEntry in
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    return FileEntry(name: url.lastPathComponent, path: url.path, kind: isDirectory.boolValue ? .directory : .file,
                                     isDirectoryLike: isDirectory.boolValue, size: 0, modified: Date(timeIntervalSince1970: 0),
                                     mode: 0, owner: "", group: "", linkTarget: nil)
                }
                let internalSource = localSourcePane.flatMap { pane($0) }
                if let internalSource {
                    // Dragged from one of our local panes: move within the Mac, upload to remotes.
                    transfer(entries, from: internalSource, to: target, destinationPath: targetPath, moveAfter: target.kind == .local)
                } else {
                    // Dropped in from Finder: copy.
                    let finderSource = PaneModel(kind: .local, title: "Finder")
                    transfer(entries, from: finderSource, to: target, destinationPath: targetPath)
                }
            }

            if !remoteItems.isEmpty, let remoteProfileID {
                let entries = remoteItems.map { item in
                    FileEntry(name: item.name, path: item.path, kind: item.isDirectory ? .directory : .file,
                              isDirectoryLike: item.isDirectory, size: 0, modified: Date(timeIntervalSince1970: 0),
                              mode: 0, owner: "", group: "", linkTarget: nil)
                }
                let source = remoteSourcePane.flatMap { pane($0) }
                    ?? panes.first { $0.kind == .remote && $0.profileID == remoteProfileID && $0.isAvailable }
                guard let source else { return }
                let sameHost = target.kind == .remote && target.profileID == remoteProfileID
                transfer(entries, from: source, to: target, destinationPath: targetPath, moveAfter: sameHost)
            }
        }
    }

    // MARK: - Convenience for the default two-pane layout (menus, tests)

    /// The first local pane.
    var localPane: PaneModel { panes.first { $0.kind == .local } ?? panes[0] }
    /// The first remote pane.
    var remotePane: PaneModel { panes.first { $0.kind == .remote } ?? panes[panes.count - 1] }

    func connect(to profile: HostProfile, password: String? = nil, rememberPassword: Bool = false) {
        connectPreferringRemotePane(profile, password: password, rememberPassword: rememberPassword)
    }

    func disconnect() {
        disconnectAll()
    }

    private func pane(kind: PaneSide) -> PaneModel {
        kind == .local ? localPane : remotePane
    }

    func transfer(_ entries: [FileEntry], from source: PaneSide, to destination: PaneSide, destinationPath: String? = nil, moveAfter: Bool = false, mirror: Bool = false) {
        transfer(entries, from: pane(kind: source), to: pane(kind: destination), destinationPath: destinationPath, moveAfter: moveAfter, mirror: mirror)
    }

    func open(_ ids: Set<String>, in side: PaneSide) {
        open(ids, in: pane(kind: side))
    }

    func handleDrop(_ providers: [NSItemProvider], onto side: PaneSide) {
        handleDrop(providers, onto: pane(kind: side))
    }

    func dragItemProvider(for entry: FileEntry, in side: PaneSide) -> NSItemProvider? {
        dragItemProvider(for: entry, in: pane(kind: side))
    }
}
