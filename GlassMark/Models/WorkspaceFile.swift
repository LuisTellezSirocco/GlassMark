import Foundation

struct WorkspaceFile: Identifiable, Equatable, Hashable, Sendable {
    let id: URL
    let url: URL
    let name: String
    let relativePath: String
    let kind: Kind
    var children: [WorkspaceFile]?

    enum Kind: String, Equatable, Hashable {
        case folder
        case markdown
        case text
        case other
    }

    var isDirectory: Bool {
        kind == .folder
    }

    var isEditable: Bool {
        kind == .markdown || kind == .text
    }

    /// Whether `source` can be dropped onto this item. An item cannot be moved
    /// onto itself, and a folder cannot be moved inside one of its own
    /// descendants (which would detach the subtree from the workspace).
    func canAcceptMove(of source: WorkspaceFile) -> Bool {
        source.url != url && !url.path.hasPrefix(source.url.path + "/")
    }

    init(url: URL, rootURL: URL, kind: Kind, children: [WorkspaceFile]? = nil) {
        self.id = url
        self.url = url
        self.name = url.lastPathComponent.isEmpty ? rootURL.lastPathComponent : url.lastPathComponent
        self.relativePath = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
        self.kind = kind
        self.children = children
    }
}

/// Built once per file-tree change, rather than flattening, sorting and
/// lowercasing the entire workspace for every search keystroke.
struct WorkspaceSearchIndex {
    private struct Entry {
        let file: WorkspaceFile
        let text: String
    }
    private let entries: [Entry]

    init(files: [WorkspaceFile]) {
        var editable: [WorkspaceFile] = []
        func collect(_ nodes: [WorkspaceFile]) {
            for file in nodes {
                if file.isEditable { editable.append(file) }
                if let children = file.children { collect(children) }
            }
        }
        collect(files)
        editable.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        entries = editable.map { Entry(file: $0, text: "\($0.name) \($0.relativePath)".lowercased()) }
    }

    func results(for query: String) -> [WorkspaceFile] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries.prefix(30).map(\.file) }
        let terms = trimmed.lowercased().split(separator: " ").map(String.init)
        var matches: [WorkspaceFile] = []
        for entry in entries where terms.allSatisfy({ entry.text.contains($0) }) {
            matches.append(entry.file)
            if matches.count == 40 { break }
        }
        return matches
    }
}
