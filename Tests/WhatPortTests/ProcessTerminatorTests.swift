import Foundation
import Testing
@testable import WhatPort

@Suite("Process termination")
struct ProcessTerminatorTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func sendsSIGTERMWhenIdentityMatches() throws {
        let process = makeProcess(pid: 500, name: "node", start: start)
        let signals = RecordingSignalSender()
        let terminator = ProcessTerminator(inspector: FakeInspector([process]), signals: signals, ownPID: 1)
        try terminator.terminate(process.identity)
        #expect(signals.sent.count == 1)
        #expect(signals.sent.first?.signal == SIGTERM)
        #expect(signals.sent.first?.pid == 500)
    }

    @Test func sendsSIGKILLOnlyWhenForced() throws {
        let process = makeProcess(pid: 500, name: "node", start: start)
        let signals = RecordingSignalSender()
        let terminator = ProcessTerminator(inspector: FakeInspector([process]), signals: signals, ownPID: 1)
        try terminator.terminate(process.identity, force: true)
        #expect(signals.sent.first?.signal == SIGKILL)
    }

    @Test func refusesWhenPIDWasReused() {
        let original = makeProcess(pid: 500, name: "node", start: start)
        let reused = makeProcess(pid: 500, name: "node", start: start.addingTimeInterval(120))
        let signals = RecordingSignalSender()
        let terminator = ProcessTerminator(inspector: FakeInspector([reused]), signals: signals, ownPID: 1)
        #expect(throws: TerminationError.identityMismatch) { try terminator.terminate(original.identity) }
        #expect(signals.sent.isEmpty)
    }

    @Test func toleratesExecutableChangeFromExecShims() throws {
        // /usr/bin/python3 and version-manager shims re-exec in place: same pid
        // and start time, different executable path. That is still the same process.
        let original = makeProcess(pid: 500, name: "python3", path: "/usr/bin/python3", start: start)
        let reexeced = makeProcess(pid: 500, name: "python3", path: "/Applications/Xcode.app/Contents/Developer/usr/bin/python3", start: start)
        let signals = RecordingSignalSender()
        let terminator = ProcessTerminator(inspector: FakeInspector([reexeced]), signals: signals, ownPID: 1)
        try terminator.terminate(original.identity)
        #expect(signals.sent.count == 1)
    }

    @Test func reportsNotRunning() {
        let terminator = ProcessTerminator(inspector: FakeInspector([]), signals: RecordingSignalSender(), ownPID: 1)
        #expect(throws: TerminationError.notRunning) { try terminator.terminate(ProcessIdentity(pid: 123, startTime: start, executablePath: nil)) }
    }

    @Test func refusesProtectedAndOwnProcesses() {
        let launchd = makeProcess(pid: 1, name: "launchd", path: "/sbin/launchd", start: start, uid: 0)
        let finder = makeProcess(pid: 300, name: "Finder", path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", start: start)
        let me = makeProcess(pid: 777, name: "WhatPort", start: start)
        let signals = RecordingSignalSender()
        let terminator = ProcessTerminator(inspector: FakeInspector([launchd, finder, me]), signals: signals, ownPID: 777)
        #expect(throws: TerminationError.self) { try terminator.terminate(launchd.identity) }
        #expect(throws: TerminationError.protectedProcess("Finder")) { try terminator.terminate(finder.identity) }
        #expect(throws: TerminationError.self) { try terminator.terminate(me.identity) }
        #expect(signals.sent.isEmpty)
    }

    @Test func mapsPermissionErrors() {
        let process = makeProcess(pid: 500, name: "node", start: start)
        let signals = RecordingSignalSender()
        signals.failure = .EPERM
        let terminator = ProcessTerminator(inspector: FakeInspector([process]), signals: signals, ownPID: 1)
        #expect(throws: TerminationError.permissionDenied) { try terminator.terminate(process.identity) }
    }

    @Test func terminatesTreeRootFirstThenDescendants() throws {
        let root = makeProcess(pid: 100, parent: 1, name: "bun", start: start)
        let child = makeProcess(pid: 101, parent: 100, name: "node", start: start)
        let grandchild = makeProcess(pid: 102, parent: 101, name: "node", start: start)
        let unrelated = makeProcess(pid: 200, parent: 1, name: "node", start: start)
        let signals = RecordingSignalSender()
        let terminator = ProcessTerminator(inspector: FakeInspector([root, child, grandchild, unrelated]), signals: signals, ownPID: 1)
        try terminator.terminateTree(root: root.identity)
        #expect(signals.sent.map(\.pid) == [100, 101, 102])
        #expect(!signals.sent.contains { $0.pid == 200 })
    }

    @Test func identityMatchingRules() {
        let a = ProcessIdentity(pid: 1, startTime: start, executablePath: "/x")
        #expect(a.matches(ProcessIdentity(pid: 1, startTime: start.addingTimeInterval(0.5), executablePath: "/x")))
        #expect(a.matches(ProcessIdentity(pid: 1, startTime: nil, executablePath: nil)), "unknown fields do not disqualify")
        #expect(!a.matches(ProcessIdentity(pid: 2, startTime: start, executablePath: "/x")))
        #expect(!a.matches(ProcessIdentity(pid: 1, startTime: start.addingTimeInterval(5), executablePath: "/x")))
        #expect(a.matches(ProcessIdentity(pid: 1, startTime: start, executablePath: "/y")), "exec shims may change the path")
    }
}
