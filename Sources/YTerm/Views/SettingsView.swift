import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @AppStorage(SettingsKey.rsyncPath) private var rsyncPath = ""
    @AppStorage(SettingsKey.compress) private var compress = false
    @AppStorage(SettingsKey.excludes) private var excludes = ".DS_Store"
    @AppStorage(SettingsKey.confirmDelete) private var confirmDelete = true
    @AppStorage(SettingsKey.maxConcurrentTransfers) private var maxConcurrent = 2
    @AppStorage(SettingsKey.localStartPath) private var localStartPath = ""
    @AppStorage(SettingsKey.showHiddenFiles) private var showHidden = false
    @AppStorage(SettingsKey.editorAppPath) private var editorAppPath = ""
    @AppStorage(SettingsKey.preferredIDE) private var preferredIDE = ""
    @AppStorage(SettingsKey.syncBackupRetentionDays) private var backupRetentionDays = 30
    @State private var backupMessage: String?
    @State private var cleaningBackups = false
    @State private var confirmClearBackups = false

    var body: some View {
        Form {
            Section("rsync") {
                LabeledContent("目前使用") {
                    Text(app.rsyncFlavor?.displayName ?? "找不到 rsync")
                        .foregroundStyle(app.rsyncFlavor == nil ? .red : .primary)
                        .textSelection(.enabled)
                }
                if app.rsyncFlavor?.kind != .rsync {
                    Text("macOS 內建的 openrsync 只能顯示單一檔案的進度。建議安裝 Homebrew 版：brew install rsync，程式會自動優先使用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("自訂 rsync 路徑", text: $rsyncPath, prompt: Text("留空則自動偵測"))
                    .onChange(of: rsyncPath) { _, _ in Task { await app.detectRsync() } }
                Button("重新偵測") { Task { await app.detectRsync() } }
                Toggle("傳輸時壓縮資料（-z，適合慢速網路）", isOn: $compress)
                VStack(alignment: .leading, spacing: 4) {
                    Text("排除樣式（每行一個，對應 --exclude）")
                    TextEditor(text: $excludes)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 80)
                }
                Stepper("同時進行的傳輸數：\(maxConcurrent)", value: $maxConcurrent, in: 1...6)
                    .onChange(of: maxConcurrent) { _, newValue in app.transfers.maxConcurrent = newValue }
            }
            Section("瀏覽") {
                TextField("本機起始目錄", text: $localStartPath, prompt: Text("留空則為家目錄"))
                Toggle("預設顯示隱藏檔", isOn: $showHidden)
                Toggle("刪除前先確認", isOn: $confirmDelete)
            }
            Section("遠端編輯") {
                LabeledContent("編輯器") {
                    HStack {
                        Text(editorAppPath.isEmpty ? "系統預設" : (editorAppPath as NSString).lastPathComponent)
                        Button("選擇…") { pickEditor() }
                        Button("預設") { editorAppPath = "" }
                            .disabled(editorAppPath.isEmpty)
                    }
                }
                Text("雙擊遠端檔案會下載到暫存區，用 macOS 預設程式（或這裡指定的編輯器）開啟；儲存後自動上傳回遠端。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("暫存區") {
                    HStack {
                        Text(EditSessionManager.rootDirectory.path)
                            .font(.caption)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("清除") { EditSessionManager.removeAllStagedFiles() }
                            .disabled(!app.edits.sessions.isEmpty)
                            .help("刪除暫存區內所有副本（編輯中時無法清除）")
                    }
                }
            }
            Section("雙向同步備份") {
                Picker("自動清理", selection: $backupRetentionDays) {
                    ForEach([7, 14, 30, 60, 90, 180, 365], id: \.self) { days in
                        Text("保留 \(days) 天").tag(days)
                    }
                    Text("永久保留").tag(0)
                }
                Text("覆蓋或刪除前的備份放在本機「\(SyncBackups.localRoot)」與遠端 ~/\(SyncRule.backupFolderName)。過期的備份在開啟 App、連上主機時及每 6 小時清理一次；遠端只在連線時清理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("立即清理過期備份") {
                        guard let cutoff = SyncBackups.cutoff(retentionDays: backupRetentionDays) else { return }
                        cleanBackups(before: cutoff)
                    }
                    .disabled(backupRetentionDays == 0 || cleaningBackups)
                    Button("刪除全部備份…", role: .destructive) { confirmClearBackups = true }
                        .disabled(cleaningBackups)
                    if cleaningBackups { ProgressView().controlSize(.small) }
                }
                if let backupMessage {
                    Text(backupMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .confirmationDialog("要刪除全部同步備份嗎？", isPresented: $confirmClearBackups, titleVisibility: .visible) {
                Button("刪除", role: .destructive) { cleanBackups(before: SyncBackups.everything) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("會永久刪除本機所有規則的備份，以及目前已連線主機上的備份，無法復原。")
            }
            Section("IDE") {
                Picker("開啟目前資料夾的 IDE", selection: $preferredIDE) {
                    Text("自動（Cursor、VS Code、VS Code Insiders 依序）").tag("")
                    ForEach(IDEKind.allCases) { kind in
                        Text(installedIDEs.contains { $0.kind == kind } ? kind.name : "\(kind.name)（未安裝）").tag(kind.rawValue)
                    }
                }
                LabeledContent("目前使用") {
                    if let ide = IDELauncher.detect() {
                        Text("\(ide.name)  \(ide.cliPath)")
                            .font(.caption)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("找不到").foregroundStyle(.red)
                    }
                }
                Text("本機面板直接開啟資料夾；遠端面板以 vscode-remote://ssh-remote+主機/路徑 開啟，需先在該 IDE 安裝 Remote - SSH 擴充功能。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("關於") {
                Text("所有操作都以 ssh / rsync / tar 等指令完成，可在「指令紀錄」面板查看實際執行的指令。ssh 連線使用 ControlMaster 多工，只需驗證一次。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
    }

    private var installedIDEs: [IDELauncher.IDE] { IDELauncher.installedIDEs() }

    private func cleanBackups(before cutoff: String) {
        cleaningBackups = true
        Task {
            let removed = await app.syncs.pruneBackups(before: cutoff)
            backupMessage = "已刪除本機 \(removed.local) 份、遠端 \(removed.remote) 份備份。"
            cleaningBackups = false
        }
    }

    private func pickEditor() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "選擇用來編輯遠端檔案的程式"
        if panel.runModal() == .OK, let url = panel.url {
            editorAppPath = url.path
        }
    }
}
