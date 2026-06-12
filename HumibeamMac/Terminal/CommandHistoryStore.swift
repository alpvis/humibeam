import Foundation
import Observation

// MARK: - Befehls-Verlauf: jeder abgeschickte Befehl, über alle Server, durchsuchbar.
// Plattformneutral (Mac: ⌘R-Palette, iOS: Verlauf-Sheet) — die UI lebt je App separat.

struct CommandHistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    let command: String
    let hostName: String
    let date: Date
}

@Observable
@MainActor
final class CommandHistoryStore {
    private(set) var entries: [CommandHistoryEntry] = []   // neueste zuerst
    private static let cap = 5000

    private static var fileURL: URL {
        AppSupportPaths.appSupportDirectoryURL.appendingPathComponent("command-history.json")
    }

    init() { load() }

    func record(_ command: String, host: String) {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard cmd.count >= 2 else { return }
        if let first = entries.first, first.command == cmd, first.hostName == host { return }
        entries.insert(CommandHistoryEntry(command: cmd, hostName: host, date: Date()), at: 0)
        if entries.count > Self.cap { entries.removeLast(entries.count - Self.cap) }
        save()
    }

    func clear() { entries = []; save() }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([CommandHistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        let dir = AppSupportPaths.appSupportDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
