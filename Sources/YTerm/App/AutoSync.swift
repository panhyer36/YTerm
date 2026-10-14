import CoreServices
import Foundation
import Observation

/// A local folder kept in sync with a remote folder. In push mode local changes are pushed and
/// remote changes are only pulled on demand (pull review); in two-way mode both sides are watched.
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
    var mode: SyncMode = .push
    /// Two-way mode without inotifywait on the host: seconds between remote checks.
    var pollSeconds = 10
    /// The user said no to installing inotify-tools on this rule's host; do not ask again.
    var inotifyDeclined = false

    init() {}

    /// Backups of overwritten and deleted files on the remote side live here; never sync them.
    static let backupFolderName = ".yterm-sync-backup"

    /// Changing any of these makes the two-way baseline meaningless.
    var syncIdentity: [String] {
        [localPath, profileID?.uuidString ?? "", remotePath, mode.rawValue, excludes.joined(separator: "\n")]
    }

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
        mode = try container.decodeIfPresent(SyncMode.self, forKey: .mode) ?? .push
        pollSeconds = try container.decodeIfPresent(Int.self, forKey: .pollSeconds) ?? 10
        inotifyDeclined = try container.decodeIfPresent(Bool.self, forKey: .inotifyDeclined) ?? false
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

    // Two-way mode.
    var remoteWatch: RemoteWatchState = .none
    var remoteWatchNote: String?
    var lastSummary: String?
    var conflicts: [TwoWayConflict] = []
    var localBackupDirectory: String?
    var remoteBackupDirectory: String?
    /// Checksum of the remote listing after the last pass; a poll that differs triggers a pass.
    var remoteFingerprint: String?

    @ObservationIgnored var watcher: DirectoryWatcher?
    @ObservationIgnored var debounceTask: Task<Void, Never>?
    @ObservationIgnored var remoteWatchTask: Task<Void, Never>?
    @ObservationIgnored var inotifyFailures = 0
    @ObservationIgnored var extraPasses = 0

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
        case .idle where rule.mode == .twoWay:
            var text = "雙向監看中（遠端：\(remoteWatchText)）"
            if let lastSyncAt {
                text += "，最後同步 \(Self.timeFormatter.string(from: lastSyncAt))"
            }
            if let lastSummary { text += "：\(lastSummary)" }
            if pendingSync { text += "，有變更等待同步" }
            return text
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

    var remoteWatchText: String {
        switch remoteWatch {
        case .none: return "未監看"
        case .inotify: return "inotifywait 即時"
        case .polling: return "每 \(rule.pollSeconds) 秒輪詢"
        case .installing: return "正在安裝 inotify-tools，暫時輪詢"
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
    /// Hosts already asked about installing inotify-tools in this run.
    @ObservationIgnored var promptedProfiles: Set<UUID> = []

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

    func save() {
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
            if session.rule.syncIdentity != rule.syncIdentity {
                SyncBaselineStore.remove(rule.id)
                session.remoteFingerprint = nil
                session.conflicts = []
                session.lastSummary = nil
            }
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
        SyncBaselineStore.remove(id)
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
        startRemoteWatching(session)
    }

    private func stopWatching(_ session: SyncSession) {
        session.watcher?.stop()
        session.watcher = nil
        session.debounceTask?.cancel()
        session.debounceTask = nil
        stopRemoteWatching(session)
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

    /// Runs a sync now (or queues one if a run is in progress).
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
        if session.rule.mode == .twoWay {
            runTwoWay(session, connection: connection, flavor: flavor)
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
                    connection: connection, flavor: flavor, mirror: rule.mirror, contentsOnly: true, extraExcludes: rule.excludes,
                    // Never overwrite a remote file that was edited after the local copy.
                    tweak: { $0.update = true }
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
            session.inotifyFailures = 0
            startRemoteWatching(session)
            syncNow(session)
        }
    }

    func connectionDidClose(profileID: UUID) {
        for session in sessions where session.rule.enabled && session.rule.profileID == profileID {
            stopRemoteWatching(session)
            if session.state != .disabled { session.state = .waitingForConnection }
        }
    }

    /// True when some enabled rule still needs the connection to this host.
    func usesConnection(_ profileID: UUID) -> Bool {
        sessions.contains { $0.rule.enabled && $0.rule.profileID == profileID }
    }
}

// MARK: - Two-way mode

extension SyncManager {
    private func runTwoWay(_ session: SyncSession, connection: RemoteConnection, flavor: RsyncFlavor) {
        guard let app else { return }
        session.pendingSync = false
        session.state = .syncing
        let rule = session.rule
        let hostName = connection.profile.displayName
        let job = TransferJob(
            title: "雙向同步 \(rule.displayName)",
            subtitle: "\(rule.localPath) ⇄ \(hostName)：\(rule.remotePath)",
            direction: .upload
        ) { _ in }
        job.state = .running
        job.startedAt = Date()
        session.job = job

        let extraExcludes = rule.excludes + [SyncRule.backupFolderName]
        let engine = TwoWaySyncEngine(
            connection: connection,
            localRoot: rule.localPath,
            remoteRoot: rule.remotePath,
            excludes: SyncExcludes(AppSettings.excludes + extraExcludes),
            backupName: String(rule.id.uuidString.prefix(8)),
            transfer: { [weak app] direction, listFile, backupDirectory in
                guard let app else { throw CancellationError() }
                // Same layout as the push and pull-review transfers: contents of one root into the other.
                let entry: FileEntry
                let destination: String
                switch direction {
                case .upload:
                    entry = FileEntry(
                        name: PathUtil.name(rule.remotePath), path: rule.localPath, kind: .directory, isDirectoryLike: true,
                        size: 0, modified: Date(), mode: 0o755, owner: "", group: "", linkTarget: nil
                    )
                    destination = PathUtil.parent(rule.remotePath)
                case .download:
                    entry = FileEntry(
                        name: PathUtil.name(rule.localPath), path: rule.remotePath, kind: .directory, isDirectoryLike: true,
                        size: 0, modified: Date(), mode: 0o755, owner: "", group: "", linkTarget: nil
                    )
                    destination = PathUtil.parent(rule.localPath)
                }
                try await app.runRsync(
                    job: job, entry: entry, direction: direction, destinationDirectory: destination,
                    connection: connection, flavor: flavor, mirror: false, contentsOnly: true,
                    extraExcludes: extraExcludes, filesFrom: listFile,
                    tweak: { options in
                        options.filesFromRecursive = false
                        options.backupDirectory = backupDirectory
                    }
                )
            }
        )
        let baseline = SyncBaselineStore.load(rule.id) ?? [:]
        let profileID = connection.profile.id

        Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let outcome = try await engine.run(baseline: baseline)
                // The rule may have been edited (and its baseline reset) while this pass ran.
                guard session.rule.syncIdentity == rule.syncIdentity else { return }
                SyncBaselineStore.save(outcome.baseline, for: rule.id)
                let plan = outcome.plan
                session.remoteFingerprint = outcome.fingerprint
                // A pass that found nothing (e.g. the echo of our own download) keeps the last real result.
                if !plan.isEmpty || session.lastSyncAt == nil {
                    session.lastSummary = plan.summary
                    session.lastSyncAt = Date()
                }
                if !plan.isEmpty { session.syncCount += 1 }
                if !plan.conflicts.isEmpty {
                    session.conflicts = Array((plan.conflicts + session.conflicts).prefix(50))
                }
                if let directory = outcome.localBackupDirectory { session.localBackupDirectory = directory }
                if let directory = outcome.remoteBackupDirectory { session.remoteBackupDirectory = directory }
                // Converge when something changed mid-pass, but never loop forever.
                if outcome.needsAnotherPass, session.extraPasses < 3 {
                    session.extraPasses += 1
                    session.pendingSync = true
                } else {
                    session.extraPasses = 0
                }
                job.state = .finished
                session.state = .idle
                if !plan.pull.isEmpty || !plan.pullOverwriting.isEmpty || !plan.deleteLocal.isEmpty { app.refreshLocalPanes() }
                if !plan.push.isEmpty || !plan.pushOverwriting.isEmpty || !plan.deleteRemote.isEmpty { app.refreshPanes(profileID: profileID) }
            } catch {
                job.state = .failed(error.localizedDescription)
                session.state = .failed(error.localizedDescription)
            }
            job.finishedAt = Date()
            if session.pendingSync, session.rule.enabled { self.syncNow(session) }
        }
    }

    // MARK: Remote watching

    /// inotifywait when the host has it, otherwise polling (and an offer to install inotify-tools).
    func startRemoteWatching(_ session: SyncSession) {
        guard session.rule.enabled, session.rule.mode == .twoWay, session.remoteWatchTask == nil,
              let app, let profileID = session.rule.profileID, let connection = app.connections[profileID] else { return }
        if connection.info.has("inotifywait"), session.inotifyFailures < 3 {
            startInotify(session, connection: connection)
        } else {
            startPolling(session, connection: connection)
            offerInotifyInstall(session, connection: connection)
        }
    }

    func stopRemoteWatching(_ session: SyncSession) {
        session.remoteWatchTask?.cancel()
        session.remoteWatchTask = nil
        session.remoteWatch = .none
    }

    private func startInotify(_ session: SyncSession, connection: RemoteConnection) {
        let rule = session.rule
        let script = InotifySupport.watchScript(
            root: rule.remotePath,
            excludes: SyncExcludes(AppSettings.excludes + rule.excludes + [SyncRule.backupFolderName])
        )
        session.remoteWatch = .inotify
        session.remoteWatchNote = nil
        let onChange: @Sendable (Data) -> Void = { [weak self, weak session] _ in
            Task { @MainActor in
                guard let self, let session else { return }
                self.remoteDidChange(session)
            }
        }
        session.remoteWatchTask = Task { [weak self, weak session] in
            let result: CommandResult?
            do {
                result = try await connection.watch(script, onStdout: onChange)
            } catch {
                result = nil
            }
            guard !Task.isCancelled, let self, let session else { return }
            session.remoteWatchTask = nil
            // Exit 3: the folder does not exist yet (the first pass creates it). Anything else is a
            // dropped connection or an inotify limit; poll instead and retry inotify later.
            if let result, result.exitCode != 3 {
                session.inotifyFailures += 1
                let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                session.remoteWatchNote = message.isEmpty ? nil : "inotifywait 結束：\(message)"
            }
            guard session.rule.enabled, self.app?.connections[connection.profile.id] === connection else { return }
            self.startPolling(session, connection: connection)
        }
    }

    private func startPolling(_ session: SyncSession, connection: RemoteConnection) {
        session.remoteWatch = .polling
        session.remoteWatchTask = Task { [weak self, weak session] in
            while !Task.isCancelled {
                let seconds = max(session?.rule.pollSeconds ?? 10, 2)
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self, let session else { return }
                await self.poll(session, connection: connection)
            }
        }
    }

    private func poll(_ session: SyncSession, connection: RemoteConnection) async {
        guard session.state == .idle || session.state == .syncing else { return }
        let rule = session.rule
        let script = SyncListing.pollScript(
            root: rule.remotePath,
            excludes: SyncExcludes(AppSettings.excludes + rule.excludes + [SyncRule.backupFolderName])
        )
        guard let result = try? await connection.run(script, stdin: nil, onStdout: nil, onStderr: nil, log: false),
              result.succeeded, !Task.isCancelled else { return }
        let parsed = SyncListing.parsePoll(result.stdoutText)
        if parsed.hasInotify, session.inotifyFailures < 3, session.remoteWatch == .polling {
            // inotify-tools appeared (installed from the app or by hand): switch to it.
            connection.markToolAvailable("inotifywait")
            session.remoteWatchTask?.cancel()
            session.remoteWatchTask = nil
            startInotify(session, connection: connection)
            syncNow(session)
            return
        }
        if parsed.fingerprint != session.remoteFingerprint, session.state == .idle {
            syncNow(session)
        }
    }

    private func remoteDidChange(_ session: SyncSession) {
        guard session.rule.enabled else { return }
        session.debounceTask?.cancel()
        let interval = debounceInterval
        session.debounceTask = Task { [weak self, weak session] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self, let session else { return }
            self.syncNow(session)
        }
    }

    private func offerInotifyInstall(_ session: SyncSession, connection: RemoteConnection) {
        let profileID = connection.profile.id
        guard let app, !session.rule.inotifyDeclined, !promptedProfiles.contains(profileID), app.inotifyPrompt == nil,
              let packageManager = InotifySupport.packageManager(for: connection.info) else { return }
        promptedProfiles.insert(profileID)
        app.inotifyPrompt = InotifyPrompt(
            profileID: profileID, hostName: connection.profile.displayName,
            packageManager: packageManager, pollSeconds: session.rule.pollSeconds
        )
    }

    /// The user chose polling: remember it for every two-way rule on that host.
    func declineInotify(profileID: UUID) {
        for session in sessions where session.rule.profileID == profileID && session.rule.mode == .twoWay {
            session.rule.inotifyDeclined = true
        }
        save()
    }

    func setInstallingInotify(profileID: UUID, _ installing: Bool) {
        for session in sessions where session.rule.enabled && session.rule.profileID == profileID && session.rule.mode == .twoWay {
            if installing {
                if session.remoteWatch == .polling { session.remoteWatch = .installing }
            } else if session.remoteWatch == .installing {
                session.remoteWatch = .polling
            }
        }
    }

    /// inotify-tools was just installed on the host: move its rules from polling to inotify.
    func remoteToolsChanged(profileID: UUID) {
        guard let connection = app?.connections[profileID] else { return }
        for session in sessions where session.rule.enabled && session.rule.profileID == profileID && session.rule.mode == .twoWay {
            guard session.remoteWatch != .inotify else { continue }
            stopRemoteWatching(session)
            session.inotifyFailures = 0
            startInotify(session, connection: connection)
            syncNow(session)
        }
    }

    /// Whether this host could get inotify-tools from the app (for the rule row's install button).
    func canInstallInotify(profileID: UUID) -> Bool {
        guard let connection = app?.connections[profileID] else { return false }
        return !connection.info.has("inotifywait") && InotifySupport.packageManager(for: connection.info) != nil
    }
}
