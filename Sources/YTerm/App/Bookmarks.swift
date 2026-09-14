import Foundation
import Observation

/// A saved location: a local folder or a folder on one host.
struct Bookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var kind: PaneSide
    var profileID: UUID?
    var path: String

    @MainActor
    func matches(_ pane: PaneModel) -> Bool {
        kind == pane.kind && (kind == .local || profileID == pane.profileID)
    }
}

struct RecentPath: Codable, Hashable {
    var kind: PaneSide
    var profileID: UUID?
    var path: String
    var date: Date

    @MainActor
    func matches(_ pane: PaneModel) -> Bool {
        kind == pane.kind && (kind == .local || profileID == pane.profileID)
    }
}

@MainActor @Observable
final class BookmarkStore {
    private(set) var bookmarks: [Bookmark] = []
    private(set) var recents: [RecentPath] = []

    private struct Persisted: Codable {
        var bookmarks: [Bookmark]
        var recents: [RecentPath]
    }

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? URL(fileURLWithPath: AppPaths.supportDirectory).appendingPathComponent("bookmarks.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        bookmarks = persisted.bookmarks
        recents = persisted.recents
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Persisted(bookmarks: bookmarks, recents: recents)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: Bookmarks

    func add(name: String, kind: PaneSide, profileID: UUID?, path: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let bookmark = Bookmark(name: trimmed.isEmpty ? PathUtil.name(path) : trimmed, kind: kind, profileID: kind == .local ? nil : profileID, path: path)
        if let index = bookmarks.firstIndex(where: { $0.kind == bookmark.kind && $0.profileID == bookmark.profileID && $0.path == bookmark.path }) {
            bookmarks[index].name = bookmark.name
        } else {
            bookmarks.append(bookmark)
        }
        save()
    }

    func add(pane: PaneModel, name: String) {
        add(name: name, kind: pane.kind, profileID: pane.profileID, path: pane.path)
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { bookmarks[index].name = trimmed }
        save()
    }

    func remove(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        bookmarks.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func isBookmarked(_ pane: PaneModel) -> Bool {
        bookmarks.contains { $0.matches(pane) && $0.path == pane.path }
    }

    func bookmarks(for pane: PaneModel) -> [Bookmark] {
        bookmarks.filter { $0.matches(pane) }
    }

    func bookmarksElsewhere(for pane: PaneModel) -> [Bookmark] {
        bookmarks.filter { !$0.matches(pane) }
    }

    // MARK: Recents

    func recordRecent(_ pane: PaneModel) {
        guard pane.isAvailable, pane.path != pane.homePath, pane.path != "/" else { return }
        let entry = RecentPath(kind: pane.kind, profileID: pane.kind == .local ? nil : pane.profileID, path: pane.path, date: Date())
        recents.removeAll { $0.kind == entry.kind && $0.profileID == entry.profileID && $0.path == entry.path }
        recents.insert(entry, at: 0)
        // Keep at most 12 per location.
        var seen: [String: Int] = [:]
        recents = recents.filter { recent in
            let key = "\(recent.kind.rawValue)-\(recent.profileID?.uuidString ?? "")"
            seen[key, default: 0] += 1
            return seen[key]! <= 12
        }
        save()
    }

    func recents(for pane: PaneModel) -> [RecentPath] {
        recents.filter { $0.matches(pane) && $0.path != pane.path }
    }

    func clearRecents() {
        recents.removeAll()
        save()
    }
}
