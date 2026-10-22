import Testing
@testable import WhatPort

@Suite("Launch inference")
struct LaunchInferenceTests {
    let engine = LaunchInferenceEngine()
    let project = ProjectInfo(rootPath: "/Users/test/app", name: "app", framework: .nextjs, runtime: .node, packageManager: .pnpm, scripts: ["dev": "next dev", "build": "next build"], markers: ["package.json"])

    @Test func usesLifecycleEnvironmentWithHighConfidence() {
        let process = makeProcess(pid: 20, parent: 19, name: "node", arguments: ["next-server"], cwd: "/Users/test/app",
                                  environment: ["npm_lifecycle_event": "dev", "npm_config_user_agent": "pnpm/9.0.0 npm/? node/v22", "INIT_CWD": "/Users/test/app"])
        let suggestion = engine.infer(for: makeListener(process: process, ports: [3000], project: project))
        #expect(suggestion?.confidence == .high)
        #expect(suggestion?.configuration.executable == "pnpm")
        #expect(suggestion?.configuration.arguments == ["run", "dev"])
        #expect(suggestion?.configuration.workingDirectory == "/Users/test/app")
        #expect(suggestion?.configuration.expectedPorts == [3000])
        #expect(suggestion?.configuration.displayName == "app")
    }

    @Test func usesPackageManagerParentCommandLine() {
        let runner = makeProcess(pid: 19, parent: 5, name: "bun", path: "/Users/test/.bun/bin/bun", arguments: ["bun", "run", "dev"], cwd: "/Users/test/app")
        let child = makeProcess(pid: 20, parent: 19, name: "node", arguments: ["node", "/Users/test/app/node_modules/next/dist/bin/next", "dev"], cwd: "/Users/test/app")
        let shell = makeProcess(pid: 5, parent: 1, name: "zsh", path: "/bin/zsh", arguments: ["-zsh"], cwd: "/Users/test")
        let suggestion = engine.infer(for: makeListener(process: child, ports: [3000], project: project, ancestry: [runner, shell]))
        #expect(suggestion?.confidence == .high)
        #expect(suggestion?.configuration.executable == "bun")
        #expect(suggestion?.configuration.arguments == ["run", "dev"])
        #expect(suggestion?.reason.contains("PID 19") == true)
    }

    @Test func recognisesNpmCliScriptAsNpm() {
        let runner = makeProcess(pid: 19, parent: 5, name: "node", arguments: ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "run", "dev"], cwd: "/Users/test/app")
        let command = LaunchInferenceEngine.runnerCommand(from: runner)
        #expect(command?.executable == "npm")
        #expect(command?.arguments == ["run", "dev"])
    }

    @Test func mapsLocalBinaryToMatchingScript() {
        let process = makeProcess(pid: 30, parent: 5, name: "node", arguments: ["node", "/Users/test/app/node_modules/.bin/next", "dev"], cwd: "/Users/test/app")
        let shell = makeProcess(pid: 5, parent: 1, name: "zsh", path: "/bin/zsh", arguments: ["-zsh"], cwd: "/Users/test")
        let suggestion = engine.infer(for: makeListener(process: process, ports: [3000], project: project, ancestry: [shell]))
        #expect(suggestion?.confidence == .medium)
        #expect(suggestion?.configuration.executable == "pnpm")
        #expect(suggestion?.configuration.arguments == ["run", "dev"])
    }

    @Test func reconstructsPythonCommandLine() {
        let process = makeProcess(pid: 40, parent: 5, name: "python3.12", path: "/Users/test/api/.venv/bin/python3.12",
                                  arguments: ["python", "-m", "uvicorn", "app:main", "--reload", "--port", "8000"], cwd: "/Users/test/api",
                                  environment: ["VIRTUAL_ENV": "/Users/test/api/.venv"])
        let pyProject = ProjectInfo(rootPath: "/Users/test/api", name: "api", framework: .fastapi, runtime: .python, markers: ["pyproject.toml"])
        let suggestion = engine.infer(for: makeListener(process: process, ports: [8000], project: pyProject))
        #expect(suggestion?.confidence == .medium)
        #expect(suggestion?.configuration.executable == "/Users/test/api/.venv/bin/python3.12", "venv interpreter is preserved")
        #expect(suggestion?.configuration.arguments == ["-m", "uvicorn", "app:main", "--reload", "--port", "8000"])
    }

    @Test func usesCargoRunParent() {
        let cargo = makeProcess(pid: 50, parent: 5, name: "cargo", path: "/Users/test/.cargo/bin/cargo", arguments: ["cargo", "run", "--release"], cwd: "/Users/test/rs")
        let binary = makeProcess(pid: 51, parent: 50, name: "port-api", path: "/Users/test/rs/target/release/port-api", arguments: ["target/release/port-api"], cwd: "/Users/test/rs")
        let rust = ProjectInfo(rootPath: "/Users/test/rs", name: "port-api", runtime: .rust, markers: ["Cargo.toml"])
        let suggestion = engine.infer(for: makeListener(process: binary, ports: [8080], project: rust, ancestry: [cargo]))
        #expect(suggestion?.configuration.executable == "cargo")
        #expect(suggestion?.configuration.arguments == ["run", "--release"])
        #expect(suggestion?.confidence == .high)
    }

    @Test func fallsBackToDevScriptWithMediumConfidence() {
        let process = makeProcess(pid: 60, parent: 5, name: "mystery", path: "/opt/tools/mystery", arguments: nil, cwd: nil)
        let suggestion = engine.infer(for: makeListener(process: process, ports: [4000], project: project))
        #expect(suggestion?.confidence == .medium)
        #expect(suggestion?.configuration.arguments == ["run", "dev"])
        #expect(suggestion?.reason.contains("guess") == true)
    }

    @Test func returnsNothingForUnknownProcesses() {
        let process = makeProcess(pid: 70, parent: 1, name: "weirdd", path: "/opt/weird/weirdd", arguments: ["weirdd"], cwd: "/opt/weird")
        #expect(engine.infer(for: makeListener(process: process, ports: [9999])) == nil)
    }

    @Test func doesNotCrossShellBoundaries() {
        // A `bun run dev` from a *different* project above a shell must not be used.
        let otherRunner = makeProcess(pid: 2, parent: 1, name: "bun", arguments: ["bun", "run", "dev"], cwd: "/Users/test/other")
        let shell = makeProcess(pid: 5, parent: 2, name: "zsh", path: "/bin/zsh", arguments: ["-zsh"], cwd: "/Users/test")
        let process = makeProcess(pid: 70, parent: 5, name: "weirdd", path: "/opt/weird/weirdd", arguments: ["weirdd"], cwd: "/opt/weird")
        #expect(engine.infer(for: makeListener(process: process, ports: [9999], ancestry: [shell, otherRunner])) == nil)
    }
}
