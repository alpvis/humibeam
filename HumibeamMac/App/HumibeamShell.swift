import Foundation
import AppKit
import Observation

/// Top-level coordinator for the terminal side of humibeam:
/// owns saved hosts and the open terminal tabs (multi-session, iTerm2-style).
@Observable
@MainActor
final class HumibeamShell {
    let hostStore = HostStore()
    let knownHosts = KnownHostsStore()
    let snippets = SnippetStore()
    let bookmarks = BookmarkStore()
    let network = NetworkMonitor()

    var tabs: [TerminalTab] = []
    var selectedTabID: UUID?

    init() {
        network.onChange = { [weak self] online in self?.handleNetworkChange(online) }
    }

    /// Propagates reachability changes to every session: pause reconnects when offline,
    /// reconnect immediately when the link returns.
    private func handleNetworkChange(_ online: Bool) {
        for tab in tabs {
            if online {
                tab.controller.networkBecameAvailable()
                tab.splitController?.networkBecameAvailable()
            } else {
                tab.controller.networkBecameUnavailable()
                tab.splitController?.networkBecameUnavailable()
                if !tab.connected {
                    tab.health = .offline
                    tab.status = "offline – warte auf Netz…"
                }
            }
        }
    }

    var terminalFontSize: CGFloat = 13 {
        didSet { forEachController { $0.setFontSize(terminalFontSize) } }
    }
    var selectedThemeID: String = "black" {
        didSet { let t = TerminalTheme.by(id: selectedThemeID); forEachController { $0.applyTheme(t) } }
    }
    var broadcastInput = false
    var forwards: [ActiveForward] = []

    struct ActiveForward: Identifiable {
        let id = UUID()
        let localPort: Int
        let targetHost: String
        let targetPort: Int
        let forward: LocalForward
        let tabID: UUID
    }

    var selectedTab: TerminalTab? { tabs.first { $0.id == selectedTabID } }
    var hasTabs: Bool { !tabs.isEmpty }
    var theme: TerminalTheme { TerminalTheme.by(id: selectedThemeID) }

    private func forEachController(_ body: (TerminalSessionController) -> Void) {
        for tab in tabs {
            body(tab.controller)
            if let s = tab.splitController { body(s) }
        }
    }

    /// Broadcast keystrokes from one session to all other connected sessions (when enabled).
    private func broadcast(_ bytes: [UInt8], from sender: TerminalSessionController) {
        guard broadcastInput else { return }
        forEachController { ctrl in
            if ctrl !== sender, ctrl.connection?.isConnected == true {
                ctrl.sendToShell(bytes)
            }
        }
    }

    private func configure(_ controller: TerminalSessionController) {
        controller.setFontSize(terminalFontSize)
        controller.applyTheme(theme)
        controller.onUserInput = { [weak self, weak controller] bytes in
            guard let self, let controller else { return }
            self.broadcast(bytes, from: controller)
        }
    }

    // MARK: - Connection / tabs

    @discardableResult
    func connect(to host: SSHHost) -> TerminalTab? {
        let controller = TerminalSessionController(knownHosts: knownHosts)
        configure(controller)
        controller.primeNetwork(network.isOnline)
        let tab = TerminalTab(host: host, controller: controller)

        controller.onStatus = { [weak tab] in
            guard let tab else { return }
            tab.status = $0
            let s = $0.lowercased()
            if s.contains("offline") { tab.health = .offline }
            else if s.contains("reconnect") { tab.health = .reconnecting }
        }
        controller.onConnected = { [weak self, weak tab] in
            guard let tab else { return }
            tab.connected = true
            tab.health = .connected
            // Drop any stale borrowed file session so it re-binds to the fresh connection.
            tab.fileSession?.disconnect()
            tab.fileSession = nil
            Task { await self?.loadInitialBrowserPath(tab) }
        }
        controller.onClosed = { [weak tab] in
            guard let tab else { return }
            tab.connected = false
            tab.health = .closed
            tab.status = "Verbindung geschlossen."
            tab.fileSession?.disconnect()
            tab.fileSession = nil
        }
        controller.onClaudeDetected = { [weak tab] in tab?.claudeDetected = true }
        controller.onApprovalChange = { [weak tab, weak controller] in
            let waiting = controller?.awaitingApproval ?? false
            tab?.awaitingApproval = waiting
            tab?.approvalAllowAlways = controller?.approvalAllowAlways ?? false
            tab?.approval = controller?.approval
            if waiting, let tab {
                Self.postClaudeAlert(tab, title: "Claude wartet auf dich",
                                     body: "\(tab.host.displayName): Erlaubnis nötig")
            }
        }
        controller.onPathsChange = { [weak tab, weak controller] in
            tab?.recentPaths = controller?.recentPaths ?? []
        }
        controller.onClaudeIdle = { [weak tab] in
            if let tab {
                Self.postClaudeAlert(tab, title: "Claude ist fertig",
                                     body: tab.host.displayName)
            }
        }

        do {
            let creds = try hostStore.credentials(for: host)
            let proxy = (try? hostStore.proxyCredentials(for: host)).flatMap { $0 }
                .map { SSHConnection.ProxyJump(credentials: $0, verifier: knownHosts) }
            tabs.append(tab)
            selectedTabID = tab.id
            controller.connect(creds, proxy: proxy)
            return tab
        } catch {
            tab.status = "Fehler: \(error.localizedDescription)"
            return nil
        }
    }

    private static func postClaudeAlert(_ tab: TerminalTab, title: String, body: String) {
        NotificationCenter.default.post(name: .claudeAlert, object: nil, userInfo: [
            "sessionID": tab.id, "title": title, "body": body
        ])
    }

    func closeTab(_ tab: TerminalTab) {
        tab.controller.disconnect()
        tab.splitController?.disconnect()
        tabs.removeAll { $0.id == tab.id }
        if selectedTabID == tab.id { selectedTabID = tabs.last?.id }
    }

    func closeSelectedTab() {
        if let tab = selectedTab { closeTab(tab) }
    }

    /// Split the given tab: open a second session to the same host beside the first.
    func toggleSplit(_ tab: TerminalTab) {
        if let split = tab.splitController {
            split.disconnect()
            tab.splitController = nil
            return
        }
        let controller = TerminalSessionController(knownHosts: knownHosts)
        configure(controller)
        controller.primeNetwork(network.isOnline)
        controller.onStatus = { [weak tab] in tab?.splitStatus = $0 }
        tab.splitController = controller
        do { controller.connect(try hostStore.credentials(for: tab.host)) }
        catch { tab.splitStatus = "Fehler: \(error.localizedDescription)" }
    }

    // MARK: - AI helpers (uses the OpenAI key from humitext/humibeam settings)

    private func recentTranscript(_ tab: TerminalTab) -> String {
        String(tab.controller.transcript.suffix(5000))
    }

    func explainOutput(_ tab: TerminalTab) async {
        await runAI(tab, title: "Ausgabe erklärt",
            system: "Du bist ein erfahrener Linux/DevOps-Assistent. Erkläre dem Nutzer knapp und klar auf Deutsch, was die folgende Terminal-Ausgabe bedeutet. Wenn Fehler oder Warnungen sichtbar sind, nenne die wahrscheinliche Ursache und einen konkreten nächsten Schritt. Kein Markdown-Code-Block, nur Fließtext.",
            user: "Terminal-Ausgabe:\n\n\(recentTranscript(tab))")
    }

    func fixError(_ tab: TerminalTab) async {
        await runAI(tab, title: "Lösungsvorschlag",
            system: "Du bist ein Linux/DevOps-Assistent. Analysiere die folgende Terminal-Ausgabe auf Fehler. Gib auf Deutsch (1) die Ursache in einem Satz und (2) einen konkreten Befehl oder Schritt zur Behebung. Knapp.",
            user: "Terminal-Ausgabe:\n\n\(recentTranscript(tab))")
    }

    /// Suggests a single shell command for an intent and inserts it (un-ausgeführt) ins Terminal.
    func suggestCommand(_ tab: TerminalTab, intent: String) async {
        guard !intent.isEmpty else { return }
        tab.aiBusy = true; tab.aiTitle = "Befehlsvorschlag"; tab.showAIPanel = true
        defer { tab.aiBusy = false }
        do {
            let cmd = try await LLMService.ask(
                system: "Gib AUSSCHLIESSLICH einen einzelnen Shell-Befehl für Linux/Ubuntu zurück, der das Ziel erfüllt. Keine Erklärung, kein Markdown, keine Anführungszeichen, kein führendes $.",
                user: "Ziel: \(intent)\n\nKontext (letzte Terminal-Ausgabe):\n\(recentTranscript(tab))")
            let clean = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            tab.aiResult = clean
            // In die Eingabezeile setzen (ohne Enter) — der Nutzer prüft und bestätigt selbst.
            if tab.connected { tab.controller.sendToShell(clean) }
        } catch {
            tab.aiResult = "Fehler: \(error.localizedDescription)"
        }
    }

    private func runAI(_ tab: TerminalTab, title: String, system: String, user: String) async {
        tab.aiBusy = true; tab.aiTitle = title; tab.aiResult = ""; tab.showAIPanel = true
        defer { tab.aiBusy = false }
        do { tab.aiResult = try await LLMService.ask(system: system, user: user, model: .rageMode, temperature: 0.2) }
        catch { tab.aiResult = "Fehler: \(error.localizedDescription)" }
    }

    /// Write text into the selected connected session (voice dictation). Returns true if handled.
    @discardableResult
    func sendVoiceText(_ text: String) -> Bool {
        guard let tab = selectedTab, tab.connected else { return false }
        tab.controller.sendToShell(text)
        return true
    }

    // MARK: - File browser (operates on the selected tab)

    private func loadInitialBrowserPath(_ tab: TerminalTab) async {
        guard let conn = tab.controller.connection else { return }
        if let home = try? await conn.remoteHome() {
            tab.browserPath = home
            await refreshBrowser(tab)
        }
    }

    func refreshBrowser(_ tab: TerminalTab) async {
        guard let conn = tab.controller.connection, !tab.browserPath.isEmpty else { return }
        tab.browserBusy = true
        defer { tab.browserBusy = false }
        do { tab.browserFiles = try await conn.listDirectory(tab.browserPath) }
        catch { tab.status = "Listing fehlgeschlagen: \(error.localizedDescription)" }
    }

    func navigate(_ tab: TerminalTab, into file: RemoteFile) async {
        guard file.isDirectory else { return }
        tab.browserPath = (tab.browserPath as NSString).appendingPathComponent(file.name)
        await refreshBrowser(tab)
    }

    func navigateUp(_ tab: TerminalTab) async {
        guard tab.browserPath != "/" else { return }
        tab.browserPath = (tab.browserPath as NSString).deletingLastPathComponent
        if tab.browserPath.isEmpty { tab.browserPath = "/" }
        await refreshBrowser(tab)
    }

    func uploadFile(_ tab: TerminalTab, localURL: URL) async {
        guard let conn = tab.controller.connection else { return }
        do {
            let data = try Data(contentsOf: localURL)
            let remote = (tab.browserPath as NSString).appendingPathComponent(localURL.lastPathComponent)
            tab.status = "lade \(localURL.lastPathComponent) hoch…"
            try await conn.upload(data, to: remote)
            tab.status = "hochgeladen: \(localURL.lastPathComponent)"
            await refreshBrowser(tab)
        } catch { tab.status = "Upload fehlgeschlagen: \(error.localizedDescription)" }
    }

    func downloadFile(_ tab: TerminalTab, file: RemoteFile, to localURL: URL) async {
        guard let conn = tab.controller.connection else { return }
        do {
            let remote = (tab.browserPath as NSString).appendingPathComponent(file.name)
            tab.status = "lade \(file.name) herunter…"
            let data = try await conn.download(remote)
            try data.write(to: localURL)
            tab.status = "heruntergeladen: \(file.name)"
        } catch { tab.status = "Download fehlgeschlagen: \(error.localizedDescription)" }
    }

    func makeDirectory(_ tab: TerminalTab, name: String) async {
        guard let conn = tab.controller.connection, !name.isEmpty else { return }
        do {
            try await conn.makeDirectory((tab.browserPath as NSString).appendingPathComponent(name))
            await refreshBrowser(tab)
        } catch { tab.status = "Ordner anlegen fehlgeschlagen: \(error.localizedDescription)" }
    }

    func delete(_ tab: TerminalTab, file: RemoteFile) async {
        guard let conn = tab.controller.connection else { return }
        do {
            try await conn.remove((tab.browserPath as NSString).appendingPathComponent(file.name),
                                  recursive: file.isDirectory)
            await refreshBrowser(tab)
        } catch { tab.status = "Löschen fehlgeschlagen: \(error.localizedDescription)" }
    }

    func rename(_ tab: TerminalTab, file: RemoteFile, to newName: String) async {
        guard let conn = tab.controller.connection, !newName.isEmpty else { return }
        let base = tab.browserPath as NSString
        do {
            try await conn.rename(base.appendingPathComponent(file.name), to: base.appendingPathComponent(newName))
            await refreshBrowser(tab)
        } catch { tab.status = "Umbenennen fehlgeschlagen: \(error.localizedDescription)" }
    }

    func chmod(_ tab: TerminalTab, file: RemoteFile, mode: String) async {
        guard let conn = tab.controller.connection, !mode.isEmpty else { return }
        do {
            try await conn.chmod((tab.browserPath as NSString).appendingPathComponent(file.name), mode: mode)
            await refreshBrowser(tab)
        } catch { tab.status = "chmod fehlgeschlagen: \(error.localizedDescription)" }
    }

    func downloadFolder(_ tab: TerminalTab, file: RemoteFile, to localURL: URL) async {
        guard let conn = tab.controller.connection else { return }
        do {
            tab.status = "packe & lade \(file.name) …"
            let data = try await conn.downloadFolderTarGz((tab.browserPath as NSString).appendingPathComponent(file.name))
            try data.write(to: localURL)
            tab.status = "Ordner geladen: \(file.name).tar.gz (\(data.count / 1024) KB)"
        } catch { tab.status = "Ordner-Download fehlgeschlagen: \(error.localizedDescription)" }
    }

    // MARK: Remote text editor (download → edit → upload)

    func openForEdit(_ tab: TerminalTab, file: RemoteFile) async {
        guard let conn = tab.controller.connection else { return }
        let path = (tab.browserPath as NSString).appendingPathComponent(file.name)
        tab.editBusy = true; tab.editFileName = file.name; tab.editPath = path
        tab.editContent = ""; tab.showEditor = true
        defer { tab.editBusy = false }
        do { tab.editContent = String(decoding: try await conn.download(path), as: UTF8.self) }
        catch { tab.editContent = "// Konnte Datei nicht laden: \(error.localizedDescription)" }
    }

    /// Opens an arbitrary remote path (e.g. one Claude mentioned) in the remote editor.
    func openPathForEdit(_ tab: TerminalTab, path: String) async {
        guard let conn = tab.controller.connection else { return }
        tab.editBusy = true
        tab.editFileName = (path as NSString).lastPathComponent
        tab.editPath = path
        tab.editContent = ""; tab.showEditor = true
        defer { tab.editBusy = false }
        do { tab.editContent = String(decoding: try await conn.download(path), as: UTF8.self) }
        catch { tab.editContent = "// Konnte Datei nicht laden: \(error.localizedDescription)\n// (relative Pfade werden ggf. nicht aufgelöst — Claudes Arbeitsverzeichnis ist unbekannt)" }
    }

    func saveEdit(_ tab: TerminalTab) async {
        guard let conn = tab.controller.connection, !tab.editPath.isEmpty else { return }
        tab.editBusy = true
        defer { tab.editBusy = false }
        do {
            try await conn.upload(Data(tab.editContent.utf8), to: tab.editPath)
            tab.status = "gespeichert: \(tab.editFileName)"
            tab.showEditor = false
        } catch { tab.status = "Speichern fehlgeschlagen: \(error.localizedDescription)" }
    }

    func navigateToBookmark(_ tab: TerminalTab, path: String) async {
        tab.browserPath = path
        await refreshBrowser(tab)
    }

    // MARK: - Port forwarding

    func addForward(_ tab: TerminalTab, localPort: Int, targetHost: String, targetPort: Int) async {
        guard let conn = tab.controller.connection else { return }
        do {
            let fwd = try await conn.startLocalForward(localPort: localPort, targetHost: targetHost, targetPort: targetPort)
            forwards.append(ActiveForward(localPort: fwd.localPort, targetHost: targetHost,
                                          targetPort: targetPort, forward: fwd, tabID: tab.id))
            tab.status = "Weiterleitung aktiv: localhost:\(fwd.localPort) → \(targetHost):\(targetPort)"
        } catch {
            tab.status = "Weiterleitung fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func stopForward(_ f: ActiveForward) {
        f.forward.close()
        forwards.removeAll { $0.id == f.id }
    }
}
