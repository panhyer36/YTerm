import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

// MARK: - File watching

/// Watches one file for modifications. Editors such as TextEdit, VS Code and vim save by writing a
/// temporary file and renaming it over the original, so the containing directory is watched too and
/// the file watch is re-established after every rename/delete.
final class FileWatcher: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.yterm.filewatcher")
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var stopped = false
    private var rewatchScheduled = false
    private let onChange: @Sendable () -> Void

    init(fileURL: URL, onChange: @escaping @Sendable () -> Void) {
        self.fileURL = fileURL
        self.onChange = onChange
    }

    func start() {
        queue.sync {
            self.watchDirectory()
            self.watchFile()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.fileSource?.cancel()
            self.fileSource = nil
            self.directorySource?.cancel()
            self.directorySource = nil
        }
    }

    private func watchDirectory() {
        let descriptor = open(fileURL.deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            self.onChange()
            self.rewatchFileSoon()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        directorySource = source
    }

    private func watchFile() {
        guard !stopped else { return }
        fileSource?.cancel()
        fileSource = nil
        let descriptor = open(fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source, !self.stopped else { return }
            self.onChange()
            if !source.data.intersection([.delete, .rename, .revoke]).isEmpty {
                self.rewatchFileSoon()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileSource = source
    }

    private func rewatchFileSoon() {
        guard !rewatchScheduled, !stopped else { return }
        rewatchScheduled = true
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.rewatchScheduled = false
            self.watchFile()
        }
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
    }
}

// MARK: - Sessions

/// A remote file that has been copied to the local staging area and is being edited there.
@MainActor @Observable
final class EditSession: Identifiable {
    enum State: Equatable {
        case downloading
        case watching
        case uploading
        case failed(String)
    }

    struct Attributes: Equatable {
        var modified: Date?
        var size: Int64
    }

    let id = UUID()
    let profileID: UUID
    let remotePath: String
    let localURL: URL
    var state: State = .downloading
    var lastUploadAt: Date?
    var uploadCount = 0
    var pendingUpload = false

    @ObservationIgnored var lastKnownModification: Date?
    @ObservationIgnored var lastKnownSize: Int64 = -1
    @ObservationIgnored var watcher: FileWatcher?
    @ObservationIgnored var debounceTask: Task<Void, Never>?

    init(profileID: UUID, remotePath: String, localDirectory: URL) {
        self.profileID = profileID
        self.remotePath = remotePath
        self.localURL = localDirectory.appendingPathComponent(PathUtil.name(remotePath))
    }

    var remoteName: String { PathUtil.name(remotePath) }
    var remoteDirectory: String { PathUtil.parent(remotePath) }
    var isUploading: Bool { state == .uploading }

    var hasUnsyncedChanges: Bool {
        if pendingUpload || isUploading { return true }
        if case .failed = state { return true }
        return localChanged()
    }

    func currentAttributes() -> Attributes {
        let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        return Attributes(
            modified: attributes?[.modificationDate] as? Date,
            size: (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        )
    }

    func rememberAttributes(_ attributes: Attributes) {
        lastKnownModification = attributes.modified
        lastKnownSize = attributes.size
    }

    func localChanged() -> Bool {
        let current = currentAttributes()
        guard current.size >= 0 else { return false }
        return current.modified != lastKnownModification || current.size != lastKnownSize
    }

    var statusText: String {
        switch state {
        case .downloading:
            return "下載中…"
        case .uploading:
            return "上傳中…"
        case let .failed(message):
            return "上傳失敗：\(message)"
        case .watching:
            var text = "監看中，儲存後會自動上傳回遠端"
            if uploadCount > 0, let lastUploadAt {
                text += "（已上傳 \(uploadCount) 次，最後 \(Self.timeFormatter.string(from: lastUploadAt))）"
            }
            if pendingUpload { text += "，尚有變更等待上傳" }
            return text
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

@MainActor @Observable
final class EditSessionManager {
    private(set) var sessions: [EditSession] = []
    @ObservationIgnored weak var app: AppState?
    /// Tests turn this off so no editor window is launched.
    @ObservationIgnored var launchesEditor = true
    @ObservationIgnored var debounceInterval: Duration = .milliseconds(800)

    nonisolated static var rootDirectory: URL {
        URL(fileURLWithPath: AppPaths.supportDirectory).appendingPathComponent("edits", isDirectory: true)
    }

    func session(forRemotePath path: String, profileID: UUID) -> EditSession? {
        sessions.first { $0.remotePath == path && $0.profileID == profileID }
    }

    func makeSession(profileID: UUID, remotePath: String) throws -> EditSession {
        let directory = Self.rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = EditSession(profileID: profileID, remotePath: remotePath, localDirectory: directory)
        sessions.append(session)
        return session
    }

    /// Called once the copy has been downloaded.
    func beginWatching(_ session: EditSession) {
        // The editor must be able to write the copy even when the remote file is read-only.
        if let mode = (try? FileManager.default.attributesOfItem(atPath: session.localURL.path))?[.posixPermissions] as? NSNumber {
            try? FileManager.default.setAttributes([.posixPermissions: mode.intValue | 0o600], ofItemAtPath: session.localURL.path)
        }
        session.rememberAttributes(session.currentAttributes())
        session.state = .watching
        let watcher = FileWatcher(fileURL: session.localURL) { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session else { return }
                self.fileDidChange(session)
            }
        }
        session.watcher = watcher
        watcher.start()
    }

    func fileDidChange(_ session: EditSession) {
        session.debounceTask?.cancel()
        let interval = debounceInterval
        session.debounceTask = Task { [weak self, weak session] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self, let session else { return }
            self.uploadIfNeeded(session)
        }
    }

    /// Upload the local copy when it differs from what was last synced (or always, when forced).
    func uploadIfNeeded(_ session: EditSession, force: Bool = false) {
        guard let app, let connection = app.connections[session.profileID],
              let flavor = app.rsyncFlavor,
              sessions.contains(where: { $0.id == session.id }),
              FileManager.default.fileExists(atPath: session.localURL.path) else { return }
        if session.isUploading {
            session.pendingUpload = true
            return
        }
        guard force || session.localChanged() else { return }
        session.pendingUpload = false
        session.state = .uploading
        let snapshot = session.currentAttributes()
        let localEntry = FileEntry(
            name: session.remoteName, path: session.localURL.path, kind: .file, isDirectoryLike: false,
            size: max(snapshot.size, 0), modified: snapshot.modified ?? Date(), mode: 0o644, owner: "", group: "", linkTarget: nil
        )
        let job = TransferJob(
            title: "儲存上傳 \(session.remoteName)",
            subtitle: "暫存區 → 遠端：\(session.remoteDirectory)",
            direction: .upload
        ) { [weak self, weak session] job in
            guard let self, let session else { return }
            do {
                try await app.runRsync(
                    job: job, entry: localEntry, direction: .upload, destinationDirectory: session.remoteDirectory,
                    connection: connection, flavor: flavor, mirror: false, singleFile: true
                )
            } catch {
                session.state = .failed(error.localizedDescription)
                throw error
            }
            session.rememberAttributes(snapshot)
            session.lastUploadAt = Date()
            session.uploadCount += 1
            session.state = .watching
            if session.pendingUpload || session.localChanged() {
                self.uploadIfNeeded(session, force: true)
            }
        }
        app.transfers.enqueue(job)
    }

    func openInEditor(_ session: EditSession) {
        guard launchesEditor else { return }
        EditorLauncher.open(session.localURL) { [weak self] error in
            Task { @MainActor in self?.app?.presentError(error, title: "無法開啟編輯器") }
        }
    }

    func stop(_ session: EditSession, deleteLocalCopy: Bool) {
        session.watcher?.stop()
        session.watcher = nil
        session.debounceTask?.cancel()
        session.debounceTask = nil
        sessions.removeAll { $0.id == session.id }
        if deleteLocalCopy {
            try? FileManager.default.removeItem(at: session.localURL.deletingLastPathComponent())
        }
    }

    /// Stops every session (or only those of one host). Local copies with changes that never reached
    /// the remote are kept and returned.
    @discardableResult
    func stopAll(profileID: UUID? = nil) -> [EditSession] {
        var kept: [EditSession] = []
        for session in sessions where profileID == nil || session.profileID == profileID {
            let keep = session.hasUnsyncedChanges
            if keep { kept.append(session) }
            stop(session, deleteLocalCopy: !keep)
        }
        return kept
    }

    func revealInFinder(_ session: EditSession) {
        NSWorkspace.shared.activateFileViewerSelecting([session.localURL])
    }

    /// Removes staging directories left behind by earlier runs.
    nonisolated static func removeStaleDirectories(olderThan age: TimeInterval) {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > age {
                try? fileManager.removeItem(at: item)
            }
        }
    }

    nonisolated static func removeAllStagedFiles() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

// MARK: - Editor selection

enum EditorLauncher {
    static let textEditURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")

    /// Opens the staged copy with the editor chosen in Settings, otherwise with the macOS default
    /// application for the file type. TextEdit is only a fallback for files no app claims.
    static func open(_ url: URL, onError: @escaping (Error) -> Void) {
        let custom = AppSettings.editorAppPath
        if !custom.isEmpty, FileManager.default.fileExists(atPath: custom) {
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: custom), configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { onError(error) }
            }
            return
        }
        if NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open([url], withApplicationAt: textEditURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil {
                onError(AppError.general("找不到能開啟 \(url.lastPathComponent) 的程式，檔案在 \(url.path)"))
            }
        }
    }
}

// MARK: - AppState glue

extension AppState {
    /// Convenience for the default layout: edits files of the first remote pane.
    func openRemoteFilesForEditing(_ entries: [FileEntry]) {
        openRemoteFilesForEditing(entries, from: remotePane)
    }

    /// Download the files to the staging area, open them, and upload every save back to the remote.
    func openRemoteFilesForEditing(_ entries: [FileEntry], from pane: PaneModel) {
        let files = entries.filter { !$0.isDirectoryLike }
        guard !files.isEmpty else { return }
        guard let connection = connection(for: pane) else {
            presentError(AppError.notConnected)
            return
        }
        guard let flavor = rsyncFlavor else {
            presentAlert(title: "找不到 rsync", message: "本機沒有可用的 rsync。請安裝：brew install rsync，或在設定中指定路徑。")
            return
        }
        guard connection.info.has("rsync") else {
            presentAlert(title: "遠端主機沒有 rsync", message: "請先在遠端安裝：sudo apt install rsync")
            return
        }
        for entry in files {
            if let existing = edits.session(forRemotePath: entry.path, profileID: connection.profile.id) {
                edits.openInEditor(existing)
                continue
            }
            let session: EditSession
            do {
                session = try edits.makeSession(profileID: connection.profile.id, remotePath: entry.path)
            } catch {
                presentError(error, title: "無法建立暫存區")
                continue
            }
            let localDirectory = session.localURL.deletingLastPathComponent().path
            let job = TransferJob(
                title: "下載以編輯 \(entry.name)",
                subtitle: "遠端：\(entry.path) → 暫存區",
                direction: .download
            ) { [weak self, weak session] job in
                guard let self, let session else { return }
                do {
                    try await self.runRsync(
                        job: job, entry: entry, direction: .download, destinationDirectory: localDirectory,
                        connection: connection, flavor: flavor, mirror: false, singleFile: true
                    )
                } catch {
                    self.edits.stop(session, deleteLocalCopy: true)
                    throw error
                }
                self.edits.beginWatching(session)
                self.edits.openInEditor(session)
                self.bottomTab = .edits
            }
            transfers.enqueue(job)
        }
        showBottomPanel = true
    }
}
