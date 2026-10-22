import Foundation

/// Address family of a listening socket.
enum AddressFamily: String, Codable, Hashable, Sendable {
    case ipv4
    case ipv6
}

/// A single TCP listening socket as reported by the port scanner.
/// One process may own many of these (one per bound address/port pair).
struct ListeningSocket: Hashable, Sendable {
    var pid: pid_t
    var port: Int
    /// Local bind address, e.g. "*", "127.0.0.1", "::1", "::".
    var address: String
    var family: AddressFamily
    /// Short command name if the scanner knows it (lsof reports it, libproc does not).
    var commandName: String?
    var uid: uid_t?

    var isWildcard: Bool { address == "*" || address == "0.0.0.0" || address == "::" }
    var isLoopback: Bool { address == "127.0.0.1" || address == "::1" || address.hasPrefix("127.") }
}

/// A port a process listens on, with every address it is bound to.
struct ListeningPort: Hashable, Sendable, Identifiable, Comparable {
    var port: Int
    var addresses: [String]

    var id: Int { port }

    static func < (lhs: ListeningPort, rhs: ListeningPort) -> Bool { lhs.port < rhs.port }

    /// Address that should be used when opening the port in a browser.
    var preferredHost: String {
        if addresses.contains(where: { $0 == "*" || $0 == "0.0.0.0" || $0 == "::" || $0 == "127.0.0.1" || $0 == "::1" }) {
            return "localhost"
        }
        if let first = addresses.first {
            return first.contains(":") ? "[\(first)]" : first
        }
        return "localhost"
    }

    var localURL: URL? { URL(string: "http://\(preferredHost):\(port)") }

    var addressSummary: String {
        let normalized = Set(addresses.map { address -> String in
            switch address {
            case "*", "0.0.0.0", "::": return "all interfaces"
            case "127.0.0.1", "::1": return "localhost"
            default: return address
            }
        })
        return normalized.sorted().joined(separator: ", ")
    }

    /// Merges raw sockets into one entry per port.
    static func merge(_ sockets: [ListeningSocket]) -> [ListeningPort] {
        var byPort: [Int: [String]] = [:]
        for socket in sockets {
            var list = byPort[socket.port, default: []]
            if !list.contains(socket.address) { list.append(socket.address) }
            byPort[socket.port] = list
        }
        return byPort.map { ListeningPort(port: $0.key, addresses: $0.value) }.sorted()
    }
}
