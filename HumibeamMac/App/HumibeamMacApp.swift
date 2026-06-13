import SwiftUI
import AppKit
import SwiftTerm
import UserNotifications

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
    private var mouseSelectMonitor: Any?
    private weak var optionSelectTerm: TerminalView?
    private var sessionsMenu: NSMenu?
    private let menuBarStatusController = MenuBarStatusController()
    let appState = AppState()
    let shell = HumibeamShell()
    private lazy var sessions = SessionManager(shell: shell, updater: appState.updater)

    /// Handoff vom iPhone: Sitzung hier am Mac weiterführen.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == "app.humibeam.session" else { return false }
        shell.continueSession(hostID: userActivity.userInfo?["hostID"] as? String,
                              hostName: userActivity.userInfo?["hostName"] as? String)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

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

        // Textauswahl trotz Maus-Erfassung: läuft im Terminal eine mausgewahre App (Claude Code,
        // tmux, vim …), leitet SwiftTerm jeden Klick/Zug an die App weiter und startet nie eine
        // lokale Auswahl → man kann nichts markieren und folglich nichts mit ⌘C kopieren. Wie in
        // iTerm/Terminal.app erzwingt gedrücktes Option (⌥) beim Ziehen die lokale Auswahl: für die
        // Dauer der Geste schalten wir die Maus-Weiterleitung ab. (mouseDown/mouseUp sind in SwiftTerm
        // `public`, nicht `open`, daher nicht überschreibbar — deshalb hier per Event-Monitor.)
        mouseSelectMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown {
                if event.modifierFlags.contains(.option),
                   let term = NSApp.keyWindow?.firstResponder as? TerminalView,
                   term.allowMouseReporting {
                    term.allowMouseReporting = false
                    self.optionSelectTerm = term
                }
            } else if let term = self.optionSelectTerm { // .leftMouseUp
                self.optionSelectTerm = nil
                // erst nach der View-eigenen mouseUp die Auswahl finalisieren lassen, dann zurückschalten
                DispatchQueue.main.async { term.allowMouseReporting = true }
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClaudeAlert(_:)),
            name: .claudeAlert,
            object: nil
        )
        NotificationCenter.default.addObserver(
            forName: .manageSnippets, object: nil, queue: .main) { [weak self] _ in
            self?.sessions.openSnippetsWindow()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowSettingsHub), name: .showSettingsHub, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowHistoryHub), name: .showHistoryHub, object: nil)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        registerNotificationActions()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.showOnboardingIfNeeded()
            self.sessions.restoreSessions()
            self.sessions.showMainWindow()   // single main window is humibeam's home
            self.sessions.openHubTipsIfNeeded()
        }
    }

    // When the user reopens the app (e.g. clicks the Dock icon), bring the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sessions.showMainWindow() }
        return true
    }

    /// Reveal the settings hub (menu-bar popover on its settings page).
    @objc private func handleShowSettingsHub() {
        if !popover.isShown { showPopover() }
        appState.page = .settings
    }

    /// Reveal the history hub (menu-bar popover, settings page on the Verlauf tab).
    @objc private func handleShowHistoryHub() {
        if !popover.isShown { showPopover() }
        appState.settingsInitialTab = 3
        appState.page = .settings
    }

    /// "Nach Updates suchen…" — open the main window (so the result is visible in its sidebar) and check.
    @objc private func checkForUpdatesAction() {
        sessions.showMainWindow()
        Task { await appState.updater.check(silent: false) }
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
        appMenu.addItem(withTitle: "Nach Updates suchen…", action: #selector(checkForUpdatesAction), keyEquivalent: "").target = self
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

        let palette = NSMenuItem(title: "Befehls-Palette…", action: #selector(openPaletteAction), keyEquivalent: "k")
        palette.target = self
        menu.addItem(palette)

        let history = NSMenuItem(title: "Befehls-Verlauf…", action: #selector(openCommandHistoryAction), keyEquivalent: "r")
        history.target = self
        menu.addItem(history)

        let fleet = NSMenuItem(title: "Fleet-Übersicht…", action: #selector(openFleetAction), keyEquivalent: "F")
        fleet.target = self
        menu.addItem(fleet)

        let transcripts = NSMenuItem(title: "Agenten-Protokolle…", action: #selector(openTranscriptsAction), keyEquivalent: "")
        transcripts.target = self
        menu.addItem(transcripts)
        menu.addItem(.separator())

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

    @objc private func openPaletteAction() { sessions.toggleCommandPalette() }
    @objc private func openCommandHistoryAction() { sessions.toggleCommandHistory() }
    @objc private func openFleetAction() { sessions.openFleetWindow() }
    @objc private func openTranscriptsAction() { sessions.openTranscriptsWindow() }
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

    /// A Claude session wants attention — post a desktop notification unless its window is frontmost.
    @objc private func handleClaudeAlert(_ note: Notification) {
        guard let info = note.userInfo,
              let id = info["sessionID"] as? UUID,
              let title = info["title"] as? String,
              let body = info["body"] as? String else { return }
        if sessions.isFrontmost(id) { return } // user is already looking at it
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionID": id.uuidString]
        if info["kind"] as? String == "approval" {
            content.categoryIdentifier = Self.approvalCategoryID
        }
        let request = UNNotificationRequest(identifier: id.uuidString + "-" + title,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        // Zusätzlich aufs iPhone, falls das Push-Relay konfiguriert ist — Freigaben mit
        // Aktions-Buttons (kind/sessionID), Antwort holt der Mac per /actions-Poll ab.
        PushRelayClient.notify(title: title, body: body,
                               host: shell.tabs.first { $0.id == id }?.host.displayName ?? "",
                               kind: info["kind"] as? String ?? "",
                               sessionID: id.uuidString)
    }

    // MARK: - Freigabe direkt aus der Benachrichtigung (Erlauben / Immer / Ablehnen)

    private static let approvalCategoryID = "CLAUDE_APPROVAL"

    private func registerNotificationActions() {
        let approve = UNNotificationAction(identifier: "APPROVE", title: "Erlauben", options: [])
        let always = UNNotificationAction(identifier: "APPROVE_ALWAYS", title: "Immer erlauben", options: [])
        let deny = UNNotificationAction(identifier: "DENY", title: "Ablehnen", options: [.destructive])
        let category = UNNotificationCategory(identifier: Self.approvalCategoryID,
                                              actions: [approve, always, deny],
                                              intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
        UNUserNotificationCenter.current().delegate = self
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
        // The popover follows the terminal theme, like the main window — no light popover
        // next to a dark terminal.
        popover.appearance = NSAppearance(named: shell.theme.isDark ? .darkAqua : .aqua)
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

// MARK: - Benachrichtigungs-Aktionen (Erlauben/Ablehnen direkt aus der Mitteilung)

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let idString = response.notification.request.content.userInfo["sessionID"] as? String
        Task { @MainActor in
            let tab = idString.flatMap { s in
                UUID(uuidString: s).flatMap { id in self.shell.tabs.first { $0.id == id } }
            }
            switch action {
            case "APPROVE": tab?.controller.approve()
            case "APPROVE_ALWAYS": tab?.controller.approveAlways()
            case "DENY": tab?.controller.deny()
            default:
                if let tab { self.sessions.focus(tab.id) }
            }
            completionHandler()
        }
    }

    /// Mitteilungen auch zeigen, wenn die App im Vordergrund ist (anderes Fenster fokussiert).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
