import Foundation

/// „Claude-Status Plus": Was tut der Agent gerade? Geparst aus dem ANSI-bereinigten
/// Transcript-Schwanz — plattformneutral (Mac-Sidebar/Fleet, iOS-Statuszeile/Widgets).
struct ClaudeStatus: Equatable {
    enum Kind: Equatable {
        case idle            // Claude erkannt, wartet auf Eingabe
        case busy            // arbeitet ("esc to interrupt")
        case waiting         // wartet auf eine Freigabe
    }

    var kind: Kind
    /// Menschlich lesbar, z. B. „liest AppModel.swift", „führt npm test aus".
    var detail: String?

    var label: String {
        switch kind {
        case .waiting: return "wartet auf Freigabe"
        case .busy: return detail ?? "arbeitet…"
        case .idle: return detail.map { "fertig: \($0)" } ?? "bereit"
        }
    }

    /// Letzte Tool-Aktion aus dem Stream ziehen: Read(...)/Update(...)/Bash(...) usw.
    private static let toolRegex = try? NSRegularExpression(
        pattern: #"(Read|Update|Write|Edit|MultiEdit|Create|Search|Grep|Glob|Bash|WebFetch|WebSearch|Task)\(([^)\n]{1,160})\)"#)

    private static let verbs: [String: String] = [
        "Read": "liest", "Update": "bearbeitet", "Edit": "bearbeitet", "MultiEdit": "bearbeitet",
        "Write": "schreibt", "Create": "erstellt", "Search": "sucht", "Grep": "sucht", "Glob": "sucht",
        "Bash": "führt aus:", "WebFetch": "lädt", "WebSearch": "sucht im Web:", "Task": "delegiert:",
    ]

    static func parse(transcriptTail: String, busy: Bool, awaitingApproval: Bool) -> ClaudeStatus {
        if awaitingApproval { return ClaudeStatus(kind: .waiting, detail: lastAction(in: transcriptTail)) }
        if busy { return ClaudeStatus(kind: .busy, detail: lastAction(in: transcriptTail)) }
        return ClaudeStatus(kind: .idle, detail: nil)
    }

    private static func lastAction(in text: String) -> String? {
        guard let regex = toolRegex else { return nil }
        let tail = String(text.suffix(2000))
        let ns = tail as NSString
        let matches = regex.matches(in: tail, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last, last.numberOfRanges > 2 else { return nil }
        let tool = ns.substring(with: last.range(at: 1))
        var subject = ns.substring(with: last.range(at: 2)).trimmingCharacters(in: .whitespaces)
        // "datei.swift, lines 10-20" → "datei.swift"; lange Befehle kappen
        if let r = subject.range(of: #"\s*,?\s*lines?\s.*$"#, options: .regularExpression) {
            subject.removeSubrange(r)
        }
        if subject.count > 60 { subject = String(subject.prefix(57)) + "…" }
        let verb = verbs[tool] ?? tool
        // Bei Pfaden nur den Dateinamen zeigen
        if subject.hasPrefix("/"), !verb.hasSuffix(":") {
            subject = (subject as NSString).lastPathComponent
        }
        return "\(verb) \(subject)"
    }
}
