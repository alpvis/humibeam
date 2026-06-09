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
    var onApprovalChange: (() -> Void)?

    // Reconnect
    var autoReconnect = true
    private var lastCredentials: SSHCredentials?
    private var userInitiatedDisconnect = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    init(knownHosts: KnownHostsStore) {
        self.knownHosts = knownHosts
        self.terminalView = HumibeamTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        super.init()
        terminalView.terminalDelegate = self
        terminalView.configureNativeColors()
        if let hv = terminalView as? HumibeamTerminalView {
            hv.pasteInterceptor = { [weak self] in self?.pasteBridge.handlePasteFromClipboard() ?? false }
            hv.fileDropHandler = { [weak self] urls in self?.pasteBridge.handleDroppedFiles(urls) ?? false }
            hv.registerForDraggedTypes([.fileURL])
        }
    }

    // MARK: - Lifecycle

    func connect(_ credentials: SSHCredentials) {
        lastCredentials = credentials
        userInitiatedDisconnect = false
        onStatus?("verbinde zu \(credentials.username)@\(credentials.host)…")
        let conn = SSHConnection(credentials: credentials, hostKeyVerifier: knownHosts)
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
                self.reconnectAttempts = 0
                self.onStatus?("verbunden")
                self.onConnected?()
            } catch {
                self.onStatus?("Fehler: \(error.localizedDescription)")
                self.onError?(error.localizedDescription)
            }
        }
    }

    private func handleSessionClosed() {
        ptySession = nil
        connection = nil
        // Auto-reconnect on an unexpected drop (keeps the same terminal view + scrollback).
        if !userInitiatedDisconnect, autoReconnect, reconnectAttempts < maxReconnectAttempts,
           let creds = lastCredentials {
            reconnectAttempts += 1
            onStatus?("Verbindung verloren – Reconnect \(reconnectAttempts)/\(maxReconnectAttempts)…")
            let delay = Double(min(reconnectAttempts, 4)) // 1,2,3,4s backoff
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.connection == nil, !self.userInitiatedDisconnect else { return }
                self.connect(creds)
            }
        } else {
            onStatus?("Verbindung geschlossen.")
            onClosed?()
        }
    }

    func disconnect() {
        userInitiatedDisconnect = true
        ptySession?.close()
        let conn = connection
        connection = nil
        ptySession = nil
        Task { await conn?.close() }
    }

    func setFontSize(_ size: CGFloat) {
        terminalView.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

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
                onClaudeDetected?()
            }
        }
        detectApprovalPrompt()
    }

    /// Heuristically detects Claude Code's permission prompt in the recent output so the UI can
    /// surface Allow/Deny buttons. Looks only at the tail (the prompt is the last thing on screen).
    private func detectApprovalPrompt() {
        let tail = transcript.suffix(700).lowercased()
        let hasYes = tail.contains("1. yes") || tail.contains("❯ 1.")
        let hasNo = tail.contains("no, and tell claude") || tail.contains("3. no") || tail.contains("2. no")
        let prompt = hasYes && (hasNo || tail.contains("do you want"))
        let allowAlways = tail.contains("don't ask again") || tail.contains("don’t ask again")
        if prompt != awaitingApproval || allowAlways != approvalAllowAlways {
            awaitingApproval = prompt
            approvalAllowAlways = allowAlways
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
        onUserInput?(bytes) // broadcast-input to sibling sessions, if enabled
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        ptySession?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) { /* could surface to window title */ }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { /* unused */ }

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
