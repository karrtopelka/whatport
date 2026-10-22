import SwiftUI

@main
struct WhatPortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView()
                .environment(AppModel.shared)
        } label: {
            MenuBarLabel()
                .environment(AppModel.shared)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(AppModel.shared)
        }
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.developmentCount
        if model.settings.showCountInMenuBar, count > 0 {
            Label {
                Text(String(count))
            } icon: {
                Image(systemName: "network")
            }
            .labelStyle(.titleAndIcon)
            .accessibilityLabel("WhatPort, \(count) development servers")
        } else {
            Image(systemName: "network")
                .accessibilityLabel("WhatPort")
        }
    }
}
