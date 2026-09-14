import Foundation

/// Something that can execute a POSIX shell script: the local machine or an ssh host.
protocol CommandExecutor: AnyObject, Sendable {
    var label: String { get }
    var isRemote: Bool { get }
    func run(
        _ script: String,
        stdin: Data?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> CommandResult
}

extension CommandExecutor {
    func run(_ script: String) async throws -> CommandResult {
        try await run(script, stdin: nil, onStdout: nil, onStderr: nil)
    }

    @discardableResult
    func runChecked(_ script: String) async throws -> CommandResult {
        let result = try await run(script)
        guard result.succeeded else {
            throw AppError.commandFailed(command: script, exitCode: result.exitCode, output: result.combinedText)
        }
        return result
    }
}

enum LocalEnvironment {
    /// The GUI app inherits a minimal PATH when launched from Finder; make sure Homebrew is visible.
    static var base: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var parts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for path in extra where !parts.contains(path) {
            parts.append(path)
        }
        env["PATH"] = parts.joined(separator: ":")
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }
}

final class LocalExecutor: CommandExecutor, @unchecked Sendable {
    let label = "本機"
    let isRemote = false
    let log: CommandLog

    init(log: CommandLog) {
        self.log = log
    }

    func run(
        _ script: String,
        stdin: Data?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> CommandResult {
        let start = Date()
        do {
            let result = try await ShellRunner.run(
                "/bin/sh", ["-c", script],
                options: .init(environment: LocalEnvironment.base, stdin: stdin, onStdout: onStdout, onStderr: onStderr)
            )
            log.record(target: label, command: script, exitCode: result.exitCode, output: result.combinedText, duration: Date().timeIntervalSince(start))
            return result
        } catch {
            log.record(target: label, command: script, exitCode: nil, output: error.localizedDescription, duration: Date().timeIntervalSince(start))
            throw error
        }
    }
}
