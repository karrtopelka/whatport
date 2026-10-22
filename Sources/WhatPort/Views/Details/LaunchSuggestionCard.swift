import SwiftUI

/// Shows an inferred launch command and asks the user to confirm it.
struct LaunchSuggestionCard: View {
    var suggestion: LaunchSuggestion
    var onSaveAndRestart: () -> Void
    var onSave: () -> Void
    var onEdit: () -> Void

    private var confidenceColor: Color {
        switch suggestion.confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }

    var body: some View {
        SectionCard(title: "Suggested launch command", symbol: "wand.and.stars") {
            Text(suggestion.configuration.commandLine)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 6))
            DetailRow("Directory", AppModel.abbreviate(suggestion.configuration.workingDirectory))
            HStack(spacing: 4) {
                Circle().fill(confidenceColor).frame(width: 6, height: 6)
                Text(suggestion.confidence.displayName).font(.caption.weight(.medium)).foregroundStyle(confidenceColor)
            }
            Text(suggestion.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("This was inferred, not recorded. Review it before use — nothing runs until you confirm.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Save & Restart", action: onSaveAndRestart)
                    .prominentActionStyle()
                    .help("Save this configuration, stop the running process and start it again with this command")
                Button("Save", action: onSave)
                    .secondaryActionStyle()
                    .help("Save without restarting")
                Button("Edit…", action: onEdit)
                    .secondaryActionStyle()
                    .help("Adjust the command before saving")
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
    }
}
