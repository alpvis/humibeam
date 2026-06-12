import Foundation
import AppKit
import SwiftUI
import Observation
import SwiftTerm

/// Owns the single main window and the set of running sessions (local + SSH).
/// Sessions live in `shell` / `localSessions` and keep running even when the main window is
/// closed — the menu bar is the stable home, the window is just a view onto the sessions.
@Observable
@MainActor
final class SessionManager: NSObject, NSWindowDelegate {
    let shell: HumibeamShell
    let updater: UpdateService
    var localSessions: [LocalSession] = []
    var fileSessions: [FileSession] = []

    /// The session currently shown in the main window's detail pane.
    var selectedSessionID: UUID?

    @ObservationIgnored private var mainWindow: NSWindow?
    @ObservationIgnored private var profilesWindow: NSWindow?
    @ObservationIgnored private var paletteWindow: NSWindow?
    @ObservationIgnored private var snippetsWindow: NSWindow?
    @ObservationIgnored private var tipsWindow: NSWindow?

    private var anyUtilityWindowOpen: Bool {
        profilesWindow != nil || paletteWindow != nil || snippetsWindow != nil || tipsWindow != nil
    }
    private var anyWindowOpen: Bool { mainWindow != nil || anyUtilityWindowOpen }

    init(shell: HumibeamShell, updater: UpdateService) {
        self.shell = shell
        self.updater = updater
        super.init()
    }

    // MARK: - Main window

    /// Creates (or focuses) the single main window.
    func showMainWindow() {
        if let window = mainWindow {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "HUMIBEAM"
        // Transparent titlebar + fullSizeContentView: the content's background runs up under the
        // title, so titlebar, session toolbar and terminal read as one surface (no stacked bars).
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 760, height: 440)
        window.contentViewController = NSHostingController(
            rootView: MainWindowView(shell: shell, sessions: self, updater: updater))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("humibeam.mainWindow")
        mainWindow = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens (or focuses) the settings hub — handled by the AppDelegate's menu-bar popover.
    func openSettingsHub() {
        NotificationCenter.default.post(name: .showSettingsHub, object: nil)
    }

    /// Opens (or focuses) the history/usage hub — handled by the AppDelegate's menu-bar popover.
    func openHistoryHub() {
        NotificationCenter.default.post(name: .showHistoryHub, object: nil)
    }

    // MARK: - Open / select sessions

    func openLocalSession() {
        let session = LocalSession(fontSize: shell.terminalFontSize, theme: shell.theme)
        localSessions.append(session)
        showMainWindow()
        select(session.id)
        persistOpenSessions()
    }

    @discardableResult
    func openSSHSession(_ host: SSHHost) -> TerminalTab? {
        showMainWindow()
        if let existing = shell.tabs.first(where: { $0.host.id == host.id }) {
            select(existing.id)
            return existing
        }
        guard let tab = shell.connect(to: host) else {
            NSSound.beep()
            return nil
        }
        select(tab.id)
        persistOpenSessions()
        return tab
    }

    /// Opens an SSH session and switches it straight into the integrated file manager.
    func openFileSession(_ host: SSHHost) {
        if let tab = openSSHSession(host) { tab.mode = .files }
    }

    /// Selects a session in the main window and brings the window forward.
    func select(_ id: UUID) {
        selectedSessionID = id
        showMainWindow()
    }

    /// Kept for older call sites — same as `select`.
    func focus(_ id: UUID) { select(id) }

    func close(_ id: UUID) {
        if let tab = shell.tabs.first(where: { $0.id == id }) {
            shell.closeTab(tab)
        } else if let index = localSessions.firstIndex(where: { $0.id == id }) {
            localSessions[index].terminate()
            localSessions.remove(at: index)
        } else if let index = fileSessions.firstIndex(where: { $0.id == id }) {
            fileSessions[index].disconnect()
            fileSessions.remove(at: index)
        }
        if selectedSessionID == id { selectedSessionID = activeSessions.first?.id }
        persistOpenSessions()
    }

    func isOpen(_ id: UUID) -> Bool {
        shell.tabs.contains { $0.id == id } || localSessions.contains { $0.id == id }
    }

    /// True if the session is the one shown in the key main window (no need to notify).
    func isFrontmost(_ id: UUID) -> Bool {
        guard NSApp.isActive, let window = mainWindow, window.isKeyWindow else { return false }
        return selectedSessionID == id
    }

    // MARK: - Unified session list (drives the sidebar)

    struct ActiveSession: Identifiable {
        let id: UUID
        let title: String
        let connected: Bool
        let symbol: String
        let health: SessionHealth
    }

    var localActiveSessions: [ActiveSession] {
        localSessions.map {
            ActiveSession(id: $0.id, title: $0.title, connected: true,
                          symbol: "apple.terminal", health: .connected)
        }
    }

    var activeSessions: [ActiveSession] {
        let ssh = shell.tabs.map {
            ActiveSession(id: $0.id, title: $0.title, connected: $0.connected,
                          symbol: "server.rack", health: $0.health)
        }
        return ssh + localActiveSessions
    }

    var hasOpenSessions: Bool { !activeSessions.isEmpty }

    // MARK: - Voice dictation / path routing

    /// The SSH session currently selected (for menu commands like search/split).
    func focusedTab() -> TerminalTab? {
        guard let id = selectedSessionID else { return nil }
        return shell.tabs.first { $0.id == id }
    }

    /// Types text into the currently selected session. Returns true if handled.
    @discardableResult
    func sendTextToFocusedSession(_ text: String) -> Bool {
        // Only capture dictation into the terminal when humibeam's terminal is *actually* focused.
        // Otherwise return false so the text pastes into whatever external app is frontmost — the
        // global "dictate anywhere" behavior from humitext. (Previously this returned true whenever
        // any session was connected, so dictation always landed in the terminal.)
        guard NSApp.isActive,
              let key = NSApp.keyWindow, key === mainWindow,
              key.firstResponder is TerminalView else { return false }

        guard let id = selectedSessionID else { return false }
        if let tab = shell.tabs.first(where: { $0.id == id }), tab.connected {
            tab.controller.sendToShell(text)
            return true
        }
        if let local = localSessions.first(where: { $0.id == id }) {
            local.terminalView.send(txt: text)
            return true
        }
        return false
    }

    /// Injects a remote file path into a terminal session for `host` (where Claude Code runs) and
    /// brings the window forward. Prefers an open terminal for the same host. Returns false if none.
    @discardableResult
    func giveToTerminal(path: String, host: SSHHost) -> Bool {
        let candidate = shell.tabs.first { $0.host.id == host.id }
            ?? shell.tabs.first { $0.connected }
        guard let tab = candidate else { return false }
        tab.controller.sendToShell(path + " ")
        tab.mode = .terminal
        select(tab.id)
        return true
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
        list += shell.tabs.map { SessionDescriptor(kind: $0.mode == .files ? "files" : "ssh", hostID: $0.host.id) }
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

    // MARK: - Utility windows (command palette, profiles, snippets, first-run tips)

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
            backing: .buffered, defer: false)
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

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        if window === mainWindow {
            // Closing the main window does NOT end sessions — they keep running in the background.
            mainWindow = nil
        } else if window === paletteWindow {
            paletteWindow = nil
        } else if window === profilesWindow {
            profilesWindow = nil
        } else if window === snippetsWindow {
            snippetsWindow = nil
        } else if window === tipsWindow {
            tipsWindow = nil
        }

        // Back to a pure menu-bar agent once every window is gone (sessions stay alive).
        if !anyWindowOpen { NSApp.setActivationPolicy(.accessory) }
    }
}
