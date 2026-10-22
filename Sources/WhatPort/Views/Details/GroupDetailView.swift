import SwiftUI

/// Process / project / launch details for one group.
struct GroupDetailView: View {
    var groupID: String
    @Binding var path: [String]
    @Environment(AppModel.self) private var model
    @State private var logTail = ""

    private var group: ProjectGroup? { model.group(withID: groupID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let group {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        launchSection(for: group)
                        ForEach(group.listeners) { listener in
                            processSection(listener, showTitle: group.listeners.count > 1)
                        }
                        if let project = group.project { projectSection(project) }
                        if let configuration = group.configuration { logsSection(configuration) }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 520)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("This process is no longer running.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(40)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { path.removeLast() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.accessoryBar)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back (⌘[)")
            .accessibilityLabel("Back")
            if let group {
                ProjectIcon(symbolName: group.symbolName, category: group.category, size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.title).font(.headline).lineLimit(1)
                    Text(group.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("Details").font(.headline)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    // MARK: Launch

    @ViewBuilder
    private func launchSection(for group: ProjectGroup) -> some View {
        if let configuration = group.configuration {
            SectionCard(title: "Launch Configuration", symbol: "star.fill") {
                DetailRow("Command", configuration.commandLine, monospaced: true)
                DetailRow("Directory", AppModel.abbreviate(configuration.workingDirectory))
                if !configuration.environment.isEmpty {
                    DetailRow("Environment", configuration.environment.keys.sorted().joined(separator: ", "))
                }
                if let state = group.managedState {
                    if case .stopped = state, !group.listeners.isEmpty {
                        DetailRow("State", "Running outside WhatPort (started elsewhere)")
                    } else {
                        DetailRow("State", state.displayName + (state.identity.map { " · PID \($0.pid)" } ?? ""))
                    }
                }
                HStack(spacing: 8) {
                    if group.listeners.isEmpty, !(group.managedState?.isRunning ?? false) {
                        Button("Start") { Task { await model.startManaged(configuration) } }
                            .prominentActionStyle()
                    } else {
                        Button("Restart") { Task { await model.restart(configuration) } }
                            .prominentActionStyle()
                        Button("Stop") { model.requestStop(group) }
                            .secondaryActionStyle()
                    }
                    Button("Edit…") {
                        model.pendingEditor = configuration
                        model.selectedSettingsTab = .projects
                        SettingsOpener.open()
                    }
                    .secondaryActionStyle()
                    Spacer()
                    Button(role: .destructive) { model.delete(configuration) } label: { Image(systemName: "trash") }
                        .buttonStyle(.accessoryBar)
                        .help("Forget this launch configuration")
                }
                .controlSize(.small)
                .disabled(group.managedState?.isBusy ?? false)
                .padding(.top, 4)
            }
        } else if let listener = group.primaryListener, let suggestion = model.suggestion(for: listener) {
            LaunchSuggestionCard(suggestion: suggestion) {
                let saved = model.save(suggestion.configuration)
                Task { await model.restart(saved) }
            } onSave: {
                _ = model.save(suggestion.configuration)
            } onEdit: {
                model.pendingEditor = suggestion.configuration
                model.selectedSettingsTab = .projects
                SettingsOpener.open()
            }
        } else if let listener = group.primaryListener {
            SectionCard(title: "Restart", symbol: "arrow.clockwise") {
                Text("WhatPort could not infer how this process was started, so it cannot restart it. You can stop it, or define a launch command yourself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Configure Launch…") {
                    model.pendingEditor = LaunchConfiguration(
                        displayName: listener.displayName,
                        projectRootPath: listener.project?.rootPath ?? listener.process.workingDirectory ?? NSHomeDirectory(),
                        workingDirectory: listener.process.workingDirectory ?? listener.project?.rootPath ?? NSHomeDirectory(),
                        executable: "",
                        expectedPorts: listener.ports.map(\.port)
                    )
                    model.selectedSettingsTab = .projects
                    SettingsOpener.open()
                }
                .secondaryActionStyle()
                .controlSize(.small)
            }
        }
    }

    // MARK: Process

    private func processSection(_ listener: ListenerEntry, showTitle: Bool) -> some View {
        let process = listener.process
        return SectionCard(title: showTitle ? "Process · \(process.executableName)" : "Process", symbol: "cpu") {
            DetailRow("PID", String(process.pid))
            if let parent = process.parentPID { DetailRow("Parent PID", String(parent)) }
            DetailRow("Ports", listener.ports.map { ":\($0.port) (\($0.addressSummary))" }.joined(separator: ", "))
            DetailRow("User", process.userName ?? process.uid.map { "uid \($0)" } ?? "Unavailable")
            DetailRow("Executable", process.executablePath.map(AppModel.abbreviate) ?? "Unavailable", monospaced: true)
            DetailRow("Arguments", process.arguments.map { ShellWords.join($0) } ?? "Not accessible (owned by another user)", monospaced: true)
            DetailRow("Directory", process.workingDirectory.map(AppModel.abbreviate) ?? "Not accessible")
            if let start = process.startTime {
                DetailRow("Started", start.formatted(date: .abbreviated, time: .shortened) + " · " + DurationFormatter.compact(Date().timeIntervalSince(start)) + " ago")
            }
            if let script = process.environmentHints.lifecycleEvent {
                DetailRow("Script", "\(script) via \(process.environmentHints.packageManager?.rawValue ?? "package manager")")
            }
            DetailRow("Category", listener.category.displayName)
            if !listener.ancestry.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Parents").font(.caption).foregroundStyle(.secondary)
                    ForEach(listener.ancestry) { parent in
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.quaternary)
                            Text(parent.executableName).font(.caption.monospaced())
                            Text(String(parent.pid)).font(.caption2).foregroundStyle(.tertiary)
                            if let args = parent.arguments, args.count > 1 {
                                Text(args.dropFirst().joined(separator: " ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            if listener.runnerParent?.pid == parent.pid {
                                Text("runner").font(.caption2).padding(.horizontal, 4).background(Color.accentColor.opacity(0.15), in: .capsule)
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
            HStack(spacing: 8) {
                if let cwd = process.workingDirectory {
                    Button("Reveal Directory") { model.reveal(path: cwd) }
                }
                Button("Copy PID") { model.copy(String(process.pid), label: "PID") }
                if let command = process.commandLine {
                    Button("Copy Command") { model.copy(command, label: "command line") }
                }
            }
            .buttonStyle(.link)
            .font(.caption)
            .padding(.top, 2)
        }
    }

    // MARK: Project

    private func projectSection(_ project: ProjectInfo) -> some View {
        SectionCard(title: "Project", symbol: "folder") {
            DetailRow("Name", project.name)
            DetailRow("Root", AppModel.abbreviate(project.rootPath))
            if let workspace = project.workspaceRootPath, project.isMonorepoPackage {
                DetailRow("Workspace", "\(project.workspaceName ?? "") · \(AppModel.abbreviate(workspace))")
            }
            if let framework = project.framework { DetailRow("Framework", framework.displayName) }
            if let runtime = project.runtime { DetailRow("Runtime", runtime.displayName) }
            if let manager = project.packageManager { DetailRow("Package manager", manager.rawValue) }
            DetailRow("Detected via", project.markers.joined(separator: ", "))
            if !project.scripts.isEmpty {
                DetailRow("Scripts", project.scripts.keys.sorted().prefix(8).joined(separator: ", ") + (project.scripts.count > 8 ? "…" : ""))
            }
            Button("Reveal in Finder") { model.reveal(path: project.rootPath) }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    // MARK: Logs

    private func logsSection(_ configuration: LaunchConfiguration) -> some View {
        SectionCard(title: "Output", symbol: "text.alignleft") {
            if logTail.isEmpty {
                Text("No output captured yet. Output is only captured for instances started by WhatPort.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    Text(logTail)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            HStack {
                Button("Refresh") { logTail = model.logTail(for: configuration) }
                Button("Reveal Log File") { model.reveal(path: model.logURL(for: configuration).path) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .task(id: configuration.id) {
            logTail = model.logTail(for: configuration)
        }
    }
}

// MARK: - Building blocks

struct SectionCard<Content: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 10))
    }
}

struct DetailRow: View {
    var label: String
    var value: String
    var monospaced: Bool

    init(_ label: String, _ value: String, monospaced: Bool = false) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
