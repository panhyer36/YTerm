import Foundation

struct SSHConfigHost: Identifiable, Hashable, Sendable {
    var id: String { alias }
    var alias: String
    var hostName: String?
    var user: String?
    var port: Int?
    var identityFile: String?

    var summary: String {
        var text = ""
        if let user { text += user + "@" }
        text += hostName ?? alias
        if let port, port != 22 { text += ":\(port)" }
        return text
    }

    /// Build a profile that uses the alias so ssh applies the whole config block (ProxyJump etc.).
    func makeProfile() -> HostProfile {
        var profile = HostProfile()
        profile.name = alias
        profile.host = alias
        return profile
    }
}

enum SSHConfigParser {
    static var defaultPath: String { NSHomeDirectory() + "/.ssh/config" }

    static func loadDefault() -> [SSHConfigHost] {
        guard let text = try? String(contentsOfFile: defaultPath, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var current: [SSHConfigHost] = []
        var skipping = false

        func flush() {
            hosts.append(contentsOf: current)
            current = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "="))
            let parts = line.components(separatedBy: separators).filter { !$0.isEmpty }
            guard let keyword = parts.first?.lowercased() else { continue }
            let values = Array(parts.dropFirst())

            switch keyword {
            case "host":
                flush()
                skipping = false
                let concrete = values.filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
                current = concrete.map { SSHConfigHost(alias: $0) }
            case "match":
                flush()
                skipping = true
            default:
                guard !skipping, !current.isEmpty, let value = values.first else { continue }
                for index in current.indices {
                    switch keyword {
                    case "hostname": current[index].hostName = value
                    case "user": current[index].user = value
                    case "port": current[index].port = Int(value)
                    case "identityfile": current[index].identityFile = value
                    default: break
                    }
                }
            }
        }
        flush()
        return hosts
    }
}
