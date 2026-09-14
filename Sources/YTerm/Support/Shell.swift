import Foundation

/// POSIX shell quoting helpers. Everything we send to `sh -c` (locally or over ssh)
/// goes through here so that spaces, quotes and other special characters are safe.
enum Shell {
    private static let safeCharacters: Set<Character> = {
        var set = Set<Character>()
        for c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./+=:@,%" {
            set.insert(c)
        }
        return set
    }()

    /// Single-quote a value for POSIX shells (`'` becomes `'\''`).
    static func quote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        if value.allSatisfy({ safeCharacters.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func quoteAll(_ values: [String]) -> String {
        values.map(quote).joined(separator: " ")
    }

    /// Split a user supplied option string (e.g. `-J jump -o Foo=bar`) into arguments.
    /// Supports simple single/double quoting.
    static func splitArguments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character? = nil
        var hasToken = false
        for ch in text {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch
                hasToken = true
            } else if ch == " " || ch == "\t" || ch == "\n" {
                if hasToken { result.append(current); current = ""; hasToken = false }
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { result.append(current) }
        return result
    }
}

/// Path helpers that work for remote (POSIX) paths without touching the local disk.
enum PathUtil {
    static func join(_ directory: String, _ name: String) -> String {
        if directory.isEmpty { return name }
        if directory.hasSuffix("/") { return directory + name }
        return directory + "/" + name
    }

    static func name(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        if let idx = trimmed.lastIndex(of: "/") {
            return String(trimmed[trimmed.index(after: idx)...])
        }
        return trimmed
    }

    static func parent(_ path: String) -> String {
        let normalized = normalize(path, relativeTo: "/", home: "/")
        if normalized == "/" { return "/" }
        guard let idx = normalized.lastIndex(of: "/") else { return "/" }
        let parent = String(normalized[..<idx])
        return parent.isEmpty ? "/" : parent
    }

    /// Expand `~`, resolve relative segments and collapse `.`/`..`.
    static func normalize(_ input: String, relativeTo base: String, home: String) -> String {
        var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return base }
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + String(path.dropFirst(1))
        } else if !path.hasPrefix("/") {
            path = base + "/" + path
        }
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { _ = components.popLast(); continue }
            components.append(String(component))
        }
        return "/" + components.joined(separator: "/")
    }

    /// True when `ancestor` is the same as or a parent directory of `path`.
    static func isSameOrAncestor(_ ancestor: String, of path: String) -> Bool {
        if ancestor == path { return true }
        if ancestor == "/" { return true }
        return path.hasPrefix(ancestor + "/")
    }

    /// Strip a known archive extension (`foo.tar.gz` -> `foo`).
    static func stripArchiveExtension(_ name: String) -> String {
        let lower = name.lowercased()
        for ext in ArchiveKind.orderedExtensions {
            if lower.hasSuffix("." + ext) {
                return String(name.dropLast(ext.count + 1))
            }
        }
        return (name as NSString).deletingPathExtension
    }

    static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

enum AppPaths {
    static var supportDirectory: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("YTerm", isDirectory: true)
        // The app used to be called RsyncEnhance; carry its hosts and staging area over once.
        let legacy = base.appendingPathComponent("RsyncEnhance", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}
