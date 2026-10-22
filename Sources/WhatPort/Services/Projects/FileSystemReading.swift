import Foundation

/// Minimal file-system interface so project detection is testable in memory.
protocol FileSystemReading: Sendable {
    func fileExists(atPath path: String) -> Bool
    func directoryExists(atPath path: String) -> Bool
    func contents(atPath path: String) -> Data?
    func modificationDate(atPath path: String) -> Date?
    var homeDirectory: String { get }
}

struct RealFileSystem: FileSystemReading {
    func fileExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    func directoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func contents(atPath path: String) -> Data? {
        // Cap reads: package.json files are small; never slurp something huge.
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 1_000_000)
    }

    func modificationDate(atPath path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    var homeDirectory: String { NSHomeDirectory() }
}

/// In-memory file system for tests.
final class InMemoryFileSystem: FileSystemReading, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]
    private var directories: Set<String>
    let homeDirectory: String

    init(files: [String: String] = [:], directories: [String] = [], homeDirectory: String = "/Users/test") {
        self.files = files.mapValues { Data($0.utf8) }
        self.homeDirectory = homeDirectory
        var dirs = Set(directories)
        for path in files.keys {
            var dir = (path as NSString).deletingLastPathComponent
            while dir != "/" && !dir.isEmpty {
                dirs.insert(dir)
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        dirs.insert("/")
        self.directories = dirs
    }

    func fileExists(atPath path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return files[path] != nil
    }

    func directoryExists(atPath path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return directories.contains(path)
    }

    func contents(atPath path: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return files[path]
    }

    func modificationDate(atPath path: String) -> Date? {
        fileExists(atPath: path) ? Date(timeIntervalSince1970: 0) : nil
    }
}
