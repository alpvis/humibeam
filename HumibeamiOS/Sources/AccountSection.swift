import SwiftUI

/// Einstellungen → Humibeam-Konto: anmelden/registrieren und E2E-verschlüsselt
/// mit allen Macs/iPhones/iPads synchronisieren (Profile, Snippets, Darstellung).
struct AccountSection: View {
    @Bindable var account: AccountSyncService

    @State private var email = UserDefaults.standard.string(forKey: "account.email") ?? ""
    @State private var password = ""
    @State private var showsServer = false

    var body: some View {
        Section {
            switch account.state {
            case .loggedIn(let mail):
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.title2).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mail).font(.subheadline.weight(.semibold))
                        Text(account.lastSync.map { "Zuletzt synchronisiert \($0.formatted(.relative(presentation: .named)))" }
                             ?? "Noch nicht synchronisiert")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Jetzt synchronisieren") { Task { await account.syncNow() } }
                Button("Abmelden", role: .destructive) { account.logout() }
            case .busy(let what):
                HStack { ProgressView(); Text(what).foregroundStyle(.secondary) }
            case .loggedOut:
                TextField("E-Mail", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Passwort (min. 8 Zeichen)", text: $password)
                    .textContentType(.password)
                Button("Anmelden") {
                    Task { await account.login(email: email, password: password); password = "" }
                }
                .disabled(email.isEmpty || password.count < 8)
                Button("Konto erstellen") {
                    Task { await account.register(email: email, password: password); password = "" }
                }
                .disabled(email.isEmpty || password.count < 8)
            }

            if let error = account.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            if showsServer {
                TextField("Server-URL", text: Binding(
                    get: { account.serverURL },
                    set: { account.serverURL = $0 }
                ))
                .font(.caption.monospaced())
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        } header: {
            Text("Humibeam-Konto")
        } footer: {
            Text("Synchronisiert Server-Profile, Snippets und Darstellung Ende-zu-Ende-verschlüsselt über alle Geräte. Passwörter und SSH-Schlüssel bleiben im Geräte-Keychain.")
                .onTapGesture(count: 3) { showsServer.toggle() }
        }
    }
}
