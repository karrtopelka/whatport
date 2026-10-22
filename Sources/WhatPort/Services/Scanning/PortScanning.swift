import Foundation

/// Abstraction over "find every TCP listening socket on this machine".
protocol PortScanning: Sendable {
    func scan() async throws -> [ListeningSocket]
}

enum PortScanError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let what): return "\(what) is not available on this system."
        case .timedOut: return "The port scan timed out."
        case .failed(let message): return message
        }
    }
}

/// Uses libproc first (fast, in-process) and falls back to `lsof` when libproc
/// fails or returns nothing while lsof sees listeners.
struct CompositePortScanner: PortScanning {
    var primary: any PortScanning = LibprocPortScanner()
    var fallback: any PortScanning = LsofPortScanner()

    func scan() async throws -> [ListeningSocket] {
        do {
            let sockets = try await primary.scan()
            if !sockets.isEmpty { return sockets }
        } catch {
            // fall through to lsof
        }
        return try await fallback.scan()
    }
}
