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

    /// Rolling, ANSI-stripped transcript of recent output. Capped.
    private(set) var transcript = ""
    private static let transcriptCap = 16_000

    /// True while Claude Code is actively working ("esc to interrupt" visible).
    private var claudeBusy = false
    var onClaudeIdle: (() -> Void)?
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
                let session = try await conn.openShell(cols: cols, rows: rows)
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
                if let startup = self.startupCommand {
                    session.write(startup + "\n")
                }
                self.reconnectAttempts = 0
                self.status = "verbunden"
                self.isConnected = true
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

    func setFontSize(_ size: CGFloat) {
        terminalView.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func setStatus(_ text: String) { status = text }

    private func captureTranscript(_ bytes: [UInt8]) {
        let chunk = Self.stripANSI(String(decoding: bytes, as: UTF8.self))
        guard !chunk.isEmpty else { return }
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
    }

    private func detectClaudeIdle() {
        let busy = transcript.suffix(400).lowercased().contains("esc to interrupt")
        if busy != claudeBusy {
            let wasBusy = claudeBusy
            claudeBusy = busy
            if wasBusy && !busy { onClaudeIdle?() }
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

/// TerminalView subclass (Haken für künftige Anpassungen; Accessory wird via
/// SwiftTerms setzbarem `inputAccessoryView` angehängt).
final class BeamTerminalView: SwiftTerm.TerminalView {}
