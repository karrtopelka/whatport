import Foundation

/// Reads process metadata. Abstracted so the discovery pipeline can be tested
/// with canned processes.
protocol ProcessInspecting: Sendable {
    /// `nil` when the process does not exist (or basic info is unreadable).
    func snapshot(pid: pid_t) -> ProcessSnapshot?
    func isAlive(pid: pid_t) -> Bool
    /// PIDs whose parent is `pid`.
    func children(of pid: pid_t) -> [pid_t]
}

extension ProcessInspecting {
    /// Parent chain of `pid`, nearest first, bounded to avoid runaway walks.
    func ancestry(of pid: pid_t, limit: Int = 8) -> [ProcessSnapshot] {
        var chain: [ProcessSnapshot] = []
        var current = pid
        var seen: Set<pid_t> = [pid]
        while chain.count < limit {
            guard let snapshot = self.snapshot(pid: current), let parent = snapshot.parentPID else { break }
            guard parent > 0, !seen.contains(parent) else { break }
            seen.insert(parent)
            guard let parentSnapshot = self.snapshot(pid: parent) else { break }
            chain.append(parentSnapshot)
            if parent == 1 { break }
            current = parent
        }
        return chain
    }

    /// All descendants of `pid` (children, grandchildren, …), breadth first.
    func descendants(of pid: pid_t, limit: Int = 256) -> [pid_t] {
        var result: [pid_t] = []
        var queue: [pid_t] = [pid]
        var seen: Set<pid_t> = [pid]
        while let next = queue.first, result.count < limit {
            queue.removeFirst()
            for child in children(of: next) where seen.insert(child).inserted {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    /// Returns the live identity if the process still exists and matches.
    func verify(_ identity: ProcessIdentity) -> ProcessSnapshot? {
        guard let snapshot = snapshot(pid: identity.pid) else { return nil }
        return snapshot.identity.matches(identity) ? snapshot : nil
    }
}
