import SwiftUI

/// Einstellungen → Konto: Humibeam-Konto anlegen/anmelden und den E2E-verschlüsselten
/// Geräte-Sync steuern (Profile, Snippets, Lesezeichen, Darstellung — Secrets nie).
struct AccountSettingsView: View {
    @Bindable var account: AccountSyncService
    var beam: MacBeamServer? = nil

    @State private var email = ""
    @State private var password = ""
    @State private var showsPairing = false
    @AppStorage("beam.enabled") private var beamEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch account.state {
            case .loggedIn(let mail):
                loggedInSection(mail)
            case .busy(let what):
                ProgressView(what)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            case .loggedOut:
                loginSection
            }

            if let error = account.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Mein Mac als Server")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("Steuere diesen Mac vom iPhone aus — QR scannen, fertig.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Button("iPhone koppeln…") { showsPairing = true }

                if let beam {
                    Toggle("MacBeam: Bildschirm vom iPhone steuern", isOn: $beamEnabled)
                        .font(.system(size: 11.5))
                        .onChange(of: beamEnabled) { _, on in
                            on ? beam.start() : beam.stop()
                        }
                    if beamEnabled {
                        Text(beam.lastError
                             ?? (beam.clientConnected ? "iPhone verbunden — Streaming läuft."
                                                      : "Wartet auf das iPhone (gleiches WLAN, Profil gekoppelt)."))
                            .font(.system(size: 10))
                            .foregroundStyle(beam.lastError == nil ? Color.secondary : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Braucht einmalig: Bildschirmaufnahme + Bedienungshilfen (Systemeinstellungen → Datenschutz).")
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    }
                }
            }
            .sheet(isPresented: $showsPairing) { PairPhoneView() }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Server").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                TextField("https://…", text: Binding(
                    get: { account.serverURL },
                    set: { account.serverURL = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                Text("Ende-zu-Ende-verschlüsselt: Der Server sieht weder dein Passwort noch deine Daten. Passwörter und SSH-Schlüssel bleiben immer im Geräte-Keychain.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .onAppear { email = accountEmailPrefill }
    }

    private var accountEmailPrefill: String {
        if case .loggedIn(let mail) = account.state { return mail }
        return UserDefaults.standard.string(forKey: "account.email") ?? ""
    }

    @ViewBuilder
    private var loginSection: some View {
        Text("Humibeam-Konto")
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        Text("Ein Konto synchronisiert Server-Profile, Snippets, Lesezeichen und Darstellung über alle deine Macs, iPhones und iPads.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        TextField("E-Mail", text: $email)
            .textFieldStyle(.roundedBorder)
        SecureField("Passwort (min. 8 Zeichen)", text: $password)
            .textFieldStyle(.roundedBorder)

        HStack {
            Button("Anmelden") {
                Task { await account.login(email: email, password: password); password = "" }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(email.isEmpty || password.count < 8)

            Button("Konto erstellen") {
                Task { await account.register(email: email, password: password); password = "" }
            }
            .disabled(email.isEmpty || password.count < 8)
        }
    }

    @ViewBuilder
    private func loggedInSection(_ mail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 24))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(mail).font(.system(size: 12, weight: .semibold))
                Text(account.lastSync.map { "Zuletzt synchronisiert \($0.formatted(.relative(presentation: .named)))" }
                     ?? "Noch nicht synchronisiert")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
        }

        HStack {
            Button("Jetzt synchronisieren") { Task { await account.syncNow() } }
            Button("Abmelden", role: .destructive) { account.logout() }
        }

        Text("Synchronisiert: Server-Profile · Snippets · Lesezeichen · Theme & Schrift")
            .font(.system(size: 10)).foregroundStyle(.tertiary)
    }
}
