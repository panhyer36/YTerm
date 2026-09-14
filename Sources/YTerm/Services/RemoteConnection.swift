import Foundation

struct RemoteInfo: Sendable {
    var home: String = "/"
    var osName: String = ""
    var userName: String = ""
    var tools: Set<String> = []
    var hasGNUFind = false
    var rsyncVersionLine = ""

    func has(_ tool: String) -> Bool { tools.contains(tool) }
    /// macOS 15+ ships openrsync, which rejects several GNU rsync server options.
    var remoteRsyncIsOpenrsync: Bool { rsyncVersionLine.lowercased().contains("openrsync") }
}

/// Writes the tiny SSH_ASKPASS helper that hands a stored password to ssh.
enum AskpassHelper {
    static var scriptPath: String {
        let path = AppPaths.supportDirectory + "/askpass.sh"
        let content = "#!/bin/sh\nprintf '%s\\n' \"$YTERM_PASSWORD\"\n"
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        if existing != content {
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }
}

/// An ssh connection (multiplexed with ControlMaster) to one host profile.
final class RemoteConnection: CommandExecutor, @unchecked Sendable {
    let profile: HostProfile
    let password: String?
    let log: CommandLog
    let sshPath = "/usr/bin/ssh"
    let controlDirectory: String
    let isRemote = true

    private let infoLock = NSLock()
    private var storedInfo = RemoteInfo()

    var info: RemoteInfo { infoLock.withLock { storedInfo } }
    var label: String { profile.displayName }
    var destination: String { profile.destination }
    var controlPath: String { controlDirectory + "/%C" }

    init(profile: HostProfile, password: String?, log: CommandLog) {
        self.profile = profile
        self.password = (password?.isEmpty ?? true) ? nil : password
        self.log = log
        self.controlDirectory = "/tmp/yterm-\(getuid())"
        try? FileManager.default.createDirectory(
            atPath: controlDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// ssh options shared by every invocation (no destination, no command).
    private var baseOptionArguments: [String] {
        var args: [String] = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=1800",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=20",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=4",
            "-o", "LogLevel=ERROR",
        ]
        if let port = profile.port, port > 0 {
            args += ["-p", String(port)]
        }
        let identity = profile.identityFile.trimmingCharacters(in: .whitespaces)
        if !identity.isEmpty {
            args += ["-i", PathUtil.expandTilde(identity), "-o", "IdentitiesOnly=yes"]
        }
        args += profile.extraArguments
        return args
    }

    /// Options for non-interactive use from the app.
    var sshOptionArguments: [String] {
        var args = baseOptionArguments
        if password == nil {
            args += ["-o", "BatchMode=yes"]
        } else {
            args += ["-o", "NumberOfPasswordPrompts=1"]
        }
        return args
    }

    var environment: [String: String] {
        var env = LocalEnvironment.base
        if let password {
            env["SSH_ASKPASS"] = AskpassHelper.scriptPath
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["YTERM_PASSWORD"] = password
        }
        return env
    }

    /// The `-e` value handed to rsync. rsync splits on spaces and honours quotes.
    var rshCommand: String {
        ([sshPath] + sshOptionArguments).map { arg -> String in
            if arg.contains(" ") { return "\"" + arg + "\"" }
            return arg
        }.joined(separator: " ")
    }

    /// A shell command line that opens an interactive session in `path` (used for Terminal.app).
    func interactiveCommand(path: String) -> String {
        let remote = "cd " + Shell.quote(path) + " 2>/dev/null; exec \"${SHELL:-sh}\" -l"
        let args = [sshPath] + baseOptionArguments + ["-t", destination, remote]
        return Shell.quoteAll(args)
    }

    func run(
        _ script: String,
        stdin: Data?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> CommandResult {
        try await run(script, stdin: stdin, onStdout: onStdout, onStderr: onStderr, log: true)
    }

    /// `log: false` keeps periodic polling (resource monitor) out of the command log.
    func run(
        _ script: String,
        stdin: Data?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?,
        log shouldLog: Bool
    ) async throws -> CommandResult {
        let start = Date()
        let remoteCommand = "sh -c " + Shell.quote(script)
        let args = sshOptionArguments + ["--", destination, remoteCommand]
        do {
            let result = try await ShellRunner.run(
                sshPath, args,
                options: .init(environment: environment, stdin: stdin, onStdout: onStdout, onStderr: onStderr)
            )
            if shouldLog {
                log.record(target: label, command: script, exitCode: result.exitCode, output: result.combinedText, duration: Date().timeIntervalSince(start))
            }
            return result
        } catch {
            if shouldLog {
                log.record(target: label, command: script, exitCode: nil, output: error.localizedDescription, duration: Date().timeIntervalSince(start))
            }
            throw error
        }
    }

    /// Establish the master connection and discover the remote environment.
    @discardableResult
    func bootstrap() async throws -> RemoteInfo {
        let script = """
        printf 'home\\t%s\\n' "$HOME"
        printf 'os\\t%s\\n' "$(uname -s 2>/dev/null)"
        printf 'user\\t%s\\n' "$(id -un 2>/dev/null)"
        for c in rsync tar zip unzip gzip bzip2 xz zstd 7z unrar du df; do command -v "$c" >/dev/null 2>&1 && printf 'tool\\t%s\\n' "$c"; done
        if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then printf 'gnufind\\tyes\\n'; fi
        printf 'rsyncversion\\t%s\\n' "$(rsync --version 2>/dev/null | head -n 1)"
        exit 0
        """
        let result = try await run(script)
        guard result.succeeded else {
            throw AppError.connectionFailed(RemoteConnection.describeFailure(result))
        }
        var info = RemoteInfo()
        for line in result.stdoutText.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let value = String(parts[1])
            switch parts[0] {
            case "home": if !value.isEmpty { info.home = value }
            case "os": info.osName = value
            case "user": info.userName = value
            case "tool": info.tools.insert(value)
            case "gnufind": info.hasGNUFind = (value == "yes")
            case "rsyncversion": info.rsyncVersionLine = value
            default: break
            }
        }
        infoLock.withLock { storedInfo = info }
        return info
    }

    func disconnect() async {
        let args = sshOptionArguments + ["-O", "exit", "--", destination]
        _ = try? await ShellRunner.run(sshPath, args, options: .init(environment: environment))
    }

    static func describeFailure(_ result: CommandResult) -> String {
        let text = result.combinedText
        let lower = text.lowercased()
        var hint = ""
        if lower.contains("permission denied") {
            hint = "驗證失敗：請確認使用者名稱、金鑰或密碼是否正確。"
        } else if lower.contains("remote host identification has changed") {
            hint = "遠端主機金鑰已變更，為了安全 ssh 拒絕連線。請確認後手動更新 ~/.ssh/known_hosts。"
        } else if lower.contains("could not resolve hostname") {
            hint = "無法解析主機名稱，請檢查 Host 設定或網路。"
        } else if lower.contains("connection refused") {
            hint = "連線被拒絕，請確認 sshd 已啟動且連接埠正確。"
        } else if lower.contains("timed out") || lower.contains("timeout") {
            hint = "連線逾時，請確認網路、VPN 或防火牆設定。"
        } else if lower.contains("no route to host") {
            hint = "找不到主機路由，請確認 IP 與網路狀態。"
        }
        let detail = text.isEmpty ? "ssh 結束碼 \(result.exitCode)" : text
        return hint.isEmpty ? detail : hint + "\n\n" + detail
    }

    static func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let appError = error as? AppError, case let .connectionFailed(message) = appError else { return false }
        return message.lowercased().contains("permission denied")
    }
}
