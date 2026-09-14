import Foundation
import Observation

/// What a pane shows: the local disk or a remote host.
enum PaneSide: String, Sendable, Hashable, Codable {
    case local
    case remote

    var other: PaneSide { self == .local ? .remote : .local }
    var label: String { self == .local ? "本機" : "遠端" }
}

/// State of one file browser pane. Panes can be split freely; each one is local or bound to a host profile.
@MainActor @Observable
final class PaneModel: Identifiable {
    let id = UUID()
    var kind: PaneSide
    /// Host profile this pane is (or was last) connected to. Stays set after a disconnect so the pane can reconnect.
    var profileID: UUID?
    var title: String
    var provider: FileSystemProvider?
    /// Path to open instead of the profile start path once the pane gets connected.
    var pendingPath: String?
    var path: String = "/"
    var entries: [FileEntry] = []
    var selection: Set<String> = []
    var sortOrder: [KeyPathComparator<FileEntry>] = [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)]
    var showHidden = false
    var isLoading = false
    var errorMessage: String?
    private(set) var backStack: [String] = []
    private(set) var forwardStack: [String] = []
    private var loadGeneration = 0

    init(kind: PaneSide, title: String, profileID: UUID? = nil) {
        self.kind = kind
        self.title = title
        self.profileID = profileID
    }

    var isAvailable: Bool { provider != nil }
    var isRemote: Bool { kind == .remote }
    var homePath: String { provider?.homePath ?? "/" }
    var canGoUp: Bool { path != "/" }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// "本機" or "主機名稱：/path" for menus and confirmations.
    var locationText: String { "\(title)：\(path)" }

    var visibleEntries: [FileEntry] {
        let filtered = showHidden ? entries : entries.filter { !$0.isHidden }
        let directories = filtered.filter(\.isDirectoryLike).sorted(using: sortOrder)
        let files = filtered.filter { !$0.isDirectoryLike }.sorted(using: sortOrder)
        return directories + files
    }

    var selectedEntries: [FileEntry] {
        visibleEntries.filter { selection.contains($0.id) }
    }

    func entries(for ids: Set<String>) -> [FileEntry] {
        visibleEntries.filter { ids.contains($0.id) }
    }

    var statusText: String {
        let visible = visibleEntries
        var text = "\(visible.count) 個項目"
        let hiddenCount = entries.count - visible.count
        if hiddenCount > 0 { text += "（隱藏 \(hiddenCount)）" }
        let selected = selectedEntries
        if !selected.isEmpty {
            let bytes = selected.filter { !$0.isDirectoryLike }.reduce(Int64(0)) { $0 + $1.size }
            text += " · 已選 \(selected.count) 個"
            if bytes > 0 { text += "，" + FileEntry.byteFormatter.string(fromByteCount: bytes) }
        }
        return text
    }

    func attach(provider: FileSystemProvider, startPath: String) {
        self.provider = provider
        backStack = []
        forwardStack = []
        selection = []
        entries = []
        errorMessage = nil
        path = PathUtil.normalize(startPath, relativeTo: provider.homePath, home: provider.homePath)
        load()
    }

    /// Drops the provider (e.g. after a disconnect) but keeps kind/profile so the pane can reconnect.
    func detach() {
        loadGeneration += 1
        provider = nil
        entries = []
        selection = []
        backStack = []
        forwardStack = []
        errorMessage = nil
        isLoading = false
        path = "/"
    }

    func navigate(to input: String, recordHistory: Bool = true) {
        guard let provider else { return }
        let target = PathUtil.normalize(input, relativeTo: path, home: provider.homePath)
        if recordHistory, target != path {
            backStack.append(path)
            forwardStack.removeAll()
        }
        path = target
        selection = []
        load()
    }

    func enter(_ entry: FileEntry) {
        guard entry.isDirectoryLike else { return }
        navigate(to: entry.path)
    }

    func goUp() {
        guard canGoUp else { return }
        let current = PathUtil.name(path)
        navigate(to: PathUtil.parent(path))
        selection = [PathUtil.join(path, current)]
    }

    func goHome() {
        navigate(to: homePath)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        path = previous
        selection = []
        load()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        path = next
        selection = []
        load()
    }

    func reload() {
        load()
    }

    private func load() {
        guard let provider else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let target = path
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let list = try await provider.list(target)
                guard generation == loadGeneration else { return }
                entries = list
                let ids = Set(list.map(\.id))
                selection = selection.filter { ids.contains($0) }
            } catch {
                guard generation == loadGeneration else { return }
                entries = []
                selection = []
                errorMessage = error.localizedDescription
            }
            if generation == loadGeneration { isLoading = false }
        }
    }
}
