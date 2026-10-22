import SwiftUI

/// Root of the menu bar popover.
struct MenuBarRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @State private var path: [String] = []

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            MainListView(path: $path)
                .navigationDestination(for: String.self) { groupID in
                    GroupDetailView(groupID: groupID, path: $path)
                }
        }
        .frame(width: 420)
        // Sheets and alerts dismiss the menu bar window and lose their action,
        // so confirmation is shown inline instead.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let request = model.stopRequest {
                StopConfirmationBanner(request: request)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: model.stopRequest?.id)
        .background(WindowVisibilityObserver { visible in model.setPopoverVisible(visible) })
        .onAppear {
            model.setPopoverVisible(true)
            SettingsOpener.action = { openSettings() }
        }
    }
}

/// Inline destructive confirmation shown at the bottom of the popover.
struct StopConfirmationBanner: View {
    var request: StopRequest
    @Environment(AppModel.self) private var model

    private var targets: [ProcessSnapshot] { model.processesToStop(for: request.group) }

    private var title: String {
        request.force ? "Force stop \(request.group.title)?" : "Stop \(request.group.title)?"
    }

    private var message: String {
        let list = targets.map { "\($0.executableName) (PID \($0.pid))" }.joined(separator: ", ")
        if targets.isEmpty { return "The process is no longer running." }
        return request.force
            ? "SIGKILL will be sent to \(list). Unsaved work in that process is lost."
            : "SIGTERM will be sent to \(list)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: request.force ? "exclamationmark.octagon.fill" : "stop.circle.fill")
                    .foregroundStyle(.red)
                Text(title).font(.callout.weight(.semibold))
                Spacer(minLength: 0)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { model.cancelStop() }
                    .secondaryActionStyle()
                    .keyboardShortcut(.cancelAction)
                Button(request.force ? "Force Stop" : "Stop", role: .destructive) { model.confirmStop() }
                    .prominentActionStyle()
                    .tint(.red)
                    .disabled(targets.isEmpty)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.25)))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Header, filter bar, list and footer.
struct MainListView: View {
    @Binding var path: [String]
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 0
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    private let maxListHeight: CGFloat = 470

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            filterBar
            Divider().padding(.top, 8)
            if let notice = model.notice {
                NoticeBanner(notice: notice) { model.notice = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notice.id) {
                        try? await Task.sleep(for: .seconds(notice.kind == .error ? 8 : 3))
                        if model.notice?.id == notice.id { model.notice = nil }
                    }
            }
            list
            Divider()
            footer
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.visibleGroups.map(\.id))
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.notice?.id)
        .background { hiddenShortcuts }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("WhatPort").font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isScanning {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh (⌘R)")
            .accessibilityLabel("Refresh")
            .disabled(model.isScanning)

            Button {
                model.selectedSettingsTab = .general
                SettingsOpener.open()
            } label: {
                Image(systemName: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .buttonStyle(.accessoryBar)
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var summary: String {
        let listeners = model.listeners
        let projects = Set(listeners.compactMap { $0.project?.rootPath }).count
        let ports = Set(listeners.flatMap { $0.ports.map(\.port) }).count
        if listeners.isEmpty { return model.lastScan == nil ? "Scanning…" : "No listening ports" }
        var text = "\(ports) \(ports == 1 ? "port" : "ports")"
        if projects > 0 { text += " · \(projects) \(projects == 1 ? "project" : "projects")" }
        return text
    }

    // MARK: Filter bar

    private var filterBar: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Picker("Filter", selection: $model.filter) {
                ForEach(ListFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .help("Dev: development servers · All: every listener · Managed: saved projects")

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Search", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($searchFocused)
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 7))
            .frame(maxWidth: 150)
        }
        .padding(.horizontal, 14)
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        let groups = model.visibleGroups
        ScrollView {
            LazyVStack(spacing: 6) {
                if groups.isEmpty {
                    EmptyStateView(
                        filter: model.filter,
                        hasSearch: !model.searchText.isEmpty,
                        hiddenCount: model.hiddenCount,
                        scanError: model.scanError
                    ) {
                        model.filter = .all
                        model.settings.showSystemProcesses = true
                    }
                } else {
                    ForEach(groups) { group in
                        ProjectGroupRow(group: group) { path.append(group.id) }
                    }
                    if model.hiddenCount > 0, model.filter != .managed {
                        Text("\(model.hiddenCount) hidden by filter")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(max(contentHeight, 140), maxListHeight))
        .scrollIndicators(.automatic)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let lastScan = model.lastScan {
                HStack(spacing: 3) {
                    Text("Updated")
                    Text(lastScan, style: .relative)
                    Text("ago")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Quit WhatPort") { model.quit() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q", modifiers: .command)
                .help("Quit (⌘Q). Managed servers keep running.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    /// Invisible buttons that give the popover keyboard shortcuts.
    private var hiddenShortcuts: some View {
        Group {
            Button("") { model.filter = .development }.keyboardShortcut("1", modifiers: .command)
            Button("") { model.filter = .all }.keyboardShortcut("2", modifiers: .command)
            Button("") { model.filter = .managed }.keyboardShortcut("3", modifiers: .command)
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
