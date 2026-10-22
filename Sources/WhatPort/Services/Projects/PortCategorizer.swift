import Foundation

/// Classifies a listening process into development / application / system.
enum PortCategorizer {
    static let systemPathPrefixes = [
        "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/usr/share/",
    ]

    static let systemNames: Set<String> = [
        "rapportd", "ControlCenter", "sharingd", "cupsd", "AirPlayXPCHelper", "identityservicesd",
        "launchd", "mDNSResponder", "remoted", "screensharingd", "sshd", "smbd", "netbiosd",
        "universalaccessd", "Spotlight", "coreaudiod", "bluetoothd", "syncdefaultsd", "rpcsvchost",
    ]

    static func categorize(process: ProcessSnapshot, project: ProjectInfo?, runtime: Runtime?, home: String) -> PortCategory {
        if project != nil { return .development }
        if let uid = process.uid, uid == 0 { return .system }
        if let path = process.executablePath {
            if systemPathPrefixes.contains(where: { path.hasPrefix($0) }) { return .system }
            if path.hasPrefix("/Applications/Xcode") || path.contains("/Xcode.app/") {
                // Xcode's bundled toolchains (python3, simulators) are dev tools.
                return runtime != nil ? .development : .application
            }
            if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") || path.contains(".app/Contents/") {
                return .application
            }
            // Runtimes bundled by apps (Raycast's node, Docker's helpers, …).
            if path.hasPrefix(home + "/Library/") || path.hasPrefix("/Library/Application Support/") {
                return .application
            }
            if runtime != nil { return .development }
            if path.hasPrefix(home + "/") || path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/") || path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/") {
                return .development
            }
            if path.hasPrefix("/usr/bin/") || path.hasPrefix("/bin/") { return .system }
        }
        if systemNames.contains(process.name) { return .system }
        if runtime != nil { return .development }
        return .unknown
    }
}
