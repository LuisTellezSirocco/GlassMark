import SwiftUI

struct QuickOpenView: View {
    let files: [WorkspaceFile]
    let onOpen: (WorkspaceFile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var searchIndex = WorkspaceSearchIndex(files: [])
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let results = searchIndex.results(for: query)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search files by name or path…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onSubmit {
                        openFirstResult()
                    }
            }
            .padding(14)

            Divider()

            if results.isEmpty {
                ContentUnavailableView("No Files Found", systemImage: "doc.text.magnifyingglass")
                    .frame(height: 220)
            } else {
                List(results) { file in
                    Button {
                        open(file)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.name)
                                .font(.headline)
                                .lineLimit(1)

                            Text(file.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 620, height: 460)
        .onAppear {
            isSearchFocused = true
        }
        .onChange(of: files, initial: true) { _, files in
            searchIndex = WorkspaceSearchIndex(files: files)
        }
    }

    private func openFirstResult() {
        guard let firstResult = searchIndex.results(for: query).first else { return }
        open(firstResult)
    }

    private func open(_ file: WorkspaceFile) {
        onOpen(file)
        dismiss()
    }
}
