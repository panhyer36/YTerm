import SwiftUI

/// Lists what a remote folder has that the local copy lacks, and downloads only the ticked items.
struct PullReviewSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: PullReviewRequest
    @State private var includeDeletions: Bool
    @State private var changes: [PullChange] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var previewTask: Task<Void, Never>?

    init(request: PullReviewRequest) {
        self.request = request
        _includeDeletions = State(initialValue: request.mirror)
    }

    private var hostName: String {
        app.profiles.profile(id: request.profileID)?.displayName ?? "遠端"
    }

    private var downloadable: [PullChange] { changes.filter(\.isDownloadable) }
    private var deletions: [PullChange] { changes.filter { $0.kind == .deleted } }
    private var selectedDownloads: [PullChange] { downloadable.filter { selected.contains($0.id) } }
    private var selectedDeletions: [PullChange] { deletions.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("從「\(hostName)」拉回變更")
                .font(.title2)
                .bold()
            VStack(alignment: .leading, spacing: 2) {
                Text("遠端：\(request.remotePath)")
                Text("本機：\(request.localPath)")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            HStack {
                Toggle("也列出遠端已刪除、本機多出來的檔案", isOn: $includeDeletions)
                    .onChange(of: includeDeletions) { _, _ in runPreview() }
                Spacer()
                Button("重新比對") { runPreview() }
                    .disabled(isLoading)
            }
            .controlSize(.small)

            Group {
                if isLoading {
                    HStack { ProgressView().controlSize(.small); Text("正在用 rsync 試跑比對…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if changes.isEmpty {
                    Text("本機已與遠端一致，沒有需要下載的項目。")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if !downloadable.isEmpty {
                            Section("遠端新增或修改（勾選要下載的項目）") {
                                ForEach(downloadable) { change in
                                    changeRow(change)
                                }
                            }
                        }
                        if !deletions.isEmpty {
                            Section("遠端已刪除、本機還在（勾選會移到垃圾桶）") {
                                ForEach(deletions) { change in
                                    changeRow(change)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(height: 340)

            HStack {
                Button("全選新增與修改") { selected.formUnion(downloadable.map(\.id)) }
                    .disabled(downloadable.isEmpty)
                Button("全不選") { selected.removeAll() }
                    .disabled(selected.isEmpty)
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) { perform() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedDownloads.isEmpty && selectedDeletions.isEmpty)
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(width: 680)
        .onAppear { runPreview() }
        .onDisappear { previewTask?.cancel() }
    }

    private func changeRow(_ change: PullChange) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(change.id) },
            set: { if $0 { selected.insert(change.id) } else { selected.remove(change.id) } }
        )) {
            HStack(spacing: 8) {
                Text(change.kind.label)
                    .font(.caption)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(badgeColor(change.kind).opacity(0.18), in: Capsule())
                Text(change.relativePath)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let size = change.size {
                    Text(FileEntry.byteFormatter.string(fromByteCount: size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private func badgeColor(_ kind: PullChange.Kind) -> Color {
        switch kind {
        case .added, .newDirectory: return .green
        case .modified: return .orange
        case .deleted: return .red
        }
    }

    private var summaryText: String {
        var parts: [String] = []
        if !downloadable.isEmpty { parts.append("\(downloadable.count) 個可下載，已選 \(selectedDownloads.count)") }
        if !deletions.isEmpty { parts.append("\(deletions.count) 個本機多出，已選 \(selectedDeletions.count)") }
        return parts.joined(separator: "；")
    }

    private var actionTitle: String {
        var parts: [String] = []
        if !selectedDownloads.isEmpty { parts.append("下載 \(selectedDownloads.count) 個") }
        if !selectedDeletions.isEmpty { parts.append("移除 \(selectedDeletions.count) 個") }
        return parts.isEmpty ? "下載" : parts.joined(separator: "並")
    }

    private func runPreview() {
        previewTask?.cancel()
        isLoading = true
        errorMessage = nil
        let include = includeDeletions
        previewTask = Task {
            do {
                let result = try await app.previewPull(request, includeDeletions: include)
                guard !Task.isCancelled else { return }
                changes = result
                // Everything new or changed is ticked by default; deletions are opt-in.
                selected = Set(result.filter(\.isDownloadable).map(\.id))
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func perform() {
        let downloads = selectedDownloads
        let trash = selectedDeletions
        dismiss()
        app.performPull(request, download: downloads, trash: trash)
    }
}
