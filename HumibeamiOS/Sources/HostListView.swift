import SwiftUI

/// Startansicht: gespeicherte Server, Verbinden per Tap, Verwalten per Swipe.
struct HostListView: View {
    @Environment(AppModel.self) private var model
    @State private var editingHost: SSHHost?
    @State private var showsNewHost = false
    @State private var showsSettings = false
    @State private var path: [SSHHost] = []

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
                        ForEach(model.hostStore.hosts) { host in
                            NavigationLink(value: host) {
                                HostRow(host: host, active: model.activeSessions.contains(host.id))
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    model.closeSession(for: host.id)
                                    model.hostStore.delete(host)
                                } label: { Label("Löschen", systemImage: "trash") }
                                Button {
                                    editingHost = host
                                } label: { Label("Bearbeiten", systemImage: "pencil") }
                                .tint(.indigo)
                            }
                        }
                    }
                }
            }
            .navigationTitle("humibeam")
            .navigationDestination(for: SSHHost.self) { host in
                TerminalScreen(host: host)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsNewHost = true } label: { Image(systemName: "plus") }
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
            .onAppear {
                #if DEBUG
                // Test-Hook: `simctl launch … -autoconnect` öffnet den ersten Host direkt.
                if CommandLine.arguments.contains("-autoconnect"), let first = model.hostStore.hosts.first {
                    path = [first]
                }
                #endif
            }
        }
    }
}

private struct HostRow: View {
    let host: SSHHost
    let active: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName).font(.headline)
                Text("\(host.username)@\(host.host):\(String(host.port))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if active {
                Circle().fill(.green).frame(width: 9, height: 9)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Einstellungen: Theme + Schriftgröße + Diktat-Key.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var openAIKey = KeychainService.load(key: .openAIAPIKey) ?? ""

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
                    Stepper("Schriftgröße: \(Int(model.fontSize))",
                            value: $model.fontSize, in: 9...22, step: 1)
                }
                Section {
                    SecureField("sk-…", text: $openAIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: openAIKey) { _, value in
                            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty { KeychainService.delete(key: .openAIAPIKey) }
                            else { try? KeychainService.save(key: .openAIAPIKey, value: trimmed) }
                        }
                } header: {
                    Text("Sprach-Diktat (OpenAI API Key)")
                } footer: {
                    Text("Für den Mikrofon-Knopf in der Terminal-Tastenleiste: aufnehmen → Whisper → Text landet im Terminal. Der Key bleibt im Geräte-Keychain.")
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
