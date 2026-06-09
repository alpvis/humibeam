import Foundation
import Observation

struct Snippet: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var command: String

    static let placeholderRegex = try? NSRegularExpression(pattern: #"\{\{\s*([^}]+?)\s*\}\}"#)

    /// Distinct `{{name}}` placeholders in the command, in order of first appearance.
    var placeholders: [String] {
        guard let regex = Self.placeholderRegex else { return [] }
        let ns = command as NSString
        var seen: [String] = []
        for m in regex.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    /// The command with each `{{name}}` replaced by the supplied value.
    func filled(with values: [String: String]) -> String {
        guard let regex = Self.placeholderRegex else { return command }
        let ns = command as NSString
        let mutable = NSMutableString(string: command)
        for m in regex.matches(in: command, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            mutable.replaceCharacters(in: m.range, with: values[name] ?? "")
        }
        return mutable as String
    }
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
