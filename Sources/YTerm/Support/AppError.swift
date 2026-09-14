import Foundation

enum AppError: LocalizedError {
    case commandFailed(command: String, exitCode: Int32, output: String)
    case connectionFailed(String)
    case notConnected
    case toolMissing(String)
    case unsupportedArchive(String)
    case refused(String)
    case general(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, exitCode, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let shortCommand = command.count > 200 ? String(command.prefix(200)) + "…" : command
            if trimmed.isEmpty {
                return "指令失敗（結束碼 \(exitCode)）：\(shortCommand)"
            }
            return "\(trimmed)\n\n指令（結束碼 \(exitCode)）：\(shortCommand)"
        case let .connectionFailed(message):
            return message
        case .notConnected:
            return "尚未連線到遠端主機。"
        case let .toolMissing(tool):
            return "找不到所需的工具：\(tool)"
        case let .unsupportedArchive(name):
            return "不支援的壓縮檔格式：\(name)"
        case let .refused(message):
            return message
        case let .general(message):
            return message
        }
    }
}

struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}
