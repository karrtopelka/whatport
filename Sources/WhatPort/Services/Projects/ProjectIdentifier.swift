import Foundation

/// Finds the project a directory belongs to by walking up the tree looking for
/// well-known marker files. Never scans downwards.
struct ProjectIdentifier: Sendable {
    var fileSystem: any FileSystemReading = RealFileSystem()
    /// Maximum number of parent directories to inspect.
    var maxDepth = 12

    /// Files that mark a project root, in priority order.
    static let projectMarkers = [
        "package.json", "deno.json", "deno.jsonc", "Cargo.toml", "pyproject.toml", "go.mod",
        "Package.swift", "Gemfile", "mix.exs", "composer.json", "build.gradle", "build.gradle.kts",
        "pom.xml", "manage.py", "requirements.txt", "Pipfile",
    ]

    /// Files that mark a workspace/monorepo root.
    static let workspaceMarkers = [
        "pnpm-workspace.yaml", "lerna.json", "nx.json", "turbo.json", "go.work", "rush.json",
    ]

    /// Identifies the project for `directory`, or `nil` when no markers exist.
    func identify(directory: String) -> ProjectInfo? {
        let start = Self.normalize(directory)
        guard fileSystem.directoryExists(atPath: start) else { return nil }
        let chain = Self.ancestors(of: start, limit: maxDepth, home: fileSystem.homeDirectory)

        // 1. Nearest directory with a project marker.
        var rootIndex: Int?
        var rootMarkers: [String] = []
        for (index, dir) in chain.enumerated() {
            let found = Self.projectMarkers.filter { fileSystem.fileExists(atPath: dir + "/" + $0) }
            if !found.isEmpty {
                rootIndex = index
                rootMarkers = found
                break
            }
        }

        // 2. Fallback: a bare git repository.
        if rootIndex == nil {
            for (index, dir) in chain.enumerated() where fileSystem.directoryExists(atPath: dir + "/.git") || fileSystem.fileExists(atPath: dir + "/.git") {
                rootIndex = index
                rootMarkers = [".git"]
                break
            }
        }

        guard let rootIndex else { return nil }
        let root = chain[rootIndex]
        var info = ProjectInfo(rootPath: root, name: (root as NSString).lastPathComponent, markers: rootMarkers)
        populateMetadata(&info, markers: rootMarkers)

        // 3. Workspace root above the project root.
        for dir in chain.dropFirst(rootIndex + 1) {
            if let workspace = workspaceInfo(at: dir) {
                info.workspaceRootPath = dir
                info.workspaceName = workspace
                if info.packageManager == nil { info.packageManager = detectPackageManager(at: dir) }
                break
            }
            if fileSystem.directoryExists(atPath: dir + "/.git") { break }
        }
        return info
    }

    // MARK: - Metadata

    private func populateMetadata(_ info: inout ProjectInfo, markers: [String]) {
        let root = info.rootPath
        if markers.contains("package.json"), let data = fileSystem.contents(atPath: root + "/package.json") {
            applyPackageJSON(data, to: &info)
            if info.packageManager == nil { info.packageManager = detectPackageManager(at: root) }
            if info.runtime == nil { info.runtime = info.packageManager == .bun ? .bun : .node }
        } else if markers.contains("deno.json") || markers.contains("deno.jsonc") {
            info.runtime = .deno
            info.packageManager = .deno
            if let data = fileSystem.contents(atPath: root + "/" + (markers.contains("deno.json") ? "deno.json" : "deno.jsonc")),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let name = object["name"] as? String, !name.isEmpty { info.name = name }
                if let tasks = object["tasks"] as? [String: String] { info.scripts = tasks }
            }
        } else if markers.contains("Cargo.toml"), let text = string(at: root + "/Cargo.toml") {
            info.runtime = .rust
            if let name = Self.tomlValue("name", in: text, section: "package") { info.name = name }
            if text.contains("axum") { info.framework = .axum } else if text.contains("actix-web") { info.framework = .actix } else if text.contains("rocket") { info.framework = .rocket }
        } else if markers.contains("pyproject.toml") || markers.contains("manage.py") || markers.contains("requirements.txt") || markers.contains("Pipfile") {
            info.runtime = .python
            if let text = string(at: root + "/pyproject.toml") {
                if let name = Self.tomlValue("name", in: text, section: "project") ?? Self.tomlValue("name", in: text, section: "tool.poetry") { info.name = name }
                info.framework = Self.pythonFramework(in: text)
            }
            if info.framework == nil, let text = string(at: root + "/requirements.txt") {
                info.framework = Self.pythonFramework(in: text)
            }
            if info.framework == nil, fileSystem.fileExists(atPath: root + "/manage.py") { info.framework = .django }
        } else if markers.contains("go.mod"), let text = string(at: root + "/go.mod") {
            info.runtime = .go
            if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("module ") }) {
                let module = line.dropFirst("module ".count).trimmingCharacters(in: .whitespaces)
                if let last = module.split(separator: "/").last { info.name = String(last) }
            }
            if text.contains("gin-gonic/gin") { info.framework = .gin } else if text.contains("labstack/echo") { info.framework = .echo } else if text.contains("gofiber/fiber") { info.framework = .fiber }
        } else if markers.contains("Package.swift"), let text = string(at: root + "/Package.swift") {
            info.runtime = .swift
            if let name = Self.firstMatch(#"name:\s*"([^"]+)""#, in: text) { info.name = name }
            if text.contains("vapor") { info.framework = .vapor }
        } else if markers.contains("Gemfile") {
            info.runtime = .ruby
            if let text = string(at: root + "/Gemfile"), text.contains("rails") { info.framework = .rails }
        } else if markers.contains("mix.exs") {
            info.runtime = .elixir
            if let text = string(at: root + "/mix.exs") {
                if let name = Self.firstMatch(#"app:\s*:([a-zA-Z0-9_]+)"#, in: text) { info.name = name }
                if text.contains("phoenix") { info.framework = .phoenix }
            }
        } else if markers.contains("composer.json") {
            info.runtime = .php
            if let data = fileSystem.contents(atPath: root + "/composer.json"),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let name = object["name"] as? String, let last = name.split(separator: "/").last { info.name = String(last) }
                if let require = object["require"] as? [String: Any], require["laravel/framework"] != nil { info.framework = .laravel }
            }
        } else if markers.contains("build.gradle") || markers.contains("build.gradle.kts") || markers.contains("pom.xml") {
            info.runtime = .java
            if let text = string(at: root + "/pom.xml") ?? string(at: root + "/build.gradle") ?? string(at: root + "/build.gradle.kts"), text.contains("spring") {
                info.framework = .spring
            }
        }
    }

    private func applyPackageJSON(_ data: Data, to info: inout ProjectInfo) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let name = object["name"] as? String, !name.isEmpty {
            // Scoped package names: show the unscoped part for compactness.
            info.name = name.hasPrefix("@") ? (name.split(separator: "/").last.map(String.init) ?? name) : name
        }
        if let scripts = object["scripts"] as? [String: Any] {
            info.scripts = scripts.compactMapValues { $0 as? String }
        }
        if let packageManager = object["packageManager"] as? String {
            let tool = packageManager.split(separator: "@").first.map(String.init) ?? packageManager
            info.packageManager = PackageManager(rawValue: tool)
        }
        var dependencies: Set<String> = []
        for key in ["dependencies", "devDependencies", "peerDependencies"] {
            if let deps = object[key] as? [String: Any] { dependencies.formUnion(deps.keys) }
        }
        info.framework = Self.jsFramework(dependencies: dependencies, root: info.rootPath, fileSystem: fileSystem)
        if dependencies.contains("elysia") && info.framework == nil { info.framework = .elysia }
        if info.framework == .elysia { info.runtime = .bun }
    }

    private func workspaceInfo(at dir: String) -> String? {
        for marker in Self.workspaceMarkers where fileSystem.fileExists(atPath: dir + "/" + marker) {
            return packageName(at: dir) ?? (dir as NSString).lastPathComponent
        }
        if let data = fileSystem.contents(atPath: dir + "/package.json"),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["workspaces"] != nil {
            return (object["name"] as? String) ?? (dir as NSString).lastPathComponent
        }
        if let text = string(at: dir + "/Cargo.toml"), text.contains("[workspace]") {
            return (dir as NSString).lastPathComponent
        }
        return nil
    }

    private func packageName(at dir: String) -> String? {
        guard let data = fileSystem.contents(atPath: dir + "/package.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["name"] as? String
    }

    func detectPackageManager(at dir: String) -> PackageManager? {
        if fileSystem.fileExists(atPath: dir + "/bun.lock") || fileSystem.fileExists(atPath: dir + "/bun.lockb") { return .bun }
        if fileSystem.fileExists(atPath: dir + "/pnpm-lock.yaml") { return .pnpm }
        if fileSystem.fileExists(atPath: dir + "/yarn.lock") { return .yarn }
        if fileSystem.fileExists(atPath: dir + "/package-lock.json") || fileSystem.fileExists(atPath: dir + "/npm-shrinkwrap.json") { return .npm }
        if fileSystem.fileExists(atPath: dir + "/deno.lock") { return .deno }
        return nil
    }

    private func string(at path: String) -> String? {
        fileSystem.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Static helpers

    static func jsFramework(dependencies: Set<String>, root: String, fileSystem: any FileSystemReading) -> Framework? {
        func hasConfig(_ base: String) -> Bool {
            ["js", "mjs", "cjs", "ts", "mts", "cts"].contains { fileSystem.fileExists(atPath: "\(root)/\(base).\($0)") }
        }
        if dependencies.contains("next") || hasConfig("next.config") { return .nextjs }
        if dependencies.contains("nuxt") || hasConfig("nuxt.config") { return .nuxt }
        if dependencies.contains("@sveltejs/kit") { return .sveltekit }
        if dependencies.contains("astro") || hasConfig("astro.config") { return .astro }
        if dependencies.contains("@remix-run/dev") || dependencies.contains("@remix-run/react") { return .remix }
        if dependencies.contains("@react-router/dev") { return .reactRouter }
        if dependencies.contains("@angular/core") || fileSystem.fileExists(atPath: root + "/angular.json") { return .angular }
        if dependencies.contains("expo") { return .expo }
        if dependencies.contains("gatsby") { return .gatsby }
        if dependencies.contains("@nestjs/core") { return .nest }
        if dependencies.contains("vite") || hasConfig("vite.config") { return .vite }
        if dependencies.contains("storybook") || dependencies.contains("@storybook/react") { return .storybook }
        if dependencies.contains("fastify") { return .fastify }
        if dependencies.contains("hono") { return .hono }
        if dependencies.contains("elysia") { return .elysia }
        if dependencies.contains("express") { return .express }
        return nil
    }

    static func pythonFramework(in text: String) -> Framework? {
        let lowered = text.lowercased()
        if lowered.contains("fastapi") { return .fastapi }
        if lowered.contains("django") { return .django }
        if lowered.contains("flask") { return .flask }
        if lowered.contains("uvicorn") { return .uvicorn }
        return nil
    }

    /// Reads `key = "value"` from a `[section]` of a TOML file. Deliberately simple.
    static func tomlValue(_ key: String, in text: String, section: String) -> String? {
        var inSection = false
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line == "[\(section)]"
                continue
            }
            guard inSection, line.hasPrefix(key) else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    static func normalize(_ path: String) -> String {
        var result = (path as NSString).standardizingPath
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// `directory` and its parents, nearest first, never above the home
    /// directory's parent or the filesystem root.
    static func ancestors(of directory: String, limit: Int, home: String) -> [String] {
        var chain: [String] = []
        var current = directory
        let stop: Set<String> = ["/", "/Users", "/private", "/private/var", "/var", "/tmp", "/private/tmp", (home as NSString).deletingLastPathComponent]
        while chain.count < limit {
            chain.append(current)
            if stop.contains(current) || current == home { break }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { break }
            current = parent
        }
        return chain
    }
}
