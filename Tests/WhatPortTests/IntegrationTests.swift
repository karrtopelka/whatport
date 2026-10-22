import Foundation
import Testing
@testable import WhatPort

/// End-to-end tests against the real scanner, inspector and runner. They
/// start a throw-away `python3 -m http.server` inside a temporary project and
/// never touch processes they did not create.
@Suite("Integration", .serialized)
struct IntegrationTests {
    static let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Picks a free port by binding to port 0 and releasing it.
    static func freePort() -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY.bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, length) }
        }
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    static func makeProject() throws -> URL {
        let root = try TemporaryDirectory.make("whatport-it")
        try Data(#"{"name":"whatport-fixture","scripts":{"dev":"python3 -m http.server"},"dependencies":{"express":"4"}}"#.utf8)
            .write(to: root.appendingPathComponent("package.json"))
        try Data().write(to: root.appendingPathComponent("pnpm-lock.yaml"))
        return root
    }

    static func waitForListener(port: Int, timeout: TimeInterval = 10) async throws -> ListenerEntry? {
        let service = DiscoveryService()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = try await service.discover()
            if let entry = result.listeners.first(where: { $0.ports.contains { $0.port == port } }) { return entry }
            try await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    static func waitForNoListener(port: Int, timeout: TimeInterval = 10) async throws -> Bool {
        let service = DiscoveryService()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = try await service.discover()
            if !result.listeners.contains(where: { $0.ports.contains { $0.port == port } }) { return true }
            try await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    @Test func discoversIdentifiesAndStopsARealServer() async throws {
        let python = try #require(Self.python)
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = Self.freePort()

        let server = Process()
        server.executableURL = URL(fileURLWithPath: python)
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
        server.currentDirectoryURL = root
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() } }

        // Discovery (libproc first, lsof fallback) sees it with its PID and port.
        let entry = try #require(try await Self.waitForListener(port: port))
        #expect(entry.process.pid == server.processIdentifier)
        #expect(entry.ports.first?.addresses == ["127.0.0.1"])
        #expect(entry.process.workingDirectory?.hasSuffix(root.lastPathComponent) == true, "cwd is readable (modulo /private symlink)")
        #expect(entry.process.arguments?.contains("http.server") == true)
        #expect(entry.process.startTime != nil)
        #expect(entry.runtime == .python)

        // The temporary package.json is recognised as the project.
        #expect(entry.project?.name == "whatport-fixture")
        #expect(entry.project?.framework == .express)
        #expect(entry.project?.packageManager == .pnpm)
        #expect(entry.category == .development)
        #expect(entry.project?.subtitle(runtime: entry.runtime) == "Express · Python")

        // Both scanners agree.
        let lsof = try await LsofPortScanner().scan()
        #expect(lsof.contains { $0.pid == server.processIdentifier && $0.port == port })
        let libproc = try await LibprocPortScanner().scan()
        #expect(libproc.contains { $0.pid == server.processIdentifier && $0.port == port })

        // Launch inference reconstructs the python command line.
        let suggestion = LaunchInferenceEngine().infer(for: entry)
        #expect(suggestion?.configuration.arguments.contains("http.server") == true)

        // Graceful stop with identity verification.
        let terminator = ProcessTerminator()
        try terminator.terminate(entry.process.identity)
        #expect(await terminator.waitForExit(entry.process.identity, timeout: 10))
        #expect(try await Self.waitForNoListener(port: port))
        #expect(!server.isRunning)

        // Stopping again reports "not running" instead of signalling a reused PID.
        #expect(throws: TerminationError.notRunning) { try terminator.terminate(entry.process.identity) }
    }

    @Test @MainActor func managedRunnerStartsRestartsAndStops() async throws {
        let python = try #require(Self.python)
        let root = try Self.makeProject()
        let logs = try TemporaryDirectory.make("whatport-logs")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: logs)
        }
        let port = Self.freePort()
        let runner = ManagedProcessRunner(logsDirectory: logs)
        runner.searchPath = ["/usr/bin", "/bin"]
        let configuration = LaunchConfiguration(
            displayName: "fixture", projectRootPath: root.path, workingDirectory: root.path,
            executable: python, arguments: ["-m", "http.server", String(port), "--bind", "127.0.0.1"], expectedPorts: [port]
        )

        // Start
        let first = try await runner.start(configuration, occupiedPorts: [:])
        #expect(runner.instance(for: configuration.id) != nil)
        let entry = try #require(try await Self.waitForListener(port: port))
        #expect(entry.process.pid == first.pid)

        // Starting again is refused while running.
        await #expect(throws: LaunchError.self) { try await runner.start(configuration, occupiedPorts: [:]) }

        // Port conflict detection uses the latest scan.
        let occupied = [port: entry.process]
        let conflicting = LaunchConfiguration(displayName: "dup", projectRootPath: root.path, workingDirectory: root.path, executable: python, arguments: ["-c", "pass"], expectedPorts: [port])
        await #expect(throws: LaunchError.self) { try await runner.start(conflicting, occupiedPorts: occupied) }

        // Restart = stop + start, yielding a new PID on the same port.
        #expect(try await runner.stop(first, configurationID: configuration.id))
        #expect(try await Self.waitForNoListener(port: port))
        let second = try await runner.start(configuration, occupiedPorts: [:])
        #expect(second.pid != first.pid)
        let secondEntry = try #require(try await Self.waitForListener(port: port))
        #expect(secondEntry.process.pid == second.pid)

        // Output was captured to the log file.
        try await Task.sleep(for: .milliseconds(300))
        #expect(runner.readLogTail(for: configuration.id).contains("http.server"))

        // Stop and clean up.
        #expect(try await runner.stop(second, configurationID: configuration.id))
        #expect(try await Self.waitForNoListener(port: port))
        #expect(runner.instance(for: configuration.id) == nil)
    }

    @Test @MainActor func reportsImmediateExitAndMissingExecutables() async throws {
        let python = try #require(Self.python)
        let root = try Self.makeProject()
        let logs = try TemporaryDirectory.make("whatport-logs")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: logs)
        }
        let runner = ManagedProcessRunner(logsDirectory: logs)
        runner.searchPath = ["/usr/bin", "/bin"]

        let missing = LaunchConfiguration(displayName: "x", projectRootPath: root.path, workingDirectory: root.path, executable: "definitely-not-a-real-tool")
        await #expect(throws: LaunchError.self) { try await runner.start(missing, occupiedPorts: [:]) }

        let crashing = LaunchConfiguration(displayName: "y", projectRootPath: root.path, workingDirectory: root.path, executable: python, arguments: ["-c", "import sys; print('bad config'); sys.exit(3)"])
        do {
            _ = try await runner.start(crashing, occupiedPorts: [:])
            Issue.record("expected an immediate-exit error")
        } catch let LaunchError.exitedImmediately(status, output) {
            #expect(status == 3)
            #expect(output.contains("bad config"))
        }

        let badDirectory = LaunchConfiguration(displayName: "z", projectRootPath: "/nonexistent/dir", workingDirectory: "/nonexistent/dir", executable: python)
        await #expect(throws: LaunchError.self) { try await runner.start(badDirectory, occupiedPorts: [:]) }
    }

    @Test func realInspectorDescribesOurselves() {
        let inspector = SystemProcessInspector()
        let me = inspector.snapshot(pid: getpid())
        #expect(me != nil)
        #expect(me?.executablePath?.isEmpty == false)
        #expect(me?.arguments?.isEmpty == false)
        #expect(me?.workingDirectory?.isEmpty == false)
        #expect(me?.startTime != nil)
        #expect(me?.uid == getuid())
        #expect(me?.parentPID != nil)
        #expect(inspector.isAlive(pid: getpid()))
        #expect(!inspector.isAlive(pid: 2_000_000_000))
        #expect(inspector.snapshot(pid: 2_000_000_000) == nil)
        #expect(!inspector.ancestry(of: getpid()).isEmpty)
    }
}
