import AppKit
import SwiftUI

/// Form for creating or editing a launch configuration.
struct LaunchConfigurationEditor: View {
    @State private var draft: LaunchConfiguration
    @State private var commandText: String
    @State private var environmentText: String
    @State private var portsText: String
    @State private var validationError: String?
    var onSave: (LaunchConfiguration) -> Void
    var onCancel: () -> Void

    init(configuration: LaunchConfiguration, onSave: @escaping (LaunchConfiguration) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: configuration)
        _commandText = State(initialValue: configuration.executable.isEmpty ? "" : configuration.commandLine)
        _environmentText = State(initialValue: configuration.environment.keys.sorted().map { "\($0)=\(configuration.environment[$0] ?? "")" }.joined(separator: "\n"))
        _portsText = State(initialValue: configuration.expectedPorts.map(String.init).joined(separator: ", "))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.displayName, prompt: Text("my-dashboard"))
                    LabeledContent("Directory") {
                        HStack {
                            TextField("", text: $draft.workingDirectory, prompt: Text("~/Projects/my-dashboard"))
                                .labelsHidden()
                            Button("Choose…") { chooseDirectory() }
                        }
                    }
                    TextField("Command", text: $commandText, prompt: Text("bun run dev"))
                        .font(.body.monospaced())
                    Text("The command runs directly, without a shell. Use quotes for arguments containing spaces. Commands like bun, npm or pnpm are resolved via your login shell's PATH.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Optional") {
                    TextField("Expected ports", text: $portsText, prompt: Text("3000, 3001"))
                    LabeledContent("Environment") {
                        TextEditor(text: $environmentText)
                            .font(.body.monospaced())
                            .frame(height: 70)
                            .overlay(alignment: .topLeading) {
                                if environmentText.isEmpty {
                                    Text("PORT=3000\nNODE_ENV=development").font(.body.monospaced()).foregroundStyle(.quaternary).padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                                }
                            }
                    }
                }
                if let validationError {
                    Section {
                        Label(validationError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 520, height: 460)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !draft.workingDirectory.isEmpty { panel.directoryURL = URL(fileURLWithPath: (draft.workingDirectory as NSString).expandingTildeInPath) }
        if panel.runModal() == .OK, let url = panel.url {
            draft.workingDirectory = url.path
            if draft.displayName.isEmpty { draft.displayName = url.lastPathComponent }
        }
    }

    private func save() {
        do {
            let words = try ShellWords.split(commandText)
            guard let executable = words.first, !executable.isEmpty else {
                validationError = "Enter the command that starts the server."
                return
            }
            let directory = (draft.workingDirectory.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                validationError = "The directory does not exist."
                return
            }
            var environment: [String: String] = [:]
            for line in environmentText.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                guard let equals = trimmed.firstIndex(of: "=") else {
                    validationError = "Environment lines must look like KEY=value."
                    return
                }
                environment[String(trimmed[..<equals])] = String(trimmed[trimmed.index(after: equals)...])
            }
            let ports = portsText.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }.filter { $0 > 0 && $0 <= 65535 }
            var result = draft
            result.displayName = draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty ? (directory as NSString).lastPathComponent : draft.displayName
            result.workingDirectory = directory
            if result.projectRootPath.isEmpty || !directory.hasPrefix(result.projectRootPath) { result.projectRootPath = directory }
            result.executable = executable
            result.arguments = Array(words.dropFirst())
            result.environment = environment
            result.expectedPorts = ports
            onSave(result)
        } catch {
            validationError = error.localizedDescription
        }
    }
}
