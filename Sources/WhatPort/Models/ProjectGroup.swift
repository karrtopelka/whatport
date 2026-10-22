import Foundation

/// A row in the main list: a project (or a lone process) and its listeners.
struct ProjectGroup: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var symbolName: String
    var project: ProjectInfo?
    var listeners: [ListenerEntry]
    var category: PortCategory
    /// Saved configuration whose project root matches this group.
    var configuration: LaunchConfiguration?
    var managedState: ManagedState?

    var allPorts: [ListeningPort] {
        var seen = Set<Int>()
        return listeners.flatMap(\.ports).filter { seen.insert($0.port).inserted }.sorted()
    }

    var primaryListener: ListenerEntry? { listeners.first }

    /// Earliest start time among listeners.
    var startTime: Date? {
        listeners.compactMap(\.process.startTime).min()
    }

    var isManaged: Bool { configuration != nil }

    var pids: [pid_t] { listeners.map(\.process.pid) }
}

enum ListFilter: String, CaseIterable, Identifiable, Sendable {
    case development
    case all
    case managed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .development: return "Dev"
        case .all: return "All"
        case .managed: return "Managed"
        }
    }

    var symbolName: String {
        switch self {
        case .development: return "hammer"
        case .all: return "list.bullet"
        case .managed: return "star"
        }
    }
}
