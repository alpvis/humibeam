import SwiftUI

/// Startansicht: gespeicherte Server, Verbinden per Tap, Verwalten per Swipe.
/// Navigation läuft über Sitzungs-IDs (Multi-Session: mehrere Terminals pro Host).
struct HostListView: View {
    @Environment(AppModel.self) private var model
    @State private var editingHost: SSHHost?
    @State private var showsNewHost = false
    @State private var showsSettings = false
    @State private var showsArchive = false
    @State private var showsFleet = false
    @State private var showsPairing = false
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.hostStore.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("Keine Server", systemImage: "server.rack")
                    } description: {
                        Text("Lege deinen ersten Server an und starte Claude Code von unterwegs.")
                    } actions: {
                        Button("Server hinzufügen") { showsNewHost = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        // Agent-Inbox: alle Sitzungen, in denen Claude auf eine Freigabe wartet.
                        let waiting = model.sessions.filter { $0.controller.approval != nil }
                        if !waiting.isEmpty {
                            Section {
                                ForEach(waiting) { session in
                                    InboxRow(session: session) { path = [session.id] }
                                }
                            } header: {
                                Label("Wartet auf Freigabe", systemImage: "hand.raised.fill")
                                    .foregroundStyle(.orange)
                            }
                        }

                        ForEach(model.hostStore.hosts) { host in
                            Button {
                                path = [model.primarySession(for: host).id]
                            } label: {
                                HostRow(host: host,
                                        active: model.activeSessions.contains(host.id),
                                        stats: model.stats[host.id])
                            }
                            .foregroundStyle(.primary)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    model.closeSessions(for: host.id)
                                    model.hostStore.delete(host)
                                } label: { Label("Löschen", systemImage: "trash") }
                                Button {
                                    editingHost = host
                                } label: { Label("Bearbeiten", systemImage: "pencil") }
                                .tint(.indigo)
                            }
                        }

                        if model.sessions.count > 1 {
                            Section("Aktive Sitzungen") {
                                ForEach(model.sessions) { session in
                                    Button {
                                        path = [session.id]
                                    } label: {
                                        HStack {
                                            Circle()
                                                .fill(session.controller.isConnected ? .green : .orange)
                                                .frame(width: 8, height: 8)
                                            Text(session.title)
                                            Spacer()
                                            if session.controller.claudeDetected {
                                                Text(session.controller.activity.label)
                                                    .font(.caption2)
                                                    .foregroundStyle(session.controller.activity.kind == .waiting
                                                                     ? .orange : .cyan)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    .foregroundStyle(.primary)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            model.closeSession(session)
                                        } label: { Label("Schließen", systemImage: "xmark") }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("humibeam")
            .navigationDestination(for: UUID.self) { sessionID in
                TerminalScreen(sessionID: sessionID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showsFleet = true } label: { Image(systemName: "square.grid.2x2") }
                    Button { showsArchive = true } label: { Image(systemName: "doc.text.magnifyingglass") }
                    Menu {
                        Button { showsNewHost = true } label: {
                            Label("Server hinzufügen", systemImage: "server.rack")
                        }
                        Button { showsPairing = true } label: {
                            Label("Mac koppeln (QR)", systemImage: "qrcode.viewfinder")
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showsNewHost) {
                HostEditorView(host: SSHHost(), isNew: true)
            }
            .sheet(item: $editingHost) { host in
                HostEditorView(host: host, isNew: false)
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showsArchive) {
                TranscriptArchiveSheet()
            }
            .sheet(isPresented: $showsFleet) {
                FleetSheet()
            }
            .sheet(isPresented: $showsPairing) {
                PairScanSheet()
            }
            .onContinueUserActivity("app.humibeam.session") { activity in
                // Handoff vom Mac: gleiche Sitzung (tmux) auf dem iPhone weiterführen.
                guard let info = activity.userInfo else { return }
                let host: SSHHost?
                if let idStr = info["hostID"] as? String, let id = UUID(uuidString: idStr) {
                    host = model.hostStore.hosts.first { $0.id == id }
                        ?? model.hostStore.hosts.first { $0.displayName == (info["hostName"] as? String ?? "") }
                } else {
                    host = model.hostStore.hosts.first { $0.displayName == (info["hostName"] as? String ?? "") }
                }
                guard let host else { return }
                let session = model.primarySession(for: host)
                if !session.controller.isConnected && session.controller.connection == nil {
                    model.connect(session)
                }
                path = [session.id]
            }
            .onChange(of: model.requestedSessionID) { _, requested in
                if let requested {
                    path = [requested]
                    model.requestedSessionID = nil
                }
            }
            .onAppear {
                #if DEBUG
                // Test-Hook: `simctl launch … -autoconnect` öffnet den ersten Host direkt.
                if CommandLine.arguments.contains("-autoconnect"), let first = model.hostStore.hosts.first {
                    path = [model.primarySession(for: first).id]
                }
                #endif
            }
        }
    }
}

/// Inbox-Zeile: Was will der Agent? Erlauben/Ablehnen direkt hier, Tap öffnet die Sitzung.
private struct InboxRow: View {
    let session: TerminalSession
    let open: () -> Void

    var body: some View {
        let approval = session.controller.approval
        VStack(alignment: .leading, spacing: 6) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: approval?.action.symbol ?? "questionmark")
                            .foregroundStyle(approval?.looksDangerous == true ? .red : .cyan)
                        Text(session.title).font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    if let approval, !approval.question.isEmpty {
                        Text(approval.question)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    session.controller.approve()
                } label: { Label("Erlauben", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .tint(approval?.looksDangerous == true ? .red : .green)
                Button {
                    session.controller.deny()
                } label: { Label("Ablehnen", systemImage: "xmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

private struct HostRow: View {
    let host: SSHHost
    let active: Bool
    let stats: ServerStats?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(stats?.isCritical == true ? .red : .cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName).font(.headline)
                Text("\(host.username)@\(host.host):\(String(host.port))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let stats {
                    HStack(spacing: 8) {
                        if let l = stats.load1 { statChip("gauge", String(format: "%.1f", l)) }
                        if let m = stats.memUsedPercent { statChip("memorychip", "\(m)%", critical: m >= 90) }
                        if let d = stats.diskPercent { statChip("internaldrive", "\(d)%", critical: d >= 90) }
                        if let z = stats.zombies, z > 0 { statChip("ant", "\(z)", critical: z > 5) }
                    }
                }
            }
            Spacer()
            if active {
                Circle().fill(.green).frame(width: 9, height: 9)
            }
        }
        .padding(.vertical, 2)
    }

    private func statChip(_ symbol: String, _ text: String, critical: Bool = false) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(critical ? .red : .secondary)
    }
}

/// Einstellungen: Konto, Darstellung (Theme/Schrift), Sicherheit, Diktat, Push.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var openAIKey = KeychainService.load(key: .openAIAPIKey) ?? ""
    @AppStorage("lock.enabled") private var lockEnabled = false
    @AppStorage("dictation.local") private var localDictation = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                AccountSection(account: model.accountSync)

                Section("Darstellung") {
                    Picker("Theme", selection: $model.themeID) {
                        ForEach(TerminalTheme.all) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                    Picker("Schriftart", selection: $model.fontName) {
                        Text("System (SF Mono)").tag("")
                        ForEach(AppModel.availableMonospaceFamilies, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    Stepper("Schriftgröße: \(Int(model.fontSize))",
                            value: $model.fontSize, in: 9...22, step: 1)
                    HStack {
                        Text("Presets")
                        Spacer()
                        ForEach([11.0, 13.0, 15.0, 18.0], id: \.self) { size in
                            Button("\(Int(size))") { model.fontSize = size }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(model.fontSize == size ? .cyan : .secondary)
                        }
                    }
                }

                Section {
                    Toggle("Mit Face ID schützen", isOn: $lockEnabled)
                } header: {
                    Text("Sicherheit")
                } footer: {
                    Text("Beim Öffnen der App wird Face ID/Touch ID verlangt. Deine SSH-Schlüssel liegen zusätzlich im Geräte-Keychain.")
                }

                Section {
                    Toggle("Lokal transkribieren (Apple)", isOn: $localDictation)
                    if !localDictation {
                        SecureField("sk-…", text: $openAIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: openAIKey) { _, value in
                                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                if trimmed.isEmpty { KeychainService.delete(key: .openAIAPIKey) }
                                else { try? KeychainService.save(key: .openAIAPIKey, value: trimmed) }
                            }
                    }
                } header: {
                    Text("Sprach-Diktat")
                } footer: {
                    Text(localDictation
                         ? "Apple-Spracherkennung auf dem Gerät — offline, kostenlos, kein API-Key nötig."
                         : "OpenAI Whisper: aufnehmen → transkribieren → Text landet im Terminal. Der Key bleibt im Geräte-Keychain.")
                }

                Section {
                    TextField("Relay-URL", text: Binding(
                        get: { PushRegistration.baseURL },
                        set: { PushRegistration.baseURL = $0 }
                    ))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Relay-Secret", text: Binding(
                        get: { PushRegistration.secret },
                        set: { PushRegistration.secret = $0 }
                    ))
                } header: {
                    Text("Push (\u{201E}Claude wartet\u{201C})")
                } footer: {
                    Text("Gleiche Werte wie in der Mac-App (Einstellungen → iPhone-Push). Das Relay läuft auf deinem Server.")
                }
                Section {
                    LabeledContent("Version",
                                   value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                } footer: {
                    Text("humibeam für iOS — das Cockpit für Claude Code auf deinen Servern.")
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
