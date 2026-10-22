import AppKit
import SwiftUI

/// Reports whether the hosting window (the menu bar popover) is on screen.
struct WindowVisibilityObserver: NSViewRepresentable {
    var onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            guard let window else {
                report(false)
                return
            }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.willCloseNotification,
                NSWindow.didBecomeMainNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                    let isClosing = notification.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if isClosing {
                            self.report(false)
                        } else {
                            self.evaluate()
                        }
                    }
                })
            }
            evaluate()
        }

        private func evaluate() {
            guard let window else { report(false); return }
            report(window.isVisible && window.occlusionState.contains(.visible))
        }

        private func report(_ visible: Bool) {
            guard lastReported != visible else { return }
            lastReported = visible
            onChange?(visible)
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}
