import SwiftUI

struct StatusBadge: View {
    enum Status {
        case running, detected, managed, starting, stopping, restarting, stopped, failed, stubborn

        var label: String {
            switch self {
            case .running: return "Running"
            case .detected: return "Detected"
            case .managed: return "Managed"
            case .starting: return "Starting"
            case .stopping: return "Stopping"
            case .restarting: return "Restarting"
            case .stopped: return "Stopped"
            case .failed: return "Failed"
            case .stubborn: return "Not exiting"
            }
        }

        var color: Color {
            switch self {
            case .running, .managed: return .green
            case .detected: return .secondary
            case .starting, .restarting, .stopping: return .orange
            case .stopped: return .secondary
            case .failed, .stubborn: return .red
            }
        }

        var isBusy: Bool {
            switch self {
            case .starting, .stopping, .restarting: return true
            default: return false
            }
        }
    }

    var status: Status

    var body: some View {
        HStack(spacing: 4) {
            if status.isBusy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(status.color).frame(width: 6, height: 6)
            }
            Text(status.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(status.color == .secondary ? .secondary : status.color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(status.label)")
    }
}
