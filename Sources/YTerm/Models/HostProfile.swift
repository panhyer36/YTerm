import Foundation
import Observation

struct HostProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    /// Host name, IP, or an alias from ~/.ssh/config.
    var host: String = ""
    var user: String = ""
    var port: Int? = nil
    var identityFile: String = ""
    /// Directory to open after connecting; empty means the remote home.
    var initialPath: String = ""
    /// Password is kept in the macOS Keychain when true.
    var usesPassword: Bool = false
    /// Extra ssh arguments, e.g. `-J jumphost`.
    var extraOptions: String = ""

    var destination: String { user.isEmpty ? host : "\(user)@\(host)" }
    var displayName: String { name.isEmpty ? destination : name }

    var summary: String {
        var text = destination
        if let port, port > 0, port != 22 { text += ":\(port)" }
        return text
    }

    var extraArguments: [String] { Shell.splitArguments(extraOptions) }
    var isValid: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }
}

@MainActor @Observable
final class ProfileStore {
    private(set) var profiles: [HostProfile] = []

    private var fileURL: URL {
        URL(fileURLWithPath: AppPaths.supportDirectory).appendingPathComponent("hosts.json")
    }

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([HostProfile].self, from: data) {
            profiles = decoded
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(profiles) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func upsert(_ profile: HostProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        save()
    }

    func remove(_ profile: HostProfile) {
        profiles.removeAll { $0.id == profile.id }
        KeychainStore.delete(account: profile.id.uuidString)
        save()
    }

    func profile(id: UUID) -> HostProfile? {
        profiles.first { $0.id == id }
    }
}
