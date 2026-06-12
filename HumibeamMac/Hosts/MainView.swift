import SwiftUI
import AppKit
import SwiftTerm

// MARK: - Main window (single-window "Studio" layout)

/// humibeam's single main window: a full-width top bar and footer frame the whole window; the
/// collapsible sidebar (profiles + active sessions) sits *between* them, next to the session —
/// so the chrome reads as one frame instead of stacked panels.
struct MainWindowView: View {
    @Bindable var shell: HumibeamShell
    @Bindable var sessions: SessionManager
    @Bindable var updater: UpdateService
    @State private var editingHost: SSHHost?
    @State private var showingEditor = false
    @State private var isFullscreen = false
    @AppStorage("humibeam.sidebarVisible") private var sidebarVisible = true

    private var selectedTab: TerminalTab? {
        guard let id = sessions.selectedSessionID else { return nil }
        return shell.tabs.first { $0.id == id }
    }

    private var selectedLocal: LocalSession? {
        guard let id = sessions.selectedSessionID else { return nil }
        return sessions.localSessions.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isFullscreen {
                topBar
                Divider()
            }
            HStack(spacing: 0) {
                if sidebarVisible && !isFullscreen {
                    SidebarView(shell: shell, sessions: sessions,
                                editHost: { editingHost = $0; showingEditor = true })
                    .frame(width: 248)
                    .transition(.move(edge: .leading))
                    Divider()
                }
                DetailHost(shell: shell, sessions: sessions,
                           newHost: { editingHost = nil; showingEditor = true })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !isFullscreen {
                Divider()
                bottomBar
            }
        }
        .animation(.easeInOut(duration: 0.18), value: sidebarVisible)
        .background(Color(nsColor: shell.theme.background))
        .background(WindowChromeStyler(isDark: shell.theme.isDark))
        .background(FullscreenReader(isFullscreen: $isFullscreen))
        .sheet(isPresented: $showingEditor) {
            HostEditorView(host: editingHost ?? SSHHost()) { saved in
                if shell.hostStore.hosts.contains(where: { $0.id == saved.id }) {
                    shell.hostStore.update(saved)
                } else {
                    shell.hostStore.add(saved)
                }
            }
        }
    }

    /// Full-width top bar: sidebar toggle + the selected session's controls. Its background runs
    /// up under the (transparent) titlebar, so titlebar and top bar are one surface.
    private var topBar: some View {
        HStack(spacing: 12) {
            Button { sidebarVisible.toggle() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("s", modifiers: [.command, .control])
            .help("Seitenleiste ein-/ausblenden (⌃⌘S)")

            if let tab = selectedTab {
                SessionToolbar(shell: shell, sessions: sessions, tab: tab)
            } else if selectedLocal != nil {
                HStack(spacing: 8) {
                    Circle().fill(.green).frame(width: 9, height: 9)
                    Text("Lokales Terminal").font(.headline)
                }
                Spacer()
            } else {
                Text("humibeam").font(.headline).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background {
            Color(nsColor: shell.theme.chrome).ignoresSafeArea(.container, edges: .top)
        }
    }

    /// Full-width footer: new-session menu + palette/settings on the left, the selected
    /// session's status in the middle, version/update affordance on the right.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Lokales Terminal", systemImage: "apple.terminal") { sessions.openLocalSession() }
                if !shell.hostStore.hosts.isEmpty {
                    Divider()
                    Section("Verbinden") {
                        ForEach(shell.hostStore.hosts) { host in
                            Button(host.displayName) { sessions.openSSHSession(host) }
                        }
                    }
                }
                Divider()
                Button("Neues Profil…", systemImage: "plus") { editingHost = nil; showingEditor = true }
            } label: {
                Label("Neu", systemImage: "plus.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button { sessions.toggleCommandPalette() } label: { Image(systemName: "command") }
                .buttonStyle(.borderless)
                .help("Befehls-Palette (⌘K)")

            Button { sessions.openSettingsHub() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Einstellungen")

            statusArea

            Spacer()

            updateArea
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(nsColor: shell.theme.chrome))
    }

    @ViewBuilder private var statusArea: some View {
        if let tab = selectedTab {
            HStack(spacing: 7) {
                Circle().fill(Color(nsColor: tab.health.color)).frame(width: 8, height: 8)
                Text(tab.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if shell.broadcastInput {
                    Label("Broadcast", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.leading, 6)
        } else if selectedLocal != nil {
            HStack(spacing: 7) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Lokales Terminal — Mac-Shell").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.leading, 6)
        }
    }

    @ViewBuilder private var updateArea: some View {
        if let info = updater.available {
            Button { updater.installAvailableUpdate() } label: {
                HStack(spacing: 6) {
                    if updater.isInstalling { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    else { Image(systemName: "arrow.down.circle.fill") }
                    Text(updater.isInstalling ? (updater.statusText ?? "Installiere…")
                                              : "Update auf \(info.version) installieren")
                        .font(.caption).fontWeight(.medium)
                }
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless).disabled(updater.isInstalling)
            .help(info.notes)
        } else {
            HStack(spacing: 8) {
                Text(updater.statusText ?? "v\(updater.currentVersion) (Build \(updater.currentBuild))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                if updater.isChecking {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else {
                    Button("Nach Updates suchen") { Task { await updater.check(silent: false) } }
                        .buttonStyle(.borderless).font(.caption2).foregroundStyle(.secondary)
                        .help("Prüft auf eine neuere Version")
                }
            }
        }
    }
}

/// Pins the hosting window's appearance to the terminal theme: a dark theme gets a fully dark
/// window (titlebar, sidebar vibrancy, bars), a light theme a light one — instead of system-light
/// chrome stacked around a black terminal.
private struct WindowChromeStyler: NSViewRepresentable {
    let isDark: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }

    private func apply(to window: NSWindow?) {
        window?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Bindable var shell: HumibeamShell
    @Bindable var sessions: SessionManager
    var editHost: (SSHHost) -> Void

    var body: some View {
        List {
            Section("Profile") {
                if shell.hostStore.hosts.isEmpty {
                    Text("Noch keine Profile")
                        .font(.callout).foregroundStyle(.tertiary)
                }
                ForEach(shell.hostStore.hosts) { host in
                    ProfileRow(host: host,
                               connected: shell.tabs.contains { $0.host.id == host.id && $0.connected })
                    .contentShape(Rectangle())
                    .onTapGesture { sessions.openSSHSession(host) }
                    .contextMenu {
                        Button("Terminal verbinden") { sessions.openSSHSession(host) }
                        Button("Dateien öffnen") { sessions.openFileSession(host) }
                        Divider()
                        Button("Bearbeiten…") { editHost(host) }
                        Button("Löschen", role: .destructive) { shell.hostStore.delete(host) }
                    }
                }
            }

            if !sessions.activeSessions.isEmpty {
                Section("Sitzungen") {
                    ForEach(sessions.activeSessions) { s in
                        SessionRow(session: s, selected: sessions.selectedSessionID == s.id)
                            .contentShape(Rectangle())
                            .onTapGesture { sessions.select(s.id) }
                            .contextMenu {
                                Button("Schließen", role: .destructive) { sessions.close(s.id) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: shell.theme.chrome).opacity(0.5))
    }
}

private struct ProfileRow: View {
    let host: SSHHost
    let connected: Bool
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: connected ? "bolt.horizontal.circle.fill" : "server.rack")
                .foregroundStyle(connected ? Color.green : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName).font(.body)
                Text("\(host.username)@\(host.host)").font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct SessionRow: View {
    let session: SessionManager.ActiveSession
    let selected: Bool
    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(Color(nsColor: session.health.color)).frame(width: 8, height: 8)
            Image(systemName: session.symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(session.title).font(.body).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Detail host (resolves the selected session)

private struct DetailHost: View {
    @Bindable var shell: HumibeamShell
    @Bindable var sessions: SessionManager
    var newHost: () -> Void

    var body: some View {
        if let id = sessions.selectedSessionID,
           let tab = shell.tabs.first(where: { $0.id == id }) {
            SessionDetailView(shell: shell, sessions: sessions, tab: tab).id(tab.id)
        } else if let id = sessions.selectedSessionID,
                  let local = sessions.localSessions.first(where: { $0.id == id }) {
            LocalDetailView(session: local, theme: shell.theme).id(local.id)
        } else {
            EmptyStateView(shell: shell, sessions: sessions, newHost: newHost)
        }
    }
}

private struct EmptyStateView: View {
    @Bindable var shell: HumibeamShell
    @Bindable var sessions: SessionManager
    var newHost: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            BrandMark(size: 56)
            VStack(spacing: 6) {
                Text("humibeam").font(.system(size: 26, weight: .bold))
                Text("Der SSH-Client für agentische CLIs. Profil wählen — Terminal, Dateien und Screenshot-Paste laufen über dieselbe Verbindung.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 440)
            }
            if shell.hostStore.hosts.isEmpty {
                Button { newHost() } label: {
                    Label("Erstes Profil anlegen", systemImage: "plus").frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button { sessions.openLocalSession() } label: {
                    Label("Lokales Terminal öffnen", systemImage: "apple.terminal").frame(minWidth: 200)
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - SSH session detail

private struct SessionDetailView: View {
    @Bindable var shell: HumibeamShell
    @Bindable var sessions: SessionManager
    @Bindable var tab: TerminalTab

    var body: some View {
        VStack(spacing: 0) {
            if tab.searchVisible {
                SearchBar(tab: tab); Divider()
            }
            if let approval = tab.approval {
                ApprovalCard(approval: approval,
                             onApprove: { tab.controller.approve() },
                             onApproveAlways: { tab.controller.approveAlways() },
                             onDeny: { tab.controller.deny() },
                             onShowDiff: { tab.showDiff = true })
                Divider()
            }
            content
        }
        .background(Color(nsColor: shell.theme.background))
        .onChange(of: tab.mode) { _, mode in handleModeChange(mode) }
        .sheet(isPresented: $tab.showAIPanel) { AIPanel(tab: tab) }
        .sheet(isPresented: $tab.showEditor) { RemoteEditor(shell: shell, tab: tab) }
        .sheet(isPresented: $tab.showForwards) { ForwardsSheet(shell: shell, tab: tab) }
        .sheet(isPresented: $tab.showDiff) { GitDiffSheet(tab: tab) }
        .sheet(isPresented: $tab.showBridge) { ClaudeBridgeSheet(tab: tab) }
    }

    @ViewBuilder
    private var content: some View {
        switch tab.mode {
        case .terminal:
            TerminalRepresentable(controller: tab.controller)
                .padding(10).frame(minWidth: 480, minHeight: 300)
        case .split:
            HSplitView {
                TerminalRepresentable(controller: tab.controller)
                if let split = tab.splitController {
                    TerminalRepresentable(controller: split)
                }
            }
            .padding(10).frame(minWidth: 480, minHeight: 300)
        case .files:
            FilesPane(shell: shell, sessions: sessions, tab: tab)
                .frame(minWidth: 480, minHeight: 300)
        }
    }

    private func handleModeChange(_ mode: SessionMode) {
        switch mode {
        case .split:
            if tab.splitController == nil { shell.toggleSplit(tab) }
        case .files:
            if tab.browserFiles.isEmpty { Task { await shell.refreshBrowser(tab) } }
            if tab.splitController != nil { shell.toggleSplit(tab) }
        case .terminal:
            if tab.splitController != nil { shell.toggleSplit(tab) }
        }
    }
}

// MARK: - Inline approval card (the "agent cockpit")

/// Renders a parsed Claude Code permission prompt as a native card: action type, the command or
/// a colored diff, and Allow/Deny buttons that send the keystrokes Claude expects. See
/// docs/AGENT-COCKPIT.md.
private struct ApprovalCard: View {
    let approval: ClaudeApproval
    let onApprove: () -> Void
    let onApproveAlways: () -> Void
    let onDeny: () -> Void
    let onShowDiff: () -> Void

    private var accent: SwiftUI.Color { approval.looksDangerous ? .red : .orange }
    private var canShowDiff: Bool { approval.action == .edit || approval.action == .write }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: icon + action + "Claude Code" tag
            HStack(spacing: 8) {
                Image(systemName: approval.looksDangerous ? "exclamationmark.triangle.fill" : approval.action.symbol)
                    .foregroundStyle(accent)
                Text(approval.action.label).font(.headline)
                if approval.looksDangerous {
                    Text("RISKANT").font(.caption2).fontWeight(.bold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.red.opacity(0.18), in: Capsule())
                        .foregroundStyle(.red)
                }
                Spacer()
                if approval.exact {
                    Label("exakt", systemImage: "checkmark.seal.fill")
                        .font(.caption2).foregroundStyle(.green)
                        .help("Daten direkt aus der Claude-Code-Bridge (Stufe 3)")
                }
                Label("Claude Code", systemImage: "sparkles")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if !approval.preview.isEmpty {
                previewBlock
            }

            // Question + actions
            HStack(spacing: 10) {
                Text(approval.question).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if canShowDiff {
                    Button { onShowDiff() } label: { Label("Echter Diff", systemImage: "plusminus.circle") }
                        .help("Verlässlichen git-Diff vom Server holen")
                }
                Button("Ablehnen", role: .cancel) { onDeny() }
                    .keyboardShortcut(.cancelAction)
                if approval.allowAlways {
                    Button("Immer erlauben") { onApproveAlways() }
                }
                Button(approval.looksDangerous ? "Trotzdem erlauben" : "Erlauben") { onApprove() }
                    .buttonStyle(.borderedProminent).tint(accent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(accent.opacity(0.10))
        .overlay(Rectangle().frame(width: 3).foregroundStyle(accent), alignment: .leading)
    }

    private var previewBlock: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(approval.preview) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(color(for: line.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 1)
                        .background(background(for: line.kind))
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 220)
        .background(SwiftUI.Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    private func color(for kind: ClaudeApproval.Line.Kind) -> SwiftUI.Color {
        switch kind {
        case .add:     return .green
        case .remove:  return .red
        case .context: return .primary
        }
    }

    private func background(for kind: ClaudeApproval.Line.Kind) -> SwiftUI.Color {
        switch kind {
        case .add:     return .green.opacity(0.12)
        case .remove:  return .red.opacity(0.12)
        case .context: return .clear
        }
    }
}

// MARK: - Reliable working-tree diff (Stufe 2)

/// Shows the *real* working-tree changes pulled straight from the server via `git diff` over the
/// exec-channel — independent of the TUI scrape. See docs/AGENT-COCKPIT.md.
private struct GitDiffSheet: View {
    @Bindable var tab: TerminalTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Änderungen", systemImage: "plusminus.circle").font(.headline)
                if let dir = tab.controller.currentDirectory {
                    Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                Button { load() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Neu laden").disabled(tab.diffBusy)
                Button("Fertig") { tab.showDiff = false }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            content
        }
        .frame(width: 760, height: 540)
        .task { if tab.diffResult == nil { load() } }
    }

    @ViewBuilder
    private var content: some View {
        if tab.diffBusy {
            VStack { ProgressView(); Text("Lade git diff …").font(.caption).foregroundStyle(.secondary).padding(.top, 6) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch tab.diffResult {
            case .diff(let lines, let untracked):
                diffView(lines: lines, untracked: untracked)
            case .clean:
                message("checkmark.seal", "Keine Änderungen im Arbeitsverzeichnis.", .green)
            case .notARepo:
                message("folder", "Hier ist kein Git-Repository.", .secondary)
            case .noLocation:
                message("questionmark.folder",
                        "Arbeitsverzeichnis unbekannt (Shell sendet kein OSC 7). Öffne den Diff aus dem Repo-Verzeichnis.",
                        .orange)
            case .error(let m):
                message("exclamationmark.triangle", m, .red)
            case .none:
                EmptyView()
            }
        }
    }

    private func diffView(lines: [DiffHunkLine], untracked: [String]) -> some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                if !untracked.isEmpty {
                    Text("Neue Dateien (untracked)").font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8)
                    ForEach(untracked, id: \.self) { f in
                        Text("＋ " + f).font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.green).padding(.horizontal, 10).padding(.vertical, 1)
                    }
                    Divider().padding(.vertical, 6)
                }
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(color(line.kind))
                        .fontWeight(line.kind == .hunk || line.kind == .file ? .semibold : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 0.5)
                        .background(bg(line.kind))
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func message(_ symbol: String, _ text: String, _ tint: SwiftUI.Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(tint)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
        tab.diffBusy = true
        let conn = tab.controller.connection
        // Anchor candidates: the terminal's CWD (if reported) + the parent dirs of files Claude touched.
        var candidates: [String] = []
        if let dir = tab.controller.currentDirectory { candidates.append(dir) }
        for p in tab.recentPaths where p.hasPrefix("/") {
            candidates.append((p as NSString).deletingLastPathComponent)
        }
        Task {
            let result = await GitDiffService.fetch(connection: conn, candidates: candidates)
            tab.diffResult = result
            tab.diffBusy = false
        }
    }

    private func color(_ kind: DiffHunkLine.Kind) -> SwiftUI.Color {
        switch kind {
        case .add: return .green
        case .remove: return .red
        case .hunk: return .cyan
        case .file: return .secondary
        case .context: return .primary
        }
    }

    private func bg(_ kind: DiffHunkLine.Kind) -> SwiftUI.Color {
        switch kind {
        case .add: return .green.opacity(0.10)
        case .remove: return .red.opacity(0.10)
        default: return .clear
        }
    }
}

// MARK: - Claude bridge setup (Stufe 3)

/// Opt-in: installs/removes the Claude Code PreToolUse hook that feeds humibeam exact tool-calls.
private struct ClaudeBridgeSheet: View {
    @Bindable var tab: TerminalTab
    @State private var status: ClaudeBridge.Status?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Claude-Bridge", systemImage: "link").font(.headline)
                Spacer()
                Button("Fertig") { tab.showBridge = false }.keyboardShortcut(.defaultAction)
            }

            Text("""
            Installiert einen Claude-Code-Hook auf dem Server, der jeden Tool-Aufruf als JSON meldet. \
            Dann zeigt humibeam **exakte** Approval-Karten (echter Befehl, echter Diff) statt aus dem \
            Terminal geratener. Optional — Claude funktioniert auch ohne. Der Hook entscheidet nichts \
            selbst; deine Erlauben/Ablehnen-Knöpfe bleiben unverändert.
            """)
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                statusDot(status?.hookInstalled ?? false)
                Text("Hook-Skript")
                statusDot(status?.settingsConfigured ?? false)
                Text("settings.json")
                if let s = status, s.active {
                    Text("aktiv").font(.caption).foregroundStyle(.green)
                }
            }
            .font(.callout)

            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if status?.active == true {
                    Button("Entfernen", role: .destructive) { run { await ClaudeBridge.remove(connection: tab.controller.connection) } }
                        .disabled(busy)
                }
                Button(status?.active == true ? "Neu installieren" : "Bridge installieren") {
                    run { await ClaudeBridge.install(connection: tab.controller.connection) }
                }
                .buttonStyle(.borderedProminent).disabled(busy)
            }

            Text("Hinweis: Eine bereits laufende `claude`-Sitzung muss neu gestartet werden, damit der Hook greift.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(20).frame(width: 480)
        .task { await reload() }
    }

    private func statusDot(_ ok: Bool) -> some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(ok ? .green : .secondary)
    }

    private func reload() async {
        status = await ClaudeBridge.status(connection: tab.controller.connection)
    }

    private func run(_ op: @escaping () async -> Result<Void, ClaudeBridge.BridgeError>) {
        busy = true; message = nil
        Task {
            switch await op() {
            case .success: message = "Erledigt."
            case .failure(let e): message = "Fehler: \(e.localizedDescription)"
            }
            await reload()
            busy = false
        }
    }
}

// MARK: - Professional session toolbar

private struct SessionToolbar: View {
    @Bindable var shell: HumibeamShell
    @Bindable var sessions: SessionManager
    @Bindable var tab: TerminalTab
    @State private var showSuggest = false
    @State private var fillSnippet: Snippet?
    @State private var fillValues: [String: String] = [:]

    var body: some View {
        HStack(spacing: 12) {
            // Leading: identity + health + Claude badge
            HStack(spacing: 8) {
                Circle().fill(Color(nsColor: tab.health.color)).frame(width: 9, height: 9)
                Text(tab.host.displayName).font(.headline).lineLimit(1)
                if tab.claudeDetected {
                    Label("Claude Code", systemImage: "sparkles")
                        .font(.caption2).foregroundStyle(.purple)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.12), in: Capsule())
                }
            }

            Spacer(minLength: 12)

            // Center: mode switcher
            Picker("", selection: $tab.mode) {
                ForEach(SessionMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!tab.connected)

            Spacer(minLength: 12)

            // Trailing primary actions
            HStack(spacing: 6) {
                Button { sessions.toggleCommandPalette() } label: { Image(systemName: "plus") }
                    .help("Neue Sitzung (⌘K)")
                Button { tab.searchVisible.toggle() } label: { Image(systemName: "magnifyingglass") }
                    .help("Suchen (⌘F)")
                Button { uploadViaPanel() } label: { Image(systemName: "arrow.up.doc") }
                    .help("Datei hochladen").disabled(!tab.connected)
                Button { tab.showDiff = true } label: { Image(systemName: "plusminus.circle") }
                    .help("Änderungen ansehen (git diff)").disabled(!tab.connected)
                Menu {
                    Button("Letzte Ausgabe erklären") { Task { await shell.explainOutput(tab) } }
                    Button("Fehler beheben") { Task { await shell.fixError(tab) } }
                    Button("Befehl vorschlagen…") { tab.aiSuggestIntent = ""; showSuggest = true }
                } label: { Image(systemName: "sparkles") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("KI-Hilfe").disabled(!tab.connected)

                overflowMenu
            }
            .buttonStyle(.borderless)
        }
        .alert("Was soll der Befehl tun?", isPresented: $showSuggest) {
            TextField("z.B. alle .log-Dateien finden", text: $tab.aiSuggestIntent)
            Button("Vorschlagen") { Task { await shell.suggestCommand(tab, intent: tab.aiSuggestIntent) } }
            Button("Abbrechen", role: .cancel) {}
        }
        .sheet(item: $fillSnippet) { snip in snippetFillSheet(snip) }
    }

    private var overflowMenu: some View {
        Menu {
            Menu("Schriftgröße") {
                Button("Größer") { shell.terminalFontSize = min(28, shell.terminalFontSize + 1) }
                Button("Kleiner") { shell.terminalFontSize = max(9, shell.terminalFontSize - 1) }
            }
            Picker("Farbschema", selection: $shell.selectedThemeID) {
                ForEach(TerminalTheme.all) { Text($0.name).tag($0.id) }
            }
            Divider()
            if !shell.snippets.snippets.isEmpty {
                Menu("Snippets") {
                    ForEach(shell.snippets.snippets) { snip in
                        Button(snip.title) { runSnippet(snip) }
                    }
                    Divider()
                    Button("Snippets verwalten…") { NotificationCenter.default.post(name: .manageSnippets, object: nil) }
                }
            }
            Button("Claude-Bridge…") { tab.showBridge = true }.disabled(!tab.connected)
            Button("Port-Weiterleitung…") { tab.showForwards = true }.disabled(!tab.connected)
            Toggle("Eingabe an alle senden (Broadcast)", isOn: $shell.broadcastInput)
            Divider()
            Button {
                NotificationCenter.default.post(name: .toggleTerminalDictation, object: nil)
            } label: { Label("Diktat ins Terminal", systemImage: "mic") }
                .disabled(!tab.connected)
            Divider()
            Button("Sitzung schließen", role: .destructive) { sessions.close(tab.id) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Weitere Aktionen")
    }

    private func runSnippet(_ snip: Snippet) {
        if snip.placeholders.isEmpty {
            tab.controller.sendToShell(snip.command)
        } else {
            fillValues = Dictionary(uniqueKeysWithValues: snip.placeholders.map { ($0, "") })
            fillSnippet = snip
        }
    }

    @ViewBuilder
    private func snippetFillSheet(_ snip: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(snip.title).font(.headline)
            Text(snip.command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            ForEach(snip.placeholders, id: \.self) { name in
                HStack {
                    Text(name).frame(width: 110, alignment: .leading).font(.callout)
                    TextField(name, text: Binding(
                        get: { fillValues[name] ?? "" },
                        set: { fillValues[name] = $0 }))
                    .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { fillSnippet = nil }
                Button("Senden") {
                    tab.controller.sendToShell(snip.filled(with: fillValues))
                    fillSnippet = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding().frame(width: 420)
    }

    private func uploadViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await shell.uploadFile(tab, localURL: url) }
        }
    }
}

// MARK: - Integrated files pane (rich file manager over the session's own SSH connection)

/// "Dateien" mode: embeds the full file manager, but backed by the terminal session's existing
/// SSH connection (a borrowed FileSession — no second login). Opens in the terminal's current
/// directory when the shell reports it (OSC 7), otherwise the remote home.
private struct FilesPane: View {
    @Bindable var shell: HumibeamShell
    @Bindable var sessions: SessionManager
    @Bindable var tab: TerminalTab

    var body: some View {
        Group {
            if let fs = tab.fileSession {
                FileManagerView(session: fs, sessions: sessions)
            } else if tab.connected {
                ProgressView("Dateien werden geladen…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Sobald die Sitzung verbunden ist, erscheinen hier die Dateien.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: tab.connected) { await ensureFileSession() }
    }

    private func ensureFileSession() async {
        guard tab.connected, tab.fileSession == nil,
              let conn = tab.controller.connection else { return }
        let fs = FileSession(borrowing: conn, host: tab.host)
        tab.fileSession = fs
        await fs.startBorrowed(at: tab.controller.currentDirectory)
    }
}

// MARK: - Local session detail

private struct LocalDetailView: View {
    @Bindable var session: LocalSession
    let theme: TerminalTheme
    var body: some View {
        LocalTerminalRepresentable(session: session)
            .padding(10).frame(minWidth: 480, minHeight: 300)
            .background(Color(nsColor: theme.background))
    }
}

// MARK: - Shared sub-views (search, AI panel, port forwards)

private struct SearchBar: View {
    @Bindable var tab: TerminalTab
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Im Terminal suchen…", text: $tab.searchTerm)
                .textFieldStyle(.roundedBorder)
                .onSubmit { _ = tab.controller.findNext(tab.searchTerm) }
            Button { _ = tab.controller.findPrevious(tab.searchTerm) } label: { Image(systemName: "chevron.up") }
            Button { _ = tab.controller.findNext(tab.searchTerm) } label: { Image(systemName: "chevron.down") }
            Button { tab.searchVisible = false } label: { Image(systemName: "xmark") }
        }
        .padding(.horizontal, 10).padding(.vertical, 6).background(.bar)
    }
}

private struct AIPanel: View {
    @Bindable var tab: TerminalTab
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(tab.aiTitle, systemImage: "sparkles").font(.headline)
                Spacer()
                if tab.aiBusy { ProgressView().controlSize(.small) }
            }
            .padding()
            Divider()
            ScrollView {
                Text(tab.aiResult.isEmpty ? (tab.aiBusy ? "Denke nach…" : "—") : tab.aiResult)
                    .font(tab.aiTitle == "Befehlsvorschlag" ? .system(.body, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            Divider()
            HStack {
                Button("Kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tab.aiResult, forType: .string)
                }
                .disabled(tab.aiResult.isEmpty)
                Spacer()
                Button("Schließen") { tab.showAIPanel = false }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 420)
    }
}

private struct ForwardsSheet: View {
    @Bindable var shell: HumibeamShell
    @Bindable var tab: TerminalTab
    @State private var localPort = "8080"
    @State private var targetHost = "localhost"
    @State private var targetPort = "80"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Port-Weiterleitung (ssh -L)").font(.headline).padding()
            Divider()
            List {
                Section("Aktiv") {
                    if shell.forwards.isEmpty {
                        Text("Keine aktiven Weiterleitungen.").foregroundStyle(.secondary)
                    }
                    ForEach(shell.forwards) { f in
                        HStack {
                            Image(systemName: "arrow.left.arrow.right").foregroundStyle(.green)
                            Text("localhost:\(f.localPort) → \(f.targetHost):\(f.targetPort)")
                                .font(.system(.callout, design: .monospaced))
                            Spacer()
                            Button("Stoppen") { shell.stopForward(f) }
                        }
                    }
                }
                Section("Neue Weiterleitung") {
                    HStack {
                        TextField("Lokaler Port", text: $localPort).frame(width: 110)
                        Image(systemName: "arrow.right")
                        TextField("Ziel-Host", text: $targetHost)
                        TextField("Port", text: $targetPort).frame(width: 80)
                    }
                    Button("Weiterleitung starten") {
                        guard let lp = Int(localPort), let tp = Int(targetPort) else { return }
                        Task { await shell.addForward(tab, localPort: lp, targetHost: targetHost, targetPort: tp) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!tab.connected || Int(localPort) == nil || Int(targetPort) == nil)
                }
            }
            Divider()
            HStack { Spacer(); Button("Schließen") { tab.showForwards = false }.keyboardShortcut(.defaultAction) }.padding()
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - Fullscreen reader + local terminal hosting (unchanged plumbing)

/// Reports whether *this view's* window is in macOS fullscreen, so the session views can
/// hide their toolbar/status bar for a clean, edge-to-edge fullscreen terminal.
struct FullscreenReader: NSViewRepresentable {
    @Binding var isFullscreen: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.attach(to: view.window, isFullscreen: $isFullscreen) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(to: nsView.window, isFullscreen: $isFullscreen) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var window: NSWindow?
        private var tokens: [NSObjectProtocol] = []

        func attach(to window: NSWindow?, isFullscreen: Binding<Bool>) {
            guard let window, window !== self.window else { return }
            self.window = window
            isFullscreen.wrappedValue = window.styleMask.contains(.fullScreen)
            let nc = NotificationCenter.default
            tokens.forEach { nc.removeObserver($0) }
            tokens = [
                nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
                    isFullscreen.wrappedValue = true
                },
                nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
                    isFullscreen.wrappedValue = false
                },
            ]
        }
    }
}

/// Hosts SwiftTerm's `LocalProcessTerminalView` inside SwiftUI.
struct LocalTerminalRepresentable: NSViewRepresentable {
    let session: LocalSession
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = session.terminalView
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
