import Foundation
import AppKit
import SwiftTerm

/// Owns one SSH-backed terminal: a SwiftTerm `TerminalView` wired bidirectionally
/// to an `SSHConnection` PTY session. Also the hook point for the screenshot PasteBridge.
@MainActor
final class TerminalSessionController: NSObject, TerminalViewDelegate {

    let terminalView: TerminalView
    private(set) var connection: SSHConnection?
    private(set) var ptySession: PTYSession?
    /// Wird nach jedem (Re-)Connect als erste Eingabe in die Shell geschrieben (z.B. tmux-Attach).
    var startupCommand: String?
    /// $TERM für die PTY-Anforderung (Profil „Erweitert"); nil = xterm-256color.
    var termType: String?

    // MARK: - Sitzungs-Protokoll (vollständiges Transkript auf Platte, durchsuchbar)

    /// Ordnername fürs Protokoll-Archiv (Host-Anzeigename); nil = nicht archivieren.
    var archiveLabel: String?
    private var archiveURL: URL?
    private var archiveBuffer = ""

    private func archive(_ chunk: String) {
        guard let label = archiveLabel else { return }
        if archiveURL == nil {
            let dir = AppSupportPaths.appSupportDirectoryURL
                .appendingPathComponent("Transcripts", isDirectory: true)
                .appendingPathComponent(label.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
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
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
    private let knownHosts: KnownHostsStore

    var onConnected: (() -> Void)?
    var onClosed: (() -> Void)?
    var onError: ((String) -> Void)?
    /// Status line for the UI ("verbinde…", "verbunden", error).
    var onStatus: ((String) -> Void)?
    /// Called with the user's keystrokes (for broadcast-input to other sessions).
    var onUserInput: (([UInt8]) -> Void)?

    private(set) lazy var pasteBridge = PasteBridge(controller: self)

    /// Rolling, ANSI-stripped transcript of recent output (for the AI helpers). Capped.
    private(set) var transcript = ""
    private(set) var claudeDetected = false
    var onClaudeDetected: (() -> Void)?
    private static let transcriptCap = 16_000

    /// True when Claude Code is showing a permission prompt ("Do you want to proceed?").
    private(set) var awaitingApproval = false
    /// Whether the prompt offers a "don't ask again" (option 2) choice.
    private(set) var approvalAllowAlways = false
    /// The structured prompt (action type, command/diff preview) for the inline approval card.
    private(set) var approval: ClaudeApproval?
    var onApprovalChange: (() -> Void)?

    /// Files Claude Code recently touched (parsed from its tool-call output), newest first.
    private(set) var recentPaths: [String] = []
    var onPathsChange: (() -> Void)?

    /// True while Claude Code is actively working ("esc to interrupt" visible).
    private var claudeBusy = false
    /// Fired when Claude transitions from working → idle (a run finished).
    var onClaudeIdle: (() -> Void)?
    private static let pathRegex = try? NSRegularExpression(
        pattern: #"(?:Update|Read|Write|Edit|MultiEdit|Create|Search)\(([^)\n]{1,200})\)"#)

    // Reconnect (network-aware, unbounded while the link is up, capped exponential backoff)
    var autoReconnect = true
    private var lastCredentials: SSHCredentials?
    private var lastProxy: SSHConnection.ProxyJump?
    private var userInitiatedDisconnect = false
    private var reconnectAttempts = 0
    private let maxBackoff: Double = 30
    private var networkAvailable = true
    private var reconnectWorkItem: DispatchWorkItem?
    private var keepaliveTimer: Timer?
    private let keepaliveInterval: TimeInterval = 45

    init(knownHosts: KnownHostsStore) {
        self.knownHosts = knownHosts
        self.terminalView = HumibeamTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        super.init()
        terminalView.terminalDelegate = self
        terminalView.configureNativeColors()
        // Tiefer Verlauf: 10.000 Zeilen statt SwiftTerms 500 — weit zurückscrollen + durchsuchen.
        terminalView.getTerminal().changeScrollback(10_000)
        if let hv = terminalView as? HumibeamTerminalView {
            hv.pasteInterceptor = { [weak self] in self?.pasteBridge.handlePasteFromClipboard() ?? false }
            hv.fileDropHandler = { [weak self] urls in self?.pasteBridge.handleDroppedFiles(urls) ?? false }
            hv.registerForDraggedTypes([.fileURL])
        }
    }

    // MARK: - Lifecycle

    func connect(_ credentials: SSHCredentials, proxy: SSHConnection.ProxyJump? = nil) {
        lastCredentials = credentials
        lastProxy = proxy
        userInitiatedDisconnect = false
        onStatus?("verbinde zu \(credentials.username)@\(credentials.host)…")
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
                if let startup = self.startupCommand {
                    session.write(startup + "\n")
                }
                self.reconnectAttempts = 0
                self.onStatus?("verbunden")
                self.onConnected?()
                self.startKeepalive()
            } catch {
                self.onStatus?("Fehler: \(error.localizedDescription)")
                self.onError?(error.localizedDescription)
                self.connection = nil
                // A failed (re)connect attempt should keep retrying with backoff while online.
                if !self.userInitiatedDisconnect, self.autoReconnect, self.networkAvailable {
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handleSessionClosed() {
        ptySession = nil
        connection = nil
        stopKeepalive()
        flushArchive()
        if userInitiatedDisconnect { onStatus?("Verbindung geschlossen."); onClosed?(); return }
        guard autoReconnect, lastCredentials != nil else {
            onStatus?("Verbindung geschlossen."); onClosed?(); return
        }
        if !networkAvailable {
            // Offline: don't burn backoff attempts — wait for the network to return.
            onStatus?("offline – warte auf Netz…")
            return
        }
        scheduleReconnect()
    }

    /// Schedules a reconnect with capped exponential backoff (1, 2, 4, 8, 16, 30, 30 … seconds).
    private func scheduleReconnect() {
        guard let creds = lastCredentials, connection == nil, !userInitiatedDisconnect else { return }
        reconnectWorkItem?.cancel()
        reconnectAttempts += 1
        let delay = min(maxBackoff, pow(2, Double(min(reconnectAttempts - 1, 5))))
        onStatus?("Verbindung verloren – Reconnect in \(Int(delay))s (Versuch \(reconnectAttempts))…")
        let proxy = lastProxy
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connection == nil,
                  !self.userInitiatedDisconnect, self.networkAvailable else { return }
            self.connect(creds, proxy: proxy)
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Called from the network monitor when the link drops: pause reconnect loops.
    func networkBecameUnavailable() {
        networkAvailable = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    /// Called from the network monitor when the link returns: reconnect immediately, no backoff wait.
    func networkBecameAvailable() {
        networkAvailable = true
        guard connection == nil, !userInitiatedDisconnect, autoReconnect,
              let creds = lastCredentials else { return }
        reconnectAttempts = 0
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        connect(creds, proxy: lastProxy)
    }

    /// Sets the initial network state when the controller is created (no reconnect side effect).
    func primeNetwork(_ online: Bool) { networkAvailable = online }

    // MARK: Keepalive — detect a half-open connection faster than TCP alone would.

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
            // The link is dead but the OS hasn't told us yet — force the reconnect cycle.
            await conn.close()
        }
    }

    func disconnect() {
        userInitiatedDisconnect = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        stopKeepalive()
        flushArchive()
        ptySession?.close()
        let conn = connection
        connection = nil
        ptySession = nil
        Task { await conn?.close() }
    }

    func setFont(_ font: NSFont) {
        terminalView.font = font
    }

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
                onClaudeDetected?()
            }
        }
        detectApprovalPrompt()
        extractRecentPaths()
        detectClaudeIdle()
    }

    /// Tracks Claude's working state via its "esc to interrupt" indicator and fires `onClaudeIdle`
    /// when a run finishes, so the app can notify the user if the window isn't frontmost.
    private func detectClaudeIdle() {
        let busy = transcript.suffix(400).lowercased().contains("esc to interrupt")
        if busy != claudeBusy {
            let wasBusy = claudeBusy
            claudeBusy = busy
            if wasBusy && !busy { onClaudeIdle?() }
        }
    }

    /// Pulls file paths out of Claude Code's tool-call lines (e.g. "Update(src/foo.py)") so the
    /// UI can offer them for one-click opening in the remote editor.
    private func extractRecentPaths() {
        guard let regex = Self.pathRegex else { return }
        let text = String(transcript.suffix(4000))
        let ns = text as NSString
        var found: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges > 1 else { continue }
            var p = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            // Drop a trailing " line 12" / ", lines 3-9" hint Claude sometimes appends.
            if let r = p.range(of: #"\s*,?\s*lines?\s.*$"#, options: .regularExpression) { p.removeSubrange(r) }
            p = p.trimmingCharacters(in: .whitespaces)
            if !p.isEmpty, !found.contains(p) { found.append(p) }
        }
        // Newest last in transcript → newest first for the menu; cap the list.
        let newest = Array(found.reversed().prefix(8))
        if newest != recentPaths {
            recentPaths = newest
            onPathsChange?()
        }
    }

    /// Heuristically detects Claude Code's permission prompt in the recent output so the UI can
    /// surface Allow/Deny buttons. Looks only at the tail (the prompt is the last thing on screen).
    private func detectApprovalPrompt() {
        let parsed = ClaudeApproval.parse(transcript)
        let prompt = parsed != nil
        let allowAlways = parsed?.allowAlways ?? false
        if prompt != awaitingApproval || allowAlways != approvalAllowAlways || parsed != approval {
            awaitingApproval = prompt
            approvalAllowAlways = allowAlways
            approval = parsed
            onApprovalChange?()
        }
    }

    /// Sends a response to Claude Code's permission prompt (the option number / Esc).
    func approve() { sendApproval("1") }
    func approveAlways() { sendApproval("2") }
    func deny() { sendApproval("\u{1b}") } // Esc → "No, and tell Claude…"

    private func sendApproval(_ keys: String) {
        sendToShell(keys)
        awaitingApproval = false
        approvalAllowAlways = false
        approval = nil
        onApprovalChange?()
    }

    /// Strips CSI/OSC escape sequences so the AI sees readable text.
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
    }

    @discardableResult
    func findNext(_ term: String) -> Bool { terminalView.findNext(term) }
    @discardableResult
    func findPrevious(_ term: String) -> Bool { terminalView.findPrevious(term) }

    /// Used by voice dictation and PasteBridge to type text into the live session.
    func sendToShell(_ text: String) {
        ptySession?.write(text)
    }

    func sendToShell(_ bytes: [UInt8]) {
        ptySession?.write(bytes)
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        ptySession?.write(bytes)
        captureCommandInput(bytes)
        onUserInput?(bytes) // broadcast-input to sibling sessions, if enabled
    }

    // MARK: - Befehls-Verlauf (Zeilenpuffer der Tastatureingabe)

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

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Ignore transient zero/negative sizes reported during view re-parenting (split toggling).
        guard newCols > 0, newRows > 0 else { return }
        ptySession?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) { /* could surface to window title */ }

    /// Latest working directory the remote shell reported via OSC 7 (if it emits it). Used to open
    /// the integrated file manager in the same directory the terminal is sitting in.
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
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(str, forType: .string)
        }
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func bell(source: TerminalView) {
        NSSound.beep()
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { /* unused */ }
}
