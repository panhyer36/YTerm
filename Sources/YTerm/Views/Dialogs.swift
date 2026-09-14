import SwiftUI

struct NameInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let prompt: String
    let submitLabel: String
    let onSubmit: (String) -> Void
    @State private var value: String
    @State private var submitted = false

    init(title: String, prompt: String, initialValue: String, submitLabel: String, onSubmit: @escaping (String) -> Void) {
        self.title = title
        self.prompt = prompt
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
        _value = State(initialValue: initialValue)
    }

    private var trimmed: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { !trimmed.isEmpty && !trimmed.contains("/") && trimmed != "." && trimmed != ".." }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            TextField(prompt, text: $value)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(submitLabel) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func submit() {
        guard isValid, !submitted else { return }
        submitted = true
        dismiss()
        onSubmit(trimmed)
    }
}

struct ChmodSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [FileEntry]
    let onSubmit: (String, Bool) -> Void
    @State private var bits: [Bool]
    @State private var octal: String
    @State private var recursive = false
    @State private var submitted = false

    private static let labels = ["使用者", "群組", "其他"]
    private static let columns = ["讀取 (r)", "寫入 (w)", "執行 (x)"]

    init(entries: [FileEntry], onSubmit: @escaping (String, Bool) -> Void) {
        self.entries = entries
        self.onSubmit = onSubmit
        let mode = (entries.first?.mode ?? 0o644) & 0o777
        var initial: [Bool] = []
        for shift in [6, 3, 0] {
            let triplet = (mode >> shift) & 0o7
            initial.append(triplet & 4 != 0)
            initial.append(triplet & 2 != 0)
            initial.append(triplet & 1 != 0)
        }
        _bits = State(initialValue: initial)
        _octal = State(initialValue: String(format: "%03o", mode))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entries.count == 1 ? "變更「\(entries[0].name)」的權限" : "變更 \(entries.count) 個項目的權限")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    ForEach(Self.columns, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        Text(Self.labels[row])
                        ForEach(0..<3, id: \.self) { column in
                            Toggle("", isOn: Binding(
                                get: { bits[row * 3 + column] },
                                set: { bits[row * 3 + column] = $0; octal = octalFromBits() }
                            ))
                            .labelsHidden()
                        }
                    }
                }
            }
            HStack {
                Text("八進位")
                TextField("644", text: $octal)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 80)
                    .onChange(of: octal) { _, newValue in
                        if let mode = Int(newValue, radix: 8), newValue.count <= 4 { applyOctal(mode) }
                    }
                Text("chmod \(octal)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if entries.contains(where: \.isDirectoryLike) {
                Toggle("套用到資料夾內所有項目（-R）", isOn: $recursive)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("套用") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(Int(octal, radix: 8) == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func octalFromBits() -> String {
        var mode = 0
        for row in 0..<3 {
            var triplet = 0
            if bits[row * 3] { triplet |= 4 }
            if bits[row * 3 + 1] { triplet |= 2 }
            if bits[row * 3 + 2] { triplet |= 1 }
            mode = (mode << 3) | triplet
        }
        return String(format: "%03o", mode)
    }

    private func applyOctal(_ mode: Int) {
        var updated: [Bool] = []
        for shift in [6, 3, 0] {
            let triplet = (mode >> shift) & 0o7
            updated.append(triplet & 4 != 0)
            updated.append(triplet & 2 != 0)
            updated.append(triplet & 1 != 0)
        }
        if updated != bits { bits = updated }
    }

    private func submit() {
        guard !submitted, Int(octal, radix: 8) != nil else { return }
        submitted = true
        dismiss()
        onSubmit(octal, recursive)
    }
}

struct CompressSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [FileEntry]
    let tools: Set<String>
    let onSubmit: (ArchiveKind, String) -> Void
    @State private var kind: ArchiveKind = .tarGz
    @State private var baseName: String
    @State private var submitted = false

    init(entries: [FileEntry], tools: Set<String>, onSubmit: @escaping (ArchiveKind, String) -> Void) {
        self.entries = entries
        self.tools = tools
        self.onSubmit = onSubmit
        let initial = entries.count == 1 ? entries[0].name : "archive"
        _baseName = State(initialValue: initial)
    }

    private var archiveName: String { baseName.trimmingCharacters(in: .whitespaces) + "." + kind.rawValue }
    private var isValid: Bool {
        let trimmed = baseName.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains("/")
    }

    private func isAvailable(_ kind: ArchiveKind) -> Bool {
        tools.isEmpty || kind.requiredTools.allSatisfy { tools.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entries.count == 1 ? "壓縮「\(entries[0].name)」" : "壓縮 \(entries.count) 個項目")
                .font(.headline)
            Picker("格式", selection: $kind) {
                ForEach(ArchiveKind.creatable) { candidate in
                    Text(candidate.displayName + (isAvailable(candidate) ? "" : "（缺少工具）"))
                        .tag(candidate)
                }
            }
            HStack {
                TextField("檔名", text: $baseName)
                    .textFieldStyle(.roundedBorder)
                Text("." + kind.rawValue)
                    .foregroundStyle(.secondary)
            }
            Text("會在目前資料夾建立 \(archiveName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !isAvailable(kind) {
                Text("這台機器缺少 \(kind.requiredTools.joined(separator: "、"))，請改用其他格式。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("壓縮") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid || !isAvailable(kind))
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func submit() {
        guard isValid, !submitted else { return }
        submitted = true
        dismiss()
        onSubmit(kind, archiveName)
    }
}

struct ExtractSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: FileEntry
    let onSubmit: (Bool) -> Void
    @State private var intoSubfolder = true
    @State private var submitted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("解壓縮「\(entry.name)」")
                .font(.headline)
            Picker("位置", selection: $intoSubfolder) {
                Text("解壓縮到新資料夾「\(PathUtil.stripArchiveExtension(entry.name))」").tag(true)
                Text("直接解壓縮到目前資料夾（同名檔案會被覆蓋）").tag(false)
            }
            .pickerStyle(.radioGroup)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("解壓縮") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func submit() {
        guard !submitted else { return }
        submitted = true
        dismiss()
        onSubmit(intoSubfolder)
    }
}

struct RunCommandSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let pane: PaneModel
    @State private var command = ""
    @State private var output = ""
    @State private var isRunning = false
    @State private var history: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("在\(pane.kind.label)執行指令")
                .font(.headline)
            Text("工作目錄：\(pane.path)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                TextField("例如：ls -la、du -sh *、tar -tzf backup.tar.gz", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { run() }
                Button("執行") { run() }
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || isRunning)
                if isRunning { ProgressView().controlSize(.small) }
            }
            if !history.isEmpty {
                HStack {
                    Text("最近：").font(.caption).foregroundStyle(.secondary)
                    ForEach(history.suffix(5).reversed(), id: \.self) { item in
                        Button(item) { command = item }
                            .buttonStyle(.link)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                    }
                }
            }
            ScrollView {
                Text(output.isEmpty ? "（輸出會顯示在這裡）" : output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(output.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 260)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Text("指令會以 sh -c 在工作目錄執行，執行完會自動重新整理面板。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("關閉") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private func run() {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isRunning, let provider = pane.provider else { return }
        isRunning = true
        if history.last != trimmed { history.append(trimmed) }
        let directory = pane.path
        Task {
            do {
                let result = try await provider.runCommand(trimmed, in: directory)
                var text = result.combinedText
                if !result.succeeded { text += "\n[結束碼 \(result.exitCode)]" }
                output = text.isEmpty ? "（沒有輸出）" : text
            } catch {
                output = "執行失敗：\(error.localizedDescription)"
            }
            isRunning = false
            pane.reload()
        }
    }
}
