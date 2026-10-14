import AppKit
import SwiftUI

struct HostEditorView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var profile: HostProfile
    @State private var portText: String
    @State private var password = ""
    @State private var rememberPassword: Bool
    @State private var testMessage: String?
    @State private var isTesting = false
    private let isNew: Bool

    init(profile: HostProfile?) {
        _profile = State(initialValue: profile ?? HostProfile())
        _portText = State(initialValue: profile?.port.map(String.init) ?? "")
        _rememberPassword = State(initialValue: profile?.usesPassword ?? false)
        isNew = profile == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "新增主機" : "編輯主機")
                .font(.title2)
                .bold()

            Form {
                TextField("名稱", text: $profile.name, prompt: Text("顯示名稱（可留空）"))
                TextField("主機", text: $profile.host, prompt: Text("IP、主機名稱，或 ~/.ssh/config 的 Host 別名"))
                TextField("使用者", text: $profile.user, prompt: Text("留空則交給 ssh 設定決定"))
                TextField("連接埠", text: $portText, prompt: Text("22"))
                HStack {
                    TextField("金鑰檔", text: $profile.identityFile, prompt: Text("例如 ~/.ssh/id_ed25519（可留空）"))
                    Button("選擇…") { pickIdentityFile() }
                }
                TextField("起始目錄", text: $profile.initialPath, prompt: Text("留空則為遠端家目錄"))
                TextField("額外 ssh 參數", text: $profile.extraOptions, prompt: Text("例如 -J jumphost"))
                SecureField("密碼", text: $password, prompt: Text(profile.usesPassword ? "已儲存於鑰匙圈（輸入新密碼可更新）" : "使用金鑰登入時可留空"))
                Toggle("記住密碼（儲存到 macOS 鑰匙圈）", isOn: $rememberPassword)
            }
            .formStyle(.grouped)
            .frame(height: 340)

            if let testMessage {
                ScrollView {
                    Text(testMessage)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }

            HStack {
                if !isNew {
                    Button("刪除主機", role: .destructive) {
                        app.profiles.remove(profile)
                        dismiss()
                    }
                }
                Button("測試連線") { testConnection() }
                    .disabled(!profile.isValid || isTesting)
                if isTesting { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("儲存") { save(connect: false) }
                    .disabled(!profile.isValid)
                Button("儲存並連線") { save(connect: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!profile.isValid)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func normalizedProfile() -> HostProfile {
        var result = profile
        result.name = result.name.trimmingCharacters(in: .whitespaces)
        result.host = result.host.trimmingCharacters(in: .whitespaces)
        result.user = result.user.trimmingCharacters(in: .whitespaces)
        result.identityFile = result.identityFile.trimmingCharacters(in: .whitespaces)
        result.initialPath = result.initialPath.trimmingCharacters(in: .whitespaces)
        result.port = Int(portText.trimmingCharacters(in: .whitespaces))
        return result
    }

    private func save(connect: Bool) {
        var result = normalizedProfile()
        if !password.isEmpty {
            if rememberPassword {
                do {
                    try KeychainStore.save(password: password, account: result.id.uuidString)
                    result.usesPassword = true
                } catch {
                    app.presentError(error, title: "無法儲存密碼")
                }
            } else {
                KeychainStore.delete(account: result.id.uuidString)
                result.usesPassword = false
            }
        } else if !rememberPassword {
            KeychainStore.delete(account: result.id.uuidString)
            result.usesPassword = false
        }
        app.profiles.upsert(result)
        dismiss()
        if connect {
            app.connectPreferringRemotePane(result, password: password.isEmpty ? nil : password, rememberPassword: false)
        }
    }

    private func testConnection() {
        let candidate = normalizedProfile()
        var testPassword = password.isEmpty ? nil : password
        if testPassword == nil, candidate.usesPassword {
            testPassword = KeychainStore.load(account: candidate.id.uuidString)
        }
        isTesting = true
        testMessage = nil
        let connection = RemoteConnection(profile: candidate, password: testPassword, log: app.log)
        Task {
            do {
                let info = try await connection.bootstrap()
                let tools = info.tools.sorted().joined(separator: " ")
                var message = "連線成功。系統：\(info.osName)，使用者：\(info.userName)，家目錄：\(info.home)\n可用工具：\(tools.isEmpty ? "（無）" : tools)"
                if !info.has("rsync") { message += "\n⚠️ 遠端沒有 rsync，將無法傳輸檔案。" }
                testMessage = message
            } catch {
                testMessage = "連線失敗：\(error.localizedDescription)"
            }
            isTesting = false
        }
    }

    private func pickIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.message = "選擇 SSH 私密金鑰"
        if panel.runModal() == .OK, let url = panel.url {
            profile.identityFile = url.path
        }
    }
}

struct PasswordPromptView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let profile: HostProfile
    let message: String?
    let paneID: PaneID
    @State private var password = ""
    @State private var remember = true
    @State private var submitted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("連線到 \(profile.displayName)")
                .font(.headline)
            Text(profile.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
            }
            SecureField("密碼", text: $password)
                .textFieldStyle(.roundedBorder)
            Toggle("記住密碼（儲存到 macOS 鑰匙圈）", isOn: $remember)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("連線") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func submit() {
        guard !submitted, !password.isEmpty else { return }
        submitted = true
        dismiss()
        if let pane = app.pane(paneID) {
            app.connect(to: profile, in: pane, password: password, rememberPassword: remember)
        } else {
            app.connectPreferringRemotePane(profile, password: password, rememberPassword: remember)
        }
    }
}

struct InotifyCredentialsSheet: View {
    enum Account: Hashable {
        case current
        case other
    }

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: InotifyCredentialRequest
    @State private var account: Account
    @State private var otherUser = "root"
    @State private var password = ""
    @State private var submitted = false

    init(request: InotifyCredentialRequest) {
        self.request = request
        _account = State(initialValue: request.allowCurrentAccount && !request.preferOtherAccount ? .current : .other)
    }

    private var profile: HostProfile? { app.profiles.profile(id: request.profileID) }
    private var currentUser: String { app.connections[request.profileID]?.info.userName ?? "目前帳號" }
    private var loginPassword: String? { KeychainStore.load(account: request.profileID.uuidString) }
    private var canSubmit: Bool {
        !password.isEmpty && (account == .current || !otherUser.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("在「\(profile?.displayName ?? "主機")」安裝 inotify-tools")
                .font(.headline)
            Text("安裝需要 root 權限。帳號與密碼只用於這次安裝，不會儲存。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = request.message {
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("", selection: $account) {
                Text("目前帳號（\(currentUser)）").tag(Account.current)
                Text("其他有 root 權限的帳號").tag(Account.other)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!request.allowCurrentAccount)
            switch account {
            case .current:
                SecureField("\(currentUser) 的 sudo 密碼", text: $password)
                    .textFieldStyle(.roundedBorder)
            case .other:
                TextField("帳號", text: $otherUser, prompt: Text("root 或有 sudo 權限的帳號"))
                    .textFieldStyle(.roundedBorder)
                SecureField("密碼", text: $password)
                    .textFieldStyle(.roundedBorder)
                Text("會用這個帳號另外登入同一台主機來安裝；不是 root 時用同一組密碼執行 sudo。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if account == .current, loginPassword != nil {
                    Button("使用登入密碼") {
                        password = loginPassword ?? ""
                        submit()
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("安裝") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
            Text("取消後雙向同步會繼續以輪詢方式檢查遠端。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: account) { password = "" }
    }

    private func submit() {
        guard !submitted, canSubmit else { return }
        submitted = true
        dismiss()
        switch account {
        case .current:
            app.installInotify(profileID: request.profileID, credentials: .sudoPassword(password))
        case .other:
            app.installInotify(
                profileID: request.profileID,
                credentials: .account(user: otherUser.trimmingCharacters(in: .whitespaces), password: password)
            )
        }
    }
}

struct ImportSSHConfigView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var hosts: [SSHConfigHost] = SSHConfigParser.loadDefault()
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("從 ~/.ssh/config 匯入主機")
                .font(.headline)
            if hosts.isEmpty {
                Text("在 \(SSHConfigParser.defaultPath) 找不到可匯入的 Host 設定。")
                    .foregroundStyle(.secondary)
            } else {
                Text("匯入後會以 Host 別名連線，ssh 會自動套用 config 裡的 HostName、User、Port、ProxyJump 等設定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                List(hosts, selection: $selected) { host in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.alias).bold()
                        Text(host.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(host.id)
                }
                .frame(height: 260)
            }
            HStack {
                Button("全選") { selected = Set(hosts.map(\.id)) }
                    .disabled(hosts.isEmpty)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("匯入 \(selected.count) 個") { importSelected() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func importSelected() {
        let existing = Set(app.profiles.profiles.map(\.host))
        for host in hosts where selected.contains(host.id) && !existing.contains(host.alias) {
            app.profiles.upsert(host.makeProfile())
        }
        dismiss()
    }
}
