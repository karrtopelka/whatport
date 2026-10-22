import SwiftUI

/// One project (or lone process) in the main list.
struct ProjectGroupRow: View {
    var group: ProjectGroup
    var showDetails: () -> Void
    @Environment(AppModel.self) private var model
    @State private var isHovered = false

    private var status: StatusBadge.Status {
        if let state = group.managedState {
            switch state {
            case .starting: return .starting
            case .stopping: return .stopping
            case .restarting: return .restarting
            case .failed: return .failed
            case .running: return group.pids.contains { model.stubbornPIDs.contains($0) } ? .stubborn : .managed
            case .stopped: return group.listeners.isEmpty ? .stopped : .detected
            }
        }
        if group.pids.contains(where: { model.stubbornPIDs.contains($0) }) { return .stubborn }
        return .running
    }

    private var uptime: String? {
        guard let start = group.startTime else { return nil }
        return DurationFormatter.compact(Date().timeIntervalSince(start))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProjectIcon(symbolName: group.symbolName, category: group.category)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(group.title)
                        .font(.system(.body, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if group.isManaged {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .help("Managed project — WhatPort knows how to start it")
                            .accessibilityLabel("Managed")
                    }
                    Spacer(minLength: 4)
                    StatusBadge(status: status).fixedSize()
                }
                Text(group.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    ForEach(group.allPorts.prefix(4)) { port in
                        PortChip(port: port) {
                            model.open(port)
                        } copyPort: {
                            model.copy(String(port.port), label: "port \(port.port)")
                        } copyURL: {
                            model.copy(port.localURL?.absoluteString ?? "", label: "URL")
                        }
                    }
                    if group.allPorts.count > 4 {
                        Text("+\(group.allPorts.count - 4)").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let pid = group.primaryListener?.process.pid {
                        Text(group.listeners.count > 1 ? "\(group.listeners.count) processes" : "PID \(String(pid))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if let uptime {
                        Text("·").foregroundStyle(.quaternary).font(.caption2)
                        Label(uptime, systemImage: "clock")
                            .labelStyle(.titleOnly)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                            .help("Running for \(uptime)")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }

            actions
                .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03), in: .rect(cornerRadius: 10))
        .contentShape(.rect(cornerRadius: 10))
        .onHover { isHovered = $0 }
        .onTapGesture(perform: showDetails)
        .contextMenu { contextMenu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.title), \(group.subtitle), ports \(group.allPorts.map { String($0.port) }.joined(separator: ", "))")
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        let isBusy = group.managedState?.isBusy ?? false
        HStack(spacing: 2) {
            if let port = group.allPorts.first {
                Button { model.open(port) } label: { Image(systemName: "safari") }
                    .help("Open http://\(port.preferredHost):\(port.port) in your browser")
                    .accessibilityLabel("Open in browser")
            }

            if let configuration = group.configuration {
                if group.listeners.isEmpty, !(group.managedState?.isRunning ?? false) {
                    Button { Task { await model.startManaged(configuration) } } label: { Image(systemName: "play.fill") }
                        .disabled(isBusy)
                        .help("Start \(configuration.commandLine)")
                        .accessibilityLabel("Start")
                } else {
                    Button { Task { await model.restart(configuration) } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(isBusy)
                        .help("Restart with \(configuration.commandLine)")
                        .accessibilityLabel("Restart")
                    stopButton
                }
            } else {
                Button(action: showDetails) { Image(systemName: "arrow.clockwise") }
                    .help(restartHelp)
                    .accessibilityLabel("Configure restart")
                stopButton
            }

            Menu {
                contextMenu
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More actions")
        }
        .buttonStyle(.accessoryBar)
        .controlSize(.small)
        .labelStyle(.iconOnly)
    }

    private var restartHelp: String {
        if let listener = group.primaryListener, model.suggestion(for: listener) != nil {
            return "Restart needs a confirmed launch command. Open details to review the suggested one."
        }
        return "Restart needs a launch command. Open details to configure one."
    }

    @ViewBuilder
    private var stopButton: some View {
        let isBusy = group.managedState?.isBusy ?? false
        let stubborn = group.pids.contains { model.stubbornPIDs.contains($0) }
        if stubborn {
            Button { model.requestStop(group, force: true) } label: { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red) }
                .help("Force stop (SIGKILL) — the process ignored the stop request")
                .accessibilityLabel("Force stop")
        } else {
            Button { model.requestStop(group) } label: { Image(systemName: "stop.fill") }
                .disabled(isBusy)
                .help(stopHelp)
                .accessibilityLabel("Stop")
        }
    }

    private var stopHelp: String {
        let targets = model.processesToStop(for: group)
        if targets.count > 1 {
            return "Stop \(targets.map { "\($0.executableName) (\($0.pid))" }.joined(separator: ", ")) with SIGTERM"
        }
        return "Stop with SIGTERM"
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Details…", action: showDetails)
        Divider()
        if let port = group.allPorts.first, let url = port.localURL {
            Button("Open in Browser") { model.open(port) }
            Button("Copy URL") { model.copy(url.absoluteString, label: "URL") }
            Button("Copy Port") { model.copy(String(port.port), label: "port") }
        }
        if let project = group.project {
            Button("Reveal Project in Finder") { model.reveal(path: project.rootPath) }
        } else if let cwd = group.primaryListener?.process.workingDirectory {
            Button("Reveal Working Directory in Finder") { model.reveal(path: cwd) }
        }
        if let pid = group.primaryListener?.process.pid {
            Button("Copy PID") { model.copy(String(pid), label: "PID") }
        }
        Divider()
        if let configuration = group.configuration {
            Button("Edit Launch Configuration…") { model.pendingEditor = configuration; model.selectedSettingsTab = .projects; SettingsOpener.open() }
            if !group.listeners.isEmpty || (group.managedState?.isRunning ?? false) {
                Button("Restart") { Task { await model.restart(configuration) } }
            } else {
                Button("Start") { Task { await model.startManaged(configuration) } }
            }
        } else {
            Button("Configure Launch…", action: showDetails)
        }
        if !group.listeners.isEmpty {
            Button("Stop") { model.requestStop(group) }
            if model.processesToStop(for: group).count > model.processesToStop(for: group, listenersOnly: true).count {
                Button("Stop Listener Only") { Task { await model.stop(group, listenersOnly: true) } }
            }
            Button("Force Stop…") { model.requestStop(group, force: true) }
        }
    }
}

/// Opens the Settings scene. SwiftUI only exposes this as the `openSettings`
/// environment action, so the root view registers it here and any button,
/// menu item or context menu can call `open()`.
@MainActor
enum SettingsOpener {
    static var action: (() -> Void)?

    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let action {
            action()
        } else {
            // Pre-registration fallback (older AppKit selectors).
            if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
        // The menu bar window may still be key; make sure Settings comes forward.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow?.makeKeyAndOrderFront(nil)
        }
    }

    static var settingsWindow: NSWindow? {
        NSApp.windows.first { window in
            guard let identifier = window.identifier?.rawValue else { return false }
            return identifier.localizedCaseInsensitiveContains("settings") || identifier.localizedCaseInsensitiveContains("preferences")
        }
    }
}
