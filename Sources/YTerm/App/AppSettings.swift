import Foundation

enum SettingsKey {
    static let rsyncPath = "rsyncPath"
    static let compress = "rsyncCompress"
    static let excludes = "rsyncExcludes"
    static let confirmDelete = "confirmDelete"
    static let maxConcurrentTransfers = "maxConcurrentTransfers"
    static let localStartPath = "localStartPath"
    static let showHiddenFiles = "showHiddenFiles"
    static let editorAppPath = "editorAppPath"
    static let preferredIDE = "preferredIDE"
}

enum AppSettings {
    static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            SettingsKey.confirmDelete: true,
            SettingsKey.excludes: ".DS_Store",
            SettingsKey.maxConcurrentTransfers: 2,
            SettingsKey.compress: false,
            SettingsKey.showHiddenFiles: false,
        ])
    }

    static var rsyncPath: String { defaults.string(forKey: SettingsKey.rsyncPath) ?? "" }
    static var compress: Bool { defaults.bool(forKey: SettingsKey.compress) }
    static var confirmDelete: Bool { defaults.bool(forKey: SettingsKey.confirmDelete) }
    static var showHiddenFiles: Bool { defaults.bool(forKey: SettingsKey.showHiddenFiles) }
    static var localStartPath: String { defaults.string(forKey: SettingsKey.localStartPath) ?? "" }
    static var editorAppPath: String { defaults.string(forKey: SettingsKey.editorAppPath) ?? "" }
    /// nil = automatic (first installed editor).
    static var preferredIDE: IDEKind? { IDEKind(rawValue: defaults.string(forKey: SettingsKey.preferredIDE) ?? "") }

    static var maxConcurrentTransfers: Int {
        let value = defaults.integer(forKey: SettingsKey.maxConcurrentTransfers)
        return max(1, min(value == 0 ? 2 : value, 6))
    }

    static var excludes: [String] {
        (defaults.string(forKey: SettingsKey.excludes) ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
