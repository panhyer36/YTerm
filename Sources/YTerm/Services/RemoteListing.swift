import Foundation

/// Produces and parses the directory listing script used on remote hosts.
///
/// GNU find (`-printf`) is used when available (Linux); BSD `stat -f` is the fallback (macOS/BSD).
/// Records are NUL-terminated and tab-separated so odd file names survive.
enum RemoteListing {
    static func script(for path: String) -> String {
        let quoted = Shell.quote(path)
        return """
        cd -- \(quoted) || exit 2
        if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
        find . -mindepth 1 -maxdepth 1 -printf 'G\\t%y\\t%Y\\t%s\\t%T@\\t%m\\t%u\\t%g\\t%l\\t%f\\0'
        else
        stat -f 'B%t%HT%t%z%t%m%t%Op%t%Su%t%Sg%t%Y%t%N' -- .* * 2>/dev/null | tr '\\n' '\\0'
        for f in .* *; do [ -L "$f" ] && [ -d "$f" ] && printf 'L\\t%s\\0' "$f"; done
        fi
        exit 0
        """
    }

    static func parse(_ data: Data, directory: String) -> [FileEntry] {
        var entries: [FileEntry] = []
        var indexByName: [String: Int] = [:]
        var symlinkDirectories: Set<String> = []

        for record in data.split(separator: 0, omittingEmptySubsequences: true) {
            let text = String(decoding: record, as: UTF8.self)
            guard let tag = text.first else { continue }
            switch tag {
            case "G":
                let fields = text.split(separator: "\t", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 10 else { continue }
                let typeChar = fields[1]
                let targetType = fields[2]
                let kind: FileKind
                switch typeChar {
                case "d": kind = .directory
                case "f": kind = .file
                case "l": kind = .symlink
                default: kind = .other
                }
                let name = fields[9]
                guard name != "." && name != ".." else { continue }
                let entry = FileEntry(
                    name: name,
                    path: PathUtil.join(directory, name),
                    kind: kind,
                    isDirectoryLike: kind == .directory || (kind == .symlink && targetType == "d"),
                    size: Int64(fields[3]) ?? 0,
                    modified: Date(timeIntervalSince1970: Double(fields[4]) ?? 0),
                    mode: Int(fields[5], radix: 8) ?? 0,
                    owner: fields[6],
                    group: fields[7],
                    linkTarget: kind == .symlink && !fields[8].isEmpty ? fields[8] : nil
                )
                indexByName[name] = entries.count
                entries.append(entry)
            case "B":
                let fields = text.split(separator: "\t", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 9 else { continue }
                let name = fields[8]
                guard name != "." && name != ".." else { continue }
                let typeText = fields[1].lowercased()
                let kind: FileKind
                if typeText.hasPrefix("dir") { kind = .directory }
                else if typeText.hasPrefix("sym") { kind = .symlink }
                else if typeText.hasPrefix("reg") { kind = .file }
                else { kind = .other }
                let modeText = String(fields[4].suffix(4))
                let entry = FileEntry(
                    name: name,
                    path: PathUtil.join(directory, name),
                    kind: kind,
                    isDirectoryLike: kind == .directory,
                    size: Int64(fields[2]) ?? 0,
                    modified: Date(timeIntervalSince1970: Double(fields[3]) ?? 0),
                    mode: Int(modeText, radix: 8) ?? 0,
                    owner: fields[5],
                    group: fields[6],
                    linkTarget: kind == .symlink && !fields[7].isEmpty ? fields[7] : nil
                )
                indexByName[name] = entries.count
                entries.append(entry)
            case "L":
                let fields = text.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                if fields.count == 2 { symlinkDirectories.insert(String(fields[1])) }
            default:
                continue
            }
        }

        for name in symlinkDirectories {
            guard let index = indexByName[name] else { continue }
            let old = entries[index]
            entries[index] = FileEntry(
                name: old.name, path: old.path, kind: old.kind, isDirectoryLike: true,
                size: old.size, modified: old.modified, mode: old.mode,
                owner: old.owner, group: old.group, linkTarget: old.linkTarget
            )
        }
        return entries
    }
}
