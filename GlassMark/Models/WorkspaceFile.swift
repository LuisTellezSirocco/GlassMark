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
