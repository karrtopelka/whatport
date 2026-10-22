import CSystem
import Foundation

/// Enumerates listening TCP sockets via `proc_pidinfo`/`proc_pidfdinfo`.
///
/// This is what `lsof -iTCP -sTCP:LISTEN` does under the hood, without
/// spawning a process. Like lsof, it can only see file descriptors of
/// processes owned by the current user unless running as root.
struct LibprocPortScanner: PortScanning {
    func scan() async throws -> [ListeningSocket] {
        try await Task.detached(priority: .utility) {
            try Self.scanNow()
        }.value
    }

    static func scanNow() throws -> [ListeningSocket] {
        let pids = try listAllPIDs()
        var result: [ListeningSocket] = []
        result.reserveCapacity(32)
        let ownUID = getuid()
        for pid in pids where pid > 0 {
            // Cheap ownership pre-check so we do not hit EPERM for every fd of
            // root-owned daemons.
            var shortInfo = proc_bsdshortinfo()
            let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            let got = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &shortInfo, shortSize)
            guard got == shortSize else { continue }
            guard shortInfo.pbsi_uid == ownUID else { continue }
            result.append(contentsOf: listeningSockets(of: pid, uid: shortInfo.pbsi_uid))
        }
        return result
    }

    static func listAllPIDs() throws -> [pid_t] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { throw PortScanError.failed("proc_listpids failed (errno \(errno))") }
        // Leave headroom for processes created between the two calls.
        let capacity = Int(needed) / MemoryLayout<pid_t>.size + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBytes { buffer -> Int32 in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard written > 0 else { throw PortScanError.failed("proc_listpids failed (errno \(errno))") }
        let count = Int(written) / MemoryLayout<pid_t>.size
        return Array(pids.prefix(count))
    }

    static func listeningSockets(of pid: pid_t, uid: uid_t) -> [ListeningSocket] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / stride + 16)
        let written = fds.withUnsafeMutableBytes { buffer -> Int32 in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard written > 0 else { return [] }
        let count = Int(written) / stride
        var sockets: [ListeningSocket] = []
        for fd in fds.prefix(count) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            let got = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size)
            guard got == size else { continue }
            guard info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            var inet = tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport)))
            guard port > 0 else { continue }
            let isV6 = (Int32(inet.insi_vflag) & INI_IPV6) != 0 && (Int32(inet.insi_vflag) & INI_IPV4) == 0
            let address: String
            let family: AddressFamily
            if isV6 {
                family = .ipv6
                address = Self.format(v6: &inet.insi_laddr.ina_6)
            } else {
                family = .ipv4
                address = Self.format(v4: &inet.insi_laddr.ina_46.i46a_addr4)
            }
            sockets.append(ListeningSocket(pid: pid, port: port, address: address, family: family, commandName: nil, uid: uid))
        }
        return sockets
    }

    private static func format(v4 addr: inout in_addr) -> String {
        if addr.s_addr == 0 { return "*" }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
        return CStrings.string(from: buffer)
    }

    private static func format(v6 addr: inout in6_addr) -> String {
        let bytes = withUnsafeBytes(of: addr) { Array($0) }
        if bytes.allSatisfy({ $0 == 0 }) { return "*" }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
        let text = CStrings.string(from: buffer)
        // IPv4-mapped (::ffff:127.0.0.1) — present as the v4 address.
        if text.hasPrefix("::ffff:") { return String(text.dropFirst(7)) }
        return text
    }
}
