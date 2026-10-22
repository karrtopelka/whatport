import Foundation
import Testing
@testable import WhatPort

@Suite("Managed state machine")
struct ManagedStateMachineTests {
    let identity = ProcessIdentity(pid: 42, startTime: Date(), executablePath: "/usr/local/bin/bun")

    @Test func happyPath() {
        var state = ManagedState.stopped
        state = ManagedStateMachine.next(from: state, on: .startRequested)!
        #expect(state == .starting)
        state = ManagedStateMachine.next(from: state, on: .launched(identity))!
        #expect(state == .running(identity))
        state = ManagedStateMachine.next(from: state, on: .stopRequested)!
        #expect(state == .stopping(identity))
        state = ManagedStateMachine.next(from: state, on: .exited(code: 0))!
        #expect(state == .stopped)
    }

    @Test func restartCycle() {
        var state = ManagedState.running(identity)
        state = ManagedStateMachine.next(from: state, on: .restartRequested)!
        #expect(state == .restarting)
        state = ManagedStateMachine.next(from: state, on: .exited(code: 0))!
        #expect(state == .restarting, "old instance exiting keeps us restarting")
        state = ManagedStateMachine.next(from: state, on: .launched(identity))!
        #expect(state.isRunning)
    }

    @Test func failures() {
        #expect(ManagedStateMachine.next(from: .starting, on: .launchFailed("boom")) == .failed("boom"))
        #expect(ManagedStateMachine.next(from: .running(identity), on: .exited(code: 1)) == .failed("Exited with status 1"))
        #expect(ManagedStateMachine.next(from: .running(identity), on: .exited(code: 0)) == .stopped)
        #expect(ManagedStateMachine.next(from: .running(identity), on: .disappeared) == .stopped)
        #expect(ManagedStateMachine.next(from: .failed("x"), on: .startRequested) == .starting)
    }

    @Test func adoptionAfterRelaunch() {
        #expect(ManagedStateMachine.next(from: .stopped, on: .adopted(identity)) == .running(identity))
        #expect(ManagedStateMachine.next(from: .running(identity), on: .adopted(identity)) == nil)
    }

    @Test func invalidTransitionsAreRejected() {
        #expect(ManagedStateMachine.next(from: .stopped, on: .stopRequested) == nil)
        #expect(ManagedStateMachine.next(from: .stopped, on: .exited(code: 0)) == nil)
        #expect(ManagedStateMachine.next(from: .running(identity), on: .startRequested) == nil)
        #expect(ManagedStateMachine.next(from: .stopping(identity), on: .launched(identity)) == nil)
    }
}
