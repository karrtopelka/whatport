import Foundation
import Testing
@testable import WhatPort

@Suite("KERN_PROCARGS2 parser")
struct ProcArgsParserTests {
    private func buffer(exec: String, args: [String], env: [String]) -> [UInt8] {
        var bytes: [UInt8] = []
        let argc = UInt32(args.count)
        bytes += [UInt8(argc & 0xff), UInt8((argc >> 8) & 0xff), UInt8((argc >> 16) & 0xff), UInt8((argc >> 24) & 0xff)]
        bytes += Array(exec.utf8) + [0, 0, 0, 0]
        for argument in args { bytes += Array(argument.utf8) + [0] }
        for entry in env { bytes += Array(entry.utf8) + [0] }
        bytes += [0, 0]
        return bytes
    }

    @Test func parsesArgumentsAndRetainedEnvironment() {
        let data = buffer(
            exec: "/Users/me/.bun/bin/bun",
            args: ["bun", "run", "dev"],
            env: ["HOME=/Users/me", "npm_lifecycle_event=dev", "SECRET_TOKEN=abc", "npm_config_user_agent=bun/1.1.0 npm/? node/v22"]
        )
        let parsed = ProcArgsParser.parse(data)
        #expect(parsed?.executable == "/Users/me/.bun/bin/bun")
        #expect(parsed?.arguments == ["bun", "run", "dev"])
        #expect(parsed?.environment["npm_lifecycle_event"] == "dev")
        #expect(parsed?.environment["npm_config_user_agent"] == "bun/1.1.0 npm/? node/v22")
        // Only allow-listed keys are kept.
        #expect(parsed?.environment["SECRET_TOKEN"] == nil)
        #expect(parsed?.environment["HOME"] == nil)
    }

    @Test func handlesTruncatedBuffers() {
        #expect(ProcArgsParser.parse([]) == nil)
        #expect(ProcArgsParser.parse([2, 0, 0, 0]) == nil)
        let partial = Array(buffer(exec: "/bin/x", args: ["x", "y"], env: []).prefix(12))
        let parsed = ProcArgsParser.parse(partial)
        #expect(parsed != nil)
        #expect(parsed!.arguments.count <= 2)
    }

    @Test func environmentHintsDerivePackageManager() {
        var hints = EnvironmentHints(environment: ["npm_config_user_agent": "pnpm/9.1.0 npm/? node/v20.0.0 darwin arm64"])
        #expect(hints.packageManager == .pnpm)
        hints = EnvironmentHints(environment: ["npm_config_user_agent": "yarn/1.22.19 npm/? node/v20.0.0"])
        #expect(hints.packageManager == .yarn)
        hints = EnvironmentHints(environment: [:])
        #expect(hints.packageManager == nil)
        #expect(hints.isEmpty)
    }
}
