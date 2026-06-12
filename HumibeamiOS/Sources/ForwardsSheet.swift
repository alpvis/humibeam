import SwiftUI

/// Port-Weiterleitungen (`ssh -L`): Remote-Dienste (z. B. einen Dev-Webserver) lokal aufs
/// iPhone holen — danach direkt in Safari öffnen.
struct ForwardsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: TerminalSession

    @State private var localPort = ""
    @State private var targetHost = "127.0.0.1"
    @State private var targetPort = ""
    @State private var error: String?

    private var sessionForwards: [AppModel.ActiveForward] {
        model.forwards.filter { $0.sessionID == session.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Neue Weiterleitung") {
                    TextField("Lokaler Port (z. B. 8080)", text: $localPort)
                        .keyboardType(.numberPad)
                    TextField("Ziel-Host (vom Server aus)", text: $targetHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Ziel-Port (z. B. 3000)", text: $targetPort)
                        .keyboardType(.numberPad)
                    Button("Starten") { Task { await add() } }
                        .disabled(Int(localPort) == nil || Int(targetPort) == nil || targetHost.isEmpty)
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }

                if !sessionForwards.isEmpty {
                    Section("Aktiv") {
                        ForEach(sessionForwards) { fwd in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("localhost:\(String(fwd.localPort))")
                                        .font(.callout.monospaced().weight(.semibold))
                                    Text("→ \(fwd.targetHost):\(String(fwd.targetPort))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    if let url = URL(string: "http://127.0.0.1:\(fwd.localPort)/") {
                                        UIApplication.shared.open(url)
                                    }
                                } label: { Image(systemName: "safari") }
                                Button(role: .destructive) {
                                    model.stopForward(fwd)
                                } label: { Image(systemName: "stop.circle") }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .navigationTitle("Port-Weiterleitung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() async {
        guard let lp = Int(localPort), let tp = Int(targetPort) else { return }
        do {
            try await model.addForward(session: session, localPort: lp, targetHost: targetHost, targetPort: tp)
            error = nil
            localPort = ""; targetPort = ""
        } catch {
            self.error = "Weiterleitung fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}
