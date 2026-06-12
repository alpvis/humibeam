import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Live Activity („Claude arbeitet auf zürich-1"): Dynamic Island + Sperrbildschirm.
/// Geteilt zwischen App (startet/aktualisiert) und Widget-Extension (rendert).
struct ClaudeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// z. B. „bearbeitet main.swift" oder „wartet auf Freigabe"
        var status: String
        var waiting: Bool
    }

    var hostName: String
}
#endif
