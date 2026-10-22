import CSystem
import Foundation

/// Sends signals. Abstracted for tests.
protocol SignalSending: Sendable {
    /// Throws `POSIXError` with the errno on failure.
    func send(_ signal: Int32, to pid: pid_t) throws
}

struct SystemSignalSender: SignalSending {
    func send(_ signal: Int32, to pid: pid_t) throws {
        if kill(pid, signal) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
    }
}

enum TerminationError: Error, LocalizedError, Equatable {
    case notRunning
    case identityMismatch
    case permissionDenied
    case protectedProcess(String)
    case signalFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "The process is no longer running."
        case .identityMismatch: return "The PID now belongs to a different process, so nothing was stopped."
        case .permissionDenied: return "macOS denied permission to signal this process (it belongs to another user)."
        case .protectedProcess(let name): return "“\(name)” is a system process and will not be stopped by WhatPort."
        case .signalFailed(let message): return "Could not signal the process: \(message)"
        }
    }
}

/// Terminates processes safely: verifies identity first, prefers SIGTERM,
/// and only sends SIGKILL when explicitly asked.
struct ProcessTerminator: Sendable {
    var inspector: any ProcessInspecting = SystemProcessInspector()
    var signals: any SignalSending = SystemSignalSender()
    var ownPID: pid_t = getpid()

    static let protectedNames: Set<String> = [
        "launchd", "kernel_task", "WindowServer", "loginwindow", "Finder", "Dock", "SystemUIServer",
        "ControlCenter", "coreaudiod", "mDNSResponder", "configd", "securityd", "opendirectoryd", "notifyd",
    ]

    /// Sends SIGTERM (or SIGKILL when `force`) after verifying the identity.
    func terminate(_ identity: ProcessIdentity, force: Bool = false) throws {
        guard identity.pid > 1, identity.pid != ownPID else { throw TerminationError.protectedProcess("PID \(identity.pid)") }
        guard let live = inspector.snapshot(pid: identity.pid) else { throw TerminationError.notRunning }
        guard live.identity.matches(identity) else { throw TerminationError.identityMismatch }
        if Self.protectedNames.contains(live.name) || (live.executablePath?.hasPrefix("/System/Library/CoreServices/") ?? false) {
            throw TerminationError.protectedProcess(live.name)
        }
        do {
            try signals.send(force ? SIGKILL : SIGTERM, to: identity.pid)
        } catch let error as POSIXError {
            switch error.code {
            case .ESRCH: throw TerminationError.notRunning
            case .EPERM: throw TerminationError.permissionDenied
            default: throw TerminationError.signalFailed(error.localizedDescription)
            }
        }
    }

    /// Terminates a tree WhatPort launched itself: descendants first (deepest
    /// last so parents can still reap), then the root.
    func terminateTree(root identity: ProcessIdentity, force: Bool = false) throws {
        let descendants = inspector.descendants(of: identity.pid)
        try terminate(identity, force: force)
        for pid in descendants {
            guard let snapshot = inspector.snapshot(pid: pid) else { continue }
            try? terminate(snapshot.identity, force: force)
        }
    }

    /// Polls until the process is gone or the timeout elapses.
    func waitForExit(_ identity: ProcessIdentity, timeout: TimeInterval, interval: TimeInterval = 0.15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if inspector.verify(identity) == nil { return true }
            try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }
        return inspector.verify(identity) == nil
    }
}
