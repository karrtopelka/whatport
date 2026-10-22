import Foundation
@testable import WhatPort

/// Process inspector backed by a dictionary.
struct FakeInspector: ProcessInspecting {
    var processes: [pid_t: ProcessSnapshot]

    init(_ processes: [ProcessSnapshot]) {
        self.processes = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
    }

    func snapshot(pid: pid_t) -> ProcessSnapshot? { processes[pid] }
    func isAlive(pid: pid_t) -> Bool { processes[pid] != nil }
    func children(of pid: pid_t) -> [pid_t] { processes.values.filter { $0.parentPID == pid }.map(\.pid).sorted() }
}

/// Records signals instead of sending them.
final class RecordingSignalSender: SignalSending, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sent: [(signal: Int32, pid: pid_t)] = []
    var failure: POSIXErrorCode?

    func send(_ signal: Int32, to pid: pid_t) throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw POSIXError(failure) }
        sent.append((signal, pid))
    }
}

struct FakeScanner: PortScanning {
    var sockets: [ListeningSocket]
    func scan() async throws -> [ListeningSocket] { sockets }
}

func makeProcess(
    pid: pid_t,
    parent: pid_t? = 1,
    name: String,
    path: String? = nil,
    arguments: [String]? = nil,
    cwd: String? = nil,
    start: Date = Date(timeIntervalSince1970: 1_700_000_000),
    uid: uid_t = 501,
    environment: [String: String] = [:]
) -> ProcessSnapshot {
    ProcessSnapshot(
        pid: pid,
        parentPID: parent,
        name: name,
        executablePath: path ?? "/usr/local/bin/\(name)",
        arguments: arguments ?? [name],
        workingDirectory: cwd,
        startTime: start,
        uid: uid,
        userName: "test",
        environmentHints: EnvironmentHints(environment: environment)
    )
}

func makeListener(process: ProcessSnapshot, ports: [Int], project: ProjectInfo? = nil, ancestry: [ProcessSnapshot] = []) -> ListenerEntry {
    ListenerEntry(
        process: process,
        ports: ports.map { ListeningPort(port: $0, addresses: ["*"]) },
        project: project,
        category: .development,
        ancestry: ancestry,
        runnerParent: nil,
        runtime: Runtime.from(executableName: process.executableName)
    )
}

enum TemporaryDirectory {
    static func make(_ name: String = "whatport-test") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
