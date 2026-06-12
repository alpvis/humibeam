import SwiftUI

/// Fleet-Übersicht: alle Server und Agenten-Sitzungen auf einen Blick — wer arbeitet,
/// wer wartet auf Freigabe, wem geht es schlecht. Klick fokussiert die Sitzung.
struct FleetView: View {
    @Bindable var shell: HumibeamShell
    @Bindable var sessions: SessionManager

    private let columns = [GridItem(.adaptive(minimum: 270), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(shell.hostStore.hosts) { host in
                    hostCard(host)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 600, minHeight: 360)
        .background(Color(nsColor: shell.theme.chrome).opacity(0.4))
    }

    private func hostTabs(_ host: SSHHost) -> [TerminalTab] {
        shell.tabs.filter { $0.host.id == host.id }
    }

    @ViewBuilder
    private func hostCard(_ host: SSHHost) -> some View {
        let tabs = hostTabs(host)
        let connected = tabs.contains { $0.connected }
        let stats = tabs.first { $0.connected }?.stats
        let waiting = tabs.contains { $0.awaitingApproval }

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: connected ? "bolt.horizontal.circle.fill" : "server.rack")
                    .foregroundStyle(connected ? (stats?.isCritical == true ? Color.red : Color.green) : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.displayName).font(.system(size: 13, weight: .semibold))
                    Text("\(host.username)@\(host.host)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if waiting {
                    Label("wartet", systemImage: "hand.raised.fill")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
            }

            if let stats, connected, !stats.summary.isEmpty {
                Text(stats.summary)
                    .font(.caption2)
                    .foregroundStyle(stats.isCritical ? .red : .secondary)
            }

            if tabs.isEmpty {
                Button("Verbinden") { sessions.openSSHSession(host) }
                    .controlSize(.small)
            } else {
                VStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        sessionRow(tab)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(waiting ? Color.orange.opacity(0.6) : Color.primary.opacity(0.07), lineWidth: 1))
    }

    @ViewBuilder
    private func sessionRow(_ tab: TerminalTab) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(Color(nsColor: tab.health.color)).frame(width: 7, height: 7)
                Text(tab.title).font(.caption).lineLimit(1)
                if tab.claudeDetected && !tab.awaitingApproval {
                    Image(systemName: "sparkles").font(.caption2).foregroundStyle(.purple)
                        .help("Claude läuft in dieser Sitzung")
                }
                Spacer()
                Button("Öffnen") { sessions.focus(tab.id) }
                    .buttonStyle(.borderless).font(.caption2).foregroundStyle(Color.accentColor)
            }

            if tab.awaitingApproval {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tab.approval?.question ?? "Claude wartet auf deine Freigabe")
                        .font(.caption2).foregroundStyle(.orange)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Button("Erlauben") { tab.controller.approve() }
                            .controlSize(.mini).buttonStyle(.borderedProminent)
                        if tab.approvalAllowAlways {
                            Button("Immer") { tab.controller.approveAlways() }
                                .controlSize(.mini)
                        }
                        Button("Ablehnen") { tab.controller.deny() }
                            .controlSize(.mini)
                    }
                }
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.1)))
            }
        }
        .padding(.vertical, 2)
    }
}
