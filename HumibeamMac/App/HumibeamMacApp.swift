import SwiftUI
import AppKit
import SwiftTerm

@main
struct HumibeamMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var pasteMonitor: Any?
    private var sessionsMenu: NSMenu?
    private let menuBarStatusController = MenuBarStatusController()
    let appState = AppState()
    let shell = HumibeamShell()
    private lazy var sessions = SessionManager(shell: shell)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            menuBarStatusController.attach(to: button)
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 480)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuBarView(appState: appState, sessions: sessions))

        // humibeam lives in the menu bar (home). The terminal is a window opened on demand
        // from the popover, so we start as a menu-bar agent (no Dock icon, no window at launch)
        // and only switch to a regular windowed app while the terminal window is open.
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()

        // Voice dictation types into whichever session window is frontmost; otherwise
        // humitext's normal paste-into-frontmost-app behavior takes over.
        appState.directTextSink = { [weak self] text in
            self?.sessions.sendTextToFocusedSession(text) ?? false
        }

        // Rebuild the dynamic "Sitzungen" menu (profile shortcuts) whenever profiles change.
        shell.hostStore.onHostsChanged = { [weak self] in self?.rebuildSessionsMenu() }

        // Hotkey events
        appState.hotkeyService.onHotkeyEvent = { [weak self] event in
            self?.handleHotkeyEvent(event)
        }
        appState.onMenuBarStatusChange = { [weak self] status in
            self?.menuBarStatusController.update(to: status)
        }
        appState.hotkeyService.start()

        // ⌘V on a focused terminal must reach humibeam's paste handler (screenshot → upload).
        // The terminal is an AppKit view embedded in SwiftUI, and SwiftUI's hosting view
        // swallows the standard ⌘V edit command before it can reach the view's paste(_:).
        // A local key-down monitor runs *before* the responder chain / menu, so we catch it here
        // and route it straight to the terminal's paste (image upload, or text fallback).
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "v",
               let term = NSApp.keyWindow?.firstResponder as? TerminalView {
                term.paste(term) // HumibeamTerminalView → image upload; plain TerminalView → text paste
                return nil // consumed: don't let SwiftUI/menu double-handle it
            }
            return event
        }

        // Listen for popover dismiss requests (from auto-paste)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissPopover),
            name: .dismissPopover,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTerminalDictation),
            name: .toggleTerminalDictation,
            object: nil
        )

        DispatchQueue.main.async { [weak self] in
            self?.showOnboardingIfNeeded()
        }
    }

    // When the user reopens the app (e.g. clicks the Dock icon while a session is open),
    // surface the menu-bar popover so the hub is reachable.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, !popover.isShown { showPopover() }
        return true
    }

    // MARK: - Main menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Über humibeam", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Einstellungen / Sprache…", action: #selector(showVoiceAction), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "humibeam ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "humibeam beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Sessions menu — local terminal (⌘T) + one entry per profile with its launch shortcut.
        let sessionsItem = NSMenuItem()
        mainMenu.addItem(sessionsItem)
        let sessMenu = NSMenu(title: "Sitzungen")
        sessionsItem.submenu = sessMenu
        self.sessionsMenu = sessMenu

        // Edit menu (standard selectors route through the responder chain → terminal + text fields)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Bearbeiten")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Einfügen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Terminal menu
        let termItem = NSMenuItem()
        mainMenu.addItem(termItem)
        let termMenu = NSMenu(title: "Terminal")
        termItem.submenu = termMenu
        termMenu.addItem(withTitle: "Sitzung schließen", action: #selector(closeTabAction), keyEquivalent: "w").target = self
        termMenu.addItem(withTitle: "Suchen…", action: #selector(findAction), keyEquivalent: "f").target = self
        termMenu.addItem(withTitle: "Split-Ansicht", action: #selector(splitAction), keyEquivalent: "e").target = self
        termMenu.addItem(.separator())
        termMenu.addItem(withTitle: "Schrift größer", action: #selector(fontBiggerAction), keyEquivalent: "+").target = self
        termMenu.addItem(withTitle: "Schrift kleiner", action: #selector(fontSmallerAction), keyEquivalent: "-").target = self
        termMenu.addItem(.separator())
        termMenu.addItem(withTitle: "Diktat (Sprache → Terminal)", action: #selector(showVoiceAction), keyEquivalent: "d").target = self

        // Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Fenster")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimieren", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
        rebuildSessionsMenu()
    }

    /// Rebuilds the "Sitzungen" menu: local terminal + one item per profile (with its ⌘-shortcut).
    private func rebuildSessionsMenu() {
        guard let menu = sessionsMenu else { return }
        menu.removeAllItems()

        let local = NSMenuItem(title: "Lokales Terminal", action: #selector(openLocalAction), keyEquivalent: "t")
        local.target = self
        menu.addItem(local)

        let hosts = shell.hostStore.hosts
        if !hosts.isEmpty {
            menu.addItem(.separator())
            for host in hosts {
                let key = host.shortcut ?? ""
                let item = NSMenuItem(title: host.displayName, action: #selector(openProfileAction(_:)), keyEquivalent: key)
                item.keyEquivalentModifierMask = key.isEmpty ? [] : [.command]
                item.target = self
                item.representedObject = host.id.uuidString
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Profile verwalten…", action: #selector(openProfilesAction), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
    }

    @objc private func closeTabAction() { NSApp.keyWindow?.performClose(nil) }
    @objc private func findAction() { sessions.focusedTab()?.searchVisible.toggle() }
    @objc private func splitAction() { if let t = sessions.focusedTab() { shell.toggleSplit(t) } }
    @objc private func fontBiggerAction() { shell.terminalFontSize = min(28, shell.terminalFontSize + 1) }
    @objc private func fontSmallerAction() { shell.terminalFontSize = max(9, shell.terminalFontSize - 1) }

    @objc private func openLocalAction() { sessions.openLocalSession() }
    @objc private func openProfilesAction() { sessions.openProfilesWindow() }
    @objc private func openProfileAction(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr),
              let host = shell.hostStore.hosts.first(where: { $0.id == id }) else { return }
        sessions.openSSHSession(host)
    }

    @objc private func showVoiceAction() {
        // Menu bar is home: just reveal the popover (voice + settings), don't force the terminal open.
        if !popover.isShown { togglePopover() }
    }

    @objc private func handleDismissPopover() {
        appState.isPopoverShown = false
        popover.performClose(nil)
    }

    /// Mic button in a terminal: toggle background dictation. The result is routed straight into
    /// the focused terminal session via `directTextSink` (no popover, so the terminal keeps focus).
    @objc private func handleTerminalDictation() {
        if let active = appState.activeWorkflow, active.phase.isActive {
            active.stop()
            return
        }
        guard appState.isConfigured else { return }
        let type: WorkflowType = appState.appSettings.secureLocalModeEnabled ? .localTranscription : .transcription
        appState.startWorkflow(type, source: .hotkeyBackground)
    }

    private func handleHotkeyEvent(_ event: HotkeyEvent) {
        switch event {
        case .down(let type):
            handleHotkeyDown(type)
        case .up(let type):
            handleHotkeyUp(type)
        case .cancel:
            handleHotkeyCancel()
        }
    }

    private func handleHotkeyDown(_ type: WorkflowType) {
        guard appState.isConfigured else { return }

        let mode = appState.appSettings.hotkeyMode

        switch mode {
        case .hold:
            // Hold mode: start recording on key down
            appState.startWorkflow(type, source: .hotkeyBackground)

        case .toggle:
            // Toggle mode: if already recording same workflow, stop it
            if let active = appState.activeWorkflow,
               active.type == type,
               active.phase.isActive {
                active.stop()
            } else {
                appState.prepareForPopoverPresentation()
                appState.startWorkflow(type, source: .manual)
                showPopover()
            }
        }
    }

    private func handleHotkeyUp(_ type: WorkflowType) {
        let mode = appState.appSettings.hotkeyMode

        guard mode == .hold else { return }

        // Hold mode: stop recording on key release
        if let active = appState.activeWorkflow,
           active.type == type {
            // Only stop if currently recording (running phase)
            if case .running = active.phase {
                active.stop()
            }
        }
    }

    private func handleHotkeyCancel() {
        appState.activeWorkflow?.stop()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            appState.isPopoverShown = false
        } else {
            appState.prepareForPopoverPresentation()
            showPopover()
        }
    }

    private func showOnboardingIfNeeded() {
        guard appState.shouldShowOnboarding else { return }
        appState.prepareForPopoverPresentation()
        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        appState.isPopoverShown = true
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            appState.isPopoverShown = false
            switch appState.currentPhase {
            case .done, .error:
                appState.resetCurrentWorkflow()
            default:
                appState.page = .main
            }
        }
    }
}
