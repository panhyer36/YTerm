import Foundation

enum FileKind: String, Sendable {
    case directory
    case file
    case symlink
    case other
}

struct FileEntry: Identifiable, Hashable, Sendable {
    var id: String { path }

    let name: String
    let path: String
    let kind: FileKind
    /// Directory, or symlink pointing at a directory.
    let isDirectoryLike: Bool
    let size: Int64
    let modified: Date
    /// Permission bits (0o7777 mask).
    let mode: Int
    let owner: String
    let group: String
    let linkTarget: String?

    var isHidden: Bool { name.hasPrefix(".") }
    var sizeSortKey: Int64 { isDirectoryLike ? -1 : size }

    var sizeText: String {
        (isDirectoryLike || kind == .symlink) ? "—" : FileEntry.byteFormatter.string(fromByteCount: size)
    }

    var modifiedText: String {
        modified.timeIntervalSince1970 == 0 ? "—" : FileEntry.dateFormatter.string(from: modified)
    }

    var ownerText: String {
        if owner.isEmpty { return group }
        if group.isEmpty { return owner }
        return "\(owner):\(group)"
    }

    var octalMode: String { String(format: "%03o", mode & 0o7777) }

    var permissionText: String {
        let prefix: String
        switch kind {
        case .directory: prefix = "d"
        case .symlink: prefix = "l"
        case .file: prefix = "-"
        case .other: prefix = "?"
        }
        var text = prefix
        let triplets: [(shift: Int, special: Int, specialChar: Character)] = [
            (6, 0o4000, "s"), (3, 0o2000, "s"), (0, 0o1000, "t"),
        ]
        for triplet in triplets {
            let bits = (mode >> triplet.shift) & 0o7
            text.append(bits & 4 != 0 ? "r" : "-")
            text.append(bits & 2 != 0 ? "w" : "-")
            let executable = bits & 1 != 0
            if mode & triplet.special != 0 {
                text.append(executable ? triplet.specialChar : Character(triplet.specialChar.uppercased()))
            } else {
                text.append(executable ? "x" : "-")
            }
        }
        return text
    }

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    var archiveKind: ArchiveKind? { ArchiveKind.detect(fileName: name) }
    var isArchive: Bool { archiveKind != nil }

    static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

/// Archive types we know how to create and/or extract.
enum ArchiveKind: String, CaseIterable, Identifiable, Sendable {
    case tarGz = "tar.gz"
    case tgz = "tgz"
    case tarBz2 = "tar.bz2"
    case tbz2 = "tbz2"
    case tarXz = "tar.xz"
    case txz = "txz"
    case tarZst = "tar.zst"
    case tar = "tar"
    case zip = "zip"
    case sevenZip = "7z"
    case rar = "rar"
    case gz = "gz"
    case bz2 = "bz2"
    case xz = "xz"
    case zst = "zst"

    var id: String { rawValue }

    /// Longest extensions first so `tar.gz` wins over `gz`.
    static let orderedExtensions: [String] = allCases.map(\.rawValue).sorted { $0.count > $1.count }

    static func detect(fileName: String) -> ArchiveKind? {
        let lower = fileName.lowercased()
        for ext in orderedExtensions where lower.hasSuffix("." + ext) {
            return ArchiveKind(rawValue: ext)
        }
        return nil
    }

    /// Formats offered when creating a new archive.
    static let creatable: [ArchiveKind] = [.tarGz, .zip, .tarXz, .tarBz2, .tarZst, .tar, .sevenZip]

    var displayName: String {
        switch self {
        case .tarGz, .tgz: return "tar.gz（gzip）"
        case .tarBz2, .tbz2: return "tar.bz2（bzip2）"
        case .tarXz, .txz: return "tar.xz（xz）"
        case .tarZst: return "tar.zst（zstd）"
        case .tar: return "tar（不壓縮）"
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .rar: return "rar"
        case .gz: return "gzip 單一檔案"
        case .bz2: return "bzip2 單一檔案"
        case .xz: return "xz 單一檔案"
        case .zst: return "zstd 單一檔案"
        }
    }

    /// Tools that must exist on the machine that performs the (de)compression.
    var requiredTools: [String] {
        switch self {
        case .tarGz, .tgz: return ["tar", "gzip"]
        case .tarBz2, .tbz2: return ["tar", "bzip2"]
        case .tarXz, .txz: return ["tar", "xz"]
        case .tarZst: return ["tar", "zstd"]
        case .tar: return ["tar"]
        case .zip: return ["zip"]
        case .sevenZip: return ["7z"]
        case .rar: return ["unrar"]
        case .gz: return ["gzip"]
        case .bz2: return ["bzip2"]
        case .xz: return ["xz"]
        case .zst: return ["zstd"]
        }
    }

    var extractionTools: [String] {
        switch self {
        case .zip: return ["unzip"]
        default: return requiredTools
        }
    }
}
