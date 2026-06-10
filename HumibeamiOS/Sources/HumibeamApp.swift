import SwiftUI

@main
struct HumibeamApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HostListView()
                .environment(model)
        }
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
