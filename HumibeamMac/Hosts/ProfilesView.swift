import SwiftUI

/// Manage SSH connection profiles: create, edit (incl. shortcut), delete, and launch.
/// Opened from the menu-bar hub since there is no longer a sidebar.
struct ProfilesView: View {
    @Bindable var shell: HumibeamShell
    let sessions: SessionManager
    @State private var editingHost: SSHHost?
    @State private var showingEditor = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if shell.hostStore.hosts.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(shell.hostStore.hosts) { host in
                        row(host)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 460, minHeight: 380)
        .sheet(isPresented: $showingEditor) {
            HostEditorView(host: editingHost ?? SSHHost()) { saved in
                if shell.hostStore.hosts.contains(where: { $0.id == saved.id }) {
                    shell.hostStore.update(saved)
                } else {
                    shell.hostStore.add(saved)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("SSH-Profile").font(.headline)
            Spacer()
            Button { shell.hostStore.importSSHConfig() } label: {
                Label("~/.ssh/config", systemImage: "square.and.arrow.down")
            }
            .help("Aus ~/.ssh/config importieren")
            Button { editingHost = nil; showingEditor = true } label: {
                Label("Neues Profil", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func row(_ host: SSHHost) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName).font(.body).fontWeight(.medium)
                Text("\(host.username)@\(host.host):\(host.port)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)

            if let key = host.shortcut, !key.isEmpty {
                Text("⌘\(key.uppercased())")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
            }

            Button { sessions.openSSHSession(host) } label: {
                Image(systemName: "bolt.horizontal.fill")
            }
            .buttonStyle(.borderless)
            .help("Terminal verbinden")

            Button { sessions.openFileSession(host) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Dateien (SFTP)")

            Button { editingHost = host; showingEditor = true } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Bearbeiten")

            Button(role: .destructive) { shell.hostStore.delete(host) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Löschen")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { sessions.openSSHSession(host) }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "server.rack").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Noch keine Profile").font(.title3).bold()
            Text("Lege deine erste SSH-Verbindung an, um sie aus der Menüleiste zu starten.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
            Button { editingHost = nil; showingEditor = true } label: {
                Label("Erstes Profil anlegen", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
