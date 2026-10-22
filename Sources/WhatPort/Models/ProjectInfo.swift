import Foundation

enum PackageManager: String, Codable, Hashable, Sendable, CaseIterable {
    case npm, pnpm, yarn, bun, deno

    var executable: String { rawValue }

    /// Arguments that run a package.json script with this manager.
    func runScriptArguments(_ script: String) -> [String] {
        switch self {
        case .npm: return ["run", script]
        case .pnpm: return ["run", script]
        case .yarn: return ["run", script]
        case .bun: return ["run", script]
        case .deno: return ["task", script]
        }
    }

    /// Arguments that execute a locally installed binary (`node_modules/.bin/<tool>`).
    func execArguments(_ tool: String, _ args: [String]) -> (executable: String, arguments: [String]) {
        switch self {
        case .npm: return ("npx", [tool] + args)
        case .pnpm: return ("pnpm", ["exec", tool] + args)
        case .yarn: return ("yarn", [tool] + args)
        case .bun: return ("bunx", [tool] + args)
        case .deno: return ("deno", ["run", "-A", "npm:" + tool] + args)
        }
    }
}

enum Runtime: String, Codable, Hashable, Sendable, CaseIterable {
    case node, bun, deno, python, ruby, rust, go, swift, java, elixir, php, dotnet, other

    var displayName: String {
        switch self {
        case .node: return "Node.js"
        case .bun: return "Bun"
        case .deno: return "Deno"
        case .python: return "Python"
        case .ruby: return "Ruby"
        case .rust: return "Rust"
        case .go: return "Go"
        case .swift: return "Swift"
        case .java: return "Java"
        case .elixir: return "Elixir"
        case .php: return "PHP"
        case .dotnet: return ".NET"
        case .other: return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .node: return "hexagon.fill"
        case .bun: return "b.circle.fill"
        case .deno: return "d.circle.fill"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .ruby: return "diamond.fill"
        case .rust: return "gearshape.2.fill"
        case .go: return "g.circle.fill"
        case .swift: return "swift"
        case .java: return "cup.and.saucer.fill"
        case .elixir: return "drop.fill"
        case .php: return "p.circle.fill"
        case .dotnet: return "n.circle.fill"
        case .other: return "terminal.fill"
        }
    }

    /// Runtime guessed from an executable name such as "node", "bun", "python3.12".
    static func from(executableName name: String) -> Runtime? {
        let lowered = name.lowercased()
        if lowered == "node" || lowered.hasPrefix("node-") || lowered == "nodejs" { return .node }
        if lowered == "bun" || lowered == "bunx" { return .bun }
        if lowered == "deno" { return .deno }
        if lowered.hasPrefix("python") || lowered == "uvicorn" || lowered == "gunicorn" || lowered == "flask" || lowered == "uv" { return .python }
        if lowered == "ruby" || lowered == "puma" || lowered == "rails" || lowered == "unicorn" { return .ruby }
        if lowered == "cargo" { return .rust }
        if lowered == "go" { return .go }
        if lowered == "java" || lowered == "gradle" || lowered == "kotlin" { return .java }
        if lowered == "beam.smp" || lowered == "beam" || lowered == "elixir" || lowered == "mix" || lowered == "erl" { return .elixir }
        if lowered == "php" || lowered == "php-fpm" { return .php }
        if lowered == "dotnet" { return .dotnet }
        if lowered == "swift-run" || lowered == "swift" { return .swift }
        return nil
    }
}

enum Framework: String, Codable, Hashable, Sendable, CaseIterable {
    case nextjs, nuxt, sveltekit, astro, remix, reactRouter, angular, expo, gatsby, vite, storybook
    case nest, fastify, hono, express, elysia
    case django, fastapi, flask, uvicorn
    case rails, phoenix, laravel, vapor, axum, actix, rocket, spring, gin, echo, fiber

    var displayName: String {
        switch self {
        case .nextjs: return "Next.js"
        case .nuxt: return "Nuxt"
        case .sveltekit: return "SvelteKit"
        case .astro: return "Astro"
        case .remix: return "Remix"
        case .reactRouter: return "React Router"
        case .angular: return "Angular"
        case .expo: return "Expo"
        case .gatsby: return "Gatsby"
        case .vite: return "Vite"
        case .storybook: return "Storybook"
        case .nest: return "NestJS"
        case .fastify: return "Fastify"
        case .hono: return "Hono"
        case .express: return "Express"
        case .elysia: return "Elysia"
        case .django: return "Django"
        case .fastapi: return "FastAPI"
        case .flask: return "Flask"
        case .uvicorn: return "Uvicorn"
        case .rails: return "Rails"
        case .phoenix: return "Phoenix"
        case .laravel: return "Laravel"
        case .vapor: return "Vapor"
        case .axum: return "Axum"
        case .actix: return "Actix"
        case .rocket: return "Rocket"
        case .spring: return "Spring"
        case .gin: return "Gin"
        case .echo: return "Echo"
        case .fiber: return "Fiber"
        }
    }

    var symbolName: String {
        switch self {
        case .nextjs: return "n.square.fill"
        case .nuxt: return "leaf.fill"
        case .sveltekit: return "flame.fill"
        case .astro: return "sparkles"
        case .remix, .reactRouter: return "arrow.triangle.branch"
        case .angular: return "a.square.fill"
        case .expo: return "iphone"
        case .gatsby: return "g.square.fill"
        case .vite: return "bolt.fill"
        case .storybook: return "book.fill"
        case .nest: return "shield.lefthalf.filled"
        case .fastify: return "hare.fill"
        case .hono: return "flame"
        case .express: return "e.square.fill"
        case .elysia: return "e.circle.fill"
        case .django: return "d.square.fill"
        case .fastapi: return "bolt.horizontal.fill"
        case .flask: return "flask.fill"
        case .uvicorn: return "u.square.fill"
        case .rails: return "tram.fill"
        case .phoenix: return "bird.fill"
        case .laravel: return "l.square.fill"
        case .vapor: return "cloud.fill"
        case .axum, .actix, .rocket: return "gearshape.2.fill"
        case .spring: return "leaf.circle.fill"
        case .gin, .echo, .fiber: return "g.circle.fill"
        }
    }
}

/// What we learned about the project a process belongs to.
struct ProjectInfo: Hashable, Sendable, Codable {
    /// Nearest project root (the package in a monorepo).
    var rootPath: String
    /// Display name — package name, Cargo crate name, or directory name.
    var name: String
    /// Monorepo/workspace root when it differs from `rootPath`.
    var workspaceRootPath: String?
    var workspaceName: String?
    var framework: Framework?
    var runtime: Runtime?
    var packageManager: PackageManager?
    /// package.json scripts (name → command). Empty for non-JS projects.
    var scripts: [String: String] = [:]
    /// Marker files that led to this identification, e.g. ["package.json", "next.config.ts"].
    var markers: [String] = []

    var rootURL: URL { URL(fileURLWithPath: rootPath) }

    var isMonorepoPackage: Bool { workspaceRootPath != nil && workspaceRootPath != rootPath }

    var subtitle: String { subtitle(runtime: runtime) }

    /// Subtitle using the runtime actually observed for the process, which
    /// can differ from the project's default (e.g. `node` running a Bun project).
    func subtitle(runtime observed: Runtime?) -> String {
        let runtime = observed ?? self.runtime
        var parts: [String] = []
        if let framework { parts.append(framework.displayName) }
        if let runtime, framework == nil || runtime != .node { parts.append(runtime.displayName) }
        if let workspaceName, isMonorepoPackage { parts.append("in \(workspaceName)") }
        return parts.joined(separator: " · ")
    }

    var symbolName: String {
        framework?.symbolName ?? runtime?.symbolName ?? "shippingbox.fill"
    }
}
