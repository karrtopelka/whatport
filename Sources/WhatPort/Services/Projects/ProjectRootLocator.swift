import Foundation

/// Decides where to start looking for a project for a given process, caching
/// results per starting directory.
actor ProjectRootLocator {
    private let identifier: ProjectIdentifier
    private var cache: [String: CacheEntry] = [:]
    private let ttl: TimeInterval

    private struct CacheEntry {
        var project: ProjectInfo?
        var timestamp: Date
    }

    init(identifier: ProjectIdentifier = ProjectIdentifier(), ttl: TimeInterval = 120) {
        self.identifier = identifier
        self.ttl = ttl
    }

    /// Candidate directories for a process, most specific first.
    nonisolated static func candidateDirectories(for process: ProcessSnapshot, ancestry: [ProcessSnapshot]) -> [String] {
        var candidates: [String] = []
        func add(_ path: String?) {
            guard var path, path.hasPrefix("/") else { return }
            path = ProjectIdentifier.normalize(path)
            if !candidates.contains(path) { candidates.append(path) }
        }
        add(process.environmentHints.packageJSONPath.map { ($0 as NSString).deletingLastPathComponent })
        add(process.workingDirectory)
        add(process.environmentHints.initialWorkingDirectory)
        // Script paths inside the project, e.g. node /proj/node_modules/.bin/vite
        for argument in process.arguments ?? [] where argument.hasPrefix("/") {
            if let range = argument.range(of: "/node_modules/") {
                add(String(argument[..<range.lowerBound]))
            } else if argument.hasSuffix(".js") || argument.hasSuffix(".ts") || argument.hasSuffix(".mjs") || argument.hasSuffix(".py") {
                add((argument as NSString).deletingLastPathComponent)
            }
        }
        for parent in ancestry.prefix(3) {
            add(parent.workingDirectory)
        }
        return candidates
    }

    func project(for process: ProcessSnapshot, ancestry: [ProcessSnapshot]) -> ProjectInfo? {
        for directory in Self.candidateDirectories(for: process, ancestry: ancestry) {
            if let project = identify(directory: directory) { return project }
        }
        return nil
    }

    func identify(directory: String) -> ProjectInfo? {
        let now = Date()
        if let entry = cache[directory], now.timeIntervalSince(entry.timestamp) < ttl {
            return entry.project
        }
        let project = identifier.identify(directory: directory)
        cache[directory] = CacheEntry(project: project, timestamp: now)
        return project
    }

    func invalidate() {
        cache.removeAll()
    }
}
