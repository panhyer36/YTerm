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
            Section("關於") {
                Text("所有操作都以 ssh / rsync / tar 等指令完成，可在「指令紀錄」面板查看實際執行的指令。ssh 連線使用 ControlMaster 多工，只需驗證一次。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
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
