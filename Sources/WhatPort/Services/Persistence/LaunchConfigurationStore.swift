import Foundation

/// Persists launch configurations as a JSON file in Application Support.
protocol ConfigurationPersisting: Sendable {
    func load() throws -> [LaunchConfiguration]
    func save(_ configurations: [LaunchConfiguration]) throws
}

struct JSONConfigurationStore: ConfigurationPersisting {
    var fileURL: URL

    static func defaultURL() -> URL {
        AppPaths.supportDirectory.appendingPathComponent("launch-configurations.json")
    }

    func load() throws -> [LaunchConfiguration] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Envelope.self, from: data).configurations
    }

    func save(_ configurations: [LaunchConfiguration]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: 1, configurations: configurations))
        try data.write(to: fileURL, options: .atomic)
    }

    private struct Envelope: Codable {
        var version: Int
        var configurations: [LaunchConfiguration]
    }
}

final class InMemoryConfigurationStore: ConfigurationPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LaunchConfiguration] = []

    func load() throws -> [LaunchConfiguration] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func save(_ configurations: [LaunchConfiguration]) throws {
        lock.lock(); defer { lock.unlock() }
        stored = configurations
    }
}

enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("WhatPort", isDirectory: true)
    }

    static var logsDirectory: URL {
        supportDirectory.appendingPathComponent("logs", isDirectory: true)
    }
}
