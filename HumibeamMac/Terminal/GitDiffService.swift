import Foundation

/// Stufe 2 of the agent cockpit: the *reliable* diff. Instead of scraping Claude Code's TUI, this
/// reads the actual working-tree changes straight from the server over the existing exec-channel
/// (`git diff HEAD` + untracked files) — independent of any terminal repaint noise. See
/// docs/AGENT-COCKPIT.md.

struct DiffHunkLine: Identifiable, Equatable {
    enum Kind { case add, remove, context, hunk, file }
    let id = UUID()
    let kind: Kind
    let text: String
    static func == (l: DiffHunkLine, r: DiffHunkLine) -> Bool { l.kind == r.kind && l.text == r.text }
}

enum GitDiffResult: Equatable {
    case diff(lines: [DiffHunkLine], untracked: [String])
    case clean          // repo found, nothing changed
    case notARepo       // working dir isn't a git repo
    case noLocation     // couldn't determine the remote working directory
    case error(String)
}

@MainActor
enum GitDiffService {

    /// Runs git over the live SSH connection and returns a parsed, colorable diff.
    ///
    /// Anchor strategy: Stock-Ubuntu bash often doesn't emit OSC 7, so the terminal CWD is frequently
    /// unknown. We therefore try a list of candidate directories — the reported CWD plus the parent
    /// folders of files Claude recently touched — and take the first one inside a git repo. `$HOME`
    /// is the last resort.
    static func fetch(connection: SSHConnection?, candidates: [String]) async -> GitDiffResult {
        guard let conn = connection else { return .error("Keine Verbindung") }

        // Build a deduped, shell-quoted candidate list (absolute paths only — relative ones are
        // meaningless without a known CWD), with $HOME appended as the fallback.
        var dirs: [String] = []
        for c in candidates where c.hasPrefix("/") && !dirs.contains(c) { dirs.append(c) }
        let quoted = dirs.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let dirList = (quoted + ["\"$HOME\""]).joined(separator: " ")

        let untrackedMarker = "<<<HUMIBEAM-UNTRACKED>>>"
        let noRepoMarker = "<<<HUMIBEAM-NOREPO>>>"
        let script = """
        for d in \(dirList); do \
          root=$(cd "$d" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null); \
          if [ -n "$root" ]; then \
            git -C "$root" --no-pager diff --no-color HEAD; \
            echo '\(untrackedMarker)'; \
            git -C "$root" ls-files --others --exclude-standard; \
            exit 0; \
          fi; \
        done; \
        echo '\(noRepoMarker)'
        """

        do {
            let (_, out, _) = try await conn.exec(script)
            let text = String(decoding: out, as: UTF8.self)
            if text.contains(noRepoMarker) {
                // Nothing matched. If we had no anchor at all, the cause is the unknown CWD.
                return dirs.isEmpty ? .noLocation : .notARepo
            }
            let parts = text.components(separatedBy: untrackedMarker)
            let diffText = parts.first ?? ""
            let untracked = parts.count > 1
                ? parts[1].split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
                : []
            let lines = parse(diffText)
            if lines.isEmpty && untracked.isEmpty { return .clean }
            return .diff(lines: lines, untracked: untracked)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Parses unified `git diff` output into classified lines for colored rendering.
    static func parse(_ s: String) -> [DiffHunkLine] {
        var out: [DiffHunkLine] = []
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let kind: DiffHunkLine.Kind
            if raw.hasPrefix("diff --git") || raw.hasPrefix("index ")
                || raw.hasPrefix("--- ") || raw.hasPrefix("+++ ")
                || raw.hasPrefix("new file") || raw.hasPrefix("deleted file")
                || raw.hasPrefix("rename ") || raw.hasPrefix("similarity ") {
                kind = .file
            } else if raw.hasPrefix("@@") {
                kind = .hunk
            } else if raw.hasPrefix("+") {
                kind = .add
            } else if raw.hasPrefix("-") {
                kind = .remove
            } else {
                kind = .context
            }
            // Drop the trailing empty line git appends so the view doesn't show a blank row.
            if raw.isEmpty && out.last?.text.isEmpty == true { continue }
            out.append(DiffHunkLine(kind: kind, text: raw))
        }
        while out.last?.text.isEmpty == true { out.removeLast() }
        return out
    }
}
