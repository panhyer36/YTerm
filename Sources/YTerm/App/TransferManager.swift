import Foundation
import Observation

@MainActor @Observable
final class TransferJob: Identifiable {
    enum State: Equatable {
        case queued
        case running
        case finished
        case failed(String)
        case cancelled

        var label: String {
            switch self {
            case .queued: return "等待中"
            case .running: return "進行中"
            case .finished: return "完成"
            case .failed: return "失敗"
            case .cancelled: return "已取消"
            }
        }
    }

    let id = UUID()
    let title: String
    let subtitle: String
    let direction: TransferDirection
    var state: State = .queued
    var progress = RsyncProgress()
    var output = ""
    var commandLine = ""
    var startedAt: Date?
    var finishedAt: Date?
    /// Profile id of the ssh connection the job depends on (nil for purely local work).
    @ObservationIgnored var connectionID: UUID?

    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored let work: @MainActor (TransferJob) async throws -> Void

    init(title: String, subtitle: String, direction: TransferDirection, work: @escaping @MainActor (TransferJob) async throws -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.direction = direction
        self.work = work
    }

    var isActive: Bool { state == .queued || state == .running }

    func appendOutput(_ text: String) {
        output += text
        if output.count > 20_000 { output = String(output.suffix(20_000)) }
    }

    var elapsedText: String {
        guard let startedAt else { return "" }
        let end = finishedAt ?? Date()
        let seconds = Int(end.timeIntervalSince(startedAt))
        if seconds < 60 { return "\(seconds) 秒" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Runs transfer jobs with a small concurrency limit.
@MainActor @Observable
final class TransferManager {
    private(set) var jobs: [TransferJob] = []
    var maxConcurrent = 2
    @ObservationIgnored var onJobFinished: ((TransferJob) -> Void)?

    var activeJobs: [TransferJob] { jobs.filter(\.isActive) }
    var hasActiveJobs: Bool { jobs.contains { $0.isActive } }

    func enqueue(_ job: TransferJob) {
        jobs.append(job)
        pump()
    }

    func cancel(_ job: TransferJob) {
        switch job.state {
        case .queued:
            job.state = .cancelled
            job.finishedAt = Date()
            pump()
        case .running:
            job.task?.cancel()
        default:
            break
        }
    }

    func cancelAll() {
        for job in jobs where job.isActive { cancel(job) }
    }

    func cancel(connectionID: UUID) {
        for job in jobs where job.isActive && job.connectionID == connectionID { cancel(job) }
    }

    func remove(_ job: TransferJob) {
        guard !job.isActive else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    private func pump() {
        let running = jobs.filter { $0.state == .running }.count
        guard running < maxConcurrent, let next = jobs.first(where: { $0.state == .queued }) else { return }
        start(next)
        pump()
    }

    private func start(_ job: TransferJob) {
        job.state = .running
        job.startedAt = Date()
        job.task = Task { [weak self] in
            do {
                try await job.work(job)
                job.state = Task.isCancelled ? .cancelled : .finished
            } catch is CancellationError {
                job.state = .cancelled
            } catch {
                job.state = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
            job.finishedAt = Date()
            self?.onJobFinished?(job)
            self?.pump()
        }
    }
}
