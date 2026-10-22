import SwiftUI

struct NoticeBanner: View {
    var notice: Notice
    var dismiss: () -> Void

    private var symbol: String {
        switch notice.kind {
        case .info: return "info.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch notice.kind {
        case .info: return .accentColor
        case .error: return .red
        case .success: return .green
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(notice.message)
                .font(.callout)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.25)))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
