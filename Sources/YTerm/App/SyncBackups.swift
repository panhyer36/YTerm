import Foundation

/// Backups written by two-way sync: the losing copy of a conflict and files deleted on the remote
/// side. Each pass that backs something up writes one snapshot folder named after its time:
/// `<root>/<rule folder>/<yyyyMMdd-HHmmss>/<relative path>`. Locally the root is in Application
/// Support; remotely it is `~/.yterm-sync-backup`. Nothing reads these folders back, so any of
/// them can be deleted at any time.
enum SyncBackups {
    static var localRoot: String { AppPaths.supportDirectory + "/sync-backup" }

    static func remoteRoot(home: String) -> String {
        PathUtil.join(home, SyncRule.backupFolderName)
    }

    /// Short, shell-safe folder name for one rule.
    static func folderName(for ruleID: UUID) -> String {
        String(ruleID.uuidString.prefix(8))
    }

    static func stamp(for date: Date) -> String {
        stampFormatter.string(from: date)
    }

    /// Snapshots whose stamp sorts before this are expired; nil means keep forever (0 days).
    static func cutoff(retentionDays: Int, now: Date = Date()) -> String? {
        guard retentionDays > 0 else { return nil }
        return stamp(for: now.addingTimeInterval(-Double(retentionDays) * 86_400))
    }

    /// Sorts after every real stamp: removes all snapshots.
    static let everything = "99999999-999999"

    static func isStamp(_ name: String) -> Bool {
        name.range(of: #"^\d{8}-\d{6}$"#, options: .regularExpression) != nil
    }

    struct Usage: Equatable, Sendable {
        var snapshots = 0
        var bytes: Int64 = 0
        var oldest: String?

        var oldestDate: Date? { oldest.flatMap { stampFormatter.date(from: $0) } }
    }

    // MARK: Local

    /// Removes snapshot folders older than `cutoff` (one rule's, or every rule's), then empty rule
    /// folders. Returns how many snapshots were removed.
    @discardableResult
    static func pruneLocal(before cutoff: String, ruleFolder: String? = nil, root: String = localRoot) -> Int {
        let fm = FileManager.default
        var removed = 0
        for folder in ruleFolders(ruleFolder, root: root) {
            let path = root + "/" + folder
            for snapshot in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where isStamp(snapshot) && snapshot < cutoff {
                if (try? fm.removeItem(atPath: path + "/" + snapshot)) != nil { removed += 1 }
            }
            if (try? fm.contentsOfDirectory(atPath: path))?.isEmpty == true { try? fm.removeItem(atPath: path) }
        }
        return removed
    }

    static func localUsage(ruleFolder: String, root: String = localRoot) -> Usage {
        let path = root + "/" + ruleFolder
        let snapshots = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter(isStamp).sorted()
        var usage = Usage(snapshots: snapshots.count, oldest: snapshots.first)
        if let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: []
        ) {
            for case let url as URL in enumerator {
                usage.bytes += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            }
        }
        return usage
    }

    private static func ruleFolders(_ ruleFolder: String?, root: String) -> [String] {
        if let ruleFolder { return [ruleFolder] }
        return (try? FileManager.default.contentsOfDirectory(atPath: root))?.filter { !$0.hasPrefix(".") } ?? []
    }

    // MARK: Remote

    /// Same as `pruneLocal` on the remote side; prints the number of removed snapshots.
    static func remotePruneScript(home: String, before cutoff: String, ruleFolder: String? = nil) -> String {
        let pattern = (ruleFolder.map(Shell.quote) ?? "*") + "/[0-9]*-[0-9]*"
        return """
        cd -- \(Shell.quote(remoteRoot(home: home))) 2>/dev/null || { echo 0; exit 0; }
        n=0
        for d in \(pattern); do
        [ -d "$d" ] || continue
        s=${d##*/}
        case "$s" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) continue;; esac
        if expr "$s" \\< \(Shell.quote(cutoff)) >/dev/null; then rm -rf -- "$d" && n=$((n+1)); fi
        done
        for r in */; do rmdir -- "$r" 2>/dev/null; done
        cd .. && rmdir -- \(Shell.quote(SyncRule.backupFolderName)) 2>/dev/null
        echo "$n"
        exit 0
        """
    }

    /// Prints `snapshots\tkilobytes\toldest` for one rule's remote backups.
    static func remoteUsageScript(home: String, ruleFolder: String) -> String {
        """
        cd -- \(Shell.quote(PathUtil.join(remoteRoot(home: home), ruleFolder))) 2>/dev/null || { printf '0\\t0\\t\\n'; exit 0; }
        l=$(ls -1 | grep -E '^[0-9]{8}-[0-9]{6}$' | sort)
        n=$(printf '%s\\n' "$l" | grep -c .)
        k=$(du -sk . 2>/dev/null | cut -f1)
        printf '%s\\t%s\\t%s\\n' "$n" "${k:-0}" "$(printf '%s\\n' "$l" | head -n 1)"
        exit 0
        """
    }

    static func parseRemoteUsage(_ text: String) -> Usage {
        let fields = text.trimmingCharacters(in: .newlines).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2 else { return Usage() }
        let oldest = fields.count > 2 && isStamp(fields[2]) ? fields[2] : nil
        let snapshots = Int(fields[0].trimmingCharacters(in: .whitespaces)) ?? 0
        return Usage(snapshots: snapshots, bytes: snapshots == 0 ? 0 : (Int64(fields[1]) ?? 0) * 1024, oldest: oldest)
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
