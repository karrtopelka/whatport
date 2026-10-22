import Foundation
import Testing
@testable import WhatPort

@Suite("Discovery pipeline")
struct DiscoveryServiceTests {
    @Test func groupsSocketsPerProcessAndSkipsVanishedProcesses() async throws {
        let fs = InMemoryFileSystem(files: [
            "/Users/test/app/package.json": #"{"name":"app","dependencies":{"vite":"5"}}"#,
            "/Users/test/app/bun.lockb": "",
        ])
        let node = makeProcess(pid: 10, parent: 9, name: "node", cwd: "/Users/test/app")
        let runner = makeProcess(pid: 9, parent: 5, name: "bun", path: "/Users/test/.bun/bin/bun", arguments: ["bun", "run", "dev"], cwd: "/Users/test/app")
        let shell = makeProcess(pid: 5, parent: 1, name: "zsh", path: "/bin/zsh", cwd: "/Users/test")
        let daemon = makeProcess(pid: 30, parent: 1, name: "rapportd", path: "/usr/libexec/rapportd", cwd: nil)
        let scanner = FakeScanner(sockets: [
            ListeningSocket(pid: 10, port: 5173, address: "*", family: .ipv4),
            ListeningSocket(pid: 10, port: 5173, address: "*", family: .ipv6),
            ListeningSocket(pid: 10, port: 5174, address: "127.0.0.1", family: .ipv4),
            ListeningSocket(pid: 30, port: 49152, address: "*", family: .ipv4),
            ListeningSocket(pid: 999, port: 1234, address: "*", family: .ipv4), // exited during scan
        ])
        let service = DiscoveryService(
            scanner: scanner,
            inspector: FakeInspector([node, runner, shell, daemon]),
            locator: ProjectRootLocator(identifier: ProjectIdentifier(fileSystem: fs)),
            home: "/Users/test"
        )
        let result = try await service.discover()
        #expect(result.listeners.count == 2)
        let app = try #require(result.listeners.first { $0.process.pid == 10 })
        #expect(app.ports.map(\.port) == [5173, 5174])
        #expect(app.project?.name == "app")
        #expect(app.project?.framework == .vite)
        #expect(app.category == .development)
        #expect(app.ancestry.map(\.pid) == [9, 5])
        #expect(app.runnerParent?.pid == 9)
        let system = try #require(result.listeners.first { $0.process.pid == 30 })
        #expect(system.category == .system)
        #expect(result.listeners.first?.process.pid == 10, "development listeners sort first")
    }

    @Test func handlesInaccessibleMetadata() async throws {
        var opaque = makeProcess(pid: 40, parent: 1, name: "otherd", path: nil, arguments: nil, cwd: nil, uid: 502)
        opaque.executablePath = nil
        opaque.arguments = nil
        let service = DiscoveryService(
            scanner: FakeScanner(sockets: [ListeningSocket(pid: 40, port: 8000, address: "*", family: .ipv4)]),
            inspector: FakeInspector([opaque]),
            locator: ProjectRootLocator(identifier: ProjectIdentifier(fileSystem: InMemoryFileSystem())),
            home: "/Users/test"
        )
        let listener = try #require(try await service.discover().listeners.first)
        #expect(listener.project == nil)
        #expect(listener.process.arguments == nil)
        #expect(listener.process.workingDirectory == nil)
        #expect(listener.category == .unknown)
        #expect(listener.displayName == "otherd")
    }

    @Test func relatedAncestorsStopAtShellsAndOtherProjects() {
        let listener = makeProcess(pid: 10, parent: 9, name: "node", cwd: "/Users/test/app")
        let nextDev = makeProcess(pid: 9, parent: 8, name: "node", arguments: ["node", "/Users/test/app/node_modules/.bin/next", "dev"], cwd: "/Users/test/app")
        let npm = makeProcess(pid: 8, parent: 7, name: "npm", arguments: ["npm", "run", "dev"], cwd: "/Users/test/app")
        let shell = makeProcess(pid: 7, parent: 6, name: "zsh", path: "/bin/zsh", cwd: "/Users/test/app")
        let other = makeProcess(pid: 6, parent: 1, name: "bun", arguments: ["bun", "run", "dev"], cwd: "/Users/test/other")
        let related = DiscoveryService.relatedAncestors(of: listener, ancestry: [nextDev, npm, shell, other], projectRoot: "/Users/test/app")
        #expect(related.map(\.pid) == [9, 8])
    }

    @Test func categorizerRules() {
        let home = "/Users/test"
        #expect(PortCategorizer.categorize(process: makeProcess(pid: 1, name: "node", path: "/opt/homebrew/bin/node"), project: nil, runtime: .node, home: home) == .development)
        #expect(PortCategorizer.categorize(process: makeProcess(pid: 1, name: "ControlCenter", path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"), project: nil, runtime: nil, home: home) == .system)
        #expect(PortCategorizer.categorize(process: makeProcess(pid: 1, name: "Spotify", path: "/Applications/Spotify.app/Contents/MacOS/Spotify"), project: nil, runtime: nil, home: home) == .application)
        #expect(PortCategorizer.categorize(process: makeProcess(pid: 1, name: "root-thing", path: "/opt/x/root-thing", uid: 0), project: nil, runtime: nil, home: home) == .system)
        #expect(PortCategorizer.categorize(process: makeProcess(pid: 1, name: "custom", path: "/Users/test/bin/custom"), project: nil, runtime: nil, home: home) == .development)
        #expect(PortCategorizer.categorize(process: makeProcess(pid: 1, name: "x", path: "/opt/vendor/x"), project: nil, runtime: nil, home: home) == .unknown)
        #expect(PortCategorizer.categorize(process: makeProcess(pid: 1, name: "node", path: "/Users/test/Library/Application Support/com.raycast.macos/node/bin/node"), project: nil, runtime: .node, home: home) == .application, "app-bundled runtimes are not dev servers")
    }
}

@Suite("Stop confirmation flow")
struct StopConfirmationTests {
    @Test @MainActor func confirmStopSignalsTheGroupProcesses() async throws {
        let runner = makeProcess(pid: 4241, parent: 1, name: "bun", path: "/Users/test/.bun/bin/bun", arguments: ["bun", "run", "dev"], cwd: "/Users/test/p")
        let server = makeProcess(pid: 4242, parent: 4241, name: "bun", path: "/Users/test/.bun/bin/bun", arguments: ["bun", "server.ts"], cwd: "/Users/test/p")
        let inspector = FakeInspector([runner, server])
        let signals = RecordingSignalSender()
        let defaults = UserDefaults(suiteName: "com.karrtopelka.whatport.stoptests")!
        defaults.removePersistentDomain(forName: "com.karrtopelka.whatport.stoptests")
        let model = AppModel(
            settings: AppSettings(defaults: defaults),
            discovery: DiscoveryService(scanner: FakeScanner(sockets: [ListeningSocket(pid: 4242, port: 3000, address: "*", family: .ipv4)]), inspector: inspector, locator: ProjectRootLocator(identifier: ProjectIdentifier(fileSystem: InMemoryFileSystem())), home: "/Users/test"),
            inspector: inspector,
            terminator: ProcessTerminator(inspector: inspector, signals: signals, ownPID: 1),
            store: InMemoryConfigurationStore(),
            logsDirectory: try TemporaryDirectory.make("stop-tests")
        )
        await model.refresh()
        let group = try #require(model.allGroups.first)
        #expect(model.processesToStop(for: group).map(\.pid) == [4241, 4242], "runner parent first, then the listener")

        model.requestStop(group)
        #expect(model.stopRequest?.group.id == group.id, "confirmation is requested by default")
        #expect(signals.sent.isEmpty)

        model.cancelStop()
        #expect(model.stopRequest == nil)
        #expect(signals.sent.isEmpty)

        model.requestStop(group)
        model.confirmStop()
        #expect(model.stopRequest == nil)
        try await Task.sleep(for: .seconds(1.5))
        #expect(signals.sent.map(\.pid) == [4241, 4242])
        #expect(signals.sent.allSatisfy { $0.signal == SIGTERM })
        #expect(model.notice?.kind == .success)

        model.settings.confirmBeforeStop = false
        model.requestStop(group)
        #expect(model.stopRequest == nil, "no confirmation when disabled")
        try await Task.sleep(for: .seconds(1.5))
        #expect(signals.sent.count == 4)
    }
}
