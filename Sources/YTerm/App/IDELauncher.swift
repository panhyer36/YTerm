import AppKit
import Foundation

/// Editors that can open a folder locally or through Remote-SSH (`vscode-remote://ssh-remote+host/path`).
enum IDEKind: String, CaseIterable, Identifiable, Sendable {
    case cursor
    case vscode
    case vscodeInsiders

    var id: String { rawValue }

    var name: String {
        switch self {
        case .cursor: return "Cursor"
        case .vscode: return "VS Code"
        case .vscodeInsiders: return "VS Code Insiders"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .vscode: return "com.microsoft.VSCode"
        case .vscodeInsiders: return "com.microsoft.VSCodeInsiders"
        }
    }

    /// Command-line launcher, checked in order: the app bundle's own CLI, then the shell-command symlinks.
    var cliCandidates: [String] {
        let home = NSHomeDirectory()
        switch self {
        case .cursor:
            return [
                "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
                home + "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
                "/usr/local/bin/cursor", "/opt/homebrew/bin/cursor",
            ]
        case .vscode:
            return [
                "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
                home + "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
                "/usr/local/bin/code", "/opt/homebrew/bin/code",
            ]
        case .vscodeInsiders:
            return [
                "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code-insiders",
                home + "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code-insiders",
                "/usr/local/bin/code-insiders", "/opt/homebrew/bin/code-insiders",
            ]
        }
    }
}

/// Opens a pane's directory in Cursor / VS Code: locally as a folder, remotely through the
/// editor's Remote-SSH support.
enum IDELauncher {
    struct IDE: Equatable {
        let kind: IDEKind
        let cliPath: String
        var name: String { kind.name }
    }

    typealias ExecutableCheck = (String) -> Bool
    static let defaultExecutableCheck: ExecutableCheck = { FileManager.default.isExecutableFile(atPath: $0) }

    static func installed(_ kind: IDEKind, isExecutable: ExecutableCheck = defaultExecutableCheck) -> IDE? {
        kind.cliCandidates.first(where: isExecutable).map { IDE(kind: kind, cliPath: $0) }
    }

    static func installedIDEs(isExecutable: ExecutableCheck = defaultExecutableCheck) -> [IDE] {
        IDEKind.allCases.compactMap { installed($0, isExecutable: isExecutable) }
    }

    /// `preferred == nil` picks the first installed editor in `IDEKind.allCases` order.
    /// A preferred editor that is not installed yields nil so the user is told instead of silently switched.
    static func detect(preferred: IDEKind? = AppSettings.preferredIDE, isExecutable: ExecutableCheck = defaultExecutableCheck) -> IDE? {
        if let preferred { return installed(preferred, isExecutable: isExecutable) }
        return installedIDEs(isExecutable: isExecutable).first
    }

    /// `[user@]host[:port]` — Remote-SSH resolves aliases through ~/.ssh/config like ssh does.
    static func remoteTarget(for profile: HostProfile) -> String {
        var target = profile.destination
        if let port = profile.port, port > 0, port != 22 { target += ":\(port)" }
        return target
    }

    static func remoteFolderURI(profile: HostProfile, path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "+@:")
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "vscode-remote://ssh-remote+\(remoteTarget(for: profile))\(encodedPath)"
    }

    @MainActor
    static func arguments(for pane: PaneModel, profile: HostProfile?) -> [String]? {
        switch pane.kind {
        case .local:
            return [pane.path]
        case .remote:
            guard let profile else { return nil }
            return ["--folder-uri", remoteFolderURI(profile: profile, path: pane.path)]
        }
    }
}

extension AppState {
    var ideName: String { IDELauncher.detect()?.name ?? AppSettings.preferredIDE?.name ?? "IDE" }

    /// Jump to the pane's current directory in the configured (or first installed) IDE.
    func openInIDE(_ pane: PaneModel) {
        guard pane.isAvailable else { return }
        guard let ide = IDELauncher.detect() else {
            if let preferred = AppSettings.preferredIDE {
                presentAlert(title: "找不到 \(preferred.name)", message: "請安裝 \(preferred.name)，或在設定中改選其他 IDE。")
            } else {
                presentAlert(title: "找不到 Cursor 或 VS Code", message: "請安裝 Cursor 或 Visual Studio Code 到 /Applications，或在該程式內執行「Install 'code' / 'cursor' command in PATH」。")
            }
            return
        }
        let profile = pane.profileID.flatMap { profiles.profile(id: $0) }
        guard let args = IDELauncher.arguments(for: pane, profile: profile) else {
            presentError(AppError.notConnected)
            return
        }
        let commandLine = Shell.quoteAll([ide.cliPath] + args)
        Task {
            let start = Date()
            do {
                let result = try await ShellRunner.run(ide.cliPath, args, options: .init(environment: LocalEnvironment.base))
                log.record(target: ide.name, command: commandLine, exitCode: result.exitCode, output: result.combinedText, duration: Date().timeIntervalSince(start))
                if !result.succeeded {
                    presentAlert(title: "無法開啟 \(ide.name)", message: result.combinedText)
                } else if let app = NSRunningApplication.runningApplications(withBundleIdentifier: ide.kind.bundleIdentifier).first {
                    NSApp.yieldActivation(to: app)
                    app.activate(from: NSRunningApplication.current, options: [])
                }
            } catch {
                presentError(error, title: "無法開啟 \(ide.name)")
            }
        }
    }
}
