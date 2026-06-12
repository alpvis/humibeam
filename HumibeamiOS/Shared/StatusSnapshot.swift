import Foundation

/// Kompakter App-Zustand für Widget, Siri-Intents und Apple Watch — liegt in der
/// App-Group (group.app.humibeam), damit die Extensions ihn lesen können.
struct StatusSnapshot: Codable {
    struct Server: Codable, Hashable {
        let name: String
        let connected: Bool
        let load: Double?
        let mem: Int?
        let disk: Int?
        let critical: Bool
    }

    struct Waiting: Codable, Hashable {
        let sessionID: String
        let title: String
        let question: String
    }

    var servers: [Server]
    var waiting: [Waiting]
    var date: Date

    static let appGroup = "group.app.humibeam"
    private static let key = "status.snapshot"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    func save() {
        // Nur bei echter Änderung schreiben + Widget neu laden (der 5-s-Abgleich ruft oft).
        if let old = Self.load(), old.servers == servers, old.waiting == waiting { return }
        if let data = try? JSONEncoder().encode(self) {
            Self.defaults.set(data, forKey: Self.key)
        }
        #if canImport(WidgetKit) && !WIDGET_EXTENSION
        WidgetRefresher.refresh()
        #endif
    }

    static func load() -> StatusSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StatusSnapshot.self, from: data)
    }

    var summaryText: String {
        if servers.isEmpty { return "Keine Server angelegt." }
        let critical = servers.filter(\.critical)
        var parts: [String] = []
        if waiting.isEmpty {
            parts.append("Keine Freigaben offen.")
        } else {
            parts.append("\(waiting.count) Freigabe\(waiting.count == 1 ? "" : "n") offen (\(waiting.map(\.title).joined(separator: ", "))).")
        }
        if critical.isEmpty {
            parts.append("Alle \(servers.count) Server im grünen Bereich.")
        } else {
            parts.append("Kritisch: \(critical.map(\.name).joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }
}

#if canImport(WidgetKit) && !WIDGET_EXTENSION
import WidgetKit

enum WidgetRefresher {
    static func refresh() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
#endif
