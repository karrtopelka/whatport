import SwiftUI

/// Liquid Glass on macOS 26+, a material on macOS 15, and a flat fill when
/// the user asked for reduced transparency.
struct AdaptiveGlass: ViewModifier {
    var cornerRadius: CGFloat
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: cornerRadius))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    func adaptiveGlass(cornerRadius: CGFloat = 12, interactive: Bool = false) -> some View {
        modifier(AdaptiveGlass(cornerRadius: cornerRadius, interactive: interactive))
    }

    /// Prominent action button: glass on macOS 26, bordered prominent before.
    @ViewBuilder
    func prominentActionStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Secondary action button: glass on macOS 26, bordered before.
    @ViewBuilder
    func secondaryActionStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// Animation that respects Reduce Motion.
struct MotionAwareAnimation {
    @MainActor
    static func animation(_ animation: Animation = .snappy(duration: 0.25)) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation
    }
}
