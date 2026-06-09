import SwiftUI
import AppKit
import SwiftTerm

/// The humibeam main window: hosts sidebar + tabbed terminals + per-tab file browser.
struct MainView: View {
    @Bindable var shell: HumibeamShell
    @State private var selection: UUID?
    @State private var editingHost: SSHHost?
    @State private var showingEditor = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
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

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Verbindungen") {
                ForEach(shell.hostStore.hosts) { host in
                    HostRow(host: host, connected: shell.tabs.contains { $0.host.id == host.id && $0.connected })
                        .tag(host.id)
                        .contextMenu {
                            Button("Verbinden") { shell.connect(to: host) }
                            Button("Bearbeiten") { editingHost = host; showingEditor = true }
                            Divider()
                            Button("Löschen", role: .destructive) { shell.hostStore.delete(host) }
                        }
                        .onTapGesture(count: 2) { shell.connect(to: host) }
                }
            }
        }
        .frame(minWidth: 230)
        .toolbar {
            ToolbarItemGroup {
                Button { editingHost = nil; showingEditor = true } label: { Image(systemName: "plus") }
                    .help("Neue Verbindung")
                Button { shell.hostStore.importSSHConfig() } label: { Image(systemName: "square.and.arrow.down.on.square") }
                    .help("~/.ssh/config importieren")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let host = shell.hostStore.hosts.first(where: { $0.id == selection }) {
                Button { shell.connect(to: host) } label: {
                    Label("Verbinden", systemImage: "bolt.horizontal.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(8)
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if shell.hasTabs {
            VStack(spacing: 0) {
                TabBar(shell: shell)
                Divider()
                if let tab = shell.selectedTab {
                    TabContent(shell: shell, tab: tab)
                }
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            BrandMark(size: 60)

            VStack(spacing: 6) {
                Text("humibeam").font(.system(size: 26, weight: .bold))
                Text("Steuere Claude Code auf deinem Server — per Terminal, Screenshot-Paste (⌘V) und Sprache.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }

            if shell.hostStore.hosts.isEmpty {
                Button { editingHost = nil; showingEditor = true } label: {
                    Label("Erste Verbindung anlegen", systemImage: "plus")
                        .frame(minWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                VStack(spacing: 8) {
                    Text("Verbinden")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    ForEach(shell.hostStore.hosts) { host in
                        Button { shell.connect(to: host) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "server.rack").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(host.displayName).font(.body).fontWeight(.medium)
                                    Text("\(host.username)@\(host.host):\(host.port)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 16)
                                Image(systemName: "bolt.horizontal.fill").foregroundStyle(.green)
                            }
                            .frame(width: 320)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    Button { editingHost = nil; showingEditor = true } label: {
                        Label("Neue Verbindung", systemImage: "plus").font(.callout)
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Tab bar

private struct TabBar: View {
    @Bindable var shell: HumibeamShell
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(shell.tabs) { tab in
                    let active = shell.selectedTabID == tab.id
                    HStack(spacing: 6) {
                        Circle().fill(tab.connected ? .green : .secondary).frame(width: 7, height: 7)
                        Text(tab.title).font(.callout).lineLimit(1)
                        Button { shell.closeTab(tab) } label: { Image(systemName: "xmark").font(.caption2) }
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(active ? Color.accentColor.opacity(0.18) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                    .onTapGesture { shell.selectedTabID = tab.id }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .background(.bar)
    }
}

// MARK: - Tab content

private struct TabContent: View {
    @Bindable var shell: HumibeamShell
    @Bindable var tab: TerminalTab
    var onClose: () -> Void = {}
    @State private var isFullscreen = false

    var body: some View {
        VStack(spacing: 0) {
            if !isFullscreen {
                TerminalToolbar(shell: shell, tab: tab, onClose: onClose)
                Divider()
            }
            if tab.searchVisible {
                SearchBar(tab: tab)
                Divider()
            }
            if tab.awaitingApproval {
                approvalBar
                Divider()
            }
            terminals
                .padding(12)
                .frame(minWidth: 480, minHeight: 300)
            if tab.showFileBrowser {
                Divider()
                FileBrowserView(shell: shell, tab: tab).frame(height: 250)
            }
            if !isFullscreen {
                statusBar
            }
        }
        .background(Color.black)
        .background(FullscreenReader(isFullscreen: $isFullscreen))
        .sheet(isPresented: $tab.showAIPanel) { AIPanel(tab: tab) }
        .sheet(isPresented: $tab.showEditor) { RemoteEditor(shell: shell, tab: tab) }
        .sheet(isPresented: $tab.showForwards) { ForwardsSheet(shell: shell, tab: tab) }
    }

    @ViewBuilder
    private var terminals: some View {
        if let split = tab.splitController {
            HSplitView {
                TerminalRepresentable(controller: tab.controller)
                TerminalRepresentable(controller: split)
            }
        } else {
            TerminalRepresentable(controller: tab.controller)
        }
    }

    private var approvalBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text("Claude möchte etwas ausführen — erlauben?")
                .font(.callout).fontWeight(.medium)
            Spacer()
            Button("Ablehnen") { tab.controller.deny() }
                .keyboardShortcut(.cancelAction)
            if tab.approvalAllowAlways {
                Button("Immer erlauben") { tab.controller.approveAlways() }
            }
            Button("Erlauben") { tab.controller.approve() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(tab.connected ? Color.green : Color.secondary).frame(width: 8, height: 8)
            Text(tab.status).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if shell.broadcastInput {
                Label("Broadcast", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5).background(.bar)
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

private struct TerminalToolbar: View {
    @Bindable var shell: HumibeamShell
    @Bindable var tab: TerminalTab
    var onClose: () -> Void = {}
    @State private var showSuggest = false

    var body: some View {
        HStack(spacing: 12) {
            Text(tab.host.displayName).font(.headline)
            if tab.claudeDetected {
                Label("Claude Code", systemImage: "sparkles")
                    .font(.caption2).foregroundStyle(.purple)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.purple.opacity(0.12), in: Capsule())
            }
            Spacer()
            Button { NotificationCenter.default.post(name: .toggleTerminalDictation, object: nil) } label: {
                Image(systemName: "mic.fill")
            }
            .help("Diktat ins Terminal (an Claude sprechen) — nochmal klicken zum Stoppen")
            .disabled(!tab.connected)
            Menu {
                Button("Letzte Ausgabe erklären") { Task { await shell.explainOutput(tab) } }
                Button("Fehler beheben") { Task { await shell.fixError(tab) } }
                Button("Befehl vorschlagen…") { tab.aiSuggestIntent = ""; showSuggest = true }
            } label: { Image(systemName: "sparkles") }
                .menuStyle(.borderlessButton).fixedSize().help("KI-Hilfe").disabled(!tab.connected)
                .alert("Was soll der Befehl tun?", isPresented: $showSuggest) {
                    TextField("z.B. alle .log-Dateien finden", text: $tab.aiSuggestIntent)
                    Button("Vorschlagen") { Task { await shell.suggestCommand(tab, intent: tab.aiSuggestIntent) } }
                    Button("Abbrechen", role: .cancel) {}
                }
            if !tab.recentPaths.isEmpty {
                Menu {
                    Section("Von Claude geöffnet") {
                        ForEach(tab.recentPaths, id: \.self) { p in
                            Button(p) { Task { await shell.openPathForEdit(tab, path: p) } }
                        }
                    }
                } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Dateien aus Claudes Ausgabe im Editor öffnen").disabled(!tab.connected)
            }
            HStack(spacing: 4) {
                Button { shell.terminalFontSize = max(9, shell.terminalFontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                Button { shell.terminalFontSize = min(28, shell.terminalFontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
            }
            .help("Schriftgröße")
            Button { tab.searchVisible.toggle() } label: { Image(systemName: "magnifyingglass") }
                .help("Suchen (Cmd+F)")
            Menu {
                Picker("Theme", selection: $shell.selectedThemeID) {
                    ForEach(TerminalTheme.all) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
            } label: { Image(systemName: "paintpalette") }
                .menuStyle(.borderlessButton).fixedSize().help("Farbschema")
            Button { shell.broadcastInput.toggle() } label: {
                Image(systemName: shell.broadcastInput ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
            }
            .help("Eingabe an alle Tabs senden")
            .foregroundStyle(shell.broadcastInput ? .orange : .primary)
            Menu {
                ForEach(shell.snippets.snippets) { snip in
                    Button(snip.title) { tab.controller.sendToShell(snip.command) }
                }
            } label: { Image(systemName: "text.append") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Snippets").disabled(!tab.connected)
            Button { shell.toggleSplit(tab) } label: {
                Image(systemName: tab.isSplit ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
            }
            .help("Split-Ansicht").disabled(!tab.connected)
            Button { tab.showForwards = true } label: { Image(systemName: "arrow.left.arrow.right") }
                .help("Port-Weiterleitung").disabled(!tab.connected)
            Button {
                tab.showFileBrowser.toggle()
                if tab.showFileBrowser { Task { await shell.refreshBrowser(tab) } }
            } label: { Image(systemName: "folder") }
                .help("Datei-Browser")
            Button { uploadViaPanel() } label: { Image(systemName: "arrow.up.doc") }
                .help("Datei hochladen").disabled(!tab.connected)
            Button(role: .destructive) { onClose() } label: { Image(systemName: "xmark.circle") }
                .help("Sitzung schließen")
        }
        .padding(.horizontal, 12).padding(.vertical, 7).background(.bar)
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

private struct HostRow: View {
    let host: SSHHost
    let connected: Bool
    var body: some View {
        HStack {
            Image(systemName: connected ? "bolt.horizontal.circle.fill" : "server.rack")
                .foregroundStyle(connected ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName).font(.body)
                Text("\(host.username)@\(host.host):\(host.port)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Per-session windows (one window per session)

/// Content of an SSH session window — full terminal toolbar + file browser, without sidebar/tabs.
struct SSHSessionWindowView: View {
    @Bindable var shell: HumibeamShell
    @Bindable var tab: TerminalTab
    var onClose: () -> Void
    var body: some View {
        TabContent(shell: shell, tab: tab, onClose: onClose)
            .frame(minWidth: 620, minHeight: 380)
    }
}

/// Content of a local terminal window (the user's Mac shell).
struct LocalSessionWindowView: View {
    @Bindable var session: LocalSession
    @State private var isFullscreen = false
    var body: some View {
        VStack(spacing: 0) {
            LocalTerminalRepresentable(session: session)
                .padding(12)
                .frame(minWidth: 620, minHeight: 340)
            if !isFullscreen {
                HStack(spacing: 8) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Lokales Terminal — Mac-Shell").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 5).background(.bar)
            }
        }
        .background(Color.black)
        .background(FullscreenReader(isFullscreen: $isFullscreen))
    }
}

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
