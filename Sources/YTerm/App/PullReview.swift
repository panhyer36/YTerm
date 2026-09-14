import Foundation

/// One difference between a remote folder and its local copy, as reported by `rsync -n -i`.
struct PullChange: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case added
        case modified
        case newDirectory
        case deleted

        var label: String {
            switch self {
            case .added: return "新增"
            case .modified: return "修改"
            case .newDirectory: return "新資料夾"
            case .deleted: return "遠端已刪除"
            }
        }
    }

    var relativePath: String
    var kind: Kind
    var size: Int64?

    var id: String { kind.rawValue + ":" + relativePath }
    var isDownloadable: Bool { kind != .deleted }
}

enum PullPreviewParser {
    /// Parses `--out-format=%i\t%l\t%n` lines (deletions show up as `*deleting`).
    static func parse(_ text: String) -> [PullChange] {
        var changes: [PullChange] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let fields = rawLine.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { continue }
            let itemized = fields[0]
            let size: Int64? = fields.count == 3 ? Int64(fields[1]) : nil
            var path = fields.count == 3 ? fields[2] : fields[1]
            path = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, path != "." else { continue }

            if itemized.hasPrefix("*deleting") {
                changes.append(PullChange(relativePath: path, kind: .deleted, size: nil))
                continue
            }
            guard itemized.count >= 11 else { continue }
            let chars = Array(itemized)
            let update = chars[0]
            let type = chars[1]
            let flags = String(chars[2..<11])
            let isNew = flags.allSatisfy { $0 == "+" }
            switch (update, type) {
            case (">", "f"), (">", "L"):
                if isNew {
                    changes.append(PullChange(relativePath: path, kind: .added, size: size))
                } else if flags.contains("s") || flags.contains("c") || flags.contains("t") {
                    changes.append(PullChange(relativePath: path, kind: .modified, size: size))
                }
            case ("c", "d") where isNew:
                changes.append(PullChange(relativePath: path.hasSuffix("/") ? String(path.dropLast()) : path, kind: .newDirectory, size: nil))
            default:
                // Attribute-only changes (".f..p......") and directory timestamps are not worth downloading.
                continue
            }
        }
        return changes
    }
}

/// What the pull review sheet works on.
struct PullReviewRequest: Identifiable, Hashable {
    let id = UUID()
    var profileID: UUID
    var remotePath: String
    var localPath: String
    var mirror: Bool
    var excludes: [String]
    var ruleID: UUID?
}

extension AppState {
    /// Dry-run rsync from the remote folder into the local folder and list what would change.
    func previewPull(_ request: PullReviewRequest, includeDeletions: Bool) async throws -> [PullChange] {
        guard let connection = connections[request.profileID] else { throw AppError.notConnected }
        guard let flavor = rsyncFlavor else { throw AppError.toolMissing("rsync") }
        var options = RsyncOptions(mirror: includeDeletions, excludes: AppSettings.excludes + request.excludes, dryRun: true)
        options.contentsOnly = true
        options.itemize = true
        let remoteIsOpenrsync = connection.info.remoteRsyncIsOpenrsync
        let args = RsyncBuilder.arguments(
            flavor: flavor, direction: .download, localPath: request.localPath, remotePath: request.remotePath,
            remoteDestination: connection.destination, rsh: connection.rshCommand, options: options,
            remoteIsOpenrsync: remoteIsOpenrsync
        )
        let commandLine = Shell.quoteAll([flavor.path] + args)
        let start = Date()
        let result = try await ShellRunner.run(flavor.path, args, options: .init(environment: connection.environment))
        log.record(target: "rsync（試跑）", command: commandLine, exitCode: result.exitCode, output: result.combinedText, duration: Date().timeIntervalSince(start))
        guard result.succeeded else {
            throw AppError.commandFailed(command: commandLine, exitCode: result.exitCode, output: result.stderrText)
        }
        return PullPreviewParser.parse(result.stdoutText)
    }

    /// Download only the chosen changes (and trash chosen local leftovers). Returns once queued.
    func performPull(_ request: PullReviewRequest, download: [PullChange], trash: [PullChange]) {
        guard let connection = connections[request.profileID] else {
            presentError(AppError.notConnected)
            return
        }
        guard let flavor = rsyncFlavor else {
            presentAlert(title: "找不到 rsync", message: "本機沒有可用的 rsync。")
            return
        }
        let hostName = connection.profile.displayName
        let downloadPaths = download.map(\.relativePath)
        let trashPaths = trash.map { PathUtil.join(request.localPath, $0.relativePath) }
        let excludes = request.excludes
        let ruleID = request.ruleID

        if !downloadPaths.isEmpty {
            let listURL = URL(fileURLWithPath: AppPaths.supportDirectory)
                .appendingPathComponent("transfers", isDirectory: true)
                .appendingPathComponent("pull-\(UUID().uuidString).txt")
            let job = TransferJob(
                title: "拉回 \(downloadPaths.count) 個項目 ← \(hostName)",
                subtitle: "\(hostName)：\(request.remotePath) → \(request.localPath)",
                direction: .download
            ) { [weak self] job in
                guard let self else { return }
                try FileManager.default.createDirectory(at: listURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (downloadPaths.joined(separator: "\n") + "\n").write(to: listURL, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: listURL) }
                let entry = FileEntry(
                    name: PathUtil.name(request.localPath), path: request.remotePath, kind: .directory, isDirectoryLike: true,
                    size: 0, modified: Date(), mode: 0o755, owner: "", group: "", linkTarget: nil
                )
                try await self.runRsync(
                    job: job, entry: entry, direction: .download, destinationDirectory: PathUtil.parent(request.localPath),
                    connection: connection, flavor: flavor, mirror: false, contentsOnly: true, extraExcludes: excludes,
                    filesFrom: listURL.path
                )
                if let ruleID, let session = self.syncs.session(ruleID) {
                    session.lastSyncAt = Date()
                    session.syncCount += 1
                }
                self.refreshLocalPanes()
            }
            job.connectionID = connection.profile.id
            transfers.enqueue(job)
            showBottomPanel = true
            bottomTab = .transfers
        }

        if !trashPaths.isEmpty {
            Task {
                do {
                    try await localFileSystem.delete(trashPaths)
                } catch {
                    presentError(error, title: "無法移到垃圾桶")
                }
                refreshLocalPanes()
            }
        }
    }
}
