import Foundation
import Observation

struct LogEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let target: String
    let command: String
    let exitCode: Int32?
    let output: String
    let duration: TimeInterval

    var isFailure: Bool { exitCode != 0 }

    var statusText: String {
        if let exitCode { return exitCode == 0 ? "成功" : "失敗（\(exitCode)）" }
        return "無法執行"
    }
}

/// Every shell command the app executes (locally or remotely) is recorded here,
/// so the user can see exactly what was run and copy it for later.
@MainActor @Observable
final class CommandLog {
    private(set) var entries: [LogEntry] = []
    var maxEntries = 400

    func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    nonisolated func record(target: String, command: String, exitCode: Int32?, output: String, duration: TimeInterval) {
        let entry = LogEntry(
            id: UUID(),
            date: Date(),
            target: target,
            command: command,
            exitCode: exitCode,
            output: String(output.suffix(6000)),
            duration: duration
        )
        Task { @MainActor in
            self.append(entry)
        }
    }
}
