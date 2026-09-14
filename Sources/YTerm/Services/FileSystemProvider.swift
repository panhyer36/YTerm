import Foundation

/// Command builders shared by the local and remote file systems.
enum UnixCommands {
    static func mkdir(_ path: String) -> String {
        "mkdir -p -- " + Shell.quote(path)
    }

    static func remove(_ paths: [String]) -> String {
        "rm -rf -- " + Shell.quoteAll(paths)
    }

    static func rename(_ path: String, to newPath: String) -> String {
        "mv -- " + Shell.quote(path) + " " + Shell.quote(newPath)
    }

    static func move(_ paths: [String], into directory: String) -> String {
        "mv -- " + Shell.quoteAll(paths) + " " + Shell.quote(directory.hasSuffix("/") ? directory : directory + "/")
    }

    static func copy(_ paths: [String], into directory: String) -> String {
        "cp -Rp -- " + Shell.quoteAll(paths) + " " + Shell.quote(directory.hasSuffix("/") ? directory : directory + "/")
    }

    static func chmod(_ paths: [String], mode: String, recursive: Bool) -> String {
        // `--` goes before the mode: BSD chmod treats a `--` after the mode as a file name.
        "chmod " + (recursive ? "-R " : "") + "-- " + Shell.quote(mode) + " " + Shell.quoteAll(paths)
    }

    static func diskUsage(_ paths: [String]) -> String {
        "du -sh -- " + Shell.quoteAll(paths)
    }

    static func exists(_ path: String) -> String {
        "test -e " + Shell.quote(path)
    }

    static func runInDirectory(_ directory: String, _ command: String) -> String {
        "cd -- " + Shell.quote(directory) + " && " + command
    }

    /// Create an archive from `names` (relative to `directory`).
    static func compress(kind: ArchiveKind, names: [String], in directory: String, archiveName: String) -> String? {
        let items = Shell.quoteAll(names)
        let archive = Shell.quote(archiveName)
        let body: String
        switch kind {
        case .tarGz, .tgz: body = "tar -czf \(archive) -- \(items)"
        case .tarBz2, .tbz2: body = "tar -cjf \(archive) -- \(items)"
        case .tarXz, .txz: body = "tar -cJf \(archive) -- \(items)"
        case .tarZst: body = "tar --zstd -cf \(archive) -- \(items)"
        case .tar: body = "tar -cf \(archive) -- \(items)"
        case .zip: body = "zip -r -q \(archive) \(items)"
        case .sevenZip: body = "7z a -bd -y \(archive) \(items) >/dev/null"
        case .rar, .gz, .bz2, .xz, .zst: return nil
        }
        return runInDirectory(directory, body)
    }

    /// Extract `archivePath` into `target` (created if needed).
    static func extract(kind: ArchiveKind, archivePath: String, into target: String) -> String {
        let archive = Shell.quote(archivePath)
        let dir = Shell.quote(target)
        let name = PathUtil.name(archivePath)
        switch kind {
        case .tarGz, .tgz, .tarBz2, .tbz2, .tarXz, .txz, .tarZst, .tar:
            return "mkdir -p -- \(dir) && tar -xf \(archive) -C \(dir)"
        case .zip:
            return "mkdir -p -- \(dir) && unzip -q -o \(archive) -d \(dir)"
        case .sevenZip:
            return "mkdir -p -- \(dir) && 7z x -bd -y -o\(dir) \(archive) >/dev/null"
        case .rar:
            return "mkdir -p -- \(dir) && unrar x -y \(archive) \(Shell.quote(target + "/")) >/dev/null"
        case .gz:
            let out = Shell.quote(PathUtil.join(target, PathUtil.stripArchiveExtension(name)))
            return "mkdir -p -- \(dir) && gzip -dc \(archive) > \(out)"
        case .bz2:
            let out = Shell.quote(PathUtil.join(target, PathUtil.stripArchiveExtension(name)))
            return "mkdir -p -- \(dir) && bzip2 -dc \(archive) > \(out)"
        case .xz:
            let out = Shell.quote(PathUtil.join(target, PathUtil.stripArchiveExtension(name)))
            return "mkdir -p -- \(dir) && xz -dc \(archive) > \(out)"
        case .zst:
            let out = Shell.quote(PathUtil.join(target, PathUtil.stripArchiveExtension(name)))
            return "mkdir -p -- \(dir) && zstd -dc \(archive) > \(out)"
        }
    }

    /// Script that reports which tools exist (used for both local and remote).
    static let toolProbe = "for c in rsync tar zip unzip gzip bzip2 xz zstd 7z unrar; do command -v \"$c\" >/dev/null 2>&1 && printf '%s\\n' \"$c\"; done; exit 0"
}

/// A browsable file system (local disk or remote host) with the common operations.
protocol FileSystemProvider: AnyObject, Sendable {
    var executor: CommandExecutor { get }
    var homePath: String { get }
    var isRemote: Bool { get }
    var availableTools: Set<String> { get }
    var label: String { get }

    func list(_ path: String) async throws -> [FileEntry]
    func delete(_ paths: [String]) async throws
}

extension FileSystemProvider {
    var label: String { executor.label }

    func hasTools(_ tools: [String]) -> Bool {
        tools.allSatisfy { availableTools.contains($0) }
    }

    func makeDirectory(_ path: String) async throws {
        try await executor.runChecked(UnixCommands.mkdir(path))
    }

    func rename(_ path: String, to newPath: String) async throws {
        try await executor.runChecked(UnixCommands.rename(path, to: newPath))
    }

    func move(_ paths: [String], into directory: String) async throws {
        try await executor.runChecked(UnixCommands.move(paths, into: directory))
    }

    func copy(_ paths: [String], into directory: String) async throws {
        try await executor.runChecked(UnixCommands.copy(paths, into: directory))
    }

    func chmod(_ paths: [String], mode: String, recursive: Bool) async throws {
        try await executor.runChecked(UnixCommands.chmod(paths, mode: mode, recursive: recursive))
    }

    func compress(_ names: [String], in directory: String, kind: ArchiveKind, archiveName: String) async throws {
        let missing = kind.requiredTools.filter { !availableTools.contains($0) }
        if let tool = missing.first, !availableTools.isEmpty {
            throw AppError.toolMissing("\(tool)（\(label)）")
        }
        guard let script = UnixCommands.compress(kind: kind, names: names, in: directory, archiveName: archiveName) else {
            throw AppError.unsupportedArchive(kind.rawValue)
        }
        try await executor.runChecked(script)
    }

    func extract(_ archivePath: String, into target: String) async throws {
        guard let kind = ArchiveKind.detect(fileName: PathUtil.name(archivePath)) else {
            throw AppError.unsupportedArchive(PathUtil.name(archivePath))
        }
        let missing = kind.extractionTools.filter { !availableTools.contains($0) }
        if let tool = missing.first, !availableTools.isEmpty {
            throw AppError.toolMissing("\(tool)（\(label)）")
        }
        try await executor.runChecked(UnixCommands.extract(kind: kind, archivePath: archivePath, into: target))
    }

    func runCommand(_ command: String, in directory: String) async throws -> CommandResult {
        try await executor.run(UnixCommands.runInDirectory(directory, command))
    }

    func diskUsage(_ paths: [String]) async throws -> String {
        let result = try await executor.runChecked(UnixCommands.diskUsage(paths))
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func exists(_ path: String) async throws -> Bool {
        let result = try await executor.run(UnixCommands.exists(path))
        return result.succeeded
    }

    static func parseToolProbe(_ text: String) -> Set<String> {
        Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
}

// MARK: - Local

final class LocalFileSystem: FileSystemProvider, @unchecked Sendable {
    let executor: CommandExecutor
    let homePath: String = NSHomeDirectory()
    let isRemote = false
    private let toolsLock = NSLock()
    private var tools: Set<String> = []
    private let log: CommandLog

    var availableTools: Set<String> { toolsLock.withLock { tools } }

    init(log: CommandLog) {
        self.log = log
        self.executor = LocalExecutor(log: log)
    }

    func detectTools() async {
        guard let result = try? await ShellRunner.run("/bin/sh", ["-c", UnixCommands.toolProbe], options: .init(environment: LocalEnvironment.base)) else { return }
        let found = Self.parseToolProbe(result.stdoutText)
        toolsLock.withLock { tools = found }
    }

    func list(_ path: String) async throws -> [FileEntry] {
        try await Task.detached(priority: .userInitiated) {
            let names = try FileManager.default.contentsOfDirectory(atPath: path)
            var result: [FileEntry] = []
            result.reserveCapacity(names.count)
            for name in names {
                let full = PathUtil.join(path, name)
                // lstat() only. FileManager.attributesOfItem also reads extended attributes, and getxattr
                // can block for a very long time on cloud-provider folders (iCloud Drive, Dropbox, …).
                var info = stat()
                guard lstat(full, &info) == 0 else { continue }
                let kind: FileKind
                switch info.st_mode & S_IFMT {
                case S_IFDIR: kind = .directory
                case S_IFREG: kind = .file
                case S_IFLNK: kind = .symlink
                default: kind = .other
                }
                var isDirectoryLike = kind == .directory
                var linkTarget: String? = nil
                if kind == .symlink {
                    linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: full)
                    var target = stat()
                    if stat(full, &target) == 0 {
                        isDirectoryLike = (target.st_mode & S_IFMT) == S_IFDIR
                    }
                }
                let modified = Date(
                    timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
                )
                result.append(FileEntry(
                    name: name,
                    path: full,
                    kind: kind,
                    isDirectoryLike: isDirectoryLike,
                    size: Int64(info.st_size),
                    modified: modified,
                    mode: Int(info.st_mode & 0o7777),
                    owner: OwnerNames.user(info.st_uid),
                    group: OwnerNames.group(info.st_gid),
                    linkTarget: linkTarget
                ))
            }
            return result
        }.value
    }

    /// Local deletes go to the Trash so mistakes are recoverable.
    func delete(_ paths: [String]) async throws {
        let start = Date()
        var failures: [String] = []
        for path in paths {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            } catch {
                failures.append("\(PathUtil.name(path))：\(error.localizedDescription)")
            }
        }
        log.record(
            target: executor.label,
            command: "移到垃圾桶：" + paths.map(PathUtil.name).joined(separator: ", "),
            exitCode: failures.isEmpty ? 0 : 1,
            output: failures.joined(separator: "\n"),
            duration: Date().timeIntervalSince(start)
        )
        if !failures.isEmpty {
            throw AppError.general("部分項目無法移到垃圾桶：\n" + failures.joined(separator: "\n"))
        }
    }
}

// MARK: - Remote

final class RemoteFileSystem: FileSystemProvider, @unchecked Sendable {
    let connection: RemoteConnection
    let isRemote = true

    var executor: CommandExecutor { connection }
    var homePath: String { connection.info.home }
    var availableTools: Set<String> { connection.info.tools }

    init(connection: RemoteConnection) {
        self.connection = connection
    }

    func list(_ path: String) async throws -> [FileEntry] {
        let result = try await connection.run(RemoteListing.script(for: path))
        guard result.succeeded else {
            let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.general(message.isEmpty ? "無法讀取目錄：\(path)" : message)
        }
        return RemoteListing.parse(result.stdout, directory: path)
    }

    func delete(_ paths: [String]) async throws {
        for path in paths {
            let normalized = PathUtil.normalize(path, relativeTo: "/", home: homePath)
            if normalized == "/" || normalized == homePath {
                throw AppError.refused("為了安全，拒絕刪除根目錄或家目錄：\(path)")
            }
        }
        try await executor.runChecked(UnixCommands.remove(paths))
    }
}

/// Cached uid/gid → name lookups for local listings.
enum OwnerNames {
    private static let lock = NSLock()
    private static var users: [uid_t: String] = [:]
    private static var groups: [gid_t: String] = [:]

    static func user(_ uid: uid_t) -> String {
        lock.withLock {
            if let cached = users[uid] { return cached }
            let name = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
            users[uid] = name
            return name
        }
    }

    static func group(_ gid: gid_t) -> String {
        lock.withLock {
            if let cached = groups[gid] { return cached }
            let name = getgrgid(gid).map { String(cString: $0.pointee.gr_name) } ?? String(gid)
            groups[gid] = name
            return name
        }
    }
}
