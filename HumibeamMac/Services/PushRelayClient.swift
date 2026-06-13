import Foundation

/// Schickt "Claude wartet"-Ereignisse an das Push-Relay auf alpvis.com, das sie als
/// APNs-Push an Ali's iPhones weiterreicht. Fire-and-forget, niemals blockierend.
enum PushRelayClient {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "push.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "push.enabled") }
    }
    /// Push-Relay läuft ausschließlich auf humibeam.com (früher alpvis.com).
    static let defaultPushURL = "https://humibeam.com/humibeam-push"
    static var baseURL: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "push.url")
            // Einmal-Migration: alte alpvis-URL auf humibeam.com umschreiben.
            if let s = stored, s.contains("alpvis.com") {
                UserDefaults.standard.set(defaultPushURL, forKey: "push.url")
                return defaultPushURL
            }
            return stored ?? defaultPushURL
        }
        set { UserDefaults.standard.set(newValue, forKey: "push.url") }
    }
    static var secret: String {
        get { UserDefaults.standard.string(forKey: "push.secret") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "push.secret") }
    }

    static func notify(title: String, body: String, host: String,
                       kind: String = "", sessionID: String = "") {
        guard enabled, !secret.isEmpty,
              let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/notify") else { return }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "secret": secret, "title": title, "body": body, "host": host,
            "kind": kind, "sessionID": sessionID,
        ])
        URLSession.shared.dataTask(with: request).resume()
    }

    /// Vom iPhone beantwortete Freigaben abholen (das Relay leert die Liste beim Abruf).
    struct RemoteAction: Decodable {
        let sessionID: String
        let action: String   // approve | approve_always | deny
    }

    static func fetchActions() async -> [RemoteAction] {
        guard enabled, !secret.isEmpty,
              let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/actions") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["secret": secret])
        struct Response: Decodable { let actions: [RemoteAction] }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return decoded.actions
    }
}
