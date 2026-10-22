import AppKit
import SwiftUI
import Testing
@testable import WhatPort

@Suite("Settings window", .serialized)
struct SettingsOpenerTests {
    /// The test host is the real app, so the Settings scene exists. Hosting the
    /// root view registers the `openSettings` action; `open()` must then show
    /// a Settings window.
    @Test @MainActor func openShowsTheSettingsWindow() async throws {
        let defaults = UserDefaults(suiteName: "com.karrtopelka.whatport.settings-tests")!
        let model = AppModel(settings: AppSettings(defaults: defaults), discovery: DiscoveryService(scanner: FakeScanner(sockets: []), inspector: FakeInspector([]), locator: ProjectRootLocator(identifier: ProjectIdentifier(fileSystem: InMemoryFileSystem())), home: "/Users/test"), inspector: FakeInspector([]), terminator: ProcessTerminator(inspector: FakeInspector([]), signals: RecordingSignalSender(), ownPID: 1), store: InMemoryConfigurationStore(), logsDirectory: try TemporaryDirectory.make("settings-tests"))
        let hosting = NSHostingView(rootView: MenuBarRootView().environment(model))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 420, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<10 where SettingsOpener.action == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(SettingsOpener.action != nil, "root view registers the openSettings action")

        SettingsOpener.open()
        var settings: NSWindow?
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if let found = SettingsOpener.settingsWindow, found.isVisible { settings = found; break }
        }
        #expect(settings != nil, "a Settings window is visible; windows: \(NSApp.windows.map { $0.identifier?.rawValue ?? $0.title })")
        settings?.close()
    }
}
