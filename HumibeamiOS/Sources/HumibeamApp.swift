import SwiftUI
import UIKit
import UserNotifications

@main
struct HumibeamApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HostListView()
                .environment(model)
        }
    }
}

// MARK: - Push: "Claude wartet auf dich" vom Relay (alpvis.com) aufs Gerät.
// Funktioniert erst mit Push-fähigem Provisioning (aps-environment); ohne läuft
// die App unverändert weiter — Registrierung schlägt dann einfach still fehl.

final class PushDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        PushRegistration.register(token: token)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Erwartbar ohne Push-Entitlement — bewusst still.
    }
}

enum PushRegistration {
    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "push.url") ?? "https://alpvis.com/humibeam-push" }
        set { UserDefaults.standard.set(newValue, forKey: "push.url") }
    }
    static var secret: String {
        get { UserDefaults.standard.string(forKey: "push.secret") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "push.secret") }
    }

    static func register(token: String) {
        guard !secret.isEmpty,
              let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/register") else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "secret": secret, "token": token, "device": UIDevice.current.name,
        ])
        URLSession.shared.dataTask(with: request).resume()
    }
}

/// Zentrales App-Modell: Profile, known_hosts, Netz-Monitor und die lebenden Terminal-Sessions
/// (eine pro Host, bleibt beim Zurücknavigieren bestehen).
@Observable
@MainActor
final class AppModel {
    let hostStore = HostStore()
    let knownHosts = KnownHostsStore()
    let network = NetworkMonitor()
    let snippets = SnippetStore()
    let commandHistory = CommandHistoryStore()

    @ObservationIgnored private(set) var controllers: [UUID: TerminalController] = [:]
    /// Hosts mit lebender Session (für den grünen Punkt in der Liste).
    var activeSessions: Set<UUID> = []

    var themeID: String {
        didSet {
            UserDefaults.standard.set(themeID, forKey: "themeID")
            controllers.values.forEach { $0.applyTheme(theme) }
        }
    }
    var fontSize: Double {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: "fontSize")
            controllers.values.forEach { $0.setFontSize(fontSize) }
        }
    }

    var theme: TerminalTheme { TerminalTheme.by(id: themeID) }

    init() {
        themeID = UserDefaults.standard.string(forKey: "themeID") ?? "beam"
        fontSize = UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 13
        network.onChange = { [weak self] online in
            guard let self else { return }
            for controller in self.controllers.values {
                online ? controller.networkBecameAvailable() : controller.networkBecameUnavailable()
            }
        }
    }

    /// Liefert die lebende Session für einen Host oder erzeugt eine neue.
    func controller(for host: SSHHost) -> TerminalController {
        if let existing = controllers[host.id] { return existing }
        let controller = TerminalController(knownHosts: knownHosts)
        controller.applyTheme(theme)
        controller.setFontSize(fontSize)
        controller.primeNetwork(network.isOnline)
        let hostName = host.displayName
        controller.onCommandSubmitted = { [weak self] cmd in
            self?.commandHistory.record(cmd, host: hostName)
        }
        controllers[host.id] = controller
        activeSessions.insert(host.id)
        return controller
    }

    func closeSession(for hostID: UUID) {
        controllers[hostID]?.disconnect()
        controllers.removeValue(forKey: hostID)
        activeSessions.remove(hostID)
    }

    /// Verbindet einen Controller mit den Credentials des Hosts (inkl. ProxyJump).
    func connect(_ host: SSHHost, controller: TerminalController) {
        if host.tmuxEnabled {
            controller.startupCommand =
                "command -v tmux >/dev/null 2>&1 && { clear; exec tmux new-session -A -s humibeam; } " +
                "|| echo 'humibeam: tmux ist am Server nicht installiert — normale Sitzung.'"
        }
        do {
            let creds = try hostStore.credentials(for: host)
            var proxy: SSHConnection.ProxyJump?
            if let jumpCreds = try hostStore.proxyCredentials(for: host) {
                proxy = SSHConnection.ProxyJump(credentials: jumpCreds, verifier: knownHosts)
            }
            controller.connect(creds, proxy: proxy)
        } catch {
            controller.setStatus("Fehler: \(error.localizedDescription)")
        }
    }
}
