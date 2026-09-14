import Foundation
import Observation

/// One sample of a host's load, memory, disk, GPUs and busiest processes.
struct HostResources: Sendable, Equatable {
    struct GPU: Sendable, Equatable, Identifiable {
        var index: Int
        var name: String
        var utilization: Int
        var memoryUsedMB: Int
        var memoryTotalMB: Int
        var temperature: Int
        var id: Int { index }
    }

    struct ProcessInfo: Sendable, Equatable, Identifiable {
        var pid: Int
        var user: String
        var cpu: Double
        var memory: Double
        var command: String
        var id: Int { pid }
    }

    var sampledAt = Date()
    var uptime = ""
    var cpuCount = 0
    var load: [Double] = []
    var memoryTotalKB: Int64 = 0
    var memoryAvailableKB: Int64 = -1
    var diskPath = ""
    var diskMount = ""
    var diskTotalKB: Int64 = 0
    var diskUsedKB: Int64 = 0
    var gpus: [GPU] = []
    var topProcesses: [ProcessInfo] = []

    var memoryUsedFraction: Double? {
        guard memoryTotalKB > 0, memoryAvailableKB >= 0 else { return nil }
        return Double(memoryTotalKB - memoryAvailableKB) / Double(memoryTotalKB)
    }

    var diskUsedFraction: Double? {
        guard diskTotalKB > 0 else { return nil }
        return Double(diskUsedKB) / Double(diskTotalKB)
    }

    /// 1-minute load relative to the core count.
    var cpuFraction: Double? {
        guard let first = load.first, cpuCount > 0 else { return nil }
        return min(first / Double(cpuCount), 1)
    }

    /// POSIX sh script printing tab-separated `key\tvalue` lines. Works on Linux; degrades on macOS.
    static func script(diskPath: String) -> String {
        """
        printf 'uptime\\t%s\\n' "$(uptime 2>/dev/null)"
        printf 'nproc\\t%s\\n' "$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
        if [ -r /proc/loadavg ]; then printf 'loadavg\\t%s\\n' "$(cut -d' ' -f1-3 /proc/loadavg)"; else printf 'loadavg\\t%s\\n' "$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')"; fi
        if [ -r /proc/meminfo ]; then printf 'mem\\t%s\\n' "$(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "%d %d", t, a}' /proc/meminfo)"; else printf 'mem\\t%s -1\\n' "$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 ))"; fi
        printf 'df\\t%s\\n' "$(df -Pk \(Shell.quote(diskPath)) 2>/dev/null | tail -n 1)"
        if command -v nvidia-smi >/dev/null 2>&1; then nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null | while IFS= read -r line; do printf 'gpu\\t%s\\n' "$line"; done; fi
        ( ps -eo pid,user,pcpu,pmem,comm --sort=-pcpu 2>/dev/null || ps -r -eo pid,user,pcpu,pmem,comm 2>/dev/null ) | sed -n '2,7p' | while IFS= read -r line; do printf 'ps\\t%s\\n' "$line"; done
        exit 0
        """
    }

    static func parse(_ text: String, diskPath: String) -> HostResources {
        var result = HostResources()
        result.diskPath = diskPath
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let key = String(line[..<tab])
            let value = String(line[line.index(after: tab)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "uptime":
                result.uptime = value
            case "nproc":
                result.cpuCount = Int(value) ?? 0
            case "loadavg":
                result.load = value.split(whereSeparator: { $0 == " " || $0 == "," }).prefix(3).compactMap { Double($0) }
            case "mem":
                let parts = value.split(separator: " ")
                if parts.count >= 2 {
                    result.memoryTotalKB = Int64(parts[0]) ?? 0
                    result.memoryAvailableKB = Int64(parts[1]) ?? -1
                }
            case "df":
                // Filesystem 1024-blocks Used Available Capacity Mounted on
                let parts = value.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 6 {
                    result.diskTotalKB = Int64(parts[1]) ?? 0
                    result.diskUsedKB = Int64(parts[2]) ?? 0
                    result.diskMount = parts[5...].joined(separator: " ")
                }
            case "gpu":
                let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count >= 6 {
                    result.gpus.append(GPU(
                        index: Int(parts[0]) ?? result.gpus.count, name: parts[1], utilization: Int(parts[2]) ?? 0,
                        memoryUsedMB: Int(parts[3]) ?? 0, memoryTotalMB: Int(parts[4]) ?? 0, temperature: Int(parts[5]) ?? 0
                    ))
                }
            case "ps":
                let parts = value.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true).map(String.init)
                if parts.count >= 5, let pid = Int(parts[0]) {
                    result.topProcesses.append(ProcessInfo(pid: pid, user: parts[1], cpu: Double(parts[2]) ?? 0, memory: Double(parts[3]) ?? 0, command: parts[4]))
                }
            default:
                break
            }
        }
        return result
    }
}

/// Polls every open connection for `HostResources` while the resources panel is visible.
@MainActor @Observable
final class ResourceMonitor {
    private(set) var snapshots: [UUID: HostResources] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var folderSizes: [UUID: String] = [:]
    var interval: Double = 5
    var autoRefresh = true
    private(set) var isRefreshing = false
    @ObservationIgnored weak var app: AppState?

    func refreshAll() async {
        guard let app, !app.connections.isEmpty else { return }
        isRefreshing = true
        let targets = app.connections.values.map { connection -> (RemoteConnection, String) in
            let pane = app.panes.first { $0.kind == .remote && $0.profileID == connection.profile.id && $0.isAvailable }
            return (connection, pane?.path ?? connection.info.home)
        }
        await withTaskGroup(of: (UUID, Result<HostResources, Error>).self) { group in
            for (connection, path) in targets {
                group.addTask {
                    do {
                        let result = try await connection.run(HostResources.script(diskPath: path), stdin: nil, onStdout: nil, onStderr: nil, log: false)
                        guard result.succeeded else { throw AppError.commandFailed(command: "resources", exitCode: result.exitCode, output: result.combinedText) }
                        return (connection.profile.id, .success(HostResources.parse(result.stdoutText, diskPath: path)))
                    } catch {
                        return (connection.profile.id, .failure(error))
                    }
                }
            }
            for await (profileID, outcome) in group {
                switch outcome {
                case let .success(snapshot):
                    snapshots[profileID] = snapshot
                    errors[profileID] = nil
                case let .failure(error):
                    errors[profileID] = error.localizedDescription
                }
            }
        }
        // Forget hosts that are gone.
        let live = Set(app.connections.keys)
        snapshots = snapshots.filter { live.contains($0.key) }
        isRefreshing = false
    }

    /// `du -sh` of the path shown in the host's most recent pane.
    func measureFolder(profileID: UUID) {
        guard let app, let connection = app.connections[profileID] else { return }
        let path = app.panes.first { $0.kind == .remote && $0.profileID == profileID && $0.isAvailable }?.path ?? connection.info.home
        folderSizes[profileID] = "計算中…"
        Task {
            let result = try? await connection.run("du -sh " + Shell.quote(path) + " 2>/dev/null | cut -f1")
            let size = result?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            folderSizes[profileID] = size.isEmpty ? "無法計算" : "\(size)（\(path)）"
        }
    }
}
