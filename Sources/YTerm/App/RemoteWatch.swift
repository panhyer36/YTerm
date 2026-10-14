import Foundation

/// How a two-way rule learns about changes on the remote side.
enum RemoteWatchState: Equatable, Sendable {
    case none
    case inotify
    case polling
    case installing
}

/// inotify-tools support: the watcher script and installing the package from the app.
enum InotifySupport {
    /// Package managers in order of preference, with the shell lines that install inotify-tools
    /// through the `as_root` helper defined by `installScript`.
    static let packageManagers: [(tool: String, lines: String)] = [
        ("apt-get", "as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y inotify-tools || { as_root apt-get update && as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y inotify-tools; }"),
        ("dnf", "as_root dnf install -y inotify-tools"),
        ("yum", "as_root yum install -y inotify-tools || { as_root yum install -y epel-release && as_root yum install -y inotify-tools; }"),
        ("zypper", "as_root zypper --non-interactive install inotify-tools"),
        ("pacman", "as_root pacman -S --noconfirm --needed inotify-tools"),
        ("apk", "as_root apk add inotify-tools"),
    ]

    static func packageManager(for info: RemoteInfo) -> String? {
        guard info.osName == "Linux" else { return nil }
        return packageManagers.first { info.has($0.tool) }?.tool
    }

    enum InstallExit: Int32 {
        case needsPassword = 90
        case wrongPassword = 91
        case noSudo = 92
        case stillMissing = 93
        /// sudo exists but this account is not in sudoers.
        case notSudoer = 94
        /// A password is needed and the account is in no admin group (sudo/wheel/admin), so it
        /// most likely cannot use sudo at all.
        case needsPasswordNotAdmin = 95
    }

    /// Installs inotify-tools as root, directly or through sudo. A sudo password, when needed, is
    /// read from stdin (never put on the command line).
    static func installScript(packageManager: String) -> String? {
        guard let lines = packageManagers.first(where: { $0.tool == packageManager })?.lines else { return nil }
        return """
        command -v inotifywait >/dev/null 2>&1 && exit 0
        if [ "$(id -u)" = 0 ]; then
        as_root() { "$@"; }
        elif command -v sudo >/dev/null 2>&1; then
        if sudo -n true 2>/dev/null; then
        as_root() { sudo -n "$@"; }
        else
        IFS= read -r P || P=''
        if [ -z "$P" ]; then
        case " $(id -Gn 2>/dev/null) " in *" sudo "*|*" wheel "*|*" admin "*) exit \(InstallExit.needsPassword.rawValue);; esac
        exit \(InstallExit.needsPasswordNotAdmin.rawValue)
        fi
        if ! e=$(printf '%s\\n' "$P" | LC_ALL=C sudo -S -p '' -v 2>&1); then
        case "$e" in *sudoers*|*"may not run sudo"*) exit \(InstallExit.notSudoer.rawValue);; esac
        exit \(InstallExit.wrongPassword.rawValue)
        fi
        as_root() { printf '%s\\n' "$P" | sudo -S -p '' "$@"; }
        fi
        else
        exit \(InstallExit.noSudo.rawValue)
        fi
        \(lines)
        command -v inotifywait >/dev/null 2>&1 || exit \(InstallExit.stillMissing.rawValue)
        exit 0
        """
    }

    /// Prints one line per change under `root` until stdin closes (the ssh channel went away).
    /// Exit 3: folder missing; 127: no inotifywait.
    static func watchScript(root: String, excludes: SyncExcludes) -> String {
        let exclude = excludes.inotifyRegex.map { " --exclude " + Shell.quote($0) } ?? ""
        return """
        cd -- \(Shell.quote(root)) 2>/dev/null || exit 3
        command -v inotifywait >/dev/null 2>&1 || exit 127
        exec 3<&0
        inotifywait -m -r -q -e close_write,create,delete,move,attrib --format '%w%f'\(exclude) . &
        p=$!
        ( cat <&3 >/dev/null; kill $p 2>/dev/null ) >/dev/null 2>&1 &
        wait $p
        """
    }
}

extension InotifySupport {
    enum InstallError: LocalizedError {
        case loginFailed(String)

        var errorDescription: String? {
            switch self {
            case let .loginFailed(message): return message
            }
        }
    }

    /// Runs the install script over an existing connection; returns its exit code.
    static func install(on connection: RemoteConnection, sudoPassword: String?) async throws -> CommandResult {
        guard let packageManager = packageManager(for: connection.info),
              let script = installScript(packageManager: packageManager) else {
            throw AppError.general("找不到支援的套件管理工具，請手動安裝 inotify-tools。")
        }
        // The password goes through stdin; an empty line means "none".
        let input = Data(((sudoPassword ?? "") + "\n").utf8)
        return try await connection.run(script, stdin: input, onStdout: nil, onStderr: nil)
    }

    /// Logs in to the same host as another account (root, or one that may use sudo) and installs
    /// from there, using the same password for sudo. The extra connection is closed afterwards.
    static func install(on profile: HostProfile, asUser user: String, password: String, log: CommandLog) async throws -> CommandResult {
        var adminProfile = profile
        adminProfile.user = user
        // The profile's key belongs to the usual account; let ssh fall back to the password.
        adminProfile.identityFile = ""
        let admin = RemoteConnection(profile: adminProfile, password: password, log: log)
        do {
            try await admin.bootstrap()
        } catch {
            if RemoteConnection.isAuthenticationFailure(error) {
                throw InstallError.loginFailed("無法以 \(user) 登入：帳號或密碼不正確，或伺服器不允許這個帳號用密碼登入（例如禁止 root 透過 ssh 登入）。")
            }
            throw error
        }
        let result: CommandResult
        do {
            // Root never reads the password; any other account uses it for sudo.
            result = try await install(on: admin, sudoPassword: password)
        } catch {
            await admin.disconnect()
            throw error
        }
        await admin.disconnect()
        return result
    }
}

/// Which account installs inotify-tools.
enum InotifyCredentials {
    /// The connected account, through sudo with this password.
    case sudoPassword(String)
    /// Another account on the same host (root or a sudoer), logged in with this password.
    case account(user: String, password: String)
}

/// What the credentials sheet asks for.
struct InotifyCredentialRequest: Hashable {
    var profileID: UUID
    var message: String?
    /// False when the connected account certainly cannot become root (no sudo, not in sudoers).
    var allowCurrentAccount = true
    /// Start on the "other account" tab (the connected account most likely cannot use sudo).
    var preferOtherAccount = false
}

/// Shown when a two-way rule's host has no inotifywait.
struct InotifyPrompt: Identifiable {
    let id = UUID()
    var profileID: UUID
    var hostName: String
    var packageManager: String
    var pollSeconds: Int
}
