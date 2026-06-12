import SwiftUI

/// Fleet-Übersicht (Parität zur Mac-⌘⇧F-Ansicht): alle Server mit Vitalwerten,
/// laufenden Sitzungen, Agenten-Status und Freigaben — direkt aus der Karte bedienbar.
struct FleetSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.hostStore.hosts) { host in
                        card(host)
                    }
                }
                .padding(12)
            }
            .navigationTitle("Fleet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
    }

    private func card(_ host: SSHHost) -> some View {
        let sessions = model.sessions.filter { $0.host.id == host.id }
        let stats = model.stats[host.id]
        let connected = sessions.contains { $0.controller.isConnected }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(stats?.isCritical == true ? Color.red : (connected ? .green : .gray))
                    .frame(width: 9, height: 9)
                Text(host.displayName).font(.headline)
                Spacer()
                if connected {
                    Text("\(sessions.count) Sitzung\(sessions.count == 1 ? "" : "en")")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("Verbinden") {
                        let session = model.primarySession(for: host)
                        model.connect(session)
                        model.requestedSessionID = session.id
                        dismiss()
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                }
            }

            if let stats {
                HStack(spacing: 12) {
                    if let l = stats.load1, let c = stats.cores {
                        fleetStat("gauge", String(format: "%.1f/%d", l, c), critical: l > Double(c))
                    }
                    if let m = stats.memUsedPercent { fleetStat("memorychip", "\(m)%", critical: m >= 90) }
                    if let d = stats.diskPercent { fleetStat("internaldrive", "\(d)%", critical: d >= 90) }
                    if let z = stats.zombies, z > 0 { fleetStat("ant", "\(z) Zombies", critical: z > 5) }
                    Spacer()
                }
            }

            ForEach(sessions) { session in
                let controller = session.controller
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        model.requestedSessionID = session.id
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: controller.claudeDetected ? "sparkles" : "terminal")
                                .font(.caption)
                                .foregroundStyle(controller.claudeDetected ? .cyan : .secondary)
                            Text(session.title).font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            if controller.claudeDetected {
                                Text(controller.activity.label)
                                    .font(.caption2)
                                    .foregroundStyle(controller.activity.kind == .waiting ? .orange : .secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    if controller.approval != nil {
                        HStack(spacing: 8) {
                            Button {
                                controller.approve()
                            } label: { Label("Erlauben", systemImage: "checkmark").frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent).tint(.green)
                            Button {
                                controller.deny()
                            } label: { Label("Ablehnen", systemImage: "xmark").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered)
                        }
                        .controlSize(.mini)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.1)))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
            stats?.isCritical == true ? Color.red.opacity(0.5) : Color.gray.opacity(0.2)))
    }

    private func fleetStat(_ symbol: String, _ text: String, critical: Bool) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(critical ? .red : .secondary)
    }
}
