import Foundation
import Testing
@testable import WhatPort

@Suite("Launch configuration persistence")
struct LaunchConfigurationStoreTests {
    @Test func roundTripsThroughJSON() throws {
        let directory = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONConfigurationStore(fileURL: directory.appendingPathComponent("configs.json"))
        #expect(try store.load().isEmpty)

        let identity = ProcessIdentity(pid: 99, startTime: Date(timeIntervalSince1970: 1_700_000_000), executablePath: "/x/bun")
        let configuration = LaunchConfiguration(
            displayName: "dashboard", projectRootPath: "/Users/test/dashboard", workingDirectory: "/Users/test/dashboard",
            executable: "bun", arguments: ["run", "dev"], environment: ["PORT": "3000"], expectedPorts: [3000, 3001], lastInstance: identity
        )
        try store.save([configuration])
        let loaded = try store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == configuration.id)
        #expect(loaded.first?.executable == "bun")
        #expect(loaded.first?.arguments == ["run", "dev"])
        #expect(loaded.first?.environment == ["PORT": "3000"])
        #expect(loaded.first?.expectedPorts == [3000, 3001])
        #expect(loaded.first?.lastInstance?.pid == 99)
        #expect(loaded.first?.commandLine == "bun run dev")

        try store.save([])
        #expect(try store.load().isEmpty)
    }

    @Test func rejectsCorruptFiles() throws {
        let directory = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("configs.json")
        try Data("not json".utf8).write(to: url)
        #expect(throws: Error.self) { try JSONConfigurationStore(fileURL: url).load() }
    }
}

@Suite("Shell word splitting")
struct ShellWordsTests {
    @Test func splitsQuotesAndEscapes() throws {
        #expect(try ShellWords.split("bun run dev") == ["bun", "run", "dev"])
        #expect(try ShellWords.split("node 'my server.js' --name \"a b\"") == ["node", "my server.js", "--name", "a b"])
        #expect(try ShellWords.split("echo it\\'s") == ["echo", "it's"])
        #expect(try ShellWords.split("  spaced   out  ") == ["spaced", "out"])
        #expect(try ShellWords.split("") == [])
        #expect(try ShellWords.split("\"\"") == [""])
    }

    @Test func rejectsUnterminatedQuotes() {
        #expect(throws: ShellWords.Failure.unterminatedQuote) { try ShellWords.split("bun 'run") }
    }

    @Test func joinQuotesWhenNeeded() {
        #expect(ShellWords.join(["bun", "run", "dev"]) == "bun run dev")
        #expect(ShellWords.join(["node", "my server.js"]) == "node 'my server.js'")
        #expect(ShellWords.join(["x", "it's"]) == "x 'it'\\''s'")
    }
}

@Suite("Executable resolution")
struct ExecutableResolverTests {
    @Test func resolvesViaSearchPathOrAbsolutePath() throws {
        let directory = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = directory.appendingPathComponent("mytool")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        #expect(ExecutableResolver.resolve("mytool", searchPath: [directory.path]) == tool.path)
        #expect(ExecutableResolver.resolve("mytool", searchPath: ["/nonexistent"]) == nil)
        #expect(ExecutableResolver.resolve(tool.path, searchPath: []) == tool.path)
        #expect(ExecutableResolver.resolve("/bin/definitely-missing", searchPath: []) == nil)
        #expect(ExecutableResolver.resolve("sh", searchPath: ["/bin"]) == "/bin/sh")
    }
}
