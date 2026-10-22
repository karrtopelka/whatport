import Foundation

/// A saved, user-approved way to start a project.
struct LaunchConfiguration: Identifiable, Hashable, Sendable, Codable {
    var id: UUID
    var displayName: String
    /// Project root used to match discovered processes to this configuration.
    var projectRootPath: String
    var workingDirectory: String
    /// Executable name (resolved via search paths) or absolute path.
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    /// Ports this project is expected to use. Used to warn about conflicts.
    var expectedPorts: [Int]
    var createdAt: Date
    var updatedAt: Date
    /// Identity of the last instance started by WhatPort, so the app can
    /// re-adopt it after relaunch. Never treated as authoritative.
    var lastInstance: ProcessIdentity?

    init(
        id: UUID = UUID(),
        displayName: String,
        projectRootPath: String,
        workingDirectory: String,
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        expectedPorts: [Int] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastInstance: ProcessIdentity? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.projectRootPath = projectRootPath
        self.workingDirectory = workingDirectory
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.expectedPorts = expectedPorts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastInstance = lastInstance
    }

    var commandLine: String {
        ([executable] + arguments).map(ShellWords.quoteIfNeeded).joined(separator: " ")
    }

    var workingDirectoryURL: URL { URL(fileURLWithPath: workingDirectory) }
}

enum SuggestionConfidence: String, Codable, Hashable, Sendable, Comparable {
    case low, medium, high

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    static func < (lhs: SuggestionConfidence, rhs: SuggestionConfidence) -> Bool { lhs.rank < rhs.rank }

    var displayName: String {
        switch self {
        case .low: return "Low confidence"
        case .medium: return "Medium confidence"
        case .high: return "High confidence"
        }
    }
}

/// A launch configuration inferred from a discovered process. Always needs
/// user confirmation before it is used.
struct LaunchSuggestion: Hashable, Sendable {
    var configuration: LaunchConfiguration
    var confidence: SuggestionConfidence
    /// Human-readable explanation of where the suggestion came from.
    var reason: String
}
