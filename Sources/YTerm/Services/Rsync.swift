import Foundation

enum TransferDirection: String, Sendable {
    case upload
    case download

    var verb: String { self == .upload ? "上傳" : "下載" }
}

/// Which rsync binary we have. macOS 15+ ships `openrsync`, which lacks `--info=progress2` and `-s`.
struct RsyncFlavor: Sendable, Equatable {
    enum Kind: String, Sendable {
        case rsync
        case openrsync
    }

    let path: String
    let kind: Kind
    let version: String

    var supportsOverallProgress: Bool { kind == .rsync }

    /// Parsed "major.minor.patch" of the version string (0,0,0 when unknown).
    var versionTuple: (Int, Int, Int) {
        guard let range = version.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return (0, 0, 0) }
        let parts = version[range].split(separator: ".").map { Int($0) ?? 0 }
        return (parts.count > 0 ? parts[0] : 0, parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0)
    }

    /// rsync 3.2.4+ backslash-escapes remote paths for the remote shell by itself, which works with any
    /// remote rsync (even openrsync). Older versions and openrsync need the path shell-quoted by us.
    /// (`-s` / --secluded-args is deliberately not used: remote openrsync rejects it.)
    var escapesRemoteArguments: Bool {
        guard kind == .rsync else { return false }
        let v = versionTuple
        return v.0 > 3 || (v.0 == 3 && (v.1 > 2 || (v.1 == 2 && v.2 >= 4)))
    }

    var displayName: String {
        switch kind {
        case .rsync: return "rsync \(version)（\(path)）"
        case .openrsync: return "openrsync（macOS 內建，\(path)）"
        }
    }
}

enum RsyncLocator {
    static func detect(customPath: String) async -> RsyncFlavor? {
        var candidates: [String] = []
        let trimmed = customPath.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { candidates.append(PathUtil.expandTilde(trimmed)) }
        candidates += ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/opt/local/bin/rsync", "/usr/bin/rsync"]

        var fallback: RsyncFlavor? = nil
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            guard let result = try? await ShellRunner.run(path, ["--version"]),
                  let firstLine = result.stdoutText.split(separator: "\n").first else { continue }
            let line = String(firstLine)
            let lower = line.lowercased()
            if lower.contains("openrsync") {
                if fallback == nil { fallback = RsyncFlavor(path: path, kind: .openrsync, version: line) }
            } else if lower.contains("rsync") {
                let version = line.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression).map { String(line[$0]) } ?? line
                return RsyncFlavor(path: path, kind: .rsync, version: version)
            }
        }
        return fallback
    }
}

struct RsyncOptions: Sendable {
    var compress = false
    /// Sync the *contents* of a directory and delete extraneous files on the destination.
    var mirror = false
    /// Sync directory contents into the destination directory (trailing slashes) without deleting.
    var contentsOnly = false
    var excludes: [String] = []
    var dryRun = false
    /// Print one `%i\t%l\t%n` line per change (used with dryRun to preview a pull).
    var itemize = false
    /// Only transfer the relative paths listed in this file (implies -r so listed folders recurse).
    var filesFrom: String? = nil
    /// Transfer one file with `-t` instead of `-a`: times are kept, but an existing destination
    /// file retains its own permissions/owner (used by remote editing).
    var singleFile = false
}

/// How progress is reported: `overall` needs real rsync on both ends (`--info=progress2`), otherwise
/// per-file `--progress` output is all that is available.
enum RsyncProgressStyle: Sendable {
    case overall
    case perFile
}

enum RsyncBuilder {
    static func progressStyle(flavor: RsyncFlavor, remoteIsOpenrsync: Bool) -> RsyncProgressStyle {
        flavor.kind == .rsync && !remoteIsOpenrsync ? .overall : .perFile
    }

    /// Build rsync arguments.
    ///
    /// - For a normal transfer, the source side is the item and the destination side is the directory
    ///   that will receive it (a trailing slash is added).
    /// - For a mirror transfer, both sides are directories whose contents are synchronised.
    static func arguments(
        flavor: RsyncFlavor,
        direction: TransferDirection,
        localPath: String,
        remotePath: String,
        remoteDestination: String,
        rsh: String,
        options: RsyncOptions,
        remoteIsOpenrsync: Bool = false
    ) -> [String] {
        var args = [options.singleFile ? "-t" : "-a", "-h", "--partial"]
        // A save that keeps the size and lands within the same second would otherwise be skipped by
        // rsync's quick check, so single-file (edit) transfers ignore size/time and always send.
        if options.singleFile { args.append("-I") }
        // rsync forwards --info/--no-inc-recursive to the server, which openrsync rejects.
        switch progressStyle(flavor: flavor, remoteIsOpenrsync: remoteIsOpenrsync) {
        case .overall:
            args += ["--info=progress2,name1", "--no-inc-recursive"]
        case .perFile:
            args += ["-v", "--progress"]
        }
        if options.compress { args.append("-z") }
        if options.mirror { args.append("--delete") }
        if options.dryRun { args.append("-n") }
        if options.itemize { args += ["-i", "--out-format=%i\t%l\t%n"] }
        if let filesFrom = options.filesFrom { args += ["-r", "--files-from=" + filesFrom] }
        for pattern in options.excludes where !pattern.isEmpty {
            args.append("--exclude=" + pattern)
        }
        args += ["-e", rsh]

        func remoteSpec(_ path: String) -> String {
            let quoted = flavor.escapesRemoteArguments ? path : Shell.quote(path)
            return remoteDestination + ":" + quoted
        }

        let syncTree = options.mirror || options.contentsOnly
        switch direction {
        case .upload:
            let source = syncTree ? withSlash(localPath) : localPath
            args += [source, remoteSpec(withSlash(remotePath))]
        case .download:
            let source = syncTree ? withSlash(remotePath) : remotePath
            args += [remoteSpec(source), withSlash(localPath)]
        }
        return args
    }

    static func withSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }
}

struct RsyncProgress: Sendable, Equatable {
    var overallFraction: Double? = nil
    var fileFraction: Double? = nil
    var transferred: String = ""
    var speed: String = ""
    var eta: String = ""
    var currentFile: String = ""
    var filesDone: Int = 0
    var filesTotal: Int? = nil
}

/// Parses rsync's stdout (`--info=progress2` or openrsync's `--progress`) incrementally.
final class RsyncProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var current = RsyncProgress()
    private var lastEmit = Date.distantPast
    let kind: RsyncFlavor.Kind

    private static let progressRegex = try! NSRegularExpression(
        pattern: #"^\s*([0-9][0-9,\.]*[kKMGTP]?)\s+(\d{1,3})%\s+(\S+)\s+(\d+:\d{2}:\d{2})(?:\s+\(xf(?:r|er)#(\d+),\s+(?:ir-chk|to-chk|to-check)=(\d+)/(\d+)\))?"#
    )
    private static let startRegex = try! NSRegularExpression(pattern: #"^Transfer starting: (\d+) files"#)
    private static let ignoredPrefixes = [
        "sent ", "total size", "sending incremental", "receiving incremental", "building file list",
        "created directory", "Transfer starting", "receiving file list", "delta-transmission", "total: ",
        "deleting ",
    ]

    init(kind: RsyncFlavor.Kind) {
        self.kind = kind
    }

    convenience init(style: RsyncProgressStyle) {
        self.init(kind: style == .overall ? .rsync : .openrsync)
    }

    var snapshot: RsyncProgress { lock.withLock { current } }

    /// Feed raw stdout bytes. Returns a throttled progress update when something changed.
    func feed(_ data: Data) -> RsyncProgress? {
        lock.withLock {
            buffer.append(data)
            var changed = false
            while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = buffer.subdata(in: buffer.startIndex..<index)
                buffer.removeSubrange(buffer.startIndex...index)
                if handle(String(decoding: lineData, as: UTF8.self)) { changed = true }
            }
            guard changed else { return nil }
            let now = Date()
            if now.timeIntervalSince(lastEmit) < 0.1 { return nil }
            lastEmit = now
            return current
        }
    }

    /// Parse a complete line (no locking; called from `feed`). Exposed for tests via `parseLine`.
    @discardableResult
    func parseLine(_ line: String) -> Bool {
        lock.withLock { handle(line) }
    }

    private func handle(_ rawLine: String) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return false }
        let range = NSRange(line.startIndex..., in: line)

        if let match = Self.progressRegex.firstMatch(in: line, range: range) {
            func group(_ index: Int) -> String? {
                guard let r = Range(match.range(at: index), in: line) else { return nil }
                return String(line[r])
            }
            let percent = Double(group(2) ?? "") ?? 0
            current.transferred = group(1) ?? ""
            current.speed = group(3) ?? ""
            current.eta = group(4) ?? ""
            if let done = group(5).flatMap({ Int($0) }) { current.filesDone = done }
            if kind == .rsync, let total = group(7).flatMap({ Int($0) }) { current.filesTotal = total }
            switch kind {
            case .rsync:
                current.overallFraction = percent / 100
                current.fileFraction = nil
            case .openrsync:
                current.fileFraction = percent / 100
                if let total = current.filesTotal, total > 0 {
                    let done = max(current.filesDone - 1, 0)
                    current.overallFraction = min(1, (Double(done) + percent / 100) / Double(total))
                }
            }
            return true
        }

        if let match = Self.startRegex.firstMatch(in: line, range: range),
           let r = Range(match.range(at: 1), in: line), let total = Int(line[r]) {
            current.filesTotal = total
            return true
        }

        for prefix in Self.ignoredPrefixes where line.hasPrefix(prefix) { return false }
        current.currentFile = line
        return true
    }
}
