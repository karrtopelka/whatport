import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WhatPort

/// Renders the main views with canned data into PNG files for visual review.
/// Opt-in: set the output directory before running the tests with
/// `defaults write com.karrtopelka.whatport WhatPortSnapshotDir /path/to/dir`
/// (or the `WHATPORT_SNAPSHOT_DIR` environment variable when running in Xcode).
@Suite("Snapshot rendering", .serialized)
struct SnapshotRenderTests {
    static var outputDirectory: String? {
        ProcessInfo.processInfo.environment["WHATPORT_SNAPSHOT_DIR"]
            ?? UserDefaults.standard.string(forKey: "WhatPortSnapshotDir")
    }

    @MainActor
    static func makeModel() async throws -> AppModel {
        let fs = InMemoryFileSystem(files: [
            "/Users/test/Projects/my-dashboard/package.json": #"{"name":"my-dashboard","scripts":{"dev":"next dev"},"dependencies":{"next":"15"}}"#,
            "/Users/test/Projects/my-dashboard/bun.lock": "",
            "/Users/test/Projects/agent-playground/package.json": #"{"name":"agent-playground","scripts":{"dev":"vite --host"},"devDependencies":{"vite":"5"}}"#,
            "/Users/test/Projects/agent-playground/pnpm-lock.yaml": "",
            "/Users/test/Projects/backend-api/pyproject.toml": "[project]\nname = \"backend-api\"\ndependencies = [\"fastapi\"]\n",
        ])
        let now = Date()
        let shell = makeProcess(pid: 5, parent: 1, name: "zsh", path: "/bin/zsh", cwd: "/Users/test")
        let bunRunner = makeProcess(pid: 8240, parent: 5, name: "bun", path: "/Users/test/.bun/bin/bun", arguments: ["bun", "run", "dev"], cwd: "/Users/test/Projects/my-dashboard", start: now.addingTimeInterval(-8040))
        let next = makeProcess(pid: 8241, parent: 8240, name: "node", path: "/Users/test/.nvm/versions/node/v22/bin/node", arguments: ["next-server (v15.0.0)"], cwd: "/Users/test/Projects/my-dashboard", start: now.addingTimeInterval(-8040), environment: ["npm_lifecycle_event": "dev", "npm_config_user_agent": "bun/1.2.0 npm/? node/v22"])
        let vite = makeProcess(pid: 9321, parent: 5, name: "node", path: "/Users/test/.nvm/versions/node/v22/bin/node", arguments: ["node", "/Users/test/Projects/agent-playground/node_modules/.bin/vite", "--host"], cwd: "/Users/test/Projects/agent-playground", start: now.addingTimeInterval(-2280))
        let api = makeProcess(pid: 4411, parent: 5, name: "python3.12", path: "/Users/test/Projects/backend-api/.venv/bin/python3.12", arguments: ["python", "-m", "uvicorn", "app:main", "--reload"], cwd: "/Users/test/Projects/backend-api", start: now.addingTimeInterval(-18000))
        let docker = makeProcess(pid: 611, parent: 1, name: "com.docker.backend", path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend", cwd: nil, start: now.addingTimeInterval(-90000))
        let rapport = makeProcess(pid: 455, parent: 1, name: "rapportd", path: "/usr/libexec/rapportd", cwd: nil, start: now.addingTimeInterval(-90000))
        let scanner = FakeScanner(sockets: [
            ListeningSocket(pid: 8241, port: 3000, address: "*", family: .ipv6),
            ListeningSocket(pid: 9321, port: 5173, address: "*", family: .ipv6),
            ListeningSocket(pid: 9321, port: 5174, address: "127.0.0.1", family: .ipv4),
            ListeningSocket(pid: 4411, port: 4000, address: "127.0.0.1", family: .ipv4),
            ListeningSocket(pid: 4411, port: 4001, address: "127.0.0.1", family: .ipv4),
            ListeningSocket(pid: 611, port: 5432, address: "*", family: .ipv4),
            ListeningSocket(pid: 455, port: 49152, address: "*", family: .ipv4),
        ])
        let discovery = DiscoveryService(scanner: scanner, inspector: FakeInspector([shell, bunRunner, next, vite, api, docker, rapport]), locator: ProjectRootLocator(identifier: ProjectIdentifier(fileSystem: fs)), home: "/Users/test")
        let defaults = UserDefaults(suiteName: "com.karrtopelka.whatport.snapshots")!
        defaults.removePersistentDomain(forName: "com.karrtopelka.whatport.snapshots")
        let model = AppModel(settings: AppSettings(defaults: defaults), discovery: discovery, inspector: FakeInspector([shell, bunRunner, next, vite, api, docker, rapport]), terminator: ProcessTerminator(inspector: FakeInspector([]), signals: RecordingSignalSender(), ownPID: 1), store: InMemoryConfigurationStore(), logsDirectory: try TemporaryDirectory.make("snap-logs"))
        _ = model.save(LaunchConfiguration(displayName: "backend-api", projectRootPath: "/Users/test/Projects/backend-api", workingDirectory: "/Users/test/Projects/backend-api", executable: "uvicorn", arguments: ["app:main", "--reload"], expectedPorts: [4000, 4001]))
        _ = model.save(LaunchConfiguration(displayName: "docs-site", projectRootPath: "/Users/test/Projects/docs", workingDirectory: "/Users/test/Projects/docs", executable: "pnpm", arguments: ["dev"], expectedPorts: [4321]))
        await model.refresh()
        return model
    }

    @MainActor
    static func render<V: View>(_ view: V, width: CGFloat, dark: Bool, name: String, directory: String) async throws {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(calibratedWhite: 0.13, alpha: 1) : NSColor(calibratedWhite: 0.95, alpha: 1)
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.orderFrontRegardless()
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(60))
            window.setContentSize(hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
        }
        let bounds = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { Issue.record("no bitmap"); return }
        hosting.appearance?.performAsCurrentDrawingAppearance {
            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                window.backgroundColor.setFill()
                bounds.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            hosting.cacheDisplay(in: bounds, to: rep)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { Issue.record("no png"); return }
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)\(dark ? "-dark" : "-light").png"))
        window.orderOut(nil)
    }

    /// Dumps what the real pipeline sees on this machine, for manual review.
    @Test func dumpLiveDiscovery() async throws {
        guard let directory = Self.outputDirectory else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let result = try await DiscoveryService().discover()
        var lines: [String] = []
        for listener in result.listeners {
            lines.append("pid \(listener.process.pid) \(listener.process.executableName) [\(listener.category.rawValue)] ports \(listener.portsSummary)")
            lines.append("  exe: \(listener.process.executablePath ?? "-")")
            lines.append("  args: \(listener.process.commandLine ?? "-")")
            lines.append("  cwd: \(listener.process.workingDirectory ?? "-")")
            lines.append("  env: \(listener.process.environmentHints)")
            lines.append("  project: \(listener.project.map { "\($0.name) · \($0.subtitle(runtime: listener.runtime)) @ \($0.rootPath) markers=\($0.markers)" } ?? "-")")
            lines.append("  ancestry: \(listener.ancestry.map { "\($0.executableName)(\($0.pid))" }.joined(separator: " <- ")) runner=\(listener.runnerParent.map { "\($0.executableName)(\($0.pid))" } ?? "-")")
            lines.append("  suggestion: \(LaunchInferenceEngine().infer(for: listener).map { "\($0.confidence.rawValue): \($0.configuration.commandLine) @ \($0.configuration.workingDirectory) — \($0.reason)" } ?? "-")")
        }
        try lines.joined(separator: "\n").write(toFile: directory + "/discovery.txt", atomically: true, encoding: .utf8)
    }

    @Test @MainActor func renderMainViews() async throws {
        guard let directory = Self.outputDirectory else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let model = try await Self.makeModel()
        #expect(model.visibleGroups.map(\.title) == ["agent-playground", "backend-api", "my-dashboard"], "stopped managed projects only appear under Managed")
        model.filter = .managed
        #expect(model.visibleGroups.map(\.title) == ["backend-api", "docs-site"])
        for dark in [false, true] {
            model.filter = .development
            try await Self.render(MenuBarRootView().environment(model), width: 420, dark: dark, name: "main-dev", directory: directory)
            model.filter = .all
            try await Self.render(MenuBarRootView().environment(model), width: 420, dark: dark, name: "main-all", directory: directory)
            model.filter = .managed
            try await Self.render(MenuBarRootView().environment(model), width: 420, dark: dark, name: "main-managed", directory: directory)
            model.filter = .development
            let group = try #require(model.visibleGroups.first { $0.title == "my-dashboard" })
            try await Self.render(GroupDetailView(groupID: group.id, path: .constant([group.id])).environment(model).frame(width: 420), width: 420, dark: dark, name: "detail", directory: directory)
            let managed = try #require(model.visibleGroups.first { $0.title == "backend-api" })
            try await Self.render(GroupDetailView(groupID: managed.id, path: .constant([managed.id])).environment(model).frame(width: 420), width: 420, dark: dark, name: "detail-managed", directory: directory)
            model.requestStop(group)
            try await Self.render(MenuBarRootView().environment(model), width: 420, dark: dark, name: "confirm-stop", directory: directory)
            model.cancelStop()
            model.searchText = "zzz"
            try await Self.render(MenuBarRootView().environment(model), width: 420, dark: dark, name: "empty", directory: directory)
            model.searchText = ""
            try await Self.render(SettingsView().environment(model), width: 560, dark: dark, name: "settings", directory: directory)
            model.selectedSettingsTab = .projects
            try await Self.render(SettingsView().environment(model), width: 560, dark: dark, name: "settings-projects", directory: directory)
            model.selectedSettingsTab = .general
        }
    }
}
