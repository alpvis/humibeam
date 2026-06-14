import Foundation
import UIKit
import SwiftTerm

/// Owns one SSH-backed terminal on iOS: a SwiftTerm `TerminalView` wired bidirectionally to an
/// `SSHConnection` PTY session. iOS-Port des Mac-`TerminalSessionController` — gleiche
/// Cockpit-Logik (Transcript, Approval-Erkennung, Reconnect, Keepalive), UIKit statt AppKit.
@MainActor
final class TerminalController: NSObject, TerminalViewDelegate, ObservableObject {

    let terminalView: BeamTerminalView
    private(set) var connection: SSHConnection?
    private(set) var ptySession: PTYSession?
    private let knownHosts: KnownHostsStore

    // UI-State (SwiftUI beobachtet den Controller direkt)
    @Published private(set) var status: String = ""
    @Published private(set) var isConnected = false
    @Published private(set) var claudeDetected = false
    @Published private(set) var approval: ClaudeApproval?
    @Published private(set) var recentPaths: [String] = []
    /// „Claude-Status Plus": was der Agent gerade tut (liest/bearbeitet/führt aus/wartet).
    @Published private(set) var activity = ClaudeStatus(kind: .idle, detail: nil)

    /// Rolling, ANSI-stripped transcript of recent output. Capped.
    private(set) var transcript = ""
    private static let transcriptCap = 16_000

    /// True while Claude Code is actively working ("esc to interrupt" visible).
    private var claudeBusy = false
    var onClaudeIdle: (() -> Void)?
    /// Wird nach jedem erfolgreichen (Re-)Connect aufgerufen (z. B. für Auto-Snippets).
    var onConnected: (() -> Void)?

    /// Aufträge, die nacheinander abgearbeitet werden: sobald Claude idle wird, geht der nächste raus.
    @Published private(set) var promptQueue: [String] = []

    /// Reiht einen Prompt ein. Ist Claude gerade frei, startet er sofort, sonst wartet er.
    func enqueuePrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        promptQueue.append(trimmed)
        if !claudeBusy, isConnected { drainPromptQueue() }
    }

    func clearPromptQueue() { promptQueue.removeAll() }

    private func drainPromptQueue() {
        guard !promptQueue.isEmpty else { return }
        let next = promptQueue.removeFirst()
        sendToShell(next.hasSuffix("\n") ? next : next + "\n")
    }
    private static let pathRegex = try? NSRegularExpression(
        pattern: #"(?:Update|Read|Write|Edit|MultiEdit|Create|Search)\(([^)\n]{1,200})\)"#)

    // Reconnect (network-aware, capped exponential backoff)
    var autoReconnect = true
    private var lastCredentials: SSHCredentials?
    private var lastProxy: SSHConnection.ProxyJump?
    private var userInitiatedDisconnect = false
    private var reconnectAttempts = 0
    /// Wird nach jedem (Re-)Connect als erste Eingabe geschrieben (z.B. tmux-Attach).
    var startupCommand: String?
    /// Fertige `export …`-Zeilen, vor dem Startbefehl in die Shell geschrieben (Env-Injektion).
    var envExports: String?
    /// $TERM für die PTY-Anforderung (Profil „Erweitert"); nil = xterm-256color.
    var termType: String?
    private let maxBackoff: Double = 30
    private var networkAvailable = true
    private var reconnectWorkItem: DispatchWorkItem?
    private var keepaliveTimer: Timer?
    private let keepaliveInterval: TimeInterval = 45

    init(knownHosts: KnownHostsStore) {
        self.knownHosts = knownHosts
        self.terminalView = BeamTerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        super.init()
        terminalView.terminalDelegate = self
        // Tiefer Verlauf: 10.000 Zeilen statt SwiftTerms 500 — weit zurückscrollen + durchsuchen.
        terminalView.getTerminal().changeScrollback(10_000)
    }

    // MARK: - Lifecycle

    func connect(_ credentials: SSHCredentials, proxy: SSHConnection.ProxyJump? = nil) {
        lastCredentials = credentials
        lastProxy = proxy
        userInitiatedDisconnect = false
        status = "verbinde zu \(credentials.username)@\(credentials.host)…"
        let conn = SSHConnection(credentials: credentials, hostKeyVerifier: knownHosts, proxyJump: proxy)
        self.connection = conn

        let terminal = terminalView.getTerminal()
        let cols = terminal.cols
        let rows = terminal.rows

        Task {
            do {
                try await conn.connect()
                let session = try await conn.openShell(term: self.termType ?? "xterm-256color",
                                                       cols: cols, rows: rows)
                self.ptySession = session

                session.onOutput = { [weak self] bytes in
                    Task { @MainActor in
                        self?.terminalView.feed(byteArray: bytes[...])
                        self?.captureTranscript(bytes)
                    }
                }
                session.onClosed = { [weak self] in
                    Task { @MainActor in self?.handleSessionClosed() }
                }
                if let env = self.envExports, !env.isEmpty {
                    session.write(env)
                }
                if let startup = self.startupCommand {
                    session.write(startup + "\n")
                }
                self.reconnectAttempts = 0
                self.status = "verbunden"
                self.isConnected = true
                self.onConnected?()
                self.startKeepalive()
            } catch {
                self.status = "Fehler: \(error.localizedDescription)"
                self.connection = nil
                self.isConnected = false
                if !self.userInitiatedDisconnect, self.autoReconnect, self.networkAvailable {
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handleSessionClosed() {
        flushArchive()
        ptySession = nil
        connection = nil
        isConnected = false
        stopKeepalive()
        if userInitiatedDisconnect { status = "Verbindung geschlossen."; return }
        guard autoReconnect, lastCredentials != nil else {
            status = "Verbindung geschlossen."; return
        }
        if !networkAvailable {
            status = "offline – warte auf Netz…"
            return
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard let creds = lastCredentials, connection == nil, !userInitiatedDisconnect else { return }
        reconnectWorkItem?.cancel()
        reconnectAttempts += 1
        let delay = min(maxBackoff, pow(2, Double(min(reconnectAttempts - 1, 5))))
        status = "Verbindung verloren – Reconnect in \(Int(delay))s (Versuch \(reconnectAttempts))…"
        let proxy = lastProxy
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connection == nil,
                  !self.userInitiatedDisconnect, self.networkAvailable else { return }
            self.connect(creds, proxy: proxy)
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func networkBecameUnavailable() {
        networkAvailable = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    func networkBecameAvailable() {
        networkAvailable = true
        guard connection == nil, !userInitiatedDisconnect, autoReconnect,
              let creds = lastCredentials else { return }
        reconnectAttempts = 0
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        connect(creds, proxy: lastProxy)
    }

    func primeNetwork(_ online: Bool) { networkAvailable = online }

    // MARK: Keepalive

    private func startKeepalive() {
        stopKeepalive()
        let timer = Timer.scheduledTimer(withTimeInterval: keepaliveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.keepalivePing() }
        }
        keepaliveTimer = timer
    }

    private func stopKeepalive() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
    }

    private func keepalivePing() async {
        guard let conn = connection, networkAvailable else { return }
        do {
            _ = try await conn.exec("true")
        } catch {
            await conn.close()
        }
    }

    func disconnect() {
        flushArchive()
        userInitiatedDisconnect = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        stopKeepalive()
        ptySession?.close()
        let conn = connection
        connection = nil
        ptySession = nil
        isConnected = false
        Task { await conn?.close() }
    }

    // MARK: - Suche im Scrollback (SwiftTerms TerminalViewSearch)

    @discardableResult
    func findNext(_ term: String) -> Bool { terminalView.findNext(term) }
    @discardableResult
    func findPrevious(_ term: String) -> Bool { terminalView.findPrevious(term) }
    func clearSearch() { terminalView.clearSearch() }

    func setFontSize(_ size: CGFloat) {
        terminalView.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func setFont(_ font: UIFont) {
        terminalView.font = font
    }

    // MARK: - Transcript-Archiv (wie am Mac: Application Support/Humibeam/Transcripts/<Host>/)

    /// Host-Name fürs Protokoll-Verzeichnis; nil = nicht archivieren.
    var archiveLabel: String?
    private var archiveURL: URL?
    private var archiveBuffer = ""

    private func archive(_ chunk: String) {
        guard let label = archiveLabel else { return }
        if archiveURL == nil {
            let safe = label.replacingOccurrences(of: "/", with: "-")
            let dir = AppSupportPaths.appSupportDirectoryURL
                .appendingPathComponent("Transcripts", isDirectory: true)
                .appendingPathComponent(safe, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
            archiveURL = dir.appendingPathComponent("\(fmt.string(from: Date())).log")
        }
        archiveBuffer += chunk
        if archiveBuffer.utf8.count > 8192 { flushArchive() }
    }

    func flushArchive() {
        guard let url = archiveURL, !archiveBuffer.isEmpty else { return }
        let data = Data(archiveBuffer.utf8)
        archiveBuffer = ""
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    func setStatus(_ text: String) { status = text }

    private func captureTranscript(_ bytes: [UInt8]) {
        let chunk = Self.stripANSI(String(decoding: bytes, as: UTF8.self))
        guard !chunk.isEmpty else { return }
        archive(chunk)
        transcript += chunk
        if transcript.count > Self.transcriptCap {
            transcript = String(transcript.suffix(Self.transcriptCap))
        }
        if !claudeDetected {
            let lower = transcript.lowercased()
            if lower.contains("claude code") || lower.contains("esc to interrupt") || transcript.contains("✻") {
                claudeDetected = true
            }
        }
        detectApprovalPrompt()
        extractRecentPaths()
        detectClaudeIdle()
        if claudeDetected {
            let status = ClaudeStatus.parse(transcriptTail: String(transcript.suffix(2000)),
                                            busy: claudeBusy, awaitingApproval: approval != nil)
            if status != activity { activity = status }
        }
    }

    private func detectClaudeIdle() {
        let busy = transcript.suffix(400).lowercased().contains("esc to interrupt")
        if busy != claudeBusy {
            let wasBusy = claudeBusy
            claudeBusy = busy
            if wasBusy && !busy {
                onClaudeIdle?()
                // Nächsten eingereihten Auftrag abschicken, sobald Claude fertig ist.
                if !promptQueue.isEmpty { drainPromptQueue() }
            }
        }
    }

    private func extractRecentPaths() {
        guard let regex = Self.pathRegex else { return }
        let text = String(transcript.suffix(4000))
        let ns = text as NSString
        var found: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges > 1 else { continue }
            var p = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if let r = p.range(of: #"\s*,?\s*lines?\s.*$"#, options: .regularExpression) { p.removeSubrange(r) }
            p = p.trimmingCharacters(in: .whitespaces)
            if !p.isEmpty, !found.contains(p) { found.append(p) }
        }
        let newest = Array(found.reversed().prefix(8))
        if newest != recentPaths { recentPaths = newest }
    }

    private func detectApprovalPrompt() {
        let parsed = ClaudeApproval.parse(transcript)
        if parsed != approval { approval = parsed }
    }

    /// Sends a response to Claude Code's permission prompt (the option number / Esc).
    func approve() { sendApproval("1") }
    func approveAlways() { sendApproval("2") }
    func deny() { sendApproval("\u{1b}") }

    private func sendApproval(_ keys: String) {
        sendToShell(keys)
        approval = nil
    }

    /// Strips CSI/OSC escape sequences so the parser sees readable text.
    static func stripANSI(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\u{1B}" { // ESC
                if i + 1 < chars.count, chars[i+1] == "[" { // CSI
                    i += 2
                    while i < chars.count, !("@"..."~" ~= chars[i]) { i += 1 }
                    i += 1
                } else if i + 1 < chars.count, chars[i+1] == "]" { // OSC … BEL or ST
                    i += 2
                    while i < chars.count, chars[i] != "\u{07}" && chars[i] != "\u{1B}" { i += 1 }
                    i += 1
                } else {
                    i += 1
                }
            } else if c == "\r" {
                i += 1
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    func applyTheme(_ theme: TerminalTheme) {
        terminalView.nativeForegroundColor = theme.foreground
        terminalView.nativeBackgroundColor = theme.background
        terminalView.caretColor = theme.caret
        terminalView.backgroundColor = theme.background
    }

    /// Used by image paste, snippets, dictation and the key toolbar to type into the live session.
    /// Läuft mit durch den Zeilenpuffer, damit der Befehls-Verlauf vollständige Zeilen sieht
    /// (anders als am Mac kommt auf iOS viel Eingabe nicht über die Hardware-Tastatur).
    func sendToShell(_ text: String) {
        ptySession?.write(text)
        captureCommandInput(Array(text.utf8))
    }

    func sendToShell(_ bytes: [UInt8]) {
        ptySession?.write(bytes)
        captureCommandInput(bytes)
    }

    // MARK: - Befehls-Verlauf (Zeilenpuffer der Tastatureingabe — gleiche Logik wie am Mac)

    var onCommandSubmitted: ((String) -> Void)?
    private var lineBuffer: [UInt8] = []
    /// Pfeiltasten/Tab verändern die echte Zeile unsichtbar für uns → Zeile nicht aufzeichnen.
    private var lineDirty = false

    private func captureCommandInput(_ bytes: [UInt8]) {
        for b in bytes {
            switch b {
            case 0x0D, 0x0A: // Enter
                if !lineDirty, !lineBuffer.isEmpty,
                   let cmd = String(bytes: lineBuffer, encoding: .utf8) {
                    onCommandSubmitted?(cmd)
                }
                lineBuffer.removeAll(); lineDirty = false
            case 0x7F, 0x08: // Backspace
                if !lineBuffer.isEmpty { lineBuffer.removeLast() }
            case 0x03, 0x15: // Ctrl-C / Ctrl-U verwerfen die Zeile
                lineBuffer.removeAll(); lineDirty = false
            case 0x1B, 0x09: // ESC-Sequenzen (Pfeile) und Tab-Vervollständigung
                lineDirty = true
            case 0x20...0x7E:
                lineBuffer.append(b)
            default:
                if b >= 0x80 { lineBuffer.append(b) }  // UTF-8-Folgebytes (Umlaute etc.)
                else { lineDirty = true }              // sonstige Steuerzeichen
            }
        }
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        ptySession?.write(Array(data))
        captureCommandInput(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        ptySession?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) { /* unused */ }

    /// Latest working directory the remote shell reported via OSC 7 (if it emits it).
    private(set) var currentDirectory: String?

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        if let url = URL(string: directory), url.scheme == "file" {
            currentDirectory = url.path
        } else {
            currentDirectory = directory
        }
    }

    func scrolled(source: TerminalView, position: Double) { /* unused */ }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(data: content, encoding: .utf8) {
            UIPasteboard.general.string = str
        }
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }

    func bell(source: TerminalView) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) { /* unused */ }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { /* unused */ }
}

/// TerminalView subclass: ersetzt SwiftTerms totes UIMenuController-Kontextmenü (zeigt seit
/// iOS 16 nichts mehr an) durch ein UIEditMenuInteraction-Menü — Kopieren/Einfügen/Auswählen
/// bei Doppeltipp und langem Drücken. Dazu Pinch-to-Zoom für die Schriftgröße.
final class BeamTerminalView: SwiftTerm.TerminalView, UIEditMenuInteractionDelegate {
    private var editMenu: UIEditMenuInteraction?
    private var menuPoint: CGPoint = .zero
    /// Schriftgröße beim Beginn der Pinch-Geste (Zoom rechnet relativ dazu).
    private var pinchBaseSize: CGFloat = 0
    /// Wird vom Host gesetzt; bekommt die neue Schriftgröße beim Pinch-Zoom.
    var onPinchFontSize: ((CGFloat) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, editMenu == nil else { return }
        let interaction = UIEditMenuInteraction(delegate: self)
        addInteraction(interaction)
        editMenu = interaction
        // SwiftTerms eigene Gesten weiterverwenden: zusätzliche Targets statt eigener
        // Recognizer, damit sich nichts gegenseitig blockiert. Der lange Druck setzt in
        // SwiftTerm `lastLongSelect` (Wort-Auswahl), der Doppeltipp wählt das Wort aus.
        for recognizer in gestureRecognizers ?? [] {
            if recognizer is UILongPressGestureRecognizer {
                recognizer.addTarget(self, action: #selector(beamLongPress(_:)))
            } else if let tap = recognizer as? UITapGestureRecognizer, tap.numberOfTapsRequired == 2 {
                tap.addTarget(self, action: #selector(beamDoubleTap(_:)))
            }
        }
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(beamPinch(_:)))
        addGestureRecognizer(pinch)
    }

    @objc private func beamLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        presentEditMenu(at: gesture.location(in: self))
    }

    @objc private func beamDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: self)
        // SwiftTerms Handler wählt das Wort aus; Menü erst danach zeigen.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.canPerformAction(#selector(self.copy(_:)), withSender: nil) else { return }
            self.presentEditMenu(at: point)
        }
    }

    private func presentEditMenu(at point: CGPoint) {
        menuPoint = point
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        var actions: [UIAction] = []
        let hasSelection = canPerformAction(#selector(copy(_:)), withSender: nil)
        if hasSelection {
            actions.append(UIAction(title: "Kopieren") { [weak self] _ in self?.copy(nil) })
        } else {
            // `select(nil)` wählt das Wort an der Stelle des langen Drucks (lastLongSelect).
            actions.append(UIAction(title: "Auswählen") { [weak self] _ in
                self?.select(nil)
                DispatchQueue.main.async { self?.presentEditMenu(at: self?.menuPoint ?? .zero) }
            })
        }
        if UIPasteboard.general.hasStrings {
            actions.append(UIAction(title: "Einfügen") { [weak self] _ in self?.paste(nil) })
        }
        actions.append(UIAction(title: "Alles auswählen") { [weak self] _ in
            self?.selectAll(nil)
            DispatchQueue.main.async { self?.presentEditMenu(at: self?.menuPoint ?? .zero) }
        })
        return UIMenu(children: actions)
    }

    @objc private func beamPinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchBaseSize = font.pointSize
        case .changed:
            let size = (pinchBaseSize * gesture.scale).rounded()
            let clamped = min(max(size, 9), 28)
            if clamped != font.pointSize { onPinchFontSize?(clamped) }
        default:
            break
        }
    }
}
