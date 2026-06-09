import SwiftUI

struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let symbol: String
    let run: () -> Void
}

/// A Cmd+K quick launcher: type to fuzzy-filter servers, files, sessions and actions; Enter runs
/// the top match. Keeps the keyboard-first flow that power users expect.
struct CommandPaletteView: View {
    let sessions: SessionManager
    var onClose: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var commands: [PaletteCommand] {
        var list: [PaletteCommand] = [
            PaletteCommand(title: "Lokales Terminal", subtitle: "Mac-Shell", symbol: "apple.terminal.fill") {
                sessions.openLocalSession()
            }
        ]
        for host in sessions.shell.hostStore.hosts {
            let sub = "\(host.username)@\(host.host)"
            list.append(PaletteCommand(title: "Terminal: \(host.displayName)", subtitle: sub, symbol: "server.rack") {
                sessions.openSSHSession(host)
            })
            list.append(PaletteCommand(title: "Dateien: \(host.displayName)", subtitle: "SFTP — \(sub)", symbol: "folder") {
                sessions.openFileSession(host)
            })
        }
        for s in sessions.activeSessions {
            list.append(PaletteCommand(title: "Wechseln zu: \(s.title)", subtitle: "Offene Sitzung", symbol: s.symbol) {
                sessions.focus(s.id)
            })
        }
        list.append(PaletteCommand(title: "Profile verwalten…", subtitle: "Verbindungen bearbeiten", symbol: "slider.horizontal.3") {
            sessions.openProfilesWindow()
        })
        return list
    }

    private var filtered: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        return commands.filter { c in
            let hay = (c.title + " " + c.subtitle).lowercased()
            return q.allSatisfy { hay.contains($0) } || fuzzy(q, hay)
        }
    }

    /// Loose subsequence match (e.g. "thm" matches "Terminal Humiqa").
    private func fuzzy(_ needle: String, _ hay: String) -> Bool {
        var it = hay.makeIterator()
        return needle.allSatisfy { ch in
            while let h = it.next() { if h == ch { return true } }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Server, Dateien, Sitzungen, Aktionen…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onChange(of: query) { _, _ in selection = 0 }
                    .onSubmit { runSelected() }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, cmd in
                            row(cmd, selected: idx == selection)
                                .id(idx)
                                .onTapGesture { selection = idx; runSelected() }
                        }
                    }
                }
                .frame(maxHeight: 320)
                .onChange(of: selection) { _, s in withAnimation { proxy.scrollTo(s, anchor: .center) } }
            }
        }
        .frame(width: 560)
        .background(.ultraThinMaterial)
        .onAppear { focused = true }
        .onExitCommand { onClose() }
        .onMoveCommand { dir in
            switch dir {
            case .up: selection = max(0, selection - 1)
            case .down: selection = min(filtered.count - 1, selection + 1)
            default: break
            }
        }
    }

    private func row(_ cmd: PaletteCommand, selected: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: cmd.symbol)
                .foregroundStyle(selected ? Color.white : Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(cmd.title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? .white : .primary)
                Text(cmd.subtitle).font(.system(size: 11))
                    .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(selected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }

    private func runSelected() {
        let list = filtered
        guard selection >= 0, selection < list.count else { return }
        let cmd = list[selection]
        onClose()
        cmd.run()
    }
}
