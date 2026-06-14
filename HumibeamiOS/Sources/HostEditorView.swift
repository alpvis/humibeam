import SwiftUI
import UniformTypeIdentifiers

/// Profil-Editor: Host, Login und Authentifizierung (humibeam-Schlüssel / Passwort / eigener Key).
struct HostEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State var host: SSHHost
    let isNew: Bool

    @State private var password = ""
    @State private var envText = ""
    @State private var showsKeyImporter = false
    @State private var importError: String?
    @State private var copiedKey = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name (optional)", text: $host.name)
                    TextField("Host / IP", text: $host.host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", value: $host.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    TextField("Benutzer", text: $host.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Anmeldung") {
                    // pairedKey entsteht nur über das QR-Pairing, nicht manuell.
                    Picker("Methode", selection: $host.authKind) {
                        ForEach(AuthKind.allCases.filter { $0 != .pairedKey || host.authKind == .pairedKey }) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }

                    switch host.authKind {
                    case .pairedKey:
                        Text("Der Schlüssel wurde beim Koppeln mit deinem Mac per QR übernommen und liegt im Geräte-Keychain.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .password:
                        SecureField("Passwort", text: $password)
                    case .managedKey:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Diesen öffentlichen Schlüssel einmalig am Server in `~/.ssh/authorized_keys` eintragen:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(SSHKeyManager.managedAuthorizedKeysLine())
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(3)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Button {
                                UIPasteboard.general.string = SSHKeyManager.managedAuthorizedKeysLine()
                                copiedKey = true
                            } label: {
                                Label(copiedKey ? "Kopiert" : "Schlüssel kopieren",
                                      systemImage: copiedKey ? "checkmark" : "doc.on.doc")
                            }
                        }
                    case .importedKey:
                        Button {
                            showsKeyImporter = true
                        } label: {
                            Label(host.importedKeyPath == nil ? "Privaten Schlüssel importieren…"
                                                              : "Schlüssel importiert ✓ (ändern…)",
                                  systemImage: "key")
                        }
                        if let importError {
                            Text(importError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                Section {
                    Toggle("Abbruchsicher (tmux)", isOn: Binding(
                        get: { host.tmuxEnabled },
                        set: { host.useTmux = $0 }
                    ))
                    TextField("Befehl nach dem Verbinden (optional)", text: Binding(
                        get: { host.startupCommand ?? "" },
                        set: { host.startupCommand = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                } footer: {
                    Text("tmux: Sitzung läuft am Server weiter und wird beim Neuverbinden nahtlos fortgesetzt. Ein eigener Befehl (z. B. „tmux attach -t claudes\u{201C}) wird direkt nach dem Verbinden ausgeführt und ersetzt die tmux-Automatik.")
                }

                Section("Erweitert") {
                    TextField("Terminal-Typ ($TERM)", text: Binding(
                        get: { host.terminalType ?? "" },
                        set: { host.terminalType = $0 }
                    ), prompt: Text("xterm-256color"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    Toggle("Backspace sendet ^H", isOn: Binding(
                        get: { host.backspaceCtrlH ?? false },
                        set: { host.backspaceCtrlH = $0 }
                    ))
                }

                Section {
                    TextField("NAME=WERT, eine pro Zeile", text: $envText, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3...8)
                } header: {
                    Text("Umgebungsvariablen (optional)")
                } footer: {
                    Text("Wird beim Verbinden gesetzt (export) — auch nach Reconnect. Sicher im Geräte-Keychain, wird nicht synchronisiert.")
                }

                if model.hostStore.hosts.contains(where: { $0.id != host.id }) {
                    Section("Verbindung über Bastion (ProxyJump)") {
                        Picker("Bastion", selection: $host.proxyJumpHostID) {
                            Text("Keine").tag(UUID?.none)
                            ForEach(model.hostStore.hosts.filter { $0.id != host.id }) { other in
                                Text(other.displayName).tag(UUID?.some(other.id))
                            }
                        }
                    }
                }

                if !isNew {
                    Section {
                        Button("Host-Key zurücksetzen (neu vertrauen)") {
                            model.knownHosts.forget(host: host.host, port: host.port)
                        }
                        .foregroundStyle(.orange)
                    } footer: {
                        Text("Nur nötig, wenn der Server bewusst neu aufgesetzt wurde.")
                    }
                }
            }
            .navigationTitle(isNew ? "Neuer Server" : "Server bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save() }
                        .disabled(host.host.trimmingCharacters(in: .whitespaces).isEmpty
                                  || host.username.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .fileImporter(isPresented: $showsKeyImporter,
                          allowedContentTypes: [.data, .text],
                          allowsMultipleSelection: false) { result in
                importKey(result)
            }
            .onAppear {
                if host.authKind == .password {
                    password = SSHKeyManager.loadPassword(hostID: host.id.uuidString) ?? ""
                }
                envText = SSHKeyManager.loadEnvVars(hostID: host.id.uuidString) ?? ""
            }
        }
    }

    private func save() {
        if host.authKind == .password {
            SSHKeyManager.savePassword(password, hostID: host.id.uuidString)
        }
        SSHKeyManager.saveEnvVars(envText, hostID: host.id.uuidString)
        if isNew { model.hostStore.add(host) } else { model.hostStore.update(host) }
        dismiss()
    }

    /// Kopiert den gewählten Private Key in den App-Container (security-scoped URL des Pickers
    /// ist später nicht mehr lesbar) und merkt sich den lokalen Pfad.
    private func importKey(_ result: Result<[URL], Error>) {
        importError = nil
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else {
            importError = "Kein Zugriff auf die Datei."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let pem = try String(contentsOf: url, encoding: .utf8)
            _ = try SSHKeyManager.importPrivateKey(pem: pem) // validieren, bevor wir speichern
            let dir = AppSupportPaths.appSupportDirectoryURL.appendingPathComponent("keys", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("\(host.id.uuidString).pem")
            try pem.write(to: dest, atomically: true, encoding: .utf8)
            host.importedKeyPath = dest.path
        } catch {
            importError = "Schlüssel unbrauchbar: \(error.localizedDescription)"
        }
    }
}
