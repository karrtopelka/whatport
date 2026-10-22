import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedSettingsTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ProjectsSettingsView()
                .tabItem { Label("Projects", systemImage: "star") }
                .tag(SettingsTab.projects)
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 560)
        .frame(minHeight: 420)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show dev server count in menu bar", isOn: $settings.showCountInMenuBar)
            }
            Section("Refresh") {
                Toggle("Refresh automatically", isOn: $settings.autoRefresh)
                Picker("While the popover is open", selection: $settings.refreshInterval) {
                    Text("Every 2 seconds").tag(2.0)
                    Text("Every 5 seconds").tag(5.0)
                    Text("Every 10 seconds").tag(10.0)
                    Text("Every 30 seconds").tag(30.0)
                }
                .disabled(!settings.autoRefresh)
                Picker("In the background", selection: $settings.backgroundRefreshInterval) {
                    Text("Every 30 seconds").tag(30.0)
                    Text("Every minute").tag(60.0)
                    Text("Every 5 minutes").tag(300.0)
                }
                .disabled(!settings.autoRefresh)
                Text("Background scans only run when the menu bar count is shown or a managed project is running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Visibility") {
                Picker("Default filter", selection: $settings.defaultFilter) {
                    ForEach(ListFilter.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show system and background services in “All”", isOn: $settings.showSystemProcesses)
                Toggle("Show unidentified processes in “All”", isOn: $settings.showUnidentifiedProcesses)
            }
            Section("Safety") {
                Toggle("Ask before stopping a process", isOn: $settings.confirmBeforeStop)
                Text("Force stop (SIGKILL) always asks for confirmation.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Executable search paths") {
                TextField("Extra directories (colon-separated)", text: $settings.extraSearchPaths, prompt: Text("~/.local/bin:/opt/tools/bin"))
                    .onSubmit { Task { await model.refreshSearchPath() } }
                Text("WhatPort looks for commands like bun or pnpm in your login shell's PATH plus common tool directories. Add more here if a project fails to start with “command not found”.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Current search path (\(model.searchPath.count) directories)") {
                    Text(model.searchPath.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.autoRefresh) { model.restartTimer() }
        .onChange(of: settings.refreshInterval) { model.restartTimer() }
        .onChange(of: settings.backgroundRefreshInterval) { model.restartTimer() }
        .onChange(of: settings.extraSearchPaths) { Task { await model.refreshSearchPath() } }
    }
}

struct ProjectsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: LaunchConfiguration?
    @State private var confirmDelete: LaunchConfiguration?

    var body: some View {
        VStack(spacing: 0) {
            if model.configurations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "star").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No managed projects").font(.headline)
                    Text("Save a launch command from a running server's details in the menu bar, or add one here.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.configurations) { configuration in
                        row(configuration)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Divider()
            HStack {
                Button {
                    editing = LaunchConfiguration(displayName: "", projectRootPath: NSHomeDirectory(), workingDirectory: NSHomeDirectory(), executable: "")
                } label: {
                    Label("Add Project", systemImage: "plus")
                }
                Spacer()
                Text("Instances started by WhatPort keep running when WhatPort quits and are re-adopted on relaunch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .sheet(item: $editing) { configuration in
            LaunchConfigurationEditor(configuration: configuration) { saved in
                _ = model.save(saved)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .confirmationDialog("Forget \(confirmDelete?.displayName ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible, presenting: confirmDelete) { configuration in
            Button("Forget", role: .destructive) { model.delete(configuration) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The launch configuration is removed. A running instance is not stopped.")
        }
        .onAppear { consumePendingEditor() }
        .onChange(of: model.pendingEditor) { consumePendingEditor() }
    }

    private func consumePendingEditor() {
        if let pending = model.pendingEditor {
            editing = pending
            model.pendingEditor = nil
        }
    }

    private func row(_ configuration: LaunchConfiguration) -> some View {
        let state = model.managedState(for: configuration)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(configuration.displayName).font(.body.weight(.semibold))
                    StatusBadge(status: badge(for: state))
                }
                Text(configuration.commandLine).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(AppModel.abbreviate(configuration.workingDirectory)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            HStack(spacing: 4) {
                if state.isRunning {
                    Button { Task { await model.restart(configuration) } } label: { Image(systemName: "arrow.clockwise") }.help("Restart")
                    Button { Task { await model.stopManaged(configuration) } } label: { Image(systemName: "stop.fill") }.help("Stop")
                } else {
                    Button { Task { await model.startManaged(configuration) } } label: { Image(systemName: "play.fill") }.help("Start")
                }
                Button { editing = configuration } label: { Image(systemName: "pencil") }.help("Edit")
                Button { confirmDelete = configuration } label: { Image(systemName: "trash") }.help("Forget")
            }
            .buttonStyle(.accessoryBar)
            .disabled(state.isBusy)
        }
        .padding(.vertical, 4)
    }

    private func badge(for state: ManagedState) -> StatusBadge.Status {
        switch state {
        case .stopped: return .stopped
        case .starting: return .starting
        case .running: return .running
        case .stopping: return .stopping
        case .restarting: return .restarting
        case .failed: return .failed
        }
    }
}

struct AboutView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("WhatPort").font(.title2.weight(.semibold))
            Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
            Text("Finds the dev servers listening on your Mac, shows which project they belong to, and lets you stop, start and restart them from the menu bar.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            VStack(alignment: .leading, spacing: 4) {
                Label("Only your own processes are visible: macOS hides other users' sockets without root.", systemImage: "lock")
                Label("Output is captured only for servers WhatPort starts itself.", systemImage: "text.alignleft")
                Label("No network access, telemetry or accounts.", systemImage: "hand.raised")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
