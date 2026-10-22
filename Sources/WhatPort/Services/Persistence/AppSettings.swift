import Foundation
import Observation
import ServiceManagement

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    enum Key {
        static let autoRefresh = "autoRefresh"
        static let refreshInterval = "refreshInterval"
        static let backgroundRefreshInterval = "backgroundRefreshInterval"
        static let showSystemProcesses = "showSystemProcesses"
        static let showUnidentifiedProcesses = "showUnidentifiedProcesses"
        static let confirmBeforeStop = "confirmBeforeStop"
        static let showCountInMenuBar = "showCountInMenuBar"
        static let extraSearchPaths = "extraSearchPaths"
        static let defaultFilter = "defaultFilter"
        static let hasCompletedFirstRun = "hasCompletedFirstRun"
    }

    var autoRefresh: Bool { didSet { defaults.set(autoRefresh, forKey: Key.autoRefresh) } }
    /// Seconds between scans while the popover is open.
    var refreshInterval: Double { didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) } }
    /// Seconds between scans while the popover is closed (used for the menu bar count).
    var backgroundRefreshInterval: Double { didSet { defaults.set(backgroundRefreshInterval, forKey: Key.backgroundRefreshInterval) } }
    var showSystemProcesses: Bool { didSet { defaults.set(showSystemProcesses, forKey: Key.showSystemProcesses) } }
    var showUnidentifiedProcesses: Bool { didSet { defaults.set(showUnidentifiedProcesses, forKey: Key.showUnidentifiedProcesses) } }
    var confirmBeforeStop: Bool { didSet { defaults.set(confirmBeforeStop, forKey: Key.confirmBeforeStop) } }
    var showCountInMenuBar: Bool { didSet { defaults.set(showCountInMenuBar, forKey: Key.showCountInMenuBar) } }
    /// Colon-separated extra directories to search for executables.
    var extraSearchPaths: String { didSet { defaults.set(extraSearchPaths, forKey: Key.extraSearchPaths) } }
    var defaultFilter: ListFilter { didSet { defaults.set(defaultFilter.rawValue, forKey: Key.defaultFilter) } }

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = error.localizedDescription
                launchAtLogin = oldValue
            }
        }
    }
    var launchAtLoginError: String?

    var extraSearchPathList: [String] {
        extraSearchPaths.split(separator: ":").map { ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }.filter { !$0.isEmpty }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.autoRefresh: true,
            Key.refreshInterval: 5.0,
            Key.backgroundRefreshInterval: 60.0,
            Key.showSystemProcesses: false,
            Key.showUnidentifiedProcesses: true,
            Key.confirmBeforeStop: true,
            Key.showCountInMenuBar: false,
            Key.extraSearchPaths: "",
            Key.defaultFilter: ListFilter.development.rawValue,
        ])
        autoRefresh = defaults.bool(forKey: Key.autoRefresh)
        refreshInterval = defaults.double(forKey: Key.refreshInterval)
        backgroundRefreshInterval = defaults.double(forKey: Key.backgroundRefreshInterval)
        showSystemProcesses = defaults.bool(forKey: Key.showSystemProcesses)
        showUnidentifiedProcesses = defaults.bool(forKey: Key.showUnidentifiedProcesses)
        confirmBeforeStop = defaults.bool(forKey: Key.confirmBeforeStop)
        showCountInMenuBar = defaults.bool(forKey: Key.showCountInMenuBar)
        extraSearchPaths = defaults.string(forKey: Key.extraSearchPaths) ?? ""
        defaultFilter = ListFilter(rawValue: defaults.string(forKey: Key.defaultFilter) ?? "") ?? .development
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
