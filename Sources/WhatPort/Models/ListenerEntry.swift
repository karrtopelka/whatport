import Foundation

/// How a listening process should be presented and filtered.
enum PortCategory: String, Codable, Hashable, Sendable {
    /// A development server or tool (identified project, dev runtime, user-space binary).
    case development
    /// A regular application (something in /Applications, Docker, etc.).
    case application
    /// macOS system or background service.
    case system
    /// Could not be classified.
    case unknown

    var displayName: String {
        switch self {
        case .development: return "Development"
        case .application: return "Application"
        case .system: return "System"
        case .unknown: return "Unidentified"
        }
    }
}

/// One listening process together with everything discovered about it.
struct ListenerEntry: Identifiable, Hashable, Sendable {
    var process: ProcessSnapshot
    var ports: [ListeningPort]
    var project: ProjectInfo?
    var category: PortCategory
    /// Parent chain: closest parent first. May be shorter than the real chain
    /// when a parent could not be inspected.
    var ancestry: [ProcessSnapshot] = []
    /// The nearest ancestor that is a package-manager/task runner for the same
    /// project (e.g. `npm run dev` whose child `node` listens).
    var runnerParent: ProcessSnapshot? = nil
    /// Runtime inferred from the executable name when no project is known.
    var runtime: Runtime? = nil

    var id: pid_t { process.pid }

    var primaryPort: ListeningPort? { ports.first }

    var displayName: String { project?.name ?? process.executableName }

    var portsSummary: String {
        ports.map { String($0.port) }.joined(separator: ", ")
    }

    /// Stable key used to group listeners that belong to the same project.
    var groupKey: String {
        if let project { return "project:" + project.rootPath }
        return "pid:\(process.pid)"
    }
}
