import Foundation

enum LaunchError: Error, LocalizedError {
    case executableNotFound(String)
    case workingDirectoryMissing(String)
    case portInUse(port: Int, pid: pid_t, name: String)
    case alreadyRunning
    case launchFailed(String)
    case exitedImmediately(status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            return "Could not find “\(name)”. Add its directory under Settings › Search Paths or use an absolute path."
        case .workingDirectoryMissing(let path):
            return "The working directory no longer exists: \(path)"
        case .portInUse(let port, let pid, let name):
            return "Port \(port) is already in use by \(name) (PID \(pid))."
        case .alreadyRunning:
            return "This project is already running."
        case .launchFailed(let message):
            return "Launch failed: \(message)"
        case .exitedImmediately(let status, let output):
            let tail = output.isEmpty ? "" : "\n\n" + output
            return "The process exited right after starting (status \(status)).\(tail)"
        }
    }
}

/// A live instance started by WhatPort in this app session.
@MainActor
final class ManagedInstance {
    let configurationID: UUID
    let process: Process
    let identity: ProcessIdentity
    let logURL: URL

    init(configurationID: UUID, process: Process, identity: ProcessIdentity, logURL: URL) {
        self.configurationID = configurationID
        self.process = process
        self.identity = identity
        self.logURL = logURL
    }
}

/// Launches and stops processes for saved configurations.
///
/// Children get their stdout/stderr redirected to a per-configuration log file
/// instead of a pipe, so they keep running (and never hit SIGPIPE) if WhatPort
/// quits. On relaunch, a surviving instance is re-adopted via its persisted
/// identity.
@MainActor
final class ManagedProcessRunner {
    private(set) var instances: [UUID: ManagedInstance] = [:]
    private let inspector: any ProcessInspecting
    private let terminator: ProcessTerminator
    private let logsDirectory: URL
    var searchPath: [String] = []

    /// Called on the main actor when an instance launched in this session exits.
    var onExit: (@MainActor (UUID, Int32) -> Void)?

    init(inspector: any ProcessInspecting = SystemProcessInspector(), terminator: ProcessTerminator = ProcessTerminator(), logsDirectory: URL) {
        self.inspector = inspector
        self.terminator = terminator
        self.logsDirectory = logsDirectory
    }

    func logURL(for configurationID: UUID) -> URL {
        logsDirectory.appendingPathComponent("\(configurationID.uuidString).log")
    }

    func instance(for configurationID: UUID) -> ManagedInstance? {
        instances[configurationID]
    }

    /// Starts `configuration`. `occupiedPorts` lets the caller pass the latest
    /// scan so we can refuse to start into a conflict.
    func start(_ configuration: LaunchConfiguration, occupiedPorts: [Int: ProcessSnapshot]) async throws -> ProcessIdentity {
        if let existing = instances[configuration.id], existing.process.isRunning {
            throw LaunchError.alreadyRunning
        }
        guard FileManager.default.fileExists(atPath: configuration.workingDirectory) else {
            throw LaunchError.workingDirectoryMissing(configuration.workingDirectory)
        }
        guard let executable = ExecutableResolver.resolve(configuration.executable, searchPath: searchPath) else {
            throw LaunchError.executableNotFound(configuration.executable)
        }
        for port in configuration.expectedPorts {
            if let owner = occupiedPorts[port] {
                throw LaunchError.portInUse(port: port, pid: owner.pid, name: owner.executableName)
            }
        }

        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let logURL = logURL(for: configuration.id)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
            throw LaunchError.launchFailed("Could not open log file.")
        }
        let header = "[WhatPort] \(Date().formatted(date: .abbreviated, time: .standard)) — \(configuration.commandLine)\n[WhatPort] cwd: \(configuration.workingDirectory)\n\n"
        logHandle.write(Data(header.utf8))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.workingDirectoryURL
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath.joined(separator: ":")
        environment["WHATPORT_MANAGED"] = "1"
        environment["FORCE_COLOR"] = environment["FORCE_COLOR"] ?? "0"
        for (key, value) in configuration.environment { environment[key] = value }
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice

        let configurationID = configuration.id
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                if let instance = self.instances[configurationID], instance.process === finished {
                    self.instances[configurationID] = nil
                }
                self.onExit?(configurationID, status)
            }
        }

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw LaunchError.launchFailed(error.localizedDescription)
        }
        try? logHandle.close()

        let pid = process.processIdentifier
        let snapshot = inspector.snapshot(pid: pid)
        let identity = snapshot?.identity ?? ProcessIdentity(pid: pid, startTime: Date(), executablePath: executable)
        instances[configurationID] = ManagedInstance(configurationID: configurationID, process: process, identity: identity, logURL: logURL)

        // Give it a moment: an immediate exit usually means a bad command.
        try? await Task.sleep(for: .milliseconds(600))
        if !process.isRunning {
            instances[configurationID] = nil
            throw LaunchError.exitedImmediately(status: process.terminationStatus, output: readLogTail(for: configurationID, maxBytes: 2000))
        }
        // Re-read: shims may have re-exec'd and changed the executable path.
        let settled = inspector.snapshot(pid: pid)?.identity ?? identity
        instances[configurationID] = ManagedInstance(configurationID: configurationID, process: process, identity: settled, logURL: logURL)
        return settled
    }

    /// Gracefully stops the tree rooted at `identity`. Returns `false` if it is
    /// still alive after `timeout`.
    func stop(_ identity: ProcessIdentity, configurationID: UUID, force: Bool = false, timeout: TimeInterval = 6) async throws -> Bool {
        do {
            try terminator.terminateTree(root: identity, force: force)
        } catch TerminationError.notRunning {
            instances[configurationID] = nil
            return true
        }
        let exited = await terminator.waitForExit(identity, timeout: timeout)
        if exited { instances[configurationID] = nil }
        return exited
    }

    /// Reads the tail of the log file for display.
    func readLogTail(for configurationID: UUID, maxBytes: Int = 64_000) -> String {
        let url = logURL(for: configurationID)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return "" }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return text
    }
}
