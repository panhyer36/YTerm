import AppKit
import UniformTypeIdentifiers

/// Finder-style icons looked up by file extension (works for remote entries too).
@MainActor
final class IconCache {
    static let shared = IconCache()

    private var cache: [String: NSImage] = [:]
    private lazy var folderIcon = NSWorkspace.shared.icon(for: .folder)
    private lazy var genericIcon = NSWorkspace.shared.icon(for: .data)
    private lazy var executableIcon = NSWorkspace.shared.icon(for: .unixExecutable)
    private lazy var symlinkIcon = NSWorkspace.shared.icon(for: .symbolicLink)

    func icon(for entry: FileEntry) -> NSImage {
        if entry.isDirectoryLike { return folderIcon }
        if entry.kind == .symlink { return symlinkIcon }
        let ext = entry.fileExtension
        if ext.isEmpty {
            return entry.mode & 0o111 != 0 ? executableIcon : genericIcon
        }
        if let cached = cache[ext] { return cached }
        let type = UTType(filenameExtension: ext) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        cache[ext] = icon
        return icon
    }
}
