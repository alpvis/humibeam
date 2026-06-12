import Foundation
import WatchConnectivity

/// iPhone-Seite der Watch-Verbindung: schiebt den StatusSnapshot zur Uhr und
/// wendet Freigabe-Aktionen von dort an (sendMessage weckt die App im Hintergrund).
final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchBridge()

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func push(_ snapshot: StatusSnapshot) {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? WCSession.default.updateApplicationContext(["snapshot": data])
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let action = message["action"] as? String,
              let sessionID = message["sessionID"] as? String,
              let id = UUID(uuidString: sessionID) else { return }
        Task { @MainActor in
            guard let model = AppModel.shared,
                  let target = model.session(withID: id),
                  target.controller.approval != nil else { return }
            switch action {
            case "approve": target.controller.approve()
            case "approve_always": target.controller.approveAlways()
            case "deny": target.controller.deny()
            default: break
            }
            model.publishSnapshot()
        }
    }

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
