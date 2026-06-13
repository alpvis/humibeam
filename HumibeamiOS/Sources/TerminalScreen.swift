import SwiftUI
import PhotosUI
import Combine

/// Eine laufende Sitzung: Terminal, Statuszeile, Agent-Cockpit (Approval-Karte) und Werkzeuge.
/// Multi-Session: oben eine Leiste mit allen lebenden Sitzungen, "+" öffnet eine weitere zum Host.
struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    let sessionID: UUID

    @StateObject private var holder = ControllerHolder()
    @State private var showsDiff = false
    @State private var showsSnippets = false
    @State private var showsHistory = false
    @State private var showsFiles = false
    @State private var showsForwards = false
    @State private var photoItem: PhotosPickerItem?
    @State private var dictationError: String?
    @StateObject private var aiPanel = AIPanelModel()
    @State private var showsAIPanel = false
    @State private var suggestIntentActive = false
    @State private var suggestIntent = ""
    @State private var showsSearch = false
    @State private var searchTerm = ""
    @FocusState private var searchFocused: Bool
    @State private var queueActive = false
    @State private var queuePrompt = ""

    var body: some View {
        if let session = model.session(withID: sessionID) {
            content(session)
        } else {
            ContentUnavailableView("Sitzung beendet", systemImage: "xmark.circle",
                                   description: Text("Diese Sitzung wurde geschlossen."))
        }
    }

    private func content(_ session: TerminalSession) -> some View {
        let controller = holder.bind(session.controller)

        return VStack(spacing: 0) {
            if model.sessions.count > 1 {
                sessionBar(current: session)
            }

            if showsSearch {
                searchBar(controller)
            }

            TerminalHostView(controller: controller)
                .ignoresSafeArea(.container, edges: .bottom)

            if !controller.recentPaths.isEmpty {
                recentPathChips(controller)
            }
            statusBar(controller)
        }
        .background(Color(model.theme.background))
        .overlay(alignment: .bottom) {
            if let approval = controller.approval {
                let waiting = model.sessions.filter { $0.controller.approval != nil }
                ApprovalCard(approval: approval, controller: controller,
                             queuePosition: waiting.firstIndex { $0.id == session.id }.map { $0 + 1 },
                             queueTotal: waiting.count,
                             onResolved: { advanceToNextWaiting(after: session) })
                    .padding(.horizontal, 10)
                    .padding(.bottom, 56)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: controller.approval)
        .onReceive(NotificationCenter.default.publisher(for: .dictationFailed)) { note in
            dictationError = note.userInfo?["message"] as? String ?? "Diktat fehlgeschlagen."
        }
        .alert("Diktat", isPresented: Binding(get: { dictationError != nil },
                                              set: { if !$0 { dictationError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dictationError ?? "")
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showsSnippets = true
                } label: { Image(systemName: "curlybraces") }
                    .keyboardShortcut("j", modifiers: .command)

                Button {
                    showsDiff = true
                } label: { Image(systemName: "plusminus") }
                    .disabled(!controller.isConnected)
                    .keyboardShortcut("d", modifiers: [.command, .shift])

                Button {
                    withAnimation(.snappy(duration: 0.2)) { showsSearch.toggle() }
                    if showsSearch { searchFocused = true }
                    else { controller.clearSearch(); searchTerm = "" }
                } label: { Image(systemName: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command)

                Menu {
                    Section("KI") {
                        Button {
                            showsAIPanel = true
                            Task { await aiPanel.explain(controller) }
                        } label: { Label("Ausgabe erklären", systemImage: "questionmark.bubble") }
                        Button {
                            showsAIPanel = true
                            Task { await aiPanel.fix(controller) }
                        } label: { Label("Fehler beheben", systemImage: "stethoscope") }
                        Button {
                            suggestIntentActive = true
                        } label: { Label("Befehl vorschlagen…", systemImage: "wand.and.stars") }
                    }
                    Button {
                        showsFiles = true
                    } label: { Label("Dateien…", systemImage: "folder") }
                        .disabled(!controller.isConnected)
                    Button {
                        showsForwards = true
                    } label: { Label("Port-Weiterleitung…", systemImage: "arrow.left.arrow.right") }
                        .disabled(!controller.isConnected)
                    Button {
                        showsHistory = true
                    } label: { Label("Befehls-Verlauf…", systemImage: "clock.arrow.circlepath") }
                    Button {
                        queueActive = true
                    } label: { Label("Auftrag einreihen…", systemImage: "text.line.first.and.arrowtriangle.forward") }
                        .disabled(!controller.isConnected)
                    Divider()
                    Button {
                        Task { await ImagePaste.pasteFromClipboard(into: controller) }
                    } label: { Label("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard") }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Foto hochladen…", systemImage: "photo")
                    }
                    Divider()
                    Button {
                        let newSession = model.addSession(for: session.host)
                        model.connect(newSession)
                        model.requestedSessionID = newSession.id
                    } label: { Label("Neue Sitzung zu diesem Server", systemImage: "plus.rectangle.on.rectangle") }
                        .keyboardShortcut("t", modifiers: .command)
                    if controller.isConnected {
                        Button(role: .destructive) {
                            controller.disconnect()
                        } label: { Label("Trennen", systemImage: "xmark.circle") }
                    } else {
                        Button {
                            model.connect(session)
                        } label: { Label("Verbinden", systemImage: "bolt") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showsDiff) {
            DiffSheet(controller: controller)
        }
        .sheet(isPresented: $showsSnippets) {
            SnippetsSheet(controller: controller)
        }
        .sheet(isPresented: $showsHistory) {
            HistorySheet(controller: controller)
        }
        .sheet(isPresented: $showsFiles) {
            FilesSheet(controller: controller)
        }
        .sheet(isPresented: $showsForwards) {
            ForwardsSheet(session: session)
        }
        .sheet(isPresented: $showsAIPanel) {
            AIPanelSheet(panel: aiPanel)
        }
        .alert("Was soll der Befehl tun?", isPresented: $suggestIntentActive) {
            TextField("z. B. alle Logs der letzten Stunde", text: $suggestIntent)
            Button("Vorschlagen") {
                showsAIPanel = true
                let intent = suggestIntent
                suggestIntent = ""
                Task { await aiPanel.suggest(controller, intent: intent) }
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("Auftrag einreihen", isPresented: $queueActive) {
            TextField("Prompt für Claude…", text: $queuePrompt)
            Button("Einreihen") {
                controller.enqueuePrompt(queuePrompt)
                queuePrompt = ""
            }
            Button("Abbrechen", role: .cancel) { queuePrompt = "" }
        } message: {
            Text("Wird abgeschickt, sobald Claude den aktuellen Auftrag beendet hat. Mehrere Aufträge laufen nacheinander.")
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data), let png = image.pngData() {
                    await ImagePaste.upload([png], into: controller)
                }
                photoItem = nil
            }
        }
        .onAppear {
            if !controller.isConnected && controller.connection == nil {
                model.connect(session)
            }
            if UserDefaults.standard.object(forKey: "keyboard.autoShow") as? Bool ?? true {
                _ = controller.terminalView.becomeFirstResponder()
            }
        }
        // Handoff zum Mac: dieselbe Sitzung (tmux) dort weiterführen.
        .userActivity("app.humibeam.session") { activity in
            activity.title = "Terminal: \(session.host.displayName)"
            activity.userInfo = ["hostID": session.host.id.uuidString,
                                 "hostName": session.host.displayName]
            activity.isEligibleForHandoff = true
        }
    }

    /// Nach einer Freigabe-Entscheidung zur nächsten wartenden Sitzung springen (Durchwischen).
    private func advanceToNextWaiting(after current: TerminalSession) {
        guard let next = model.sessions.first(where: {
            $0.id != current.id && $0.controller.approval != nil
        }) else { return }
        model.requestedSessionID = next.id
    }

    /// Suchleiste über dem Terminal: tippt durch die Treffer im (10.000-Zeilen-)Scrollback.
    private func searchBar(_ controller: TerminalController) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Im Terminal suchen…", text: $searchTerm)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { _ = controller.findNext(searchTerm) }
            Button {
                _ = controller.findPrevious(searchTerm)
            } label: { Image(systemName: "chevron.up") }
                .disabled(searchTerm.isEmpty)
            Button {
                _ = controller.findNext(searchTerm)
            } label: { Image(systemName: "chevron.down") }
                .disabled(searchTerm.isEmpty)
            Button {
                withAnimation(.snappy(duration: 0.2)) { showsSearch = false }
                controller.clearSearch()
                searchTerm = ""
                _ = controller.terminalView.becomeFirstResponder()
            } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    /// Leiste mit allen lebenden Sitzungen (alle Hosts) — Tap wechselt.
    private func sessionBar(current: TerminalSession) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.sessions) { session in
                    Button {
                        guard session.id != current.id else { return }
                        model.requestedSessionID = session.id
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(session.controller.isConnected ? .green : .orange)
                                .frame(width: 6, height: 6)
                            Text(session.title)
                                .font(.caption.weight(session.id == current.id ? .bold : .regular))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(session.id == current.id
                                                   ? Color.cyan.opacity(0.25) : Color.gray.opacity(0.15)))
                        .foregroundStyle(session.id == current.id ? .cyan : .secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 4)
        .background(.bar)
    }

    /// Dateien, die Claude zuletzt angefasst hat, als antippbare Chips — Tap tippt den Pfad
    /// ins Terminal (z. B. um ihn in den nächsten Prompt zu übernehmen).
    private func recentPathChips(_ controller: TerminalController) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(controller.recentPaths, id: \.self) { path in
                    Button {
                        controller.sendToShell(path)
                    } label: {
                        Label((path as NSString).lastPathComponent, systemImage: "doc.text")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.cyan.opacity(0.15)))
                            .foregroundStyle(.cyan)
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func statusBar(_ controller: TerminalController) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.isConnected ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(controller.status)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            if !controller.promptQueue.isEmpty {
                Menu {
                    ForEach(Array(controller.promptQueue.enumerated()), id: \.offset) { _, prompt in
                        Text(prompt).lineLimit(1)
                    }
                    Divider()
                    Button(role: .destructive) {
                        controller.clearPromptQueue()
                    } label: { Label("Warteschlange leeren", systemImage: "trash") }
                } label: {
                    Label("\(controller.promptQueue.count)", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                }
            }
            if controller.claudeDetected {
                // Claude-Status Plus: liest/bearbeitet/führt aus/wartet — live aus dem Stream.
                Label(controller.activity.label, systemImage: statusSymbol(controller.activity))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(controller.activity.kind == .waiting ? .orange : .cyan)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func statusSymbol(_ status: ClaudeStatus) -> String {
        switch status.kind {
        case .waiting: return "hand.raised.fill"
        case .busy: return "sparkles"
        case .idle: return "checkmark.seal"
        }
    }
}

/// Reicht objectWillChange des (ObservableObject-)Controllers an SwiftUI durch; die Sitzung
/// selbst lebt im AppModel weiter.
@MainActor
private final class ControllerHolder: ObservableObject {
    private var bound: TerminalController?
    private var bag = Set<AnyCancellable>()

    func bind(_ controller: TerminalController) -> TerminalController {
        if bound === controller { return controller }
        bag.removeAll()
        bound = controller
        controller.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        return controller
    }
}

// MARK: - Approval-Karte (Agent-Cockpit Stufe 1)

/// Native Karte für Claude Codes Erlaubnis-Prompt: Aktionstyp, Befehl/Diff,
/// Erlauben / Immer erlauben / Ablehnen. Gefährliche Befehle färben die Karte rot.
struct ApprovalCard: View {
    let approval: ClaudeApproval
    let controller: TerminalController
    /// Position dieser Sitzung in der Warteschlange (1-basiert) und Gesamtzahl wartender Sitzungen.
    var queuePosition: Int? = nil
    var queueTotal: Int = 1
    /// Wird nach Erlauben/Immer/Ablehnen aufgerufen — springt zur nächsten wartenden Sitzung.
    var onResolved: (() -> Void)? = nil

    private var tint: Color { approval.looksDangerous ? .red : .cyan }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if queueTotal > 1, let pos = queuePosition {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack.fill")
                    Text("Freigabe \(pos) von \(queueTotal)")
                    Spacer()
                    Text("nach der Antwort geht's zur nächsten")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Image(systemName: approval.action.symbol)
                Text(approval.action.label).font(.subheadline.weight(.semibold))
                if approval.exact {
                    Text("exakt")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.green.opacity(0.25)))
                        .foregroundStyle(.green)
                }
                Spacer()
                if approval.looksDangerous {
                    Label("Vorsicht", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            .foregroundStyle(tint)

            if !approval.question.isEmpty {
                Text(approval.question)
                    .font(.footnote)
                    .foregroundStyle(.primary)
            }

            if !approval.preview.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(approval.preview.prefix(40)) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(background(for: line.kind))
                        }
                    }
                }
                .frame(maxHeight: 150)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.25)))
            }

            HStack(spacing: 8) {
                Button {
                    controller.approve()
                    onResolved?()
                } label: {
                    Label("Erlauben", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(approval.looksDangerous ? .red : .green)

                if approval.allowAlways {
                    Button {
                        controller.approveAlways()
                        onResolved?()
                    } label: {
                        Text("Immer")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    controller.deny()
                    onResolved?()
                } label: {
                    Label("Ablehnen", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.5)))
        )
        .shadow(radius: 8, y: 4)
    }

    private func color(for kind: ClaudeApproval.Line.Kind) -> Color {
        switch kind {
        case .add: return .green
        case .remove: return .red
        case .context: return .primary.opacity(0.85)
        }
    }

    private func background(for kind: ClaudeApproval.Line.Kind) -> Color {
        switch kind {
        case .add: return .green.opacity(0.12)
        case .remove: return .red.opacity(0.12)
        case .context: return .clear
        }
    }
}

// MARK: - Diff-Sheet (Agent-Cockpit Stufe 2)

/// Holt den echten Arbeitsbaum-Diff (`git diff HEAD` + untracked) über den Exec-Channel.
struct DiffSheet: View {
    let controller: TerminalController
    @Environment(\.dismiss) private var dismiss
    @State private var result: GitDiffResult?

    var body: some View {
        NavigationStack {
            Group {
                switch result {
                case nil:
                    ProgressView("Hole Diff vom Server…")
                case .clean:
                    ContentUnavailableView("Keine Änderungen",
                                           systemImage: "checkmark.circle",
                                           description: Text("Der Arbeitsbaum ist sauber."))
                case .notARepo:
                    ContentUnavailableView("Kein Git-Repository",
                                           systemImage: "questionmark.folder",
                                           description: Text("Im Arbeitsverzeichnis wurde kein Repo gefunden."))
                case .noLocation:
                    ContentUnavailableView("Verzeichnis unbekannt",
                                           systemImage: "questionmark.folder",
                                           description: Text("Konnte das Remote-Arbeitsverzeichnis nicht bestimmen."))
                case .error(let message):
                    ContentUnavailableView("Fehler", systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                case .diff(let lines, let untracked):
                    diffList(lines: lines, untracked: untracked)
                }
            }
            .navigationTitle("Änderungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        result = nil
                        Task { await load() }
                    } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        var candidates: [String] = []
        if let cwd = controller.currentDirectory { candidates.append(cwd) }
        for path in controller.recentPaths where path.hasPrefix("/") {
            candidates.append((path as NSString).deletingLastPathComponent)
        }
        result = await GitDiffService.fetch(connection: controller.connection, candidates: candidates)
    }

    private func diffList(lines: [DiffHunkLine], untracked: [String]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !untracked.isEmpty {
                    Text("Neue Dateien: \(untracked.joined(separator: ", "))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                        .padding(.bottom, 6)
                }
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(for: line.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(for: line.kind))
                }
            }
            .padding(10)
        }
    }

    private func color(for kind: DiffHunkLine.Kind) -> Color {
        switch kind {
        case .add: return .green
        case .remove: return .red
        case .hunk: return .cyan
        case .file: return .primary
        case .context: return .secondary
        }
    }

    private func background(for kind: DiffHunkLine.Kind) -> Color {
        switch kind {
        case .add: return .green.opacity(0.12)
        case .remove: return .red.opacity(0.12)
        case .file: return .white.opacity(0.06)
        default: return .clear
        }
    }
}
