import SwiftUI

/// Floating panel anchored to the captured selection. Shows the instruction
/// field, literal streaming text, the unified diff, and the single
/// Accept / Discard transaction. Never renders the proposal as Markdown.
struct InlineEditPanelView: View {
    @ObservedObject var store: InlineEditStore

    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var credentials: GeminiCredentialStore
    @Environment(\.openSettings) private var openSettings

    @FocusState private var instructionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(12)
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .onAppear { instructionFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            Text("Edit with Gemini")
                .font(.headline)
            Spacer()
            if let scope = store.scope {
                Text(scopeLabel(scope))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func scopeLabel(_ scope: InlineEditScope) -> String {
        let base = scope == .selection ? "Selection" : "Paragraph"
        return "\(base) · \(store.selectionUTF16Count) characters"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle:
            EmptyView()
        case .needsSetup:
            needsSetupView
        case .awaitingInstruction:
            instructionView
        case .streaming:
            streamingView
        case .preparingDiff:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing diff…").font(.callout)
            }
        case .ready:
            proposalView(showActions: true)
        case .unchanged:
            unchangedView
        case .applying:
            applyingView
        case .stale:
            messageView(
                systemImage: "exclamationmark.triangle",
                message: store.errorMessage ?? "The document changed."
            )
        case .failed:
            failureView
        }
    }

    private var needsSetupView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(setupMessage)
                .font(.callout)
            HStack {
                Spacer()
                Button("Close") { store.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Open AI Settings…") { openAISettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var setupMessage: String {
        switch store.setupIssue {
        case .disabled:
            return "AI editing is turned off. Enable it in Settings → AI."
        case .missingKey:
            return "Add your Gemini API key in Settings → AI to start editing with Gemini."
        case nil:
            return "AI editing is not configured yet."
        }
    }

    private var instructionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model: \(store.modelDisplayTitle)")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Describe the change…", text: $store.instruction, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($instructionFocused)
                .onSubmit { store.submit() }

            HStack(alignment: .firstTextBaseline) {
                Text("The selected text is sent to Google's Gemini API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.discard() }
                    .keyboardShortcut(.cancelAction)
                Button("Generate") { store.submit() }
                    .disabled(store.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var streamingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Generating with \(store.modelDisplayTitle)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(store.partialText.isEmpty ? "…" : store.partialText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            HStack {
                Spacer()
                Button("Cancel") { store.discard() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func proposalView(showActions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Proposed changes")
                    .font(.callout.weight(.semibold))
                Spacer()
                if !store.diffExceedsBudget {
                    Text("−\(removedLineCount) +\(insertedLineCount)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if store.diffExceedsBudget {
                fullTextComparison
            } else {
                diffList
            }

            if showActions {
                HStack {
                    Text("The document is unchanged until you accept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Discard") { store.discard() }
                        .keyboardShortcut(.cancelAction)
                    Button("Accept") { store.accept() }
                        .keyboardShortcut(.return, modifiers: [.command])
                }
            }
        }
    }

    private var diffList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.diffRows) { row in
                    DiffRowView(row: row)
                }
            }
        }
        .frame(maxHeight: 260)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private var fullTextComparison: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Too many lines for a diff; compare the full text:")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                comparisonColumn(title: "Original", text: store.target?.original ?? "")
                comparisonColumn(title: "Proposed", text: store.proposal ?? "")
            }
        }
    }

    private func comparisonColumn(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity)
    }

    private var removedLineCount: Int {
        store.diffRows.reduce(0) { $0 + ($1.kind == .removed ? 1 : 0) }
    }

    private var insertedLineCount: Int {
        store.diffRows.reduce(0) { $0 + ($1.kind == .inserted ? 1 : 0) }
    }

    private var unchangedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No changes proposed.", systemImage: "equal.circle")
                .font(.callout)
            HStack {
                Spacer()
                Button("Close") { store.close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var applyingView: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Applying…").font(.callout)
        }
    }

    private var failureView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(store.errorMessage ?? "Something went wrong.")
                    .font(.callout)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if store.proposal != nil {
                proposalView(showActions: false)
            }

            HStack {
                if store.canRetry {
                    Button("Retry") { store.retry() }
                }
                Spacer()
                Button("Close") { store.close() }
                    .keyboardShortcut(.cancelAction)
                if store.proposal != nil {
                    Button("Accept") { store.accept() }
                        .keyboardShortcut(.return, modifiers: [.command])
                }
            }
        }
    }

    private func messageView(systemImage: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(message).font(.callout)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Close") { store.close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func openAISettings() {
        preferences.requestedSettingsTab = .ai
        openSettings()
        store.close()
    }
}

private struct DiffRowView: View {
    let row: DiffRow

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(prefix)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(prefixColor)
                .frame(width: 12, alignment: .trailing)
            Text(displayText)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(background)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var prefix: String {
        switch row.kind {
        case .inserted: return "+"
        case .removed: return "−"
        case .unchanged: return " "
        }
    }

    private var prefixColor: Color {
        switch row.kind {
        case .inserted: return .green
        case .removed: return .red
        case .unchanged: return .secondary
        }
    }

    private var background: Color {
        switch row.kind {
        case .inserted: return .green.opacity(0.12)
        case .removed: return .red.opacity(0.12)
        case .unchanged: return .clear
        }
    }

    private var displayText: String {
        row.hasCarriageReturn ? row.text + "␍" : row.text
    }

    private var accessibilityLabel: String {
        switch row.kind {
        case .inserted:
            return "Added line: \(row.text)"
        case .removed:
            return "Removed line: \(row.text)"
        case .unchanged:
            return row.text
        }
    }
}
