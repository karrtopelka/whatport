import Foundation

/// Selected, non-sensitive environment variables that help identify how a
/// process was launched. Nothing else from the environment is retained.
struct EnvironmentHints: Hashable, Sendable, Codable {
    /// `npm_lifecycle_event` — the package.json script name that is running.
    var lifecycleEvent: String?
    /// `npm_config_user_agent` — e.g. "bun/1.1.0 npm/? node/v22.0.0 darwin arm64".
    var userAgent: String?
    /// `npm_execpath` — path of the package manager CLI.
    var execPath: String?
    /// `INIT_CWD` — directory where the package manager command was run.
    var initialWorkingDirectory: String?
    /// `npm_package_json` — path to the package.json that defines the script.
    var packageJSONPath: String?
    /// `VIRTUAL_ENV` — active Python virtualenv.
    var virtualEnv: String?
    /// `PORT` — commonly used by dev servers to pick a port.
    var port: String?

    static let retainedKeys: Set<String> = [
        "npm_lifecycle_event", "npm_config_user_agent", "npm_execpath",
        "INIT_CWD", "npm_package_json", "VIRTUAL_ENV", "PORT",
    ]

    init() {}

    init(environment: [String: String]) {
        lifecycleEvent = environment["npm_lifecycle_event"]
        userAgent = environment["npm_config_user_agent"]
        execPath = environment["npm_execpath"]
        initialWorkingDirectory = environment["INIT_CWD"]
        packageJSONPath = environment["npm_package_json"]
        virtualEnv = environment["VIRTUAL_ENV"]
        port = environment["PORT"]
    }

    var isEmpty: Bool {
        lifecycleEvent == nil && userAgent == nil && execPath == nil && initialWorkingDirectory == nil
            && packageJSONPath == nil && virtualEnv == nil && port == nil
    }

    /// Package manager derived from the user agent string, if any.
    var packageManager: PackageManager? {
        guard let userAgent else { return nil }
        let lowered = userAgent.lowercased()
        if lowered.hasPrefix("bun/") { return .bun }
        if lowered.hasPrefix("pnpm/") { return .pnpm }
        if lowered.hasPrefix("yarn/") { return .yarn }
        if lowered.hasPrefix("npm/") { return .npm }
        if lowered.hasPrefix("deno/") { return .deno }
        return nil
    }
}

/// Identity of a process strong enough to guard against PID reuse.
struct ProcessIdentity: Hashable, Sendable, Codable {
    var pid: pid_t
    var startTime: Date?
    var executablePath: String?

    /// Two identities match when PIDs are equal and, where both sides know
    /// them, start times agree within one second. The executable path is kept
    /// for display only: shims such as `/usr/bin/python3` or version-manager
    /// wrappers re-exec in place and legitimately change it.
    func matches(_ other: ProcessIdentity) -> Bool {
        guard pid == other.pid else { return false }
        if let a = startTime, let b = other.startTime, abs(a.timeIntervalSince(b)) > 1.0 {
            return false
        }
        return true
    }
}

/// Everything we could learn about a process at a point in time.
/// Optional fields are `nil` when macOS did not let us read them.
struct ProcessSnapshot: Hashable, Sendable, Identifiable {
    var pid: pid_t
    var parentPID: pid_t?
    var name: String
    var executablePath: String?
    /// `nil` when the arguments were inaccessible (other user's process).
    var arguments: [String]?
    var workingDirectory: String?
    var startTime: Date?
    var uid: uid_t?
    var userName: String?
    var environmentHints: EnvironmentHints = EnvironmentHints()

    var id: pid_t { pid }

    var identity: ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: startTime, executablePath: executablePath)
    }

    var executableName: String {
        if let executablePath { return (executablePath as NSString).lastPathComponent }
        return name
    }

    var commandLine: String? {
        guard let arguments, !arguments.isEmpty else { return nil }
        return arguments.joined(separator: " ")
    }

    func uptime(now: Date = Date()) -> TimeInterval? {
        guard let startTime else { return nil }
        return max(0, now.timeIntervalSince(startTime))
    }
}
