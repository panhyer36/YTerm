import AppKit
import Foundation

/// Opens a pane's directory in Cursor (or VS Code): locally as a folder, remotely through the
/// editor's Remote-SSH support (`vscode-remote://ssh-remote+host/path`).
enum IDELauncher {
    struct IDE {
        let name: String
        let cliPath: String
    }

    static func detect() -> IDE? {
        let candidates: [(String, [String])] = [
            ("Cursor", ["/Applications/Cursor.app/Contents/Resources/app/bin/cursor", "/usr/local/bin/cursor", "/opt/homebrew/bin/cursor"]),
            ("Visual Studio Code", ["/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code", "/usr/local/bin/code", "/opt/homebrew/bin/code"]),
        ]
        for (name, paths) in candidates {
            if let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                return IDE(name: name, cliPath: path)
            }
        }
        return nil
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
    var ideName: String { IDELauncher.detect()?.name ?? "Cursor" }

    /// Jump to the pane's current directory in Cursor / VS Code.
    func openInIDE(_ pane: PaneModel) {
        guard pane.isAvailable else { return }
        guard let ide = IDELauncher.detect() else {
            presentAlert(title: "找不到 Cursor 或 VS Code", message: "請先安裝 Cursor（/Applications/Cursor.app），或在 Cursor 裡執行「Install 'cursor' command」。")
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
                } else if let app = NSRunningApplication.runningApplications(withBundleIdentifier: ide.name == "Cursor" ? "com.todesktop.230313mzl4w4u92" : "com.microsoft.VSCode").first {
                    NSApp.yieldActivation(to: app)
                    app.activate(from: NSRunningApplication.current, options: [])
                }
            } catch {
                presentError(error, title: "無法開啟 \(ide.name)")
            }
        }
    }
}
