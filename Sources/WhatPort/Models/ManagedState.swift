import Foundation

/// Lifecycle of an instance WhatPort is responsible for.
enum ManagedState: Hashable, Sendable {
    case stopped
    case starting
    case running(ProcessIdentity)
    case stopping(ProcessIdentity)
    case restarting
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .starting, .stopping, .restarting: return true
        default: return false
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var identity: ProcessIdentity? {
        switch self {
        case .running(let identity), .stopping(let identity): return identity
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .restarting: return "Restarting"
        case .failed: return "Failed"
        }
    }
}

/// Events that drive `ManagedState`.
enum ManagedEvent: Hashable, Sendable {
    case startRequested
    case launched(ProcessIdentity)
    case launchFailed(String)
    case stopRequested
    case restartRequested
    case exited(code: Int32)
    case disappeared
    /// WhatPort relaunched and found the previous instance still alive.
    case adopted(ProcessIdentity)
}

/// Pure state machine so transitions can be unit tested.
enum ManagedStateMachine {
    /// Returns the next state, or `nil` when the event is not valid in the current state.
    static func next(from state: ManagedState, on event: ManagedEvent) -> ManagedState? {
        switch (state, event) {
        case (.stopped, .startRequested), (.failed, .startRequested):
            return .starting
        case (.starting, .launched(let identity)), (.restarting, .launched(let identity)):
            return .running(identity)
        case (.starting, .launchFailed(let message)), (.restarting, .launchFailed(let message)):
            return .failed(message)
        case (.running(let identity), .stopRequested):
            return .stopping(identity)
        case (.running, .restartRequested):
            return .restarting
        case (.stopping, .exited), (.stopping, .disappeared):
            return .stopped
        case (.running, .exited(let code)):
            return code == 0 ? .stopped : .failed("Exited with status \(code)")
        case (.running, .disappeared):
            return .stopped
        case (.restarting, .exited), (.restarting, .disappeared):
            // The old instance went away; the runner will now launch again.
            return .restarting
        case (.stopped, .adopted(let identity)), (.failed, .adopted(let identity)):
            return .running(identity)
        case (.starting, .exited(let code)):
            return .failed("Exited with status \(code) during startup")
        case (.starting, .stopRequested), (.restarting, .stopRequested):
            return .stopped
        default:
            return nil
        }
    }
}
