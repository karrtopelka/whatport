import SwiftUI

/// A small clickable `:3000` chip that opens the port in the browser.
struct PortChip: View {
    var port: ListeningPort
    var action: () -> Void
    var copyPort: () -> Void
    var copyURL: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(":\(String(port.port))")
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isHovered ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open http://\(port.preferredHost):\(port.port) — bound to \(port.addressSummary)")
        .contextMenu {
            Button("Open in Browser", action: action)
            Button("Copy URL", action: copyURL)
            Button("Copy Port", action: copyPort)
        }
        .accessibilityLabel("Port \(port.port)")
        .accessibilityHint("Opens in the browser")
    }
}
