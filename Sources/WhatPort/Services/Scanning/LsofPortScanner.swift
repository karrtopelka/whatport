import Foundation

/// Runs `/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -F ...` and parses its
/// machine-readable field output.
struct LsofPortScanner: PortScanning {
    var executablePath = "/usr/sbin/lsof"
    var timeout: TimeInterval = 15

    func scan() async throws -> [ListeningSocket] {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw PortScanError.unavailable("lsof")
        }
        let output = try await Subprocess.run(
            executable: executablePath,
            arguments: ["-nP", "-l", "-w", "-iTCP", "-sTCP:LISTEN", "-F", "pcRuftPn"],
            timeout: timeout
        )
        // lsof exits 1 when nothing matched — that is not an error for us.
        guard output.status == 0 || output.status == 1 else {
            throw PortScanError.failed("lsof exited with status \(output.status)")
        }
        return LsofFieldParser.parse(output.stdout)
    }
}

/// Parser for `lsof -F` output. Pure and fully unit-tested.
///
/// Field output is one field per line: a one-character tag followed by the
/// value. A `p` line starts a new process section; an `f` line starts a new
/// file (socket) within that process.
enum LsofFieldParser {
    static func parse(_ text: String) -> [ListeningSocket] {
        var sockets: [ListeningSocket] = []
        var pid: pid_t?
        var command: String?
        var uid: uid_t?
        var fileProtocol: String?
        var fileType: String?
        var fileName: String?

        func flushFile() {
            defer { fileProtocol = nil; fileType = nil; fileName = nil }
            guard let pid, let fileName, fileProtocol?.uppercased() == "TCP" else { return }
            guard let endpoint = parseEndpoint(fileName) else { return }
            let family: AddressFamily
            switch fileType?.uppercased() {
            case "IPV6": family = .ipv6
            case "IPV4": family = .ipv4
            default: family = endpoint.address.contains(":") ? .ipv6 : .ipv4
            }
            sockets.append(ListeningSocket(pid: pid, port: endpoint.port, address: endpoint.address, family: family, commandName: command, uid: uid))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine[...]
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                flushFile()
                pid = pid_t(value)
                command = nil
                uid = nil
            case "c":
                command = value
            case "u":
                uid = uid_t(value)
            case "f":
                flushFile()
            case "t":
                fileType = value
            case "P":
                fileProtocol = value
            case "n":
                fileName = value
            default:
                continue
            }
        }
        flushFile()
        return sockets
    }

    /// Parses `*:3000`, `127.0.0.1:3000`, `[::1]:3000`, `[::]:5173`,
    /// and `[fe80::1%lo0]:8080` into address and port.
    static func parseEndpoint(_ name: String) -> (address: String, port: Int)? {
        // Listening sockets have no remote part, but be defensive about "->".
        let local = name.components(separatedBy: "->").first ?? name
        guard let colon = local.lastIndex(of: ":") else { return nil }
        let portText = local[local.index(after: colon)...]
        guard let port = Int(portText), port > 0, port <= 65535 else { return nil }
        var address = String(local[..<colon])
        if address.hasPrefix("["), address.hasSuffix("]") {
            address = String(address.dropFirst().dropLast())
        }
        if address.isEmpty || address == "0.0.0.0" || address == "::" { address = "*" }
        return (address, port)
    }
}
