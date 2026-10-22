import Testing
@testable import WhatPort

@Suite("Project identification")
struct ProjectIdentifierTests {
    @Test func identifiesNextProjectFromNestedDirectory() {
        let fs = InMemoryFileSystem(files: [
            "/Users/test/projects/dashboard/package.json": #"{"name":"my-dashboard","scripts":{"dev":"next dev","build":"next build"},"dependencies":{"next":"15.0.0","react":"19"}}"#,
            "/Users/test/projects/dashboard/bun.lock": "",
            "/Users/test/projects/dashboard/src/app/page.tsx": "",
        ])
        let project = ProjectIdentifier(fileSystem: fs).identify(directory: "/Users/test/projects/dashboard/src/app")
        #expect(project?.rootPath == "/Users/test/projects/dashboard")
        #expect(project?.name == "my-dashboard")
        #expect(project?.framework == .nextjs)
        #expect(project?.packageManager == .bun)
        #expect(project?.runtime == .bun)
        #expect(project?.scripts["dev"] == "next dev")
        #expect(project?.subtitle == "Next.js · Bun")
        #expect(project?.workspaceRootPath == nil)
    }

    @Test func identifiesViteFromConfigFileWithoutDependency() {
        let fs = InMemoryFileSystem(files: [
            "/Users/test/p/package.json": #"{"name":"@acme/playground"}"#,
            "/Users/test/p/vite.config.ts": "",
            "/Users/test/p/pnpm-lock.yaml": "",
        ])
        let project = ProjectIdentifier(fileSystem: fs).identify(directory: "/Users/test/p")
        #expect(project?.framework == .vite)
        #expect(project?.name == "playground")
        #expect(project?.packageManager == .pnpm)
        #expect(project?.runtime == .node)
    }

    @Test func handlesMonorepoWorkspacePackages() {
        let fs = InMemoryFileSystem(files: [
            "/Users/test/mono/package.json": #"{"name":"acme-monorepo","workspaces":["apps/*"]}"#,
            "/Users/test/mono/pnpm-workspace.yaml": "packages:\n  - apps/*\n",
            "/Users/test/mono/pnpm-lock.yaml": "",
            "/Users/test/mono/apps/web/package.json": #"{"name":"@acme/web","dependencies":{"vite":"5"}}"#,
        ])
        let project = ProjectIdentifier(fileSystem: fs).identify(directory: "/Users/test/mono/apps/web")
        #expect(project?.rootPath == "/Users/test/mono/apps/web")
        #expect(project?.name == "web")
        #expect(project?.workspaceRootPath == "/Users/test/mono")
        #expect(project?.workspaceName == "acme-monorepo")
        #expect(project?.isMonorepoPackage == true)
        #expect(project?.packageManager == .pnpm, "lockfile at the workspace root is used")
        #expect(project?.subtitle == "Vite · in acme-monorepo")
    }

    @Test func identifiesCargoPythonGoAndSwift() {
        let fs = InMemoryFileSystem(files: [
            "/Users/test/rs/Cargo.toml": "[package]\nname = \"port-api\"\nversion = \"0.1.0\"\n\n[dependencies]\naxum = \"0.7\"\n",
            "/Users/test/py/pyproject.toml": "[project]\nname = \"ml-service\"\ndependencies = [\"fastapi\", \"uvicorn\"]\n",
            "/Users/test/go/go.mod": "module github.com/acme/gateway\n\ngo 1.22\n\nrequire github.com/gin-gonic/gin v1.9.1\n",
            "/Users/test/sw/Package.swift": "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"MyServer\", dependencies: [.package(url: \"https://github.com/vapor/vapor.git\", from: \"4.0.0\")])\n",
        ])
        let identifier = ProjectIdentifier(fileSystem: fs)
        let rust = identifier.identify(directory: "/Users/test/rs")
        #expect(rust?.name == "port-api")
        #expect(rust?.runtime == .rust)
        #expect(rust?.framework == .axum)

        let python = identifier.identify(directory: "/Users/test/py")
        #expect(python?.name == "ml-service")
        #expect(python?.runtime == .python)
        #expect(python?.framework == .fastapi)

        let go = identifier.identify(directory: "/Users/test/go")
        #expect(go?.name == "gateway")
        #expect(go?.framework == .gin)

        let swift = identifier.identify(directory: "/Users/test/sw")
        #expect(swift?.name == "MyServer")
        #expect(swift?.framework == .vapor)
    }

    @Test func fallsBackToGitRepositoryName() {
        let fs = InMemoryFileSystem(files: ["/Users/test/scripts/.git/HEAD": "ref: refs/heads/main", "/Users/test/scripts/serve.sh": ""])
        let project = ProjectIdentifier(fileSystem: fs).identify(directory: "/Users/test/scripts")
        #expect(project?.name == "scripts")
        #expect(project?.markers == [".git"])
        #expect(project?.framework == nil)
    }

    @Test func returnsNilWhenNothingIsRecognisable() {
        let fs = InMemoryFileSystem(files: ["/Users/test/Downloads/readme.txt": ""])
        #expect(ProjectIdentifier(fileSystem: fs).identify(directory: "/Users/test/Downloads") == nil)
        #expect(ProjectIdentifier(fileSystem: fs).identify(directory: "/nonexistent") == nil)
    }

    @Test func doesNotWalkAboveHomeDirectory() {
        // A package.json in /Users must not claim every project.
        let fs = InMemoryFileSystem(files: ["/Users/package.json": #"{"name":"nope"}"#, "/Users/test/work/notes.md": ""])
        #expect(ProjectIdentifier(fileSystem: fs).identify(directory: "/Users/test/work") == nil)
    }

    @Test func toleratesMalformedPackageJSON() {
        let fs = InMemoryFileSystem(files: ["/Users/test/bad/package.json": "{ not json"])
        let project = ProjectIdentifier(fileSystem: fs).identify(directory: "/Users/test/bad")
        #expect(project?.name == "bad")
        #expect(project?.runtime == .node)
    }

    @Test func candidateDirectoriesPreferEnvironmentAndNodeModulesPaths() {
        let process = makeProcess(
            pid: 10, name: "node",
            arguments: ["node", "/Users/test/app/node_modules/.bin/vite", "--host"],
            cwd: "/Users/test/app/sub",
            environment: ["npm_package_json": "/Users/test/app/package.json", "INIT_CWD": "/Users/test/app"]
        )
        let candidates = ProjectRootLocator.candidateDirectories(for: process, ancestry: [])
        #expect(candidates.first == "/Users/test/app")
        #expect(candidates.contains("/Users/test/app/sub"))
        #expect(candidates.count == 2)
    }
}
