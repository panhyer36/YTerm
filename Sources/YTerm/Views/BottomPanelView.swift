import SwiftUI

struct BottomPanelView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        @Bindable var resources = app.resources
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $app.bottomTab) {
                    ForEach(BottomTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 440)
                if app.bottomTab == .transfers, app.transfers.hasActiveJobs {
                    ProgressView().controlSize(.small)
                    Text("\(app.transfers.activeJobs.count) 個進行中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if app.bottomTab == .transfers {
                    if let flavor = app.rsyncFlavor {
                        Text(flavor.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(flavor.kind == .openrsync ? "macOS 內建的 openrsync 只能顯示單一檔案進度；安裝 Homebrew rsync（brew install rsync）可顯示整體進度。" : "")
                    } else {
                        Text("找不到 rsync")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button("清除已完成") { app.transfers.clearFinished() }
                        .controlSize(.small)
                } else if app.bottomTab == .syncs {
                    Text("\(app.syncs.sessions.filter { $0.rule.enabled }.count) 條規則啟用中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("新增規則…") { app.sheet = .syncRule(nil) }
                        .controlSize(.small)
                } else if app.bottomTab == .resources {
                    Toggle("自動更新", isOn: $resources.autoRefresh)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                    Picker("", selection: $resources.interval) {
                        Text("3 秒").tag(3.0)
                        Text("5 秒").tag(5.0)
                        Text("10 秒").tag(10.0)
                        Text("30 秒").tag(30.0)
                    }
                    .labelsHidden()
                    .frame(width: 80)
                    .controlSize(.small)
                    Button("更新") { Task { await app.resources.refreshAll() } }
                        .controlSize(.small)
                        .disabled(app.resources.isRefreshing)
                } else if app.bottomTab == .edits {
                    Text("\(app.edits.sessions.count) 個檔案編輯中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("全部停止") { app.edits.stopAll() }
                        .controlSize(.small)
                        .disabled(app.edits.sessions.isEmpty)
                } else {
                    Text("\(app.log.entries.count) 筆")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("清除") { app.log.clear() }
                        .controlSize(.small)
                }
                Button { app.showBottomPanel = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("隱藏面板")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            switch app.bottomTab {
            case .transfers: TransferListView()
            case .log: CommandLogView()
            case .edits: EditSessionsView()
            case .syncs: SyncListView()
            case .resources: ResourcesView()
            }
        }
    }
}

struct TransferListView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.transfers.jobs.isEmpty {
            VStack {
                Text("尚無傳輸。選取檔案後按「上傳」「下載」，或直接把檔案拖到另一側。")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(app.transfers.jobs.reversed()) { job in
                    TransferRow(job: job)
                }
            }
            .listStyle(.inset)
        }
    }
}

struct TransferRow: View {
    @Environment(AppState.self) private var app
    let job: TransferJob
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: job.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(stateColor)
                Text(job.title)
                    .bold()
                    .lineLimit(1)
                Spacer()
                Text(job.state.label)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(stateColor.opacity(0.15), in: Capsule())
                if job.isActive {
                    Button { app.transfers.cancel(job) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .help("取消")
                } else {
                    Button { app.transfers.remove(job) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("移除紀錄")
                }
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless)
                    .help("顯示指令與輸出")
            }
            Text(job.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if job.state == .running {
                if let fraction = job.progress.overallFraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                HStack {
                    Text(progressDetail)
                        .font(.caption)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(job.elapsedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if case let .failed(message) = job.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(expanded ? nil : 2)
                    .textSelection(.enabled)
            } else if job.state == .finished {
                Text("完成，耗時 \(job.elapsedText)" + (job.progress.filesDone > 0 ? "，\(job.progress.filesDone) 個檔案" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("指令").font(.caption).bold()
                        Button("複製") { app.copyText(job.commandLine) }
                            .controlSize(.mini)
                    }
                    Text(job.commandLine)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    if !job.output.isEmpty {
                        Text("輸出").font(.caption).bold()
                        Text(job.output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 3)
    }

    private var stateColor: Color {
        switch job.state {
        case .queued: return .gray
        case .running: return .accentColor
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    private var progressDetail: String {
        let progress = job.progress
        var parts: [String] = []
        if let fraction = progress.overallFraction { parts.append("\(Int(fraction * 100))%") }
        if let fileFraction = progress.fileFraction { parts.append("目前檔案 \(Int(fileFraction * 100))%") }
        if !progress.transferred.isEmpty { parts.append(progress.transferred) }
        if !progress.speed.isEmpty { parts.append(progress.speed) }
        if !progress.eta.isEmpty { parts.append("剩餘 " + progress.eta) }
        if let total = progress.filesTotal { parts.append("\(progress.filesDone)/\(total) 檔案") }
        if !progress.currentFile.isEmpty { parts.append(progress.currentFile) }
        return parts.isEmpty ? "準備中…" : parts.joined(separator: " · ")
    }
}

struct CommandLogView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.log.entries.isEmpty {
            VStack {
                Text("這裡會列出程式實際執行的每一條指令，方便學習或複製到終端機。")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(app.log.entries.reversed()) { entry in
                    LogRow(entry: entry)
                }
            }
            .listStyle(.inset)
        }
    }
}

struct LogRow: View {
    @Environment(AppState.self) private var app
    let entry: LogEntry
    @State private var expanded = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.timeFormatter.string(from: entry.date))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(entry.target)
                    .font(.caption)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                Text(entry.command)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                Spacer()
                Text(entry.statusText)
                    .font(.caption)
                    .foregroundStyle(entry.isFailure ? .red : .secondary)
                Button { app.copyText(entry.command) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("複製指令")
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless)
            }
            if expanded, !entry.output.isEmpty {
                Text(entry.output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 2)
    }
}
