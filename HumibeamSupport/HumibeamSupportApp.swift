import SwiftUI

/// „Humibeam Support" — schlanke Kunden-App: zeigt Geräte-ID + Einmalcode an und lässt einen
/// eingeloggten Supporter (humibeam.com) den Mac nach Bestätigung im Browser fernsteuern.
@main
struct HumibeamSupportApp: App {
    @State private var session = SupportSession()

    var body: some Scene {
        WindowGroup {
            SupportView(session: session)
                .frame(width: 420, height: 520)
                .onAppear { session.start() }
        }
        .windowResizability(.contentSize)
    }
}

struct SupportView: View {
    @Bindable var session: SupportSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if !session.permissionsOK { permissions }
                else {
                    switch session.phase {
                    case .connecting: connecting
                    case .ready: ready
                    case .incoming: incoming
                    case .connected: connected
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "display.and.arrow.down")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 1) {
                Text("Humibeam Support").font(.headline)
                Text(session.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Circle().fill(session.online ? .green : .orange).frame(width: 9, height: 9)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // Berechtigungen
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Berechtigungen erteilen").font(.title3.bold())
            Text("Damit ein Supporter helfen kann, braucht Humibeam Support einmalig diese Freigaben:")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            permissionRow("Bildschirmaufnahme", session.screenGranted) { session.requestScreenRecording() }
            permissionRow("Bedienungshilfen", session.accessibilityGranted) { session.requestAccessibility() }
            permissionRow("Eingabeüberwachung", session.accessibilityGranted) { session.requestInputMonitoring() }
            Spacer()
            Button("Erneut prüfen") { session.refreshPermissions() }
                .frame(maxWidth: .infinity)
        }
    }

    private func permissionRow(_ name: String, _ granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            Text(name)
            Spacer()
            if !granted { Button("Öffnen", action: action) }
        }
        .padding(.vertical, 4)
    }

    private var connecting: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(session.statusText).foregroundStyle(.secondary)
        }
    }

    // Bereit: ID + Code anzeigen
    private var ready: some View {
        VStack(spacing: 22) {
            Label("Bereit für Verbindung", systemImage: "checkmark.shield.fill")
                .font(.headline).foregroundStyle(.green)
            VStack(spacing: 6) {
                Text("Geräte-ID").font(.caption).foregroundStyle(.secondary)
                Text(session.deviceId)
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
            }
            VStack(spacing: 6) {
                Text("Sicherheitscode").font(.caption).foregroundStyle(.secondary)
                Text(session.code)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .tracking(6).foregroundStyle(.cyan)
                    .textSelection(.enabled)
                Text("wird regelmäßig erneuert").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("Nenne deinem Supporter diese ID und den Code. Du musst die Verbindung anschließend bestätigen.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Eingehende Anfrage
    private var incoming: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 44)).foregroundStyle(.orange)
            Text("Verbindung zulassen?").font(.title3.bold())
            Text(session.supporter.isEmpty ? "Ein Supporter möchte sich verbinden." :
                 "\(session.supporter) möchte deinen Mac fernsteuern.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack(spacing: 12) {
                Button(role: .cancel) { session.deny() } label: {
                    Text("Ablehnen").frame(maxWidth: .infinity)
                }
                Button { session.approve() } label: {
                    Text("Zulassen").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // Aktive Sitzung — sichtbarer Hinweis
    private var connected: some View {
        VStack(spacing: 18) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 44)).foregroundStyle(.red)
            Text("Supporter verbunden").font(.title3.bold())
            Text("Dein Bildschirm wird gerade übertragen und kann ferngesteuert werden.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !session.supporter.isEmpty {
                Text(session.supporter).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) { session.hangup() } label: {
                Label("Verbindung beenden", systemImage: "xmark.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.red)
        }
    }
}
