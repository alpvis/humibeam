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
                .appLock()   // Face-ID-Schutz (Einstellungen → Sicherheit)
        }
    }
}

// MARK: - Push: "Claude wartet auf dich" vom Relay (alpvis.com) aufs Gerät.
// Funktioniert erst mit Push-fähigem Provisioning (aps-environment); ohne läuft
// die App unverändert weiter — Registrierung schlägt dann einfach still fehl.

final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Freigabe-Pushes mit Aktions-Buttons — beantwortet die Frage, ohne die App zu öffnen.
        let approve = UNNotificationAction(identifier: "APPROVE", title: "Erlauben", options: [])
        let always = UNNotificationAction(identifier: "APPROVE_ALWAYS", title: "Immer erlauben", options: [])
        let deny = UNNotificationAction(identifier: "DENY", title: "Ablehnen", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "HUMIBEAM_APPROVAL",
                                   actions: [approve, always, deny],
                                   intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
    }

    /// Aktion aus der Mitteilung → ans Relay; der Mac holt sie per Poll ab und drückt 1/2/Esc.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let sessionID = info["sessionID"] as? String ?? ""
        let action: String? = switch response.actionIdentifier {
        case "APPROVE": "approve"
        case "APPROVE_ALWAYS": "approve_always"
        case "DENY": "deny"
        default: nil
        }
        if let action, !sessionID.isEmpty {
            PushRegistration.sendAction(sessionID: sessionID, action: action) {
                completionHandler()
            }
        } else {
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
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

    /// Antwort auf einen Freigabe-Push (approve/approve_always/deny) ans Relay melden.
    static func sendAction(sessionID: String, action: String, done: @escaping () -> Void) {
        guard !secret.isEmpty,
              let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/action") else {
            done(); return
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "secret": secret, "sessionID": sessionID, "action": action,
        ])
        URLSession.shared.dataTask(with: request) { _, _, _ in done() }.resume()
    }
}

/// Eine lebende Terminal-Sitzung (Multi-Session: mehrere pro Host möglich, iTerm-artig).
@MainActor
final class TerminalSession: Identifiable {
    let id = UUID()
    let host: SSHHost
    let controller: TerminalController
    /// "Server (2)" ab der zweiten Sitzung zum selben Host.
    var title: String

    init(host: SSHHost, controller: TerminalController, index: Int) {
        self.host = host
        self.controller = controller
        self.title = index <= 1 ? host.displayName : "\(host.displayName) (\(index))"
    }
}

/// Zentrales App-Modell: Profile, known_hosts, Netz-Monitor, Konto-Sync und die lebenden
/// Terminal-Sitzungen (bleiben beim Zurücknavigieren bestehen).
@Observable
@MainActor
final class AppModel {
    /// Für App Intents (Siri/Kurzbefehle) — die App läuft, wenn der Intent sie öffnet.
    static weak var shared: AppModel?

    let hostStore = HostStore()
    let knownHosts = KnownHostsStore()
    let network = NetworkMonitor()
    let snippets = SnippetStore()
    let commandHistory = CommandHistoryStore()
    let bookmarks = BookmarkStore()
    let accountSync = AccountSyncService()

    private(set) var sessions: [TerminalSession] = []
    /// Vom TerminalScreen gesetzt, von der HostListView beobachtet → Navigation wechselt die Sitzung.
    var requestedSessionID: UUID?
    /// Server-Vitalwerte je Host (nur für Hosts mit lebender Verbindung, alle 30 s).
    var stats: [UUID: ServerStats] = [:]

    var themeID: String {
        didSet {
            UserDefaults.standard.set(themeID, forKey: "themeID")
            sessions.forEach { $0.controller.applyTheme(theme) }
            accountSync.scheduleExport()
        }
    }
    var fontSize: Double {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: "fontSize")
            applyFonts()
            accountSync.scheduleExport()
        }
    }
    /// Leer = System-Monospace. Synct mit dem Mac (terminal.fontName).
    var fontName: String {
        didSet {
            UserDefaults.standard.set(fontName, forKey: "fontName")
            applyFonts()
            accountSync.scheduleExport()
        }
    }

    var theme: TerminalTheme { TerminalTheme.by(id: themeID) }

    var terminalFont: UIFont {
        if !fontName.isEmpty, let f = UIFont(name: fontName, size: fontSize) { return f }
        return .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// Installierte Festbreiten-Schriften (für den Picker).
    static let availableMonospaceFamilies: [String] = UIFont.familyNames.filter { family in
        guard let name = UIFont.fontNames(forFamilyName: family).first,
              let font = UIFont(name: name, size: 13) else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
    }.sorted()

    private func applyFonts() {
        let f = terminalFont
        sessions.forEach { $0.controller.setFont(f) }
    }

    @ObservationIgnored private var healthTimer: Timer?
    @ObservationIgnored private var activityTimer: Timer?
    @ObservationIgnored private let liveActivities = LiveActivityManager()

    init() {
        defer { AppModel.shared = self }
        PhoneWatchBridge.shared.activate()
        themeID = UserDefaults.standard.string(forKey: "themeID") ?? "beam"
        fontSize = UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 13
        fontName = UserDefaults.standard.string(forKey: "fontName") ?? ""
        network.onChange = { [weak self] online in
            guard let self else { return }
            for session in self.sessions {
                online ? session.controller.networkBecameAvailable()
                       : session.controller.networkBecameUnavailable()
            }
        }

        // Humibeam-Konto: E2E-verschlüsselter Sync mit den Macs.
        hostStore.onHostsChangedSync = { [weak self] in self?.accountSync.scheduleExport() }
        snippets.onChanged = { [weak self] in self?.accountSync.scheduleExport() }
        bookmarks.onChanged = { [weak self] in self?.accountSync.scheduleExport() }
        accountSync.buildPayload = { [weak self] in
            guard let self else { return AccountSyncPayload() }
            return AccountSyncPayload(hosts: hostStore.hosts,
                                      snippets: snippets.snippets,
                                      bookmarks: bookmarks.bookmarks,
                                      fontName: fontName.isEmpty ? nil : fontName,
                                      fontSize: fontSize,
                                      themeID: themeID)
        }
        accountSync.applyPayload = { [weak self] payload in
            guard let self else { return }
            if let h = payload.hosts { hostStore.hosts = h }
            if let s = payload.snippets { snippets.snippets = s }
            if let b = payload.bookmarks { bookmarks.bookmarks = b }
            // Nur Themes übernehmen, die es auf iOS auch gibt (IDs können je Plattform abweichen).
            if let t = payload.themeID, TerminalTheme.all.contains(where: { $0.id == t }) { themeID = t }
            if let f = payload.fontSize { fontSize = f }
            if let n = payload.fontName, UIFont(name: n, size: 13) != nil { fontName = n }
        }
        accountSync.start()

        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollHealth() }
        }
        // Live Activity + Widget-Snapshot im 5-s-Takt mit dem Sitzungszustand abgleichen.
        activityTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.liveActivities.reconcile(sessions: self.sessions)
                self.publishSnapshot()
            }
        }
    }

    // MARK: - Sitzungen

    var activeSessions: Set<UUID> { Set(sessions.filter { $0.controller.isConnected }.map { $0.host.id }) }

    func session(withID id: UUID) -> TerminalSession? { sessions.first { $0.id == id } }

    /// Erste Sitzung für einen Host (oder neue anlegen) — Tap in der Serverliste.
    func primarySession(for host: SSHHost) -> TerminalSession {
        if let existing = sessions.first(where: { $0.host.id == host.id }) { return existing }
        return addSession(for: host)
    }

    /// Weitere Sitzung zum selben Host ("Neue Sitzung" im Terminal-Menü).
    @discardableResult
    func addSession(for host: SSHHost) -> TerminalSession {
        let controller = TerminalController(knownHosts: knownHosts)
        controller.applyTheme(theme)
        controller.setFont(terminalFont)
        controller.primeNetwork(network.isOnline)
        controller.archiveLabel = host.displayName
        let hostName = host.displayName
        controller.onCommandSubmitted = { [weak self] cmd in
            self?.commandHistory.record(cmd, host: hostName)
        }
        let index = sessions.filter { $0.host.id == host.id }.count + 1
        let session = TerminalSession(host: host, controller: controller, index: index)
        sessions.append(session)
        return session
    }

    func closeSession(_ session: TerminalSession) {
        session.controller.disconnect()
        sessions.removeAll { $0.id == session.id }
        if sessions.first(where: { $0.host.id == session.host.id }) == nil {
            stats.removeValue(forKey: session.host.id)
        }
    }

    /// Alle Sitzungen eines Hosts schließen (Swipe in der Serverliste).
    func closeSessions(for hostID: UUID) {
        for session in sessions.filter({ $0.host.id == hostID }) { closeSession(session) }
    }

    /// Verbindet einen Controller mit den Credentials des Hosts (inkl. ProxyJump, tmux).
    func connect(_ session: TerminalSession) {
        let host = session.host
        if host.tmuxEnabled {
            let index = sessions.filter { $0.host.id == host.id }.firstIndex { $0.id == session.id } ?? 0
            let name = index == 0 ? "humibeam" : "humibeam-\(index + 1)"
            session.controller.startupCommand =
                "command -v tmux >/dev/null 2>&1 && { clear; exec tmux new-session -A -s \(name); } " +
                "|| echo 'humibeam: tmux ist am Server nicht installiert — normale Sitzung.'"
        }
        do {
            let creds = try hostStore.credentials(for: host)
            var proxy: SSHConnection.ProxyJump?
            if let jumpCreds = try hostStore.proxyCredentials(for: host) {
                proxy = SSHConnection.ProxyJump(credentials: jumpCreds, verifier: knownHosts)
            }
            session.controller.connect(creds, proxy: proxy)
        } catch {
            session.controller.setStatus("Fehler: \(error.localizedDescription)")
        }
    }

    // MARK: - Port-Weiterleitungen (ssh -L)

    struct ActiveForward: Identifiable {
        let id = UUID()
        let localPort: Int
        let targetHost: String
        let targetPort: Int
        let forward: LocalForward
        let sessionID: UUID
    }

    var forwards: [ActiveForward] = []

    func addForward(session: TerminalSession, localPort: Int, targetHost: String, targetPort: Int) async throws {
        guard let conn = session.controller.connection else { throw AccountError.server("Keine Verbindung") }
        let fwd = try await conn.startLocalForward(localPort: localPort, targetHost: targetHost, targetPort: targetPort)
        forwards.append(ActiveForward(localPort: fwd.localPort, targetHost: targetHost,
                                      targetPort: targetPort, forward: fwd, sessionID: session.id))
    }

    func stopForward(_ f: ActiveForward) {
        f.forward.close()
        forwards.removeAll { $0.id == f.id }
    }

    // MARK: - Server-Gesundheit (Ampel in der Serverliste)

    private func pollHealth() {
        var seen = Set<UUID>()
        for session in sessions where session.controller.isConnected {
            guard !seen.contains(session.host.id) else { continue }
            seen.insert(session.host.id)
            guard let conn = session.controller.connection else { continue }
            let hostID = session.host.id
            Task { [weak self] in
                guard let (status, out, _) = try? await conn.exec(ServerStats.command), status == 0,
                      let text = String(data: out, encoding: .utf8),
                      let parsed = ServerStats.parse(text) else { return }
                self?.stats[hostID] = parsed
                self?.publishSnapshot()
            }
        }
        publishSnapshot()
    }

    // MARK: - Status-Snapshot (Widget, Siri, Watch)

    /// Kompakter Zustand für Widget/Intents: Server-Vitalwerte + wartende Freigaben.
    func publishSnapshot() {
        var servers: [StatusSnapshot.Server] = []
        for host in hostStore.hosts {
            let s = stats[host.id]
            servers.append(StatusSnapshot.Server(
                name: host.displayName,
                connected: activeSessions.contains(host.id),
                load: s?.load1, mem: s?.memUsedPercent, disk: s?.diskPercent,
                critical: s?.isCritical ?? false))
        }
        let waiting = sessions.filter { $0.controller.approval != nil }.map {
            StatusSnapshot.Waiting(sessionID: $0.id.uuidString, title: $0.title,
                                   question: $0.controller.approval?.question ?? "")
        }
        let snapshot = StatusSnapshot(servers: servers, waiting: waiting, date: Date())
        snapshot.save()
        PhoneWatchBridge.shared.push(snapshot)
    }
}
