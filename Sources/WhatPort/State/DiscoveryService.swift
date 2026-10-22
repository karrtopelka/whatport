import Foundation

struct DiscoveryResult: Sendable {
    var listeners: [ListenerEntry]
    var scannedAt: Date
}

/// Turns raw sockets into fully described listeners, off the main actor.
actor DiscoveryService {
    private let scanner: any PortScanning
    private let inspector: any ProcessInspecting
    private let locator: ProjectRootLocator
    private let home: String

    init(scanner: any PortScanning = CompositePortScanner(),
         inspector: any ProcessInspecting = SystemProcessInspector(),
         locator: ProjectRootLocator = ProjectRootLocator(),
         home: String = NSHomeDirectory()) {
        self.scanner = scanner
        self.inspector = inspector
        self.locator = locator
        self.home = home
    }

    func discover() async throws -> DiscoveryResult {
        let sockets = try await scanner.scan()
        let byPID = Dictionary(grouping: sockets, by: \.pid)
        var listeners: [ListenerEntry] = []
        listeners.reserveCapacity(byPID.count)

        for (pid, group) in byPID {
            // The process may have exited between the scan and inspection.
            guard var snapshot = inspector.snapshot(pid: pid) else { continue }
            if snapshot.name.isEmpty, let command = group.first?.commandName { snapshot.name = command }
            let ancestry = inspector.ancestry(of: pid, limit: 8)
            let project = await locator.project(for: snapshot, ancestry: ancestry)
            let runtime = Runtime.from(executableName: snapshot.executableName) ?? project?.runtime
            let category = PortCategorizer.categorize(process: snapshot, project: project, runtime: runtime, home: home)
            let related = Self.relatedAncestors(of: snapshot, ancestry: ancestry, projectRoot: project?.rootPath)
            listeners.append(ListenerEntry(
                process: snapshot,
                ports: ListeningPort.merge(group),
                project: project,
                category: category,
                ancestry: ancestry,
                runnerParent: related.last,
                runtime: runtime
            ))
        }

        listeners.sort { a, b in
            if a.category != b.category { return Self.rank(a.category) < Self.rank(b.category) }
            let nameOrder = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return (a.primaryPort?.port ?? 0) < (b.primaryPort?.port ?? 0)
        }
        return DiscoveryResult(listeners: listeners, scannedAt: Date())
    }

    func invalidateProjectCache() async {
        await locator.invalidate()
    }

    private static func rank(_ category: PortCategory) -> Int {
        switch category {
        case .development: return 0
        case .application: return 1
        case .unknown: return 2
        case .system: return 3
        }
    }

    /// Ancestors that are part of the same development run as the listener
    /// (package-manager runners, `next dev` parents, `nodemon`, …), nearest
    /// first. Stops at shells, terminals and anything from another project.
    static func relatedAncestors(of process: ProcessSnapshot, ancestry: [ProcessSnapshot], projectRoot: String?) -> [ProcessSnapshot] {
        var related: [ProcessSnapshot] = []
        let root = projectRoot ?? process.workingDirectory
        for parent in ancestry {
            if parent.pid <= 1 || LaunchInferenceEngine.isShellOrTerminal(parent) { break }
            let isRunner = LaunchInferenceEngine.runnerCommand(from: parent) != nil
            let isDevRuntime = Runtime.from(executableName: parent.executableName) != nil
            let sameProject = LaunchInferenceEngine.sameProject(parent, root: root) || parent.workingDirectory == process.workingDirectory
            guard (isRunner || isDevRuntime) && sameProject else { break }
            related.append(parent)
        }
        return related
    }
}
