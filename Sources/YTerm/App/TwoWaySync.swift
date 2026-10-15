import Darwin
import Foundation

enum SyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Local changes are pushed; remote changes are only pulled on request (pull review).
    case push
    /// Both sides are watched; whichever side changed (newer modification time on conflicts) wins.
    case twoWay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .push: return "單向：本機 → 遠端"
        case .twoWay: return "雙向：以最後修改時間為準"
        }
    }
}

/// One file, folder or symlink inside a synced tree (keyed by its path relative to the root).
struct SyncItem: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case file
        case directory
        case symlink
    }

    var kind: Kind
    var size: Int64
    var mtime: Double

    /// Same content as far as a quick check across two machines can tell: sizes match and the
    /// times are within a second. Folders only need to exist; symlink times are not always
    /// preserved by rsync, so only their size counts.
    func matches(_ other: SyncItem) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .directory: return true
        case .symlink: return size == other.size
        case .file: return size == other.size && abs(mtime - other.mtime) < 1
        }
    }

    /// Unchanged since it was recorded on the same machine (exact size and time).
    func unchanged(since recorded: SyncItem) -> Bool {
        guard kind == recorded.kind else { return false }
        return kind == .directory || (size == recorded.size && mtime == recorded.mtime)
    }
}

/// How a path looked on each side right after the last successful two-way sync. Without it a
/// deletion on one side would be indistinguishable from a new file on the other.
struct SyncBaselineEntry: Codable, Equatable, Sendable {
    var local: SyncItem
    var remote: SyncItem
}

typealias SyncTree = [String: SyncItem]
typealias SyncBaseline = [String: SyncBaselineEntry]

enum SyncBaselineStore {
    static func url(for ruleID: UUID) -> URL {
        URL(fileURLWithPath: AppPaths.supportDirectory)
            .appendingPathComponent("sync-state", isDirectory: true)
            .appendingPathComponent(ruleID.uuidString + ".json")
    }

    static func load(_ ruleID: UUID) -> SyncBaseline? {
        guard let data = try? Data(contentsOf: url(for: ruleID)) else { return nil }
        return try? JSONDecoder().decode(SyncBaseline.self, from: data)
    }

    static func save(_ baseline: SyncBaseline, for ruleID: UUID) {
        let target = url(for: ruleID)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(baseline) {
            try? data.write(to: target, options: .atomic)
        }
    }

    static func remove(_ ruleID: UUID) {
        try? FileManager.default.removeItem(at: url(for: ruleID))
    }
}

/// rsync-style exclude patterns applied to relative paths, so the listings agree with what
/// rsync itself would skip.
struct SyncExcludes: Sendable {
    struct Pattern: Sendable {
        var glob: String
        var anchored: Bool
        var hasSlash: Bool
        var directoryOnly: Bool
    }

    let patterns: [Pattern]

    init(_ raw: [String]) {
        patterns = raw.compactMap { text in
            var glob = text.trimmingCharacters(in: .whitespaces)
            guard !glob.isEmpty else { return nil }
            let directoryOnly = glob.hasSuffix("/")
            while glob.hasSuffix("/") { glob.removeLast() }
            let anchored = glob.hasPrefix("/")
            while glob.hasPrefix("/") { glob.removeFirst() }
            guard !glob.isEmpty else { return nil }
            return Pattern(glob: glob, anchored: anchored, hasSlash: anchored || glob.contains("/"), directoryOnly: directoryOnly)
        }
    }

    func excludes(_ relativePath: String, isDirectory: Bool) -> Bool {
        patterns.contains { pattern in
            if pattern.directoryOnly && !isDirectory { return false }
            if !pattern.hasSlash {
                return Self.fnmatch(pattern.glob, PathUtil.name(relativePath), flags: 0)
            }
            if Self.fnmatch(pattern.glob, relativePath, flags: FNM_PATHNAME) { return true }
            guard !pattern.anchored else { return false }
            var rest = Substring(relativePath)
            while let slash = rest.firstIndex(of: "/") {
                rest = rest[rest.index(after: slash)...]
                if Self.fnmatch(pattern.glob, String(rest), flags: FNM_PATHNAME) { return true }
            }
            return false
        }
    }

    /// Drops excluded paths and everything below excluded folders.
    func filter(_ tree: SyncTree) -> SyncTree {
        guard !patterns.isEmpty else { return tree }
        var result: SyncTree = [:]
        var excludedDirectories: Set<String> = []
        for path in tree.keys.sorted() {
            let item = tree[path]!
            if Self.ancestors(of: path).contains(where: excludedDirectories.contains) { continue }
            if excludes(path, isDirectory: item.kind == .directory) {
                if item.kind == .directory { excludedDirectories.insert(path) }
                continue
            }
            result[path] = item
        }
        return result
    }

    /// `find` arguments that prune name-only patterns early (e.g. node_modules), or "" when none apply.
    var findPrune: String {
        let terms = patterns.filter { !$0.hasSlash }.map { pattern in
            (pattern.directoryOnly ? "-type d -name " : "-name ") + Shell.quote(pattern.glob)
        }
        guard !terms.isEmpty else { return "" }
        return "\\( " + terms.joined(separator: " -o ") + " \\) -prune -o"
    }

    /// POSIX ERE for `inotifywait --exclude` covering name-only patterns, or nil.
    var inotifyRegex: String? {
        let names = patterns.filter { !$0.hasSlash }.map { Self.regex(fromGlob: $0.glob) }
        guard !names.isEmpty else { return nil }
        return "(^|/)(" + names.joined(separator: "|") + ")(/|$)"
    }

    static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = Substring(path)
        while let slash = current.lastIndex(of: "/") {
            current = current[..<slash]
            result.append(String(current))
        }
        return result
    }

    private static func fnmatch(_ pattern: String, _ string: String, flags: Int32) -> Bool {
        Darwin.fnmatch(pattern, string, flags) == 0
    }

    private static func regex(fromGlob glob: String) -> String {
        var result = ""
        for ch in glob {
            switch ch {
            case "*": result += "[^/]*"
            case "?": result += "[^/]"
            case ".", "+", "(", ")", "|", "^", "$", "{", "}", "\\": result += "\\" + String(ch)
            default: result.append(ch)
            }
        }
        return result
    }
}

// MARK: - Listing

enum SyncListing {
    /// Walks the local tree without following symlinks. Unreadable folders are an error: treating
    /// them as empty would look like deletions and remove the files on the other side.
    static func local(root: String, excludes: SyncExcludes) throws -> SyncTree {
        var base = root
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppError.general("本機資料夾不存在：\(base)")
        }
        let prefix = base == "/" ? "/" : base + "/"
        guard let rootPointer = strdup(base) else { throw AppError.general("記憶體不足") }
        defer { free(rootPointer) }
        var argv: [UnsafeMutablePointer<CChar>?] = [rootPointer, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
            throw AppError.general("無法讀取 \(base)：\(String(cString: strerror(errno)))")
        }
        defer { fts_close(fts) }

        var tree: SyncTree = [:]
        errno = 0
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            let path = String(cString: entry.pointee.fts_path)
            if entry.pointee.fts_level == 0 {
                if info == FTS_DNR || info == FTS_ERR { throw AppError.general("無法讀取 \(base)") }
                continue
            }
            let relative = String(path.dropFirst(prefix.count))
            let kind: SyncItem.Kind
            switch info {
            case FTS_DP:
                continue
            case FTS_DNR, FTS_ERR, FTS_NS:
                throw AppError.general("無法讀取 \(relative)：\(String(cString: strerror(entry.pointee.fts_errno)))")
            case FTS_D: kind = .directory
            case FTS_F: kind = .file
            case FTS_SL, FTS_SLNONE: kind = .symlink
            default: continue
            }
            if excludes.excludes(relative, isDirectory: kind == .directory) {
                if kind == .directory { fts_set(fts, entry, FTS_SKIP) }
                continue
            }
            let stat = entry.pointee.fts_statp.pointee
            tree[relative] = SyncItem(
                kind: kind,
                size: kind == .directory ? 0 : Int64(stat.st_size),
                mtime: Double(stat.st_mtimespec.tv_sec) + Double(stat.st_mtimespec.tv_nsec) / 1_000_000_000
            )
            errno = 0
        }
        if errno != 0 { throw AppError.general("無法讀取 \(base)：\(String(cString: strerror(errno)))") }
        return tree
    }

    /// The find pipeline shared by the full listing and the cheap poll, so both see the same bytes.
    /// GNU find prints `G\ttype\tsize\tmtime\tpath\0`; BSD falls back to `stat -f` lines turned into NUL records.
    static func findCommand(excludes: SyncExcludes) -> (gnu: String, bsd: String) {
        let prune = excludes.findPrune
        let gnu = "find . -mindepth 1 \(prune) -printf 'G\\t%y\\t%s\\t%T@\\t%P\\0'"
        let bsd = "find . -mindepth 1 \(prune) -exec stat -f 'B%t%HT%t%z%t%m%t%N' {} +"
        return (gnu, bsd)
    }

    /// Lists the remote tree and appends a `S\t<cksum>` record that matches `pollScript`.
    /// Exit 3 means the folder does not exist.
    static func remoteScript(root: String, excludes: SyncExcludes) -> String {
        let find = findCommand(excludes: excludes)
        return """
        cd -- \(Shell.quote(root)) 2>/dev/null || exit 3
        t=$(mktemp 2>/dev/null) || t=/tmp/yterm-list.$$
        if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
        \(find.gnu) > "$t"; s=$?
        else
        \(find.bsd) > "$t.raw"; s=$?
        tr '\\n' '\\0' < "$t.raw" > "$t"; rm -f "$t.raw"
        fi
        cat "$t"
        printf 'S\\t%s\\0' "$(cksum < "$t")"
        rm -f "$t"
        exit $s
        """
    }

    /// Prints the same checksum as `remoteScript` and whether inotifywait is available now.
    static func pollScript(root: String, excludes: SyncExcludes) -> String {
        let find = findCommand(excludes: excludes)
        return """
        cd -- \(Shell.quote(root)) 2>/dev/null || exit 3
        if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
        \(find.gnu) | cksum
        else
        \(find.bsd) | tr '\\n' '\\0' | cksum
        fi
        command -v inotifywait >/dev/null 2>&1 && echo inotify
        exit 0
        """
    }

    static func parseRemote(_ data: Data) -> (tree: SyncTree, fingerprint: String?) {
        var tree: SyncTree = [:]
        var fingerprint: String?
        for record in data.split(separator: 0, omittingEmptySubsequences: true) {
            let text = String(decoding: record, as: UTF8.self)
            let fields = text.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "S":
                if fields.count >= 2 { fingerprint = fields[1].trimmingCharacters(in: .whitespacesAndNewlines) }
            case "G":
                guard fields.count == 5, !fields[4].isEmpty else { continue }
                let kind: SyncItem.Kind
                switch fields[1] {
                case "f": kind = .file
                case "d": kind = .directory
                case "l": kind = .symlink
                default: continue
                }
                tree[fields[4]] = SyncItem(kind: kind, size: kind == .directory ? 0 : Int64(fields[2]) ?? 0, mtime: Double(fields[3]) ?? 0)
            case "B":
                guard fields.count == 5 else { continue }
                var path = fields[4]
                if path.hasPrefix("./") { path.removeFirst(2) }
                guard !path.isEmpty, path != "." else { continue }
                let type = fields[1].lowercased()
                let kind: SyncItem.Kind
                if type.hasPrefix("dir") { kind = .directory }
                else if type.hasPrefix("sym") { kind = .symlink }
                else if type.hasPrefix("reg") { kind = .file }
                else { continue }
                tree[path] = SyncItem(kind: kind, size: kind == .directory ? 0 : Int64(fields[2]) ?? 0, mtime: Double(fields[3]) ?? 0)
            default:
                continue
            }
        }
        return (tree, fingerprint)
    }

    /// First line of `pollScript` output (the cksum) and whether inotifywait showed up.
    static func parsePoll(_ text: String) -> (fingerprint: String, hasInotify: Bool) {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return (lines.first ?? "", lines.contains("inotify"))
    }
}

// MARK: - Planning

struct TwoWayConflict: Identifiable, Equatable, Sendable {
    var path: String
    /// True when the local copy was newer and was uploaded.
    var localWon: Bool
    var id: String { path }
}

struct TwoWayPlan: Equatable, Sendable {
    var push: [String] = []
    var pull: [String] = []
    /// Conflicts: the losing copy on the receiving side is kept in a backup folder.
    var pushOverwriting: [String] = []
    var pullOverwriting: [String] = []
    /// Top-most paths only (a folder's contents go with it).
    var deleteLocal: [String] = []
    var deleteRemote: [String] = []
    var conflicts: [TwoWayConflict] = []
    /// A file on one side and a folder on the other; left alone.
    var skipped: [String] = []

    var isEmpty: Bool {
        push.isEmpty && pull.isEmpty && pushOverwriting.isEmpty && pullOverwriting.isEmpty
            && deleteLocal.isEmpty && deleteRemote.isEmpty
    }

    var summary: String {
        var parts: [String] = []
        let up = push.count + pushOverwriting.count
        let down = pull.count + pullOverwriting.count
        if up > 0 { parts.append("↑\(up)") }
        if down > 0 { parts.append("↓\(down)") }
        if !deleteLocal.isEmpty || !deleteRemote.isEmpty { parts.append("刪除 \(deleteLocal.count + deleteRemote.count)") }
        if !conflicts.isEmpty { parts.append("衝突 \(conflicts.count)") }
        if !skipped.isEmpty { parts.append("略過 \(skipped.count)") }
        return parts.isEmpty ? "無變更" : parts.joined(separator: " ")
    }
}

enum TwoWayPlanner {
    static func plan(local: SyncTree, remote: SyncTree, baseline: SyncBaseline) -> TwoWayPlan {
        var plan = TwoWayPlan()
        var deleteLocal: Set<String> = []
        var deleteRemote: Set<String> = []

        for path in Set(local.keys).union(remote.keys).sorted() {
            // rsync --files-from is line based.
            if path.contains("\n") {
                plan.skipped.append(path)
                continue
            }
            let base = baseline[path]
            switch (local[path], remote[path]) {
            case let (l?, r?):
                if l.kind != r.kind {
                    plan.skipped.append(path)
                    continue
                }
                if l.kind == .directory { continue }
                if let base, l.unchanged(since: base.local), r.unchanged(since: base.remote) { continue }
                if l.matches(r) { continue }
                let localChanged = base.map { !l.unchanged(since: $0.local) } ?? true
                let remoteChanged = base.map { !r.unchanged(since: $0.remote) } ?? true
                if localChanged && !remoteChanged {
                    plan.push.append(path)
                } else if remoteChanged && !localChanged {
                    plan.pull.append(path)
                } else {
                    let localWon = l.mtime >= r.mtime
                    if localWon { plan.pushOverwriting.append(path) } else { plan.pullOverwriting.append(path) }
                    plan.conflicts.append(TwoWayConflict(path: path, localWon: localWon))
                }
            case let (l?, nil):
                if let base, l.unchanged(since: base.local) {
                    deleteLocal.insert(path)
                } else {
                    plan.push.append(path)
                }
            case let (nil, r?):
                if let base, r.unchanged(since: base.remote) {
                    deleteRemote.insert(path)
                } else {
                    plan.pull.append(path)
                }
            case (nil, nil):
                continue
            }
        }

        plan.deleteLocal = keepNeededDirectories(deleteLocal, tree: local)
        plan.deleteRemote = keepNeededDirectories(deleteRemote, tree: remote)
        return plan
    }

    /// A folder deleted on the other side is only deleted here when everything inside it goes too;
    /// otherwise it stays (and comes back on the other side with the files that still need it).
    /// Returns the top-most paths to delete.
    private static func keepNeededDirectories(_ candidates: Set<String>, tree: SyncTree) -> [String] {
        var deleting = candidates
        var kept: Set<String> = []
        for path in tree.keys where !candidates.contains(path) {
            kept.formUnion(SyncExcludes.ancestors(of: path))
        }
        let directories = candidates.filter { tree[$0]?.kind == .directory }
            .sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
        for directory in directories where kept.contains(directory) {
            deleting.remove(directory)
            kept.formUnion(SyncExcludes.ancestors(of: directory))
        }
        return deleting.filter { path in !SyncExcludes.ancestors(of: path).contains(where: deleting.contains) }.sorted()
    }

    /// The baseline after a sync, from listings taken before and after it ran.
    ///
    /// A transferred path is recorded only when its source did not change while it was being
    /// copied. Other paths count as synced when both sides still match the old baseline, or when
    /// they look identical.
    static func nextBaseline(
        plan: TwoWayPlan,
        localBefore: SyncTree, remoteBefore: SyncTree,
        localAfter: SyncTree, remoteAfter: SyncTree,
        previous: SyncBaseline
    ) -> SyncBaseline {
        let pushed = Set(plan.push + plan.pushOverwriting)
        let pulled = Set(plan.pull + plan.pullOverwriting)
        var next: SyncBaseline = [:]
        for (path, l) in localAfter {
            guard let r = remoteAfter[path], l.kind == r.kind else { continue }
            let synced: Bool
            if pushed.contains(path) {
                synced = localBefore[path].map { l.unchanged(since: $0) } ?? false
            } else if pulled.contains(path) {
                synced = remoteBefore[path].map { r.unchanged(since: $0) } ?? false
            } else if let old = previous[path], l.unchanged(since: old.local), r.unchanged(since: old.remote) {
                synced = true
            } else {
                synced = l.matches(r)
            }
            if synced { next[path] = SyncBaselineEntry(local: l, remote: r) }
        }
        return next
    }
}

// MARK: - Running one pass

struct TwoWayOutcome: Sendable {
    var plan: TwoWayPlan
    var baseline: SyncBaseline
    /// Checksum of the final remote listing, compared against later polls.
    var fingerprint: String?
    /// Something changed while the pass ran; run again.
    var needsAnotherPass: Bool
    var remoteBackupDirectory: String?
    var localBackupDirectory: String?
}

/// One full two-way pass: list both sides, plan against the baseline, transfer, delete, re-list.
struct TwoWaySyncEngine: Sendable {
    /// Runs rsync for the listed relative paths (`--files-from`), keeping overwritten files in
    /// `backupDirectory` on the receiving side when it is set.
    typealias Transfer = @Sendable (_ direction: TransferDirection, _ listFile: String, _ backupDirectory: String?) async throws -> Void

    let connection: RemoteConnection
    let localRoot: String
    let remoteRoot: String
    let excludes: SyncExcludes
    /// Short, shell-safe name for backup folders.
    let backupName: String
    let transfer: Transfer

    func run(baseline: SyncBaseline) async throws -> TwoWayOutcome {
        let localBefore = try await listLocal()
        var remoteListing = try await listRemote(createIfMissing: baseline.isEmpty)
        let remoteBefore = remoteListing.tree

        // An empty side that used to have files is far more likely a missing mount or a wrong path
        // than a deliberate "delete everything", so refuse instead of mirroring the emptiness.
        let hadFiles = baseline.values.contains { $0.local.kind != .directory }
        if hadFiles, localBefore.isEmpty, !remoteBefore.isEmpty {
            throw AppError.general("本機資料夾是空的，但上次同步時有 \(baseline.count) 個項目；為避免刪掉遠端檔案，已暫停同步。若確實要清空，請停用後重新建立規則。")
        }
        if hadFiles, remoteBefore.isEmpty, !localBefore.isEmpty {
            throw AppError.general("遠端資料夾是空的，但上次同步時有 \(baseline.count) 個項目；為避免刪掉本機檔案，已暫停同步。若確實要清空，請停用後重新建立規則。")
        }

        let plan = TwoWayPlanner.plan(local: localBefore, remote: remoteBefore, baseline: baseline)
        var outcome = TwoWayOutcome(plan: plan, baseline: [:], fingerprint: remoteListing.fingerprint, needsAnotherPass: false)
        var localAfter = localBefore
        var remoteAfter = remoteBefore

        if !plan.isEmpty {
            let stamp = SyncBackups.stamp(for: Date())
            let remoteBackup = SyncBackups.remoteRoot(home: connection.info.home) + "/\(backupName)/\(stamp)"
            let localBackup = SyncBackups.localRoot + "/\(backupName)/\(stamp)"

            try await send(.upload, plan.push, backup: nil)
            if !plan.pushOverwriting.isEmpty {
                try await send(.upload, plan.pushOverwriting, backup: remoteBackup)
                outcome.remoteBackupDirectory = remoteBackup
            }
            try await send(.download, plan.pull, backup: nil)
            if !plan.pullOverwriting.isEmpty {
                try FileManager.default.createDirectory(atPath: localBackup, withIntermediateDirectories: true)
                try await send(.download, plan.pullOverwriting, backup: localBackup)
                outcome.localBackupDirectory = localBackup
            }
            if !plan.deleteRemote.isEmpty {
                try await deleteRemote(plan.deleteRemote, backup: remoteBackup)
                outcome.remoteBackupDirectory = remoteBackup
            }
            if !plan.deleteLocal.isEmpty {
                try deleteLocal(plan.deleteLocal)
            }

            localAfter = try await listLocal()
            remoteListing = try await listRemote(createIfMissing: false)
            remoteAfter = remoteListing.tree
            outcome.fingerprint = remoteListing.fingerprint
        }

        outcome.baseline = TwoWayPlanner.nextBaseline(
            plan: plan, localBefore: localBefore, remoteBefore: remoteBefore,
            localAfter: localAfter, remoteAfter: remoteAfter, previous: baseline
        )
        outcome.needsAnotherPass = !plan.isEmpty
            && !TwoWayPlanner.plan(local: localAfter, remote: remoteAfter, baseline: outcome.baseline).isEmpty
        return outcome
    }

    private func listLocal() async throws -> SyncTree {
        let root = localRoot
        let excludes = excludes
        return try await Task.detached(priority: .utility) {
            try SyncListing.local(root: root, excludes: excludes)
        }.value
    }

    private func listRemote(createIfMissing: Bool) async throws -> (tree: SyncTree, fingerprint: String?) {
        let script = SyncListing.remoteScript(root: remoteRoot, excludes: excludes)
        var result = try await connection.run(script, stdin: nil, onStdout: nil, onStderr: nil, log: false)
        if result.exitCode == 3 {
            guard createIfMissing else { throw AppError.general("遠端資料夾不存在：\(remoteRoot)") }
            try await connection.runChecked(UnixCommands.mkdir(remoteRoot))
            result = try await connection.run(script, stdin: nil, onStdout: nil, onStderr: nil, log: false)
        }
        guard result.succeeded else {
            throw AppError.commandFailed(command: "列出遠端 \(remoteRoot)", exitCode: result.exitCode, output: result.stderrText)
        }
        let parsed = SyncListing.parseRemote(result.stdout)
        return (excludes.filter(parsed.tree), parsed.fingerprint)
    }

    private func send(_ direction: TransferDirection, _ paths: [String], backup: String?) async throws {
        guard !paths.isEmpty else { return }
        let listURL = URL(fileURLWithPath: AppPaths.supportDirectory)
            .appendingPathComponent("transfers", isDirectory: true)
            .appendingPathComponent("twoway-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: listURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (paths.joined(separator: "\n") + "\n").write(to: listURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: listURL) }
        try await transfer(direction, listURL.path, backup)
    }

    /// Remote deletions are moves into the backup folder, never `rm`.
    private func deleteRemote(_ paths: [String], backup: String) async throws {
        for chunk in stride(from: 0, to: paths.count, by: 500).map({ Array(paths[$0..<min($0 + 500, paths.count)]) }) {
            var lines = ["cd -- \(Shell.quote(remoteRoot)) || exit 3", "s=0"]
            for path in chunk {
                let parent = path.lastIndex(of: "/").map { String(path[..<$0]) }
                let target = parent.map { backup + "/" + $0 } ?? backup
                lines.append("mkdir -p -- \(Shell.quote(target)) && mv -- \(Shell.quote(path)) \(Shell.quote(target + "/")) || s=1")
            }
            lines.append("exit $s")
            try await connection.runChecked(lines.joined(separator: "\n"))
        }
    }

    /// Local deletions go to the Trash.
    private func deleteLocal(_ paths: [String]) throws {
        var failures: [String] = []
        for path in paths {
            let url = URL(fileURLWithPath: PathUtil.join(localRoot, path))
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                if FileManager.default.fileExists(atPath: url.path) { failures.append(path) }
            }
        }
        if !failures.isEmpty {
            throw AppError.general("無法移到垃圾桶：" + failures.joined(separator: ", "))
        }
    }

}
