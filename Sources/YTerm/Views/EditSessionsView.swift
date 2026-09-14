import SwiftUI

struct EditSessionsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.edits.sessions.isEmpty {
            VStack(spacing: 6) {
                Text("雙擊遠端檔案會下載到暫存區並用編輯器開啟；每次儲存都會自動上傳回遠端，不會在本機留下備份。")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                Text("預設用 macOS 對應該檔案類型的程式開啟，也可在「設定」中指定固定的編輯器。")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(app.edits.sessions) { session in
                    EditSessionRow(session: session)
                }
            }
            .listStyle(.inset)
        }
    }
}

struct EditSessionRow: View {
    @Environment(AppState.self) private var app
    let session: EditSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.circle.fill")
                .font(.title2)
                .foregroundStyle(stateColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.remoteName)
                    .bold()
                    .lineLimit(1)
                Text(session.remotePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.statusText)
                    .font(.caption)
                    .foregroundStyle(stateColor)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            if session.state == .uploading {
                ProgressView().controlSize(.small)
            }
            Button("開啟") { app.edits.openInEditor(session) }
                .help("再次用編輯器開啟本機副本")
            Button("立即上傳") { app.edits.uploadIfNeeded(session, force: true) }
                .disabled(session.state == .downloading || session.isUploading)
                .help("不等待儲存事件，立刻把目前的本機副本上傳")
            Button {
                app.edits.revealInFinder(session)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("在 Finder 顯示暫存檔")
            Button("停止") {
                app.edits.stop(session, deleteLocalCopy: !session.hasUnsyncedChanges)
            }
            .help("停止監看並刪除暫存副本（尚未上傳的變更會保留）")
        }
        .controlSize(.small)
        .padding(.vertical, 3)
    }

    private var stateColor: Color {
        switch session.state {
        case .downloading: return .gray
        case .watching: return session.pendingUpload ? .orange : .green
        case .uploading: return .accentColor
        case .failed: return .red
        }
    }
}
