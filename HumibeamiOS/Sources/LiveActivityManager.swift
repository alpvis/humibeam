import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Startet/aktualisiert die „Claude arbeitet"-Live-Activity (Dynamic Island) pro Sitzung.
/// Wird vom AppModel über einen 5-s-Abgleich getrieben — Updates laufen, solange die App lebt;
/// im Hintergrund bleibt der letzte Stand stehen (Push-Updates wären der nächste Ausbau).
@MainActor
final class LiveActivityManager {
    #if canImport(ActivityKit)
    private var activities: [UUID: Activity<ClaudeActivityAttributes>] = [:]

    func reconcile(sessions: [TerminalSession]) {
        guard #available(iOS 16.2, *),
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        var live = Set<UUID>()
        for session in sessions {
            let controller = session.controller
            guard controller.claudeDetected, controller.isConnected,
                  controller.activity.kind != .idle else { continue }
            live.insert(session.id)
            let state = ClaudeActivityAttributes.ContentState(
                status: controller.activity.label,
                waiting: controller.activity.kind == .waiting)
            if let existing = activities[session.id] {
                Task { await existing.update(ActivityContent(state: state, staleDate: nil)) }
            } else {
                let attributes = ClaudeActivityAttributes(hostName: session.title)
                if let started = try? Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: nil)) {
                    activities[session.id] = started
                }
            }
        }
        // Beendete/idle Sitzungen: Activity schließen.
        for (id, activity) in activities where !live.contains(id) {
            activities.removeValue(forKey: id)
            Task { await activity.end(nil, dismissalPolicy: .after(Date().addingTimeInterval(10))) }
        }
    }
    #else
    func reconcile(sessions: [TerminalSession]) {}
    #endif
}
