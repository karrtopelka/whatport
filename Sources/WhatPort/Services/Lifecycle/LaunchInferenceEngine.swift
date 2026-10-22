import Foundation

/// Infers how a discovered process was probably started. Everything it
/// returns is a *suggestion* that needs user confirmation.
struct LaunchInferenceEngine: Sendable {
    static let packageManagerExecutables: Set<String> = ["npm", "pnpm", "yarn", "bun", "bunx", "npx", "deno"]
    static let packageManagerScripts = ["npm-cli.js", "npm-cli.cjs", "yarn.js", "pnpm.cjs", "pnpm.js", "npx-cli.js", "corepack"]
    static let directDevExecutables: Set<String> = ["cargo", "go", "python", "python3", "uvicorn", "gunicorn", "flask", "ruby", "rails", "bundle", "mix", "php", "dotnet", "swift", "java", "node", "bun", "deno", "tsx", "ts-node", "nodemon"]

    func infer(for listener: ListenerEntry) -> LaunchSuggestion? {
        let process = listener.process
        let project = listener.project
        let projectRoot = project?.rootPath ?? process.workingDirectory

        // 1. npm lifecycle environment: the most reliable signal.
        if let script = process.environmentHints.lifecycleEvent, !script.isEmpty {
            let manager = process.environmentHints.packageManager
                ?? Self.packageManager(fromExecPath: process.environmentHints.execPath)
                ?? project?.packageManager
                ?? .npm
            if project == nil || project?.scripts[script] != nil || project?.scripts.isEmpty == true {
                let cwd = process.environmentHints.initialWorkingDirectory ?? projectRoot ?? process.workingDirectory
                if let cwd {
                    return make(
                        listener: listener,
                        executable: manager.executable,
                        arguments: manager.runScriptArguments(script),
                        workingDirectory: cwd,
                        projectRoot: projectRoot ?? cwd,
                        confidence: .high,
                        reason: "The process environment reports it is running the “\(script)” script via \(manager.rawValue)."
                    )
                }
            }
        }

        // 2. A package-manager / task-runner parent (or the process itself).
        for candidate in [process] + listener.ancestry {
            if let command = Self.runnerCommand(from: candidate), let cwd = candidate.workingDirectory ?? projectRoot {
                let confidence: SuggestionConfidence = candidate.pid == process.pid ? .high : (Self.sameProject(candidate, root: projectRoot) ? .high : .medium)
                return make(
                    listener: listener,
                    executable: command.executable,
                    arguments: command.arguments,
                    workingDirectory: cwd,
                    projectRoot: projectRoot ?? cwd,
                    confidence: confidence,
                    reason: candidate.pid == process.pid
                        ? "Taken from the process's own command line."
                        : "Taken from the command line of parent process \(candidate.executableName) (PID \(candidate.pid))."
                )
            }
            // Stop at shells and terminals — anything above them is unrelated.
            if Self.isShellOrTerminal(candidate) && candidate.pid != process.pid { break }
        }

        // 3. The process's own arguments.
        if let arguments = process.arguments, !arguments.isEmpty, let cwd = process.workingDirectory {
            let executableName = (arguments[0] as NSString).lastPathComponent
            let rest = Array(arguments.dropFirst())

            // node /proj/node_modules/.bin/vite --host  →  pm exec / matching script
            if let binaryIndex = arguments.firstIndex(where: { $0.contains("/node_modules/.bin/") }), let project {
                let tool = (arguments[binaryIndex] as NSString).lastPathComponent
                let toolArguments = Array(arguments[(binaryIndex + 1)...])
                let manager = project.packageManager ?? .npm
                if let script = Self.matchingScript(in: project.scripts, tool: tool, arguments: toolArguments) {
                    return make(listener: listener, executable: manager.executable, arguments: manager.runScriptArguments(script), workingDirectory: project.rootPath, projectRoot: project.rootPath, confidence: .medium, reason: "The process runs “\(tool)”, which matches the “\(script)” script in package.json.")
                }
                let exec = manager.execArguments(tool, toolArguments)
                return make(listener: listener, executable: exec.executable, arguments: exec.arguments, workingDirectory: cwd, projectRoot: project.rootPath, confidence: .medium, reason: "Reconstructed from the locally installed binary the process is running.")
            }

            if Self.directDevExecutables.contains(executableName.lowercased()) || Runtime.from(executableName: executableName) != nil {
                let executable = Self.preferredExecutable(path: process.executablePath, argument0: arguments[0], virtualEnv: process.environmentHints.virtualEnv)
                return make(listener: listener, executable: executable, arguments: rest, workingDirectory: cwd, projectRoot: projectRoot ?? cwd, confidence: .medium, reason: "Reconstructed from the process's command line arguments.")
            }

            if let project, let executablePath = process.executablePath, executablePath.hasPrefix(project.rootPath) {
                // A compiled binary inside the project (cargo target/, go build output).
                return make(listener: listener, executable: executablePath, arguments: rest, workingDirectory: cwd, projectRoot: project.rootPath, confidence: .low, reason: "The executable lives inside the project; this runs the binary directly, not the build step.")
            }
        }

        // 4. package.json scripts.
        if let project, !project.scripts.isEmpty {
            let manager = project.packageManager ?? .npm
            for script in ["dev", "start", "serve", "develop"] where project.scripts[script] != nil {
                return make(listener: listener, executable: manager.executable, arguments: manager.runScriptArguments(script), workingDirectory: project.rootPath, projectRoot: project.rootPath, confidence: script == "dev" ? .medium : .low, reason: "package.json defines a “\(script)” script; it is a guess that this is what was running.")
            }
        }

        return nil
    }

    // MARK: - Helpers

    private func make(listener: ListenerEntry, executable: String, arguments: [String], workingDirectory: String, projectRoot: String, confidence: SuggestionConfidence, reason: String) -> LaunchSuggestion {
        let configuration = LaunchConfiguration(
            displayName: listener.project?.name ?? listener.process.executableName,
            projectRootPath: projectRoot,
            workingDirectory: workingDirectory,
            executable: executable,
            arguments: arguments,
            expectedPorts: listener.ports.map(\.port)
        )
        return LaunchSuggestion(configuration: configuration, confidence: confidence, reason: reason)
    }

    static func packageManager(fromExecPath path: String?) -> PackageManager? {
        guard let path else { return nil }
        let lowered = path.lowercased()
        if lowered.contains("pnpm") { return .pnpm }
        if lowered.contains("yarn") { return .yarn }
        if lowered.contains("bun") { return .bun }
        if lowered.contains("npm") { return .npm }
        return nil
    }

    /// Recognises `bun run dev`, `npm run dev`, `pnpm dev`, `yarn dev`, `npx vite`,
    /// `node …/npm-cli.js run dev`, `cargo run`, `deno task dev`, `go run .`.
    static func runnerCommand(from process: ProcessSnapshot) -> (executable: String, arguments: [String])? {
        guard let arguments = process.arguments, !arguments.isEmpty else { return nil }
        var argv = arguments
        var executable = (argv[0] as NSString).lastPathComponent
        // node /…/npm-cli.js run dev  → npm run dev
        if executable == "node" || executable.hasPrefix("node"), argv.count > 1 {
            let script = (argv[1] as NSString).lastPathComponent
            if let known = packageManagerScripts.first(where: { script == $0 || argv[1].contains("/" + $0) }) {
                let manager: String
                switch known {
                case "yarn.js": manager = "yarn"
                case "pnpm.cjs", "pnpm.js": manager = "pnpm"
                case "npx-cli.js": manager = "npx"
                case "corepack": manager = "corepack"
                default: manager = "npm"
                }
                argv = [manager] + Array(argv.dropFirst(2))
                executable = manager
            }
        }
        let rest = Array(argv.dropFirst())
        switch executable {
        case "npm", "pnpm", "yarn", "bun":
            guard let first = rest.first else { return nil }
            if first == "run" || first == "run-script" { return rest.count > 1 ? (executable, rest) : nil }
            if executable == "bun", first.hasSuffix(".ts") || first.hasSuffix(".js") || first.hasSuffix(".tsx") || first == "--hot" || first == "--watch" { return (executable, rest) }
            if executable == "pnpm" || executable == "yarn", !first.hasPrefix("-"), !["install", "add", "remove", "i", "exec", "dlx", "create", "init"].contains(first) {
                return (executable, rest)
            }
            if executable == "bun", first == "x" { return ("bunx", Array(rest.dropFirst())) }
            if executable == "bun", first == "--bun" { return (executable, rest) }
            return nil
        case "bunx", "npx":
            return rest.isEmpty ? nil : (executable, rest)
        case "deno":
            if rest.first == "task" || rest.first == "run" || rest.first == "serve" { return (executable, rest) }
            return nil
        case "cargo":
            if rest.first == "run" || rest.first == "watch" || rest.first == "leptos" || rest.first == "shuttle" { return (executable, rest) }
            return nil
        case "go":
            if rest.first == "run" { return (executable, rest) }
            return nil
        case "mix":
            if rest.first == "phx.server" { return (executable, rest) }
            return nil
        case "rails", "bundle":
            if executable == "rails", rest.first == "server" || rest.first == "s" { return (executable, rest) }
            if executable == "bundle", rest.first == "exec" { return (executable, rest) }
            return nil
        default:
            return nil
        }
    }

    static func isShellOrTerminal(_ process: ProcessSnapshot) -> Bool {
        let name = process.executableName.lowercased()
        let shells: Set<String> = ["zsh", "bash", "sh", "fish", "nu", "login", "tmux", "screen", "-zsh", "-bash"]
        if shells.contains(name) { return true }
        if let path = process.executablePath, path.contains(".app/Contents/") { return true }
        return name == "launchd"
    }

    static func sameProject(_ process: ProcessSnapshot, root: String?) -> Bool {
        guard let root, let cwd = process.workingDirectory else { return false }
        return cwd == root || cwd.hasPrefix(root + "/") || root.hasPrefix(cwd + "/")
    }

    static func matchingScript(in scripts: [String: String], tool: String, arguments: [String]) -> String? {
        let preferred = ["dev", "start", "serve", "develop", "preview"]
        let candidates = scripts.filter { _, command in
            let words = (try? ShellWords.split(command)) ?? command.split(separator: " ").map(String.init)
            guard let first = words.first else { return false }
            let firstTool = (first as NSString).lastPathComponent
            guard firstTool == tool else { return false }
            let scriptArguments = Array(words.dropFirst())
            // All of the script's flags should appear in the live arguments.
            return scriptArguments.allSatisfy { $0.hasPrefix("-") ? arguments.contains($0) : true }
        }
        for name in preferred where candidates[name] != nil { return name }
        return candidates.keys.sorted().first
    }

    static func preferredExecutable(path: String?, argument0: String, virtualEnv: String?) -> String {
        if let path, let virtualEnv, path.hasPrefix(virtualEnv) { return path }
        if argument0.hasPrefix("/") { return argument0 }
        return (argument0 as NSString).lastPathComponent
    }
}
