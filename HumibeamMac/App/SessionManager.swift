import Foundation
import AppKit
import SwiftUI
import Observation
import SwiftTerm

/// Owns the open session windows — one window per session (local or SSH).
/// The menu-bar popover is the hub that launches sessions and lists the active ones;
/// closing a window actively ends that session. Sessions stay alive while their window is open.
@Observable
@MainActor
final class SessionManager: NSObject, NSWindowDelegate {
    let shell: HumibeamShell
    var localSessions: [LocalSession] = []
    var fileSessions: [FileSession] = []

    /// window per session id (an SSH tab id or a local session id)
    @ObservationIgnored private var windows: [UUID: NSWindow] = [:]
    @ObservationIgnored private var profilesWindow: NSWindow?
    @ObservationIgnored private var paletteWindow: NSWindow?
    @ObservationIgnored private var snippetsWindow: NSWindow?

    private var anyWindowOpen: Bool { !windows.isEmpty || profilesWindow != nil || snippetsWindow != nil }

    func openSnippetsWindow() {
        if let w = snippetsWindow {
            NSApp.setActivationPolicy(.regular); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Snippets"
        window.contentViewController = NSHostingController(rootView: SnippetsView(store: shell.snippets))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        snippetsWindow = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Command palette (⌘K)

    func toggleCommandPalette() {
        if paletteWindow != nil { closeCommandPalette(); return }
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                              styleMask: [.titled, .fullSizeContentView, .closable],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.contentViewController = NSHostingController(
            rootView: CommandPaletteView(sessions: self, onClose: { [weak self] in self?.closeCommandPalette() }))
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            window.setFrameTopLeftPoint(NSPoint(x: f.midX - 280, y: f.midY + 200))
        } else {
            window.center()
        }
        paletteWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeCommandPalette() {
        paletteWindow?.close()
        paletteWindow = nil
    }

    // MARK: - First-run hub tips

    @ObservationIgnored private var tipsWindow: NSWindow?

    func openHubTipsIfNeeded() {
        let key = "humibeam.didSeeHubTips.v2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentViewController = NSHostingController(
            rootView: HubTipsView(onClose: { [weak self] in self?.tipsWindow?.close(); self?.tipsWindow = nil }))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        tipsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(shell: HumibeamShell) {
        self.shell = shell
        super.init()
    }

    // MARK: - Persistence (restore open sessions on next launch)

    private struct SessionDescriptor: Codable {
        var kind: String          // "local" | "ssh" | "files"
        var hostID: UUID?
    }
    @ObservationIgnored private let restoreKey = "humibeam.openSessions"
    @ObservationIgnored private var restoring = false

    private func persistOpenSessions() {
        guard !restoring else { return }
        var list: [SessionDescriptor] = localSessions.map { _ in SessionDescriptor(kind: "local", hostID: nil) }
        list += shell.tabs.filter { windows[$0.id] != nil }.map { SessionDescriptor(kind: "ssh", hostID: $0.host.id) }
        list += fileSessions.filter { windows[$0.id] != nil }.map { SessionDescriptor(kind: "files", hostID: $0.host.id) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: restoreKey)
        }
    }

    /// Reopens the sessions that were open at the last quit. Called once at launch.
    func restoreSessions() {
        guard let data = UserDefaults.standard.data(forKey: restoreKey),
              let list = try? JSONDecoder().decode([SessionDescriptor].self, from: data),
              !list.isEmpty else { return }
        restoring = true
        for d in list {
            switch d.kind {
            case "local":
                openLocalSession()
            case "ssh":
                if let id = d.hostID, let host = shell.hostStore.hosts.first(where: { $0.id == id }) {
                    openSSHSession(host)
                }
            case "files":
                if let id = d.hostID, let host = shell.hostStore.hosts.first(where: { $0.id == id }) {
                    openFileSession(host)
                }
            default: break
            }
        }
        restoring = false
        persistOpenSessions()
    }

    // MARK: - Unified list for the topbar

    struct ActiveSession: Identifiable {
        let id: UUID
        let title: String
        let connected: Bool
        let symbol: String
    }

    var activeSessions: [ActiveSession] {
        let loc = localSessions.map {
            ActiveSession(id: $0.id, title: $0.title, connected: true, symbol: "apple.terminal")
        }
        let ssh = shell.tabs.map {
            ActiveSession(id: $0.id, title: $0.title, connected: $0.connected, symbol: "server.rack")
        }
        let files = fileSessions.map {
            ActiveSession(id: $0.id, title: $0.title, connected: $0.connected, symbol: "folder")
        }
        return loc + ssh + files
    }

    var hasOpenSessions: Bool { !windows.isEmpty }

    // MARK: - Open sessions

    func openLocalSession() {
        let session = LocalSession(fontSize: shell.terminalFontSize, theme: shell.theme)
        localSessions.append(session)
        let window = makeWindow(title: session.title, id: session.id,
                                content: AnyView(LocalSessionWindowView(session: session)))
        session.window = window
        windows[session.id] = window
        present(window)
    }

    func openSSHSession(_ host: SSHHost) {
        // If a session for this host is already open, just focus it.
        if let existing = shell.tabs.first(where: { $0.host.id == host.id }), windows[existing.id] != nil {
            focus(existing.id)
            return
        }
        guard let tab = shell.connect(to: host) else {
            NSSound.beep()
            return
        }
        let view = SSHSessionWindowView(shell: shell, tab: tab, onClose: { [weak self] in self?.close(tab.id) })
        let window = makeWindow(title: tab.title, id: tab.id, content: AnyView(view))
        windows[tab.id] = window
        present(window)
    }

    /// Opens a standalone SFTP file-manager window for a host (its own connection, no terminal).
    func openFileSession(_ host: SSHHost) {
        if let existing = fileSessions.first(where: { $0.host.id == host.id }), windows[existing.id] != nil {
            focus(existing.id)
            return
        }
        let creds: SSHCredentials
        do { creds = try shell.hostStore.credentials(for: host) }
        catch { NSSound.beep(); return }
        let proxy = (try? shell.hostStore.proxyCredentials(for: host)).flatMap { $0 }
            .map { SSHConnection.ProxyJump(credentials: $0, verifier: shell.knownHosts) }

        let session = FileSession(host: host, credentials: creds, knownHosts: shell.knownHosts, proxy: proxy)
        fileSessions.append(session)
        let window = makeWindow(title: session.title, id: session.id,
                                content: AnyView(FileManagerView(session: session, sessions: self)))
        session.window = window
        windows[session.id] = window
        present(window)
        Task { await session.start() }
    }

    // MARK: - Focus / close

    func focus(_ id: UUID) {
        guard let window = windows[id] else { return }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(_ id: UUID) {
        windows[id]?.close() // triggers windowWillClose → cleanup
    }

    func isOpen(_ id: UUID) -> Bool { windows[id] != nil }

    /// True if the session's window is the app's key window AND the app is active (no need to notify).
    func isFrontmost(_ id: UUID) -> Bool {
        guard NSApp.isActive, let window = windows[id] else { return false }
        return window.isKeyWindow
    }

    /// Injects a remote file path into a terminal session for `host` (where Claude Code runs) and
    /// brings that window forward. Prefers an open terminal for the same host. Returns false if none.
    @discardableResult
    func giveToTerminal(path: String, host: SSHHost) -> Bool {
        let candidate = shell.tabs.first { $0.host.id == host.id && windows[$0.id] != nil }
            ?? shell.tabs.first { $0.connected && windows[$0.id] != nil }
        guard let tab = candidate else { return false }
        tab.controller.sendToShell(path + " ")
        focus(tab.id)
        return true
    }

    /// The SSH session whose window is currently key (for menu commands like search/split).
    func focusedTab() -> TerminalTab? {
        guard let key = NSApp.keyWindow,
              let id = windows.first(where: { $0.value === key })?.key else { return nil }
        return shell.tabs.first { $0.id == id }
    }

    // MARK: - Profiles window

    func openProfilesWindow() {
        if let window = profilesWindow {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Profile"
        window.contentMinSize = NSSize(width: 460, height: 380)
        window.contentViewController = NSHostingController(rootView: ProfilesView(shell: shell, sessions: self))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        profilesWindow = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Voice dictation routing

    /// Types text into the terminal of the frontmost session window. Returns true if handled.
    @discardableResult
    func sendTextToFocusedSession(_ text: String) -> Bool {
        guard let key = NSApp.keyWindow, isSessionWindow(key),
              let tv = terminalView(in: key) else { return false }
        tv.send(txt: text)
        return true
    }

    private func isSessionWindow(_ window: NSWindow) -> Bool {
        windows.values.contains { $0 === window }
    }

    private func terminalView(in window: NSWindow) -> TerminalView? {
        if let tv = window.firstResponder as? TerminalView { return tv }
        return Self.findTerminalView(in: window.contentView)
    }

    private static func findTerminalView(in view: NSView?) -> TerminalView? {
        guard let view else { return nil }
        if let tv = view as? TerminalView { return tv }
        for sub in view.subviews {
            if let tv = findTerminalView(in: sub) { return tv }
        }
        return nil
    }

    // MARK: - Window plumbing

    private func makeWindow(title: String, id: UUID, content: AnyView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = title
        window.backgroundColor = .black
        window.contentMinSize = NSSize(width: 620, height: 380)
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        if let last = windows.values.first(where: { $0 !== window && $0.isVisible }) {
            var frame = last.frame
            frame.origin.x += 30
            frame.origin.y -= 30
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        persistOpenSessions()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        if window === paletteWindow {
            paletteWindow = nil
            if !anyWindowOpen { NSApp.setActivationPolicy(.accessory) }
            return
        }
        if window === profilesWindow {
            profilesWindow = nil
            if !anyWindowOpen { NSApp.setActivationPolicy(.accessory) }
            return
        }
        if window === snippetsWindow {
            snippetsWindow = nil
            if !anyWindowOpen { NSApp.setActivationPolicy(.accessory) }
            return
        }
        if window === tipsWindow {
            tipsWindow = nil
            if !anyWindowOpen { NSApp.setActivationPolicy(.accessory) }
            return
        }

        guard let id = windows.first(where: { $0.value === window })?.key else { return }
        windows.removeValue(forKey: id)

        if let tab = shell.tabs.first(where: { $0.id == id }) {
            shell.closeTab(tab)
        } else if let index = localSessions.firstIndex(where: { $0.id == id }) {
            localSessions[index].terminate()
            localSessions.remove(at: index)
        } else if let index = fileSessions.firstIndex(where: { $0.id == id }) {
            fileSessions[index].disconnect()
            fileSessions.remove(at: index)
        }

        persistOpenSessions()
        // Back to a pure menu-bar app once the last window is gone.
        if !anyWindowOpen { NSApp.setActivationPolicy(.accessory) }
    }
}
