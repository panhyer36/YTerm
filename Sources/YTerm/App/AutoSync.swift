import CoreServices
import Foundation
import Observation

/// A local folder that is pushed to a remote folder whenever something inside it changes.
/// The same pair can be compared the other way round on demand (pull review).
struct SyncRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var localPath: String = ""
    var profileID: UUID? = nil
    var remotePath: String = ""
    var enabled = true
    /// Also delete remote files that no longer exist locally (`rsync --delete`).
    var mirror = false
    var excludes: [String] = []

    init() {}

    var isValid: Bool {
        !localPath.isEmpty && localPath.hasPrefix("/") && profileID != nil
            && remotePath.hasPrefix("/") && remotePath != "/"
    }

    var displayName: String { name.isEmpty ? PathUtil.name(localPath) : name }
}

extension SyncRule {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        localPath = try container.decodeIfPresent(String.self, forKey: .localPath) ?? ""
        profileID = try container.decodeIfPresent(UUID.self, forKey: .profileID)
        remotePath = try container.decodeIfPresent(String.self, forKey: .remotePath) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mirror = try container.decodeIfPresent(Bool.self, forKey: .mirror) ?? false
        excludes = try container.decodeIfPresent([String].self, forKey: .excludes) ?? []
        // Rules saved by 1.2 previews as "pull" must never start pushing; load them disabled.
        if let legacyDirection = try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(String.self, forKey: .direction),
           legacyDirection == "pull" {
            enabled = false
            mirror = false
        }
    }

    private enum LegacyKeys: String, CodingKey {
        case direction
    }
}

/// Recursive folder watcher built on FSEvents.
final class DirectoryWatcher: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "com.yterm.directorywatcher")
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable ([String]) -> Void

    init(path: String, onChange: @escaping @Sendable ([String]) -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        queue.sync {
            guard stream == nil else { return }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
                let paths = (0..<count).compactMap { array[$0] as? String }
                watcher.onChange(paths)
            }
            let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
            guard let created = FSEventStreamCreate(nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
        }
    }

    func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

@MainActor @Observable
final class SyncSession:  Identifiable {
    enum State: Equatable {
        case disabled
        case waitingForConnection
        case idle
        case syncing
        case failed(String)
    }

    let id: UUID
    var rule: SyncRule
    var state: State
    var lastSyncAt: Date?
    var syncCount = 0
    var pendingSync = false
    var lastChangedPaths: [String] = []
    /// The most recent rsync run, for progress and the command line.
    var job: TransferJob?

    @ObservationIgnored var watcher: DirectoryWatcher?
    @ObservationIgnored var debounceTask: Task<Void, Never>?
    @ObservationIgnored var pollTask: Task<Void, Never>?

    init(rule: SyncRule) {
        self.id = rule.id
        self.rule = rule
        self.state = rule.enabled ? .idle : .disabled
    }

    var statusText: String {
        switch state {
        case .disabled: return "已停用"
        case .waitingForConnection: return "等待主機連線（連上後會自動同步）"
        case .syncing: return "同步中…"
        case let .failed(message): return "同步失敗：\(message)"
        case .idle:
            var text = "監看本機變動中"
            if let lastSyncAt {
                text += "，最後同步 \(Self.timeFormatter.string(from: lastSyncAt))（第 \(syncCount) 次）"
            } else {
                text += "，尚未同步"
            }
            if pendingSync { text += "，有變更等待同步" }
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
final class SyncManager {
    private(set) var sessions: [SyncSession] = []
    @ObservationIgnored weak var app: AppState?
    @ObservationIgnored var debounceInterval: Duration = .seconds(1)

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? URL(fileURLWithPath: AppPaths.supportDirectory).appendingPathComponent("syncs.json")
        if let data = try? Data(contentsOf: self.fileURL), let rules = try? JSONDecoder().decode([SyncRule].self, from: data) {
            sessions = rules.map(SyncSession.init(rule:))
        }
    }

    /// Call once `app` is set: starts watchers for enabled rules.
    func activate() {
        for session in sessions where session.rule.enabled {
            startWatching(session)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(sessions.map(\.rule)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func session(_ id: UUID) -> SyncSession? {
        sessions.first { $0.id == id }
    }

    func upsert(_ rule: SyncRule) {
        if let session = session(rule.id) {
            stopWatching(session)
            session.rule = rule
            session.state = rule.enabled ? .idle : .disabled
            if rule.enabled {
                startWatching(session)
                syncNow(session)
            }
        } else {
            let session = SyncSession(rule: rule)
            sessions.append(session)
            if rule.enabled {
                startWatching(session)
                syncNow(session)
            }
        }
        save()
    }

    func remove(_ id: UUID) {
        guard let session = session(id) else { return }
        stopWatching(session)
        sessions.removeAll { $0.id == id }
        save()
    }

    func setEnabled(_ session: SyncSession, _ enabled: Bool) {
        session.rule.enabled = enabled
        if enabled {
            session.state = .idle
            startWatching(session)
            syncNow(session)
        } else {
            stopWatching(session)
            session.state = .disabled
            session.pendingSync = false
        }
        save()
    }

    private func startWatching(_ session: SyncSession) {
        guard session.watcher == nil, FileManager.default.fileExists(atPath: session.rule.localPath) else { return }
        let watcher = DirectoryWatcher(path: session.rule.localPath) { [weak self, weak session] paths in
            Task { @MainActor in
                guard let self, let session else { return }
                self.folderDidChange(session, paths: paths)
            }
        }
        session.watcher = watcher
        watcher.start()
    }

    private func stopWatching(_ session: SyncSession) {
        session.watcher?.stop()
        session.watcher = nil
        session.debounceTask?.cancel()
        session.debounceTask = nil
        session.pollTask?.cancel()
        session.pollTask = nil
    }

    private func folderDidChange(_ session: SyncSession, paths: [String]) {
        guard session.rule.enabled else { return }
        let relevant = paths.filter { !isExcluded($0, rule: session.rule) }
        guard !relevant.isEmpty else { return }
        session.lastChangedPaths = Array(relevant.prefix(5))
        session.debounceTask?.cancel()
        let interval = debounceInterval
        session.debounceTask = Task { [weak self, weak session] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self, let session else { return }
            self.syncNow(session)
        }
    }

    /// Cheap pre-filter so edits inside excluded folders (e.g. .git) do not trigger a sync at all.
    private func isExcluded(_ path: String, rule: SyncRule) -> Bool {
        let patterns = (AppSettings.excludes + rule.excludes).filter { !$0.contains("*") && !$0.contains("/") }
        let components = path.dropFirst(rule.localPath.count).split(separator: "/").map(String.init)
        return components.contains { patterns.contains($0) }
    }

    /// Runs rsync now (or queues one if a run is in progress). Pull rules are handled by the review sheet.
    func syncNow(_ session: SyncSession) {
        guard session.rule.enabled, let app else { return }
        guard let profileID = session.rule.profileID, let connection = app.connections[profileID] else {
            session.state = .waitingForConnection
            session.pendingSync = true
            return
        }
        guard let flavor = app.rsyncFlavor, connection.info.has("rsync") else {
            session.state = .failed("找不到可用的 rsync（本機或遠端）")
            return
        }
        if session.state == .syncing {
            session.pendingSync = true
            return
        }
        session.pendingSync = false
        session.state = .syncing
        let rule = session.rule
        let job = TransferJob(
            title: "自動同步 \(rule.displayName)",
            subtitle: "\(rule.localPath) → \(connection.profile.displayName)：\(rule.remotePath)",
            direction: .upload
        ) { _ in }
        job.state = .running
        job.startedAt = Date()
        session.job = job
        // `contentsOnly` syncs the source tree into destinationDirectory/<entry.name>, so the entry is
        // named after the remote folder and points at the local folder.
        let entry = FileEntry(
            name: PathUtil.name(rule.remotePath), path: rule.localPath,
            kind: .directory, isDirectoryLike: true, size: 0, modified: Date(), mode: 0o755, owner: "", group: "", linkTarget: nil
        )
        let destinationDirectory = PathUtil.parent(rule.remotePath)
        Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                try await app.runRsync(
                    job: job, entry: entry, direction: .upload, destinationDirectory: destinationDirectory,
                    connection: connection, flavor: flavor, mirror: rule.mirror, contentsOnly: true, extraExcludes: rule.excludes
                )
                job.state = .finished
                session.lastSyncAt = Date()
                session.syncCount += 1
                session.state = .idle
            } catch {
                job.state = .failed(error.localizedDescription)
                session.state = .failed(error.localizedDescription)
            }
            job.finishedAt = Date()
            app.refreshPanes(profileID: profileID)
            if session.pendingSync { self.syncNow(session) }
        }
    }

    func connectionDidOpen(profileID: UUID) {
        for session in sessions where session.rule.enabled && session.rule.profileID == profileID {
            syncNow(session)
        }
    }

    func connectionDidClose(profileID: UUID) {
        for session in sessions where session.rule.enabled && session.rule.profileID == profileID {
            if session.state != .disabled { session.state = .waitingForConnection }
        }
    }

    /// True when some enabled rule still needs the connection to this host.
    func usesConnection(_ profileID: UUID) -> Bool {
        sessions.contains { $0.rule.enabled && $0.rule.profileID == profileID }
    }
}
