import Foundation

/// Builds the list of directories used to resolve executables such as `bun`
/// or `pnpm`. A menu bar app launched from Finder inherits a minimal PATH, so
/// we combine the login shell's PATH with well-known tool directories.
struct SearchPathProvider: Sendable {
    var home: String = NSHomeDirectory()
    var extraPaths: [String] = []

    /// Directories that do not depend on the login shell.
    func wellKnownDirectories() -> [String] {
        var directories: [String] = extraPaths
        directories += [
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/.deno/bin",
            "\(home)/.cargo/bin",
            "\(home)/.local/bin",
            "\(home)/.local/share/mise/shims",
            "\(home)/.asdf/shims",
            "\(home)/.proto/shims",
            "\(home)/Library/pnpm",
            "\(home)/Library/Application Support/fnm/aliases/default/bin",
            "\(home)/.local/share/fnm/aliases/default/bin",
            "\(home)/.fnm/aliases/default/bin",
            "\(home)/go/bin",
            "\(home)/.rbenv/shims",
            "\(home)/.pyenv/shims",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        directories += nvmDirectories()
        return directories
    }

    /// Highest installed nvm Node version, if any.
    private func nvmDirectories() -> [String] {
        let base = "\(home)/.nvm/versions/node"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        let sorted = versions.filter { $0.hasPrefix("v") }.sorted { a, b in
            a.compare(b, options: .numeric) == .orderedDescending
        }
        return sorted.prefix(1).map { "\(base)/\($0)/bin" }
    }

    /// Asks the user's login shell for its PATH. Runs a fixed command with no
    /// user-controlled input; failures are ignored.
    func loginShellPath() async -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return [] }
        let marker = "__WHATPORT_PATH__"
        do {
            let output = try await Subprocess.run(
                executable: shell,
                arguments: ["-l", "-c", "printf '%s%s%s' '\(marker)' \"$PATH\" '\(marker)'"],
                currentDirectory: home,
                timeout: 5
            )
            guard let start = output.stdout.range(of: marker),
                  let end = output.stdout.range(of: marker, range: start.upperBound..<output.stdout.endIndex) else { return [] }
            return output.stdout[start.upperBound..<end.lowerBound].split(separator: ":").map(String.init)
        } catch {
            return []
        }
    }

    /// Combined, de-duplicated search path: extras, login shell, well known.
    func resolveSearchPath() async -> [String] {
        let shellPaths = await loginShellPath()
        var seen: Set<String> = []
        var result: [String] = []
        for path in extraPaths + shellPaths + wellKnownDirectories() {
            let normalized = (path as NSString).standardizingPath
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }
}

enum ExecutableResolver {
    /// Returns the absolute path for `executable` or `nil` if it cannot be found.
    static func resolve(_ executable: String, searchPath: [String], fileManager: FileManager = .default) -> String? {
        let expanded = (executable as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return fileManager.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        for directory in searchPath {
            let candidate = (directory as NSString).appendingPathComponent(expanded)
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
