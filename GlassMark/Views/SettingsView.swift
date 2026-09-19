import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var preferencesStore: PreferencesStore

    @State private var selection: SettingsTab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            EditorSettingsView()
                .tabItem { Label("Editor", systemImage: "square.and.pencil") }
                .tag(SettingsTab.editor)
            PreviewSettingsView()
                .tabItem { Label("Preview", systemImage: "doc.richtext") }
                .tag(SettingsTab.preview)
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(SettingsTab.ai)
        }
        .frame(width: 460)
        .onAppear(perform: applyRequestedTab)
        .onChange(of: preferencesStore.requestedSettingsTab) {
            applyRequestedTab()
        }
    }

    private func applyRequestedTab() {
        guard let requested = preferencesStore.requestedSettingsTab else { return }
        selection = requested
        preferencesStore.requestedSettingsTab = nil
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var preferencesStore: PreferencesStore

    var body: some View {
        Form {
            Picker("Appearance", selection: $preferencesStore.appearancePreference) {
                ForEach(AppearancePreference.allCases) { preference in
                    Text(preference.title).tag(preference)
                }
            }

            Picker("Default View", selection: $preferencesStore.viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Toggle("Autosave", isOn: $preferencesStore.autosaveEnabled)
            Text("When on, edits are written to disk automatically a moment after you stop typing. Manual save (⌘S) is always available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

private struct EditorSettingsView: View {
    @EnvironmentObject private var preferencesStore: PreferencesStore

    var body: some View {
        Form {
            Toggle("Focus mode", isOn: $preferencesStore.focusModeEnabled)
            Text("Dims all but the paragraph you're editing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Typewriter scrolling", isOn: $preferencesStore.typewriterModeEnabled)
            Text("Keeps the line you're editing vertically centered.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Line numbers", isOn: $preferencesStore.showLineNumbers)
            Text("Shows each line's number in a faint monospaced gutter beside the text. Wrapped lines keep a single number.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

private struct PreviewSettingsView: View {
    @EnvironmentObject private var preferencesStore: PreferencesStore

    var body: some View {
        Form {
            Picker("Theme", selection: $preferencesStore.previewTheme) {
                ForEach(PreviewTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }

            Section("Custom CSS") {
                TextEditor(text: $preferencesStore.customPreviewCSS)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                    .border(Color.secondary.opacity(0.3))
                Text("Applied on top of the selected theme. Targets standard elements (h1, p, code, table…).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}

private struct AISettingsView: View {
    @EnvironmentObject private var preferencesStore: PreferencesStore
    @EnvironmentObject private var credentialStore: GeminiCredentialStore

    @State private var keyField = ""
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            Toggle("Enable AI editing", isOn: $preferencesStore.aiEditingEnabled)
            Text("Adds “Edit with Gemini…” (⌃⌘I) to the editor. Nothing is sent until you run it on a selection.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Section("Model") {
                LabeledContent("Model") {
                    HStack(spacing: 6) {
                        TextField("Model ID", text: $preferencesStore.aiModel)
                            .textFieldStyle(.roundedBorder)
                        Menu {
                            ForEach(AIModelCatalog.presets) { preset in
                                Button(preset.title) { preferencesStore.aiModel = preset.id }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                Text("Any Interactions API model ID works. Presets are verified choices; default: \(AIModelCatalog.defaultModelID).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Gemini API key") {
                SecureField("API key", text: $keyField)
                HStack {
                    Button("Save key") {
                        credentialStore.save(key: keyField)
                        keyField = ""
                    }
                    .disabled(keyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Remove key") {
                        credentialStore.remove()
                    }

                    Spacer()
                    credentialStatus
                }
                if let error = credentialStore.lastErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Stored in the macOS Keychain and sent only to generativelanguage.googleapis.com. Never written to preferences, logs, or the repository.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Connection") {
                HStack {
                    Button("Test connection") { testConnection() }
                        .disabled(
                            !credentialStore.isConfigured
                                || !preferencesStore.aiEditingEnabled
                                || testState == .running
                        )
                    if testState == .running {
                        ProgressView().controlSize(.small)
                    }
                    testStatus
                }
                Text("Sends a tiny synthetic request with the selected model and may consume a small amount of quota.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Link("Get an API key in Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                Link("Gemini API terms", destination: URL(string: "https://ai.google.dev/gemini-api/terms")!)
            }
        }
        .padding(24)
        .onAppear { credentialStore.refresh() }
    }

    @ViewBuilder
    private var credentialStatus: some View {
        switch credentialStore.state {
        case .available(.keychain):
            Label("Configured", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .available(.developmentEnvironment):
            Label("Development key (environment)", systemImage: "hammer.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .denied:
            Label("Keychain denied", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        case .missing, .unknown:
            Label("Not configured", systemImage: "circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle, .running:
            EmptyView()
        case .success(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func testConnection() {
        testState = .running
        let model = preferencesStore.aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let result = await credentialStore.testConnection(model: model)
            switch result {
            case .success:
                testState = .success("Connection OK")
            case .failure(let error):
                testState = .failure(error.userMessage)
            }
        }
    }
}
