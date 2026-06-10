import Foundation

/// A structured view of a Claude Code permission prompt, parsed out of the (ANSI-stripped)
/// terminal stream so the UI can render a native approval card instead of raw `1/2/Esc` text.
///
/// Best-effort by design: Claude Code is a full-screen TUI that repaints via cursor moves, so the
/// stripped transcript is not a clean line sequence. `parse` is robust for the action type, the
/// question and the command/subject, and degrades gracefully (returns a card with an empty preview)
/// when the diff can't be recovered cleanly. See docs/AGENT-COCKPIT.md.
struct ClaudeApproval: Equatable {

    enum Action: Equatable {
        case bash, edit, write, read, fetch, web, other

        var symbol: String {
            switch self {
            case .bash:  return "terminal"
            case .edit:  return "pencil.and.outline"
            case .write: return "doc.badge.plus"
            case .read:  return "doc.text"
            case .fetch: return "arrow.down.circle"
            case .web:   return "globe"
            case .other: return "hand.raised"
            }
        }

        var label: String {
            switch self {
            case .bash:  return "Befehl ausführen"
            case .edit:  return "Datei bearbeiten"
            case .write: return "Datei schreiben"
            case .read:  return "Datei lesen"
            case .fetch: return "Herunterladen"
            case .web:   return "Web-Zugriff"
            case .other: return "Aktion bestätigen"
            }
        }

        /// `rm -rf`, `sudo`, force-push & co. → the card turns red.
        var isDestructiveCapable: Bool { self == .bash }
    }

    struct Line: Equatable, Identifiable {
        enum Kind: Equatable { case add, remove, context }
        let id = UUID()
        var kind: Kind
        var text: String

        static func == (l: Line, r: Line) -> Bool { l.kind == r.kind && l.text == r.text }
    }

    var action: Action
    /// The "Do you want to …?" line, cleaned of box-drawing characters.
    var question: String
    /// Command text (bash) or diff/content lines (edits). May be empty if not recoverable.
    var preview: [Line]
    var allowAlways: Bool

    /// True when the command preview contains a genuinely dangerous pattern.
    var looksDangerous: Bool {
        guard action.isDestructiveCapable else { return false }
        let cmd = preview.map(\.text).joined(separator: "\n").lowercased()
        let patterns = ["rm -rf", "rm -fr", "mkfs", ":(){", "dd if=", "> /dev/sd",
                        "force", "--hard", "drop table", "drop database", "sudo rm"]
        return patterns.contains { cmd.contains($0) }
    }

    // MARK: - Parsing

    private static let boxChars = CharacterSet(charactersIn: "│╭╮╰╯─┌┐└┘├┤┬┴┼┃━┏┓┗┛❯►▶•")

    /// Parses the tail of a stripped transcript. Returns `nil` when no active prompt is present.
    static func parse(_ transcript: String) -> ClaudeApproval? {
        let tail = String(transcript.suffix(3000))
        let lower = tail.lowercased()

        // An active prompt always shows a numbered "Yes" option. Without it, there is nothing to confirm.
        let hasOption = lower.contains("1. yes") || lower.contains("❯ 1.") || lower.contains("1.yes")
        guard hasOption else { return nil }

        let rawLines = tail.components(separatedBy: "\n")
        let cleaned = rawLines.map { clean($0) }

        // The question is the last "do you want …" line.
        guard let qIdx = cleaned.lastIndex(where: { $0.lowercased().contains("do you want") }) else {
            // Some prompts (older builds) skip the phrasing; still surface a generic card.
            return ClaudeApproval(action: .other,
                                  question: "Claude möchte fortfahren.",
                                  preview: [],
                                  allowAlways: lower.contains("ask again"))
        }
        let question = cleaned[qIdx]

        // Preview = the content lines above the question (drop empties and the box rules),
        // back to the nearest blank gap or box-top, capped so a huge diff stays manageable.
        var preview: [Line] = []
        var i = qIdx - 1
        var blanks = 0
        while i >= 0, preview.count < 40 {
            let line = cleaned[i]
            if line.isEmpty {
                blanks += 1
                if blanks >= 2 && !preview.isEmpty { break }  // a real gap separates the box body
                i -= 1
                continue
            }
            blanks = 0
            // Skip the action header line itself (we render our own).
            if !isHeader(line) {
                preview.insert(diffLine(line), at: 0)
            }
            i -= 1
        }
        // Trim leading/trailing context-only noise.
        while let f = preview.first, f.kind == .context, f.text.isEmpty { preview.removeFirst() }

        let action = classify(question: question, preview: preview, lower: lower)
        let allowAlways = lower.contains("don't ask again") || lower.contains("don’t ask again")
            || lower.contains("ask again")

        return ClaudeApproval(action: action, question: question, preview: preview, allowAlways: allowAlways)
    }

    // MARK: - Helpers

    private static func clean(_ s: String) -> String {
        let stripped = String(s.unicodeScalars.filter { !boxChars.contains($0) })
        return stripped.trimmingCharacters(in: .whitespaces)
    }

    private static func isHeader(_ line: String) -> Bool {
        let l = line.lowercased()
        return ["bash command", "edit file", "write file", "read file", "create file",
                "web fetch", "fetch", "tool use"].contains { l == $0 || l.hasPrefix($0) }
    }

    /// Classifies a single content line as a diff add/remove or plain context.
    /// Claude renders diffs as "  12 + newcode" / "  12 - oldcode" (line number, then sign).
    private static func diffLine(_ line: String) -> Line {
        // Strip an optional leading line number to find the sign.
        let body = line.drop { $0.isNumber || $0 == " " }
        if let first = body.first {
            if first == "+" { return Line(kind: .add, text: String(body.dropFirst()).trimmingCharacters(in: .whitespaces)) }
            if first == "-" && !body.hasPrefix("--") {
                return Line(kind: .remove, text: String(body.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
        }
        return Line(kind: .context, text: line)
    }

    private static func classify(question: String, preview: [ClaudeApproval.Line], lower: String) -> Action {
        let q = question.lowercased()
        if q.contains("make this edit") || q.contains("edit to") { return .edit }
        if q.contains("create") || q.contains("write") { return .write }
        if q.contains("read") { return .read }
        if q.contains("fetch") || q.contains("download") { return .fetch }
        if q.contains("url") || lower.contains("web fetch") || lower.contains("webfetch") { return .web }
        if lower.contains("bash command") || q.contains("run this command") || q.contains("proceed") {
            return .bash
        }
        // If the preview carries diff markers, it's almost certainly an edit.
        if preview.contains(where: { $0.kind != .context }) { return .edit }
        return preview.isEmpty ? .other : .bash
    }
}
