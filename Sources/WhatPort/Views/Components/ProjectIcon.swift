import SwiftUI

/// Rounded tile with the framework/runtime symbol.
struct ProjectIcon: View {
    var symbolName: String
    var category: PortCategory
    var size: CGFloat = 30

    private var tint: Color {
        switch category {
        case .development: return .accentColor
        case .application: return .purple
        case .system: return .gray
        case .unknown: return .orange
        }
    }

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: .rect(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}
