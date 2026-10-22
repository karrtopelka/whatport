import CSystem
import Foundation

/// Real implementation backed by libproc and sysctl.
///
/// What works without root:
/// - basic info (name, parent, uid, start time) for every process;
/// - executable path for every process;
/// - working directory and arguments/environment only for processes owned by
///   the current user. Anything else is reported as `nil`.
struct SystemProcessInspector: ProcessInspecting {
    func snapshot(pid: pid_t) -> ProcessSnapshot? {
        guard pid > 0, var info = Self.kernelInfo(pid: pid) else { return nil }
        // A zombie still has an entry; treat it as gone.
        if Int32(info.kp_proc.p_stat) == SZOMB { return nil }

        let comm = withUnsafePointer(to: &info.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        let path = Self.executablePath(pid: pid)
        // p_comm is truncated to 16 characters; prefer the executable's file name.
        let name = (path as NSString?)?.lastPathComponent ?? (comm.isEmpty ? "pid \(pid)" : comm)
        let start = Date(timeIntervalSince1970: Double(info.kp_proc.p_starttime.tv_sec) + Double(info.kp_proc.p_starttime.tv_usec) / 1_000_000)
        let uid = info.kp_eproc.e_ucred.cr_uid
        let args = Self.arguments(pid: pid)

        return ProcessSnapshot(
            pid: pid,
            parentPID: pid_t(info.kp_eproc.e_ppid),
            name: name,
            executablePath: path,
            arguments: args?.arguments,
            workingDirectory: Self.workingDirectory(pid: pid),
            startTime: start,
            uid: uid,
            userName: Self.userName(uid: uid),
            environmentHints: args.map { EnvironmentHints(environment: $0.environment) } ?? EnvironmentHints()
        )
    }

    /// `kern.proc.pid` — readable for every process, unlike `PROC_PIDTBSDINFO`.
    static func kernelInfo(pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.size else { return nil }
        guard info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    func isAlive(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM means it exists but belongs to someone else.
        return errno == EPERM
    }

    func children(of pid: pid_t) -> [pid_t] {
        guard let pids = try? LibprocPortScanner.listAllPIDs() else { return [] }
        var result: [pid_t] = []
        for candidate in pids where candidate > 0 && candidate != pid {
            var short = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(candidate, PROC_PIDT_SHORTBSDINFO, 0, &short, size) == size else { continue }
            if pid_t(short.pbsi_ppid) == pid { result.append(candidate) }
        }
        return result
    }

    // MARK: - Pieces

    static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(WP_PROC_PIDPATHINFO_MAXSIZE))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return CStrings.string(from: buffer)
    }

    static func workingDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(WP_MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    static func userName(uid: uid_t) -> String? {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return nil }
        return String(cString: name)
    }

    struct ArgumentsAndEnvironment: Sendable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
    }

    /// Reads `KERN_PROCARGS2`. Only permitted for the current user's processes.
    static func arguments(pid: pid_t) -> ArgumentsAndEnvironment? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        buffer.removeSubrange(size...)
        return ProcArgsParser.parse(buffer)
    }
}

/// Parses the `KERN_PROCARGS2` buffer layout:
/// `argc:int32 | exec_path\0 | padding\0... | argv[0]\0 ... argv[argc-1]\0 | env\0 ... | \0...`
enum ProcArgsParser {
    static func parse(_ buffer: [UInt8]) -> SystemProcessInspector.ArgumentsAndEnvironment? {
        guard buffer.count > 4 else { return nil }
        let argc = Int(UInt32(buffer[0]) | UInt32(buffer[1]) << 8 | UInt32(buffer[2]) << 16 | UInt32(buffer[3]) << 24)
        var index = 4
        func readCString() -> String? {
            guard index < buffer.count else { return nil }
            var end = index
            while end < buffer.count, buffer[end] != 0 { end += 1 }
            let string = String(decoding: buffer[index..<end], as: UTF8.self)
            index = min(end + 1, buffer.count)
            return string
        }
        guard let executable = readCString() else { return nil }
        // Skip padding NULs between the exec path and argv[0].
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = readCString() else { break }
            arguments.append(argument)
        }
        var environment: [String: String] = [:]
        while index < buffer.count {
            guard let entry = readCString(), !entry.isEmpty else { break }
            if let equals = entry.firstIndex(of: "=") {
                let key = String(entry[..<equals])
                if EnvironmentHints.retainedKeys.contains(key) {
                    environment[key] = String(entry[entry.index(after: equals)...])
                }
            }
        }
        return .init(executable: executable, arguments: arguments, environment: environment)
    }
}
