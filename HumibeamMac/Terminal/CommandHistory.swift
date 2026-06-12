import SwiftUI
import Observation

// MARK: - Befehls-Verlauf: jeder abgeschickte Befehl, über alle Server, durchsuchbar (⌘R).

struct CommandHistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    let command: String
    let hostName: String
    let date: Date
}

@Observable
@MainActor
final class CommandHistoryStore {
    private(set) var entries: [CommandHistoryEntry] = []   // neueste zuerst
    private static let cap = 5000

    private static var fileURL: URL {
        AppSupportPaths.appSupportDirectoryURL.appendingPathComponent("command-history.json")
    }

    init() { load() }

    func record(_ command: String, host: String) {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard cmd.count >= 2 else { return }
        if let first = entries.first, first.command == cmd, first.hostName == host { return }
        entries.insert(CommandHistoryEntry(command: cmd, hostName: host, date: Date()), at: 0)
        if entries.count > Self.cap { entries.removeLast(entries.count - Self.cap) }
        save()
    }

    func clear() { entries = []; save() }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([CommandHistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        let dir = AppSupportPaths.appSupportDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}

// MARK: - ⌘R-Palette: tippen → filtern → Enter setzt den Befehl ins aktive Terminal.

struct CommandHistoryPaletteView: View {
    let shell: HumibeamShell
    var onClose: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var filtered: [CommandHistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = shell.commandHistory.entries
        guard !q.isEmpty else { return Array(all.prefix(50)) }
        return Array(all.filter {
            $0.command.lowercased().contains(q) || $0.hostName.lowercased().contains(q)
        }.prefix(50))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                TextField("Befehls-Verlauf durchsuchen…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onChange(of: query) { _, _ in selection = 0 }
                    .onSubmit { runSelected() }
                if !shell.commandHistory.entries.isEmpty {
                    Button("Leeren") { shell.commandHistory.clear() }
                        .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            if filtered.isEmpty {
                Text(shell.commandHistory.entries.isEmpty
                     ? "Noch keine Befehle aufgezeichnet. Alles, was du abschickst, landet hier."
                     : "Keine Treffer.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, entry in
                                row(entry, selected: idx == selection)
                                    .id(idx)
                                    .onTapGesture { selection = idx; runSelected() }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selection) { _, s in withAnimation { proxy.scrollTo(s, anchor: .center) } }
                }
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

    private func row(_ entry: CommandHistoryEntry, selected: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "terminal")
                .foregroundStyle(selected ? Color.white : Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.command)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(selected ? .white : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(entry.hostName) · \(entry.date.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11))
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
        let entry = list[selection]
        onClose()
        // Befehl nur eintippen, nicht abschicken — Enter bleibt bewusst beim Nutzer.
        shell.selectedTab?.controller.sendToShell(entry.command)
    }
}
