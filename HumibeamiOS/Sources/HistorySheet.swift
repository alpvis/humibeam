import SwiftUI

/// Befehls-Verlauf über alle Server (gleiche Daten-Logik wie die ⌘R-Palette am Mac).
/// Tap tippt den Befehl ins Terminal — Enter bleibt bewusst beim Nutzer.
struct HistorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let controller: TerminalController

    @State private var query = ""

    private var filtered: [CommandHistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = model.commandHistory.entries
        guard !q.isEmpty else { return Array(all.prefix(100)) }
        return Array(all.filter {
            $0.command.lowercased().contains(q) || $0.hostName.lowercased().contains(q)
        }.prefix(100))
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        model.commandHistory.entries.isEmpty ? "Noch keine Befehle" : "Keine Treffer",
                        systemImage: "clock.arrow.circlepath",
                        description: Text(model.commandHistory.entries.isEmpty
                                          ? "Alles, was du abschickst, landet hier — über alle Server."
                                          : "Andere Suche probieren."))
                } else {
                    List(filtered) { entry in
                        Button {
                            controller.sendToShell(entry.command)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.command)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(entry.hostName) · \(entry.date.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Befehl oder Server…")
            .navigationTitle("Verlauf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !model.commandHistory.entries.isEmpty {
                        Button("Leeren", role: .destructive) { model.commandHistory.clear() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
