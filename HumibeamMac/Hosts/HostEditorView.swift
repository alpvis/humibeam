import SwiftUI

/// Add/edit a saved SSH connection.
struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var host: SSHHost
    @State private var password: String = ""
    @State private var keyPassphrase: String = ""
    @State private var showCopiedKey = false
    var allHosts: [SSHHost] = []
    let onSave: (SSHHost) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(host.name.isEmpty ? "Neue Verbindung" : "Verbindung bearbeiten")
                .font(.title3).bold()
                .padding()

            Form {
                Section {
                    TextField("Name (optional)", text: $host.name)
                    TextField("Host / IP", text: $host.host)
                    HStack {
                        TextField("Benutzer", text: $host.username)
                        TextField("Port", value: $host.port, format: .number)
                            .frame(width: 70)
                    }
                }

                Section("Authentifizierung") {
                    // pairedKey entsteht nur über das QR-Pairing, nicht manuell.
                    Picker("Methode", selection: $host.authKind) {
                        ForEach(AuthKind.allCases.filter { $0 != .pairedKey || host.authKind == .pairedKey }) {
                            Text($0.label).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch host.authKind {
                    case .pairedKey:
                        Text("Der Schlüssel wurde beim Koppeln per QR übernommen und liegt im Geräte-Keychain.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .password:
                        SecureField("Passwort", text: $password)
                    case .managedKey:
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Füge diesen Public Key einmalig auf dem Server in ~/.ssh/authorized_keys ein:")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text(SSHKeyManager.managedAuthorizedKeysLine())
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(2).truncationMode(.middle)
                                    .textSelection(.enabled)
                                Button(showCopiedKey ? "Kopiert ✓" : "Kopieren") {
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.setString(SSHKeyManager.managedAuthorizedKeysLine(), forType: .string)
                                    showCopiedKey = true
                                }
                            }
                        }
                    case .importedKey:
                        HStack {
                            Text(host.importedKeyPath ?? "Keine Datei gewählt")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Schlüssel wählen…") { chooseKeyFile() }
                        }
                        SecureField("Passphrase (falls verschlüsselt)", text: $keyPassphrase)
                        Text("Unterstützt: OpenSSH ed25519 und ECDSA (p256/p384/p521), mit oder ohne Passphrase.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Section("Sitzung") {
                    Toggle("Abbruchsicher (tmux)", isOn: Binding(
                        get: { host.tmuxEnabled },
                        set: { host.useTmux = $0 }
                    ))
                    Text("Die Sitzung läuft am Server in tmux weiter und wird beim Neuverbinden nahtlos fortgesetzt — auch nach WLAN-Wechsel oder App-Neustart. tmux muss am Server installiert sein.")
                        .font(.caption2).foregroundStyle(.secondary)
                    TextField("Befehl nach dem Verbinden (optional)", text: Binding(
                        get: { host.startupCommand ?? "" },
                        set: { host.startupCommand = $0 }
                    ))
                    .font(.system(.body, design: .monospaced))
                    Text("Wird direkt nach dem Verbinden ausgeführt (z. B. tmux attach -t claudes) und ersetzt die tmux-Automatik.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section("Erweitert") {
                    TextField("Terminal-Typ ($TERM)", text: Binding(
                        get: { host.terminalType ?? "" },
                        set: { host.terminalType = $0 }
                    ), prompt: Text("xterm-256color"))
                    .font(.system(.body, design: .monospaced))
                    Toggle("Backspace sendet ^H", isOn: Binding(
                        get: { host.backspaceCtrlH ?? false },
                        set: { host.backspaceCtrlH = $0 }
                    ))
                }

                Section("Schnellstart (optional)") {
                    HStack {
                        Text("Tastenkürzel")
                        Spacer()
                        Text("⌘").font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
                        TextField("Taste", text: Binding(
                            get: { host.shortcut ?? "" },
                            set: { host.shortcut = Self.normalizeShortcut($0) }
                        ))
                        .frame(width: 46)
                        .multilineTextAlignment(.center)
                    }
                    Text("Eine Taste (z. B. 1 oder H). Mit ⌘ startet sie diese Verbindung, solange humibeam aktiv ist.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if !allHosts.filter({ $0.id != host.id }).isEmpty {
                    Section("Über Bastion (ProxyJump, optional)") {
                        Picker("Bastion", selection: $host.proxyJumpHostID) {
                            Text("Direkt verbinden").tag(UUID?.none)
                            ForEach(allHosts.filter { $0.id != host.id }) { h in
                                Text(h.displayName).tag(UUID?.some(h.id))
                            }
                        }
                        Text("Die Verbindung wird durch dieses Profil getunnelt (wie ssh -J).")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Speichern") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(host.host.isEmpty || host.username.isEmpty)
            }
            .padding()
        }
        .frame(width: 480)
        .onAppear {
            if host.authKind == .password {
                password = SSHKeyManager.loadPassword(hostID: host.id.uuidString) ?? ""
            }
        }
    }

    /// Keeps only a single alphanumeric character (combined with ⌘ for the launch shortcut).
    private static func normalizeShortcut(_ s: String) -> String? {
        guard let ch = s.lowercased().last, ch.isLetter || ch.isNumber else { return nil }
        return String(ch)
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            host.importedKeyPath = url.path
        }
    }

    private func save() {
        if host.authKind == .password {
            SSHKeyManager.savePassword(password, hostID: host.id.uuidString)
        }
        if host.authKind == .importedKey {
            // Passphrase pro Host im Keychain ablegen (leer = unverschlüsselt).
            SSHKeyManager.savePassword(keyPassphrase, hostID: "keypass-\(host.id.uuidString)")
        }
        onSave(host)
        dismiss()
    }
}
