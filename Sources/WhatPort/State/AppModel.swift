import AppKit
import Foundation
import Observation
import os

/// Transient message shown at the top of the popover.
struct Notice: Identifiable, Equatable {
    enum Kind { case info, error, success }
    var id = UUID()
    var kind: Kind
    var message: String
}

/// What the stop confirmation dialog is about.
struct StopRequest: Identifiable, Equatable {
    var id: String { group.id }
    var group: ProjectGroup
    var force: Bool
}

@MainActor
@Observable
final class AppModel {
    // MARK: Dependencies
    let settings: AppSettings
    private let discovery: DiscoveryService
    private let inspector: any ProcessInspecting
    private let terminator: ProcessTerminator
    private let runner: ManagedProcessRunner
    private let store: any ConfigurationPersisting
    private let inference = LaunchInferenceEngine()

    // MARK: State
    private(set) var listeners: [ListenerEntry] = []
    private(set) var configurations: [LaunchConfiguration] = []
    private(set) var managedStates: [UUID: ManagedState] = [:]
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    private(set) var scanError: String?
    var filter: ListFilter
    var searchText = ""
    var notice: Notice?
    var stopRequest: StopRequest?
    private(set) var isPopoverVisible = false
    /// PIDs that received SIGTERM and were still alive at the next scan.
    private(set) var stubbornPIDs: Set<pid_t> = []
    private var stopRequests: [pid_t: Date] = [:]
    private var refreshTask: Task<Void, Never>?
    private var hasStarted = false
    private(set) var searchPath: [String] = []
    /// Configuration the Settings window should open in its editor.
    var pendingEditor: LaunchConfiguration?
    var selectedSettingsTab: SettingsTab = .general

    static let shared = AppModel()
    private let log = Logger(subsystem: "com.karrtopelka.whatport", category: "lifecycle")

    init(settings: AppSettings = AppSettings(),
         discovery: DiscoveryService = DiscoveryService(),
         inspector: any ProcessInspecting = SystemProcessInspector(),
         terminator: ProcessTerminator = ProcessTerminator(),
         store: any ConfigurationPersisting = JSONConfigurationStore(fileURL: JSONConfigurationStore.defaultURL()),
         logsDirectory: URL = AppPaths.logsDirectory) {
        self.settings = settings
        self.discovery = discovery
        self.inspector = inspector
        self.terminator = terminator
        self.store = store
        self.runner = ManagedProcessRunner(inspector: inspector, terminator: terminator, logsDirectory: logsDirectory)
        self.filter = settings.defaultFilter
        runner.onExit = { [weak self] id, status in
            self?.apply(.exited(code: status), to: id)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        loadConfigurations()
        adoptSurvivingInstances()
        Task {
            await refreshSearchPath()
            await refresh()
            restartTimer()
        }
    }

    func refreshSearchPath() async {
        let provider = SearchPathProvider(extraPaths: settings.extraSearchPathList)
        let path = await provider.resolveSearchPath()
        searchPath = path
        runner.searchPath = path
    }

    func setPopoverVisible(_ visible: Bool) {
        guard visible != isPopoverVisible else { return }
        isPopoverVisible = visible
        if visible {
            Task { await refresh() }
        }
        restartTimer()
    }

    func restartTimer() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.isPopoverVisible ? self.settings.refreshInterval : self.settings.backgroundRefreshInterval
                try? await Task.sleep(for: .seconds(max(1, interval)))
                guard !Task.isCancelled else { return }
                guard self.settings.autoRefresh else { continue }
                let hasBusyManaged = self.managedStates.values.contains { $0.isBusy || $0.isRunning }
                if self.isPopoverVisible || self.settings.showCountInMenuBar || hasBusyManaged || !self.stopRequests.isEmpty {
                    await self.refresh()
                }
            }
        }
    }

    // MARK: - Scanning

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            let result = try await discovery.discover()
            listeners = result.listeners
            lastScan = result.scannedAt
            scanError = nil
            reconcileManagedStates()
            updateStubbornPIDs()
        } catch {
            scanError = error.localizedDescription
        }
    }

    private func updateStubbornPIDs() {
        let alive = Set(listeners.map(\.process.pid))
        var stubborn: Set<pid_t> = []
        for (pid, date) in stopRequests {
            if !alive.contains(pid), !inspector.isAlive(pid: pid) {
                stopRequests[pid] = nil
            } else if Date().timeIntervalSince(date) > 3 {
                stubborn.insert(pid)
            }
        }
        stubbornPIDs = stubborn
    }

    private func reconcileManagedStates() {
        for configuration in configurations {
            guard let state = managedStates[configuration.id] else { continue }
            switch state {
            case .running(let identity), .stopping(let identity):
                if inspector.verify(identity) == nil, runner.instance(for: configuration.id) == nil {
                    apply(.disappeared, to: configuration.id)
                }
            default:
                break
            }
        }
    }

    // MARK: - Derived data

    var developmentCount: Int { listeners.filter { $0.category == .development }.count }

    var allGroups: [ProjectGroup] { buildGroups(from: listeners) }

    /// Groups after the current filter, visibility settings and search.
    var visibleGroups: [ProjectGroup] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return allGroups.filter { group in
            switch filter {
            case .development:
                guard group.category == .development || group.isManaged else { return false }
                if group.configuration != nil, group.listeners.isEmpty, let state = group.managedState, !state.isBusy, !state.isRunning {
                    if case .failed = state { } else { return false }
                }
            case .all:
                if group.category == .system && !settings.showSystemProcesses { return false }
                if group.category == .unknown && !settings.showUnidentifiedProcesses { return false }
                if group.listeners.isEmpty { return false }
            case .managed:
                guard group.isManaged else { return false }
            }
            guard !query.isEmpty else { return true }
            let haystack = ([group.title, group.subtitle, group.project?.rootPath ?? ""] + group.allPorts.map { String($0.port) } + group.pids.map { String($0) })
                .joined(separator: " ").lowercased()
            return haystack.contains(query)
        }
    }

    var hiddenCount: Int {
        allGroups.count - visibleGroups.count
    }

    func group(withID id: String) -> ProjectGroup? {
        allGroups.first { $0.id == id }
    }

    func configuration(for listener: ListenerEntry) -> LaunchConfiguration? {
        configurations.first { configuration in
            if let project = listener.project, project.rootPath == configuration.projectRootPath { return true }
            if let managedPID = managedStates[configuration.id]?.identity?.pid {
                return listener.process.pid == managedPID || listener.ancestry.contains { $0.pid == managedPID }
            }
            return false
        }
    }

    func suggestion(for listener: ListenerEntry) -> LaunchSuggestion? {
        inference.infer(for: listener)
    }

    func managedState(for configuration: LaunchConfiguration) -> ManagedState {
        managedStates[configuration.id] ?? .stopped
    }

    private func buildGroups(from listeners: [ListenerEntry]) -> [ProjectGroup] {
        var groups: [ProjectGroup] = []
        var indexByKey: [String: Int] = [:]

        for listener in listeners {
            let configuration = configuration(for: listener)
            let key = configuration.map { "config:" + $0.id.uuidString } ?? listener.groupKey
            if let index = indexByKey[key] {
                groups[index].listeners.append(listener)
                if groups[index].category != .development, listener.category == .development { groups[index].category = .development }
                continue
            }
            let title = configuration?.displayName ?? listener.displayName
            let subtitle: String
            if let project = listener.project {
                let projectSubtitle = project.subtitle(runtime: listener.runtime)
                subtitle = projectSubtitle.isEmpty ? (listener.runtime?.displayName ?? listener.process.executableName) : projectSubtitle
            } else if let runtime = listener.runtime {
                subtitle = "\(runtime.displayName) · PID \(listener.process.pid)"
            } else {
                subtitle = listener.process.executablePath.map { Self.abbreviate($0) } ?? "PID \(listener.process.pid)"
            }
            let group = ProjectGroup(
                id: key,
                title: title,
                subtitle: subtitle,
                symbolName: listener.project?.symbolName ?? listener.runtime?.symbolName ?? (listener.category == .system ? "gearshape.fill" : listener.category == .application ? "app.fill" : "questionmark.circle"),
                project: listener.project,
                listeners: [listener],
                category: listener.category,
                configuration: configuration,
                managedState: configuration.map { managedState(for: $0) }
            )
            indexByKey[key] = groups.count
            groups.append(group)
        }

        // Managed projects that are not currently listening.
        for configuration in configurations where indexByKey["config:" + configuration.id.uuidString] == nil {
            let state = managedState(for: configuration)
            let identifier = ProjectIdentifier()
            let project = identifier.identify(directory: configuration.projectRootPath)
            groups.append(ProjectGroup(
                id: "config:" + configuration.id.uuidString,
                title: configuration.displayName,
                subtitle: project?.subtitle.isEmpty == false ? project!.subtitle : configuration.commandLine,
                symbolName: project?.symbolName ?? "shippingbox.fill",
                project: project,
                listeners: [],
                category: .development,
                configuration: configuration,
                managedState: state
            ))
        }
        return groups
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Stopping discovered processes

    /// Entry point from the UI. Shows a confirmation when the user wants one.
    func requestStop(_ group: ProjectGroup, force: Bool = false) {
        if settings.confirmBeforeStop || force {
            stopRequest = StopRequest(group: group, force: force)
        } else {
            Task { await stop(group, force: force) }
        }
    }

    /// Runs the pending stop request (the inline confirmation's Stop button).
    func confirmStop() {
        guard let request = stopRequest else { return }
        stopRequest = nil
        Task { await stop(request.group, force: request.force) }
    }

    func cancelStop() {
        stopRequest = nil
    }

    /// Processes that will be signalled for a group: the runner parent first,
    /// then intermediate related processes, then each listener.
    func processesToStop(for group: ProjectGroup, listenersOnly: Bool = false) -> [ProcessSnapshot] {
        var result: [ProcessSnapshot] = []
        var seen: Set<pid_t> = []
        for listener in group.listeners {
            if !listenersOnly {
                let related = DiscoveryService.relatedAncestors(of: listener.process, ancestry: listener.ancestry, projectRoot: listener.project?.rootPath)
                for parent in related.reversed() where seen.insert(parent.pid).inserted { result.append(parent) }
            }
            if seen.insert(listener.process.pid).inserted { result.append(listener.process) }
        }
        return result
    }

    func stop(_ group: ProjectGroup, force: Bool = false, listenersOnly: Bool = false) async {
        if let configuration = group.configuration, let state = managedStates[configuration.id], state.isRunning || state.isBusy {
            await stopManaged(configuration, force: force)
            return
        }
        var failures: [String] = []
        for process in processesToStop(for: group, listenersOnly: listenersOnly) {
            do {
                try terminator.terminate(process.identity, force: force)
                stopRequests[process.pid] = force ? nil : Date()
                log.info("Sent \(force ? "SIGKILL" : "SIGTERM", privacy: .public) to \(process.executableName, privacy: .public) (\(process.pid))")
            } catch TerminationError.notRunning {
                continue
            } catch {
                log.error("Stopping \(process.executableName, privacy: .public) (\(process.pid)) failed: \(error.localizedDescription, privacy: .public)")
                failures.append("\(process.executableName): \(error.localizedDescription)")
            }
        }
        if failures.isEmpty {
            notice = Notice(kind: .success, message: force ? "Force-stopped \(group.title)." : "Sent stop signal to \(group.title).")
        } else {
            notice = Notice(kind: .error, message: failures.joined(separator: "\n"))
        }
        try? await Task.sleep(for: .milliseconds(force ? 200 : 700))
        await refresh()
    }

    // MARK: - Managed projects

    func loadConfigurations() {
        do {
            configurations = try store.load()
        } catch {
            notice = Notice(kind: .error, message: "Could not read saved projects: \(error.localizedDescription)")
        }
        for configuration in configurations where managedStates[configuration.id] == nil {
            managedStates[configuration.id] = .stopped
        }
    }

    private func persistConfigurations() {
        do {
            try store.save(configurations)
        } catch {
            notice = Notice(kind: .error, message: "Could not save projects: \(error.localizedDescription)")
        }
    }

    private func adoptSurvivingInstances() {
        for configuration in configurations {
            guard let last = configuration.lastInstance, let live = inspector.verify(last) else { continue }
            managedStates[configuration.id] = .running(live.identity)
        }
    }

    @discardableResult
    func save(_ configuration: LaunchConfiguration) -> LaunchConfiguration {
        var updated = configuration
        updated.updatedAt = Date()
        if let index = configurations.firstIndex(where: { $0.id == configuration.id }) {
            configurations[index] = updated
        } else {
            configurations.append(updated)
            managedStates[updated.id] = .stopped
        }
        persistConfigurations()
        return updated
    }

    func delete(_ configuration: LaunchConfiguration) {
        configurations.removeAll { $0.id == configuration.id }
        managedStates[configuration.id] = nil
        persistConfigurations()
        try? FileManager.default.removeItem(at: runner.logURL(for: configuration.id))
    }

    private func apply(_ event: ManagedEvent, to id: UUID) {
        let current = managedStates[id] ?? .stopped
        guard let next = ManagedStateMachine.next(from: current, on: event) else { return }
        managedStates[id] = next
        if case .running(let identity) = next, let index = configurations.firstIndex(where: { $0.id == id }) {
            configurations[index].lastInstance = identity
            persistConfigurations()
        }
        if case .stopped = next, let index = configurations.firstIndex(where: { $0.id == id }), configurations[index].lastInstance != nil {
            configurations[index].lastInstance = nil
            persistConfigurations()
        }
        if case .failed(let message) = next {
            notice = Notice(kind: .error, message: "\(configurations.first { $0.id == id }?.displayName ?? "Project"): \(message)")
        }
    }

    private var occupiedPorts: [Int: ProcessSnapshot] {
        var map: [Int: ProcessSnapshot] = [:]
        for listener in listeners {
            for port in listener.ports { map[port.port] = listener.process }
        }
        return map
    }

    func startManaged(_ configuration: LaunchConfiguration) async {
        let state = managedState(for: configuration)
        guard !state.isRunning, !state.isBusy else { return }
        await refresh()
        apply(.startRequested, to: configuration.id)
        await launch(configuration)
    }

    private func launch(_ configuration: LaunchConfiguration) async {
        if searchPath.isEmpty { await refreshSearchPath() }
        do {
            let identity = try await runner.start(configuration, occupiedPorts: occupiedPorts)
            log.info("Started \(configuration.displayName, privacy: .public) as pid \(identity.pid)")
            apply(.launched(identity), to: configuration.id)
            notice = Notice(kind: .success, message: "Started \(configuration.displayName).")
            try? await Task.sleep(for: .milliseconds(800))
            await refresh()
        } catch {
            log.error("Starting \(configuration.displayName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            apply(.launchFailed(error.localizedDescription), to: configuration.id)
        }
    }

    /// Stops the managed instance, or — when the project is running outside
    /// WhatPort — the discovered processes for it.
    func stopManaged(_ configuration: LaunchConfiguration, force: Bool = false) async {
        let state = managedState(for: configuration)
        if let identity = state.identity {
            apply(.stopRequested, to: configuration.id)
            do {
                let exited = try await runner.stop(identity, configurationID: configuration.id, force: force)
                if exited {
                    apply(.exited(code: 0), to: configuration.id)
                } else {
                    stopRequests[identity.pid] = Date()
                    notice = Notice(kind: .info, message: "\(configuration.displayName) has not exited yet. Use Force Stop if it hangs.")
                }
            } catch {
                apply(.disappeared, to: configuration.id)
                notice = Notice(kind: .error, message: error.localizedDescription)
            }
            await refresh()
        } else if state.isBusy {
            apply(.stopRequested, to: configuration.id)
        }
    }

    /// Restart: stop whatever is running for the project (managed instance or
    /// discovered processes), wait for the ports to free up, then launch.
    func restart(_ configuration: LaunchConfiguration) async {
        let state = managedState(for: configuration)
        guard !state.isBusy else { return }
        if let identity = state.identity {
            apply(.restartRequested, to: configuration.id)
            do {
                let exited = try await runner.stop(identity, configurationID: configuration.id, force: false, timeout: 8)
                if !exited {
                    _ = try? await runner.stop(identity, configurationID: configuration.id, force: true, timeout: 3)
                }
            } catch {
                // already gone — fine
            }
        } else {
            // Discovered instance of a saved project.
            let group = allGroups.first { $0.configuration?.id == configuration.id }
            if let group, !group.listeners.isEmpty {
                apply(.startRequested, to: configuration.id)
                let targets = processesToStop(for: group)
                for process in targets { try? terminator.terminate(process.identity) }
                for process in targets {
                    let exited = await terminator.waitForExit(process.identity, timeout: 8)
                    if !exited { try? terminator.terminate(process.identity, force: true) }
                }
            } else {
                apply(.startRequested, to: configuration.id)
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        await refresh()
        await launch(configuration)
    }

    func logTail(for configuration: LaunchConfiguration) -> String {
        runner.readLogTail(for: configuration.id)
    }

    func logURL(for configuration: LaunchConfiguration) -> URL {
        runner.logURL(for: configuration.id)
    }

    // MARK: - Misc actions

    func open(_ port: ListeningPort) {
        guard let url = port.localURL else { return }
        NSWorkspace.shared.open(url)
    }

    func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = Notice(kind: .info, message: "Copied \(label).")
    }

    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func quit() {
        NSApp.terminate(nil)
    }
}

enum SettingsTab: String, Hashable, Sendable {
    case general, projects, about
}

enum DurationFormatter {
    /// "2h 14m", "38m", "45s", "3d 2h".
    static func compact(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        let days = hours / 24
        return "\(days)d \(hours % 24)h"
    }
}
