import Foundation

struct CommandResult: Sendable {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    var succeeded: Bool { exitCode == 0 }

    var combinedText: String {
        let out = stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (out.isEmpty, err.isEmpty) {
        case (true, true): return ""
        case (false, true): return out
        case (true, false): return err
        case (false, false): return out + "\n" + err
        }
    }
}

/// Holds a reference to a running `Process` so that Swift task cancellation can terminate it.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var launched = false
    private var cancelled = false

    func attach(_ process: Process) {
        lock.withLock { self.process = process }
    }

    func markLaunched() {
        lock.withLock {
            launched = true
            if cancelled, let process, process.isRunning { process.terminate() }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if launched, let process, process.isRunning { process.terminate() }
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendOut(_ data: Data) { lock.withLock { out.append(data) } }
    func appendErr(_ data: Data) { lock.withLock { err.append(data) } }
    var snapshot: (Data, Data) { lock.withLock { (out, err) } }
}

/// Runs an executable, streams stdout/stderr, and supports cancellation via Swift concurrency.
enum ShellRunner {
    struct Options {
        var environment: [String: String]? = nil
        var currentDirectory: String? = nil
        var stdin: Data? = nil
        var onStdout: (@Sendable (Data) -> Void)? = nil
        var onStderr: (@Sendable (Data) -> Void)? = nil
    }

    static func run(_ executable: String, _ arguments: [String], options: Options = Options()) async throws -> CommandResult {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let env = options.environment { process.environment = env }
                if let cwd = options.currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                var inPipe: Pipe? = nil
                if options.stdin != nil {
                    let pipe = Pipe()
                    inPipe = pipe
                    process.standardInput = pipe
                } else {
                    process.standardInput = FileHandle.nullDevice
                }

                let buffer = OutputBuffer()
                let group = DispatchGroup()
                group.enter()
                group.enter()

                process.terminationHandler = { proc in
                    group.wait()
                    let (out, err) = buffer.snapshot
                    continuation.resume(returning: CommandResult(exitCode: proc.terminationStatus, stdout: out, stderr: err))
                }

                box.attach(process)
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                box.markLaunched()

                let onStdout = options.onStdout
                let onStderr = options.onStderr
                DispatchQueue.global(qos: .userInitiated).async {
                    let handle = outPipe.fileHandleForReading
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        buffer.appendOut(data)
                        onStdout?(data)
                    }
                    group.leave()
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let handle = errPipe.fileHandleForReading
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        buffer.appendErr(data)
                        onStderr?(data)
                    }
                    group.leave()
                }
                if let data = options.stdin, let inPipe {
                    DispatchQueue.global(qos: .utility).async {
                        let handle = inPipe.fileHandleForWriting
                        try? handle.write(contentsOf: data)
                        try? handle.close()
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}
