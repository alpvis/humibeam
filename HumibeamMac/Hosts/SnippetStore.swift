import Foundation
import Observation

struct Snippet: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var command: String
}

/// Quick-insert command snippets, sent straight into the active terminal session.
@Observable
@MainActor
final class SnippetStore {
    var snippets: [Snippet] { didSet { save() } }

    private static var fileURL: URL {
        let dir = AppSupportPaths.appSupportDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("snippets.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let list = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = list
        } else {
            snippets = Self.defaults
        }
    }

    func add(_ s: Snippet) { snippets.append(s) }
    func delete(_ s: Snippet) { snippets.removeAll { $0.id == s.id } }

    static var defaults: [Snippet] {
        [
            Snippet(title: "Claude Code starten", command: "claude\n"),
            Snippet(title: "Claude (resume)", command: "claude --resume\n"),
            Snippet(title: "Git Status", command: "git status\n"),
            Snippet(title: "Letzte Commits", command: "git log --oneline -10\n"),
            Snippet(title: "Festplatte", command: "df -h\n"),
            Snippet(title: "Prozesse (top)", command: "top -b -n1 | head -20\n"),
        ]
    }

    private func save() {
        if let data = try? JSONEncoder().encode(snippets) { try? data.write(to: Self.fileURL) }
    }
}
