import Foundation

/// Compile with -O alongside MarkdownSyntaxHighlighter.swift and WorkspaceFile.swift.
/// Measures CPU work only; these numbers are not end-to-end UI latency or FPS.
@main
enum PerformanceBenchmark {
    static func timed(_ body: () -> Int) -> (milliseconds: Double, checksum: Int) {
        let start = DispatchTime.now().uptimeNanoseconds
        let checksum = body()
        return (Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, checksum)
    }

    static func main() {
        let original = String(repeating: "A **bold** word and `code` with [link](url).\n", count: 2_000)
        let versions = (0..<80).map { "# Edit \($0)\n" + original }
        let full = timed { versions.reduce(0) { $0 + MarkdownSyntaxHighlighter().tokens(in: $1).count } }
        var cache = MarkdownHighlightCache()
        _ = cache.update("# Initial\n" + original)
        let incremental = timed { versions.reduce(0) { $0 + cache.update($1).parsedLineCount } }
        precondition(cache.update(versions.last!, forceFull: true).tokens
                     == MarkdownSyntaxHighlighter().tokens(in: versions.last!))
        print("Editor: 90,000 UTF-16 units, 2,000 body lines, 80 heading edits")
        print("Full tokenization: \(full.milliseconds) ms (\(full.checksum) tokens)")
        print("Incremental: \(incremental.milliseconds) ms (\(incremental.checksum) parsed lines)")

        let root = URL(fileURLWithPath: "/benchmark")
        let files = (0..<100).map { directory in
            let folder = root.appendingPathComponent("docs\(directory)")
            let children = (0..<100).map { file in
                WorkspaceFile(url: folder.appendingPathComponent("note\(file).md"), rootURL: root, kind: .markdown)
            }
            return WorkspaceFile(url: folder, rootURL: root, kind: .folder, children: children)
        }
        let queries = (0..<20).map { "docs\($0 % 10) note99" }
        let index = WorkspaceSearchIndex(files: files)
        for query in queries {
            precondition(legacyResults(files, query: query) == index.results(for: query))
        }
        let oldSearch = timed { queries.reduce(0) { $0 + legacyResults(files, query: $1).count } }
        let indexedSearch = timed { queries.reduce(0) { $0 + index.results(for: $1).count } }
        print("Quick Open: 10,000 files in 100 directories, 20 queries; index creation excluded")
        print("Rebuild/sort/search: \(oldSearch.milliseconds) ms (\(oldSearch.checksum) matches)")
        print("Indexed search: \(indexedSearch.milliseconds) ms (\(indexedSearch.checksum) matches)")
    }

    // Original Quick Open algorithm, retained here only as a benchmark baseline.
    static func legacyFiles(_ files: [WorkspaceFile]) -> [WorkspaceFile] {
        files.flatMap { file -> [WorkspaceFile] in
            var result = file.isEditable ? [file] : []
            if let children = file.children { result.append(contentsOf: legacyFiles(children)) }
            return result
        }.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    static func legacyResults(_ files: [WorkspaceFile], query: String) -> [WorkspaceFile] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        return Array(legacyFiles(files).filter { file in
            let haystack = "\(file.name) \(file.relativePath)".lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }.prefix(40))
    }
}
