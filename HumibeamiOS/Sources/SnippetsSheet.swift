import SwiftUI

/// Snippet-Sheet: Tap tippt den Befehl ins Terminal; `{{Platzhalter}}` werden vorher abgefragt.
/// Gleiche Snippet-Daten wie am Mac (SnippetStore, geteiltes Modell).
struct SnippetsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let controller: TerminalController

    @State private var fillSnippet: Snippet?
    @State private var editingSnippet: Snippet?
    @State private var showsNew = false

    var body: some View {
        NavigationStack {
            Group {
                if model.snippets.snippets.isEmpty {
                    ContentUnavailableView("Keine Snippets", systemImage: "curlybraces",
                                           description: Text("Lege Befehle an, die du immer wieder brauchst."))
                } else {
                    List {
                        ForEach(model.snippets.snippets) { snip in
                            Button { run(snip) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snip.title).font(.headline).foregroundStyle(.primary)
                                    Text(snip.command.trimmingCharacters(in: .whitespacesAndNewlines))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    model.snippets.delete(snip)
                                } label: { Label("Löschen", systemImage: "trash") }
                                Button {
                                    editingSnippet = snip
                                } label: { Label("Bearbeiten", systemImage: "pencil") }
                                .tint(.indigo)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Snippets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsNew = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .sheet(item: $fillSnippet) { snip in
                SnippetFillSheet(snippet: snip) { filled in
                    send(filled)
                }
            }
            .sheet(item: $editingSnippet) { snip in
                SnippetEditorSheet(snippet: snip) { updated in
                    if let idx = model.snippets.snippets.firstIndex(where: { $0.id == updated.id }) {
                        model.snippets.snippets[idx] = updated
                    }
                }
            }
            .sheet(isPresented: $showsNew) {
                SnippetEditorSheet(snippet: Snippet(title: "", command: "")) { created in
                    model.snippets.add(created)
                }
            }
        }
    }

    private func run(_ snip: Snippet) {
        if snip.placeholders.isEmpty {
            send(snip.command)
        } else {
            fillSnippet = snip
        }
    }

    private func send(_ command: String) {
        controller.sendToShell(command)
        dismiss()
    }
}

/// Fragt die `{{Platzhalter}}` eines Snippets ab, bevor der Befehl getippt wird.
private struct SnippetFillSheet: View {
    let snippet: Snippet
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                ForEach(snippet.placeholders, id: \.self) { name in
                    TextField(name, text: Binding(
                        get: { values[name] ?? "" },
                        set: { values[name] = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
                Section {
                    Text(snippet.filled(with: values).trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } header: { Text("Vorschau") }
            }
            .navigationTitle(snippet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Einfügen") {
                        onSubmit(snippet.filled(with: values))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Snippet anlegen/bearbeiten. `\n` am Ende schickt den Befehl direkt ab.
private struct SnippetEditorSheet: View {
    @State var snippet: Snippet
    let onSave: (Snippet) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var runsImmediately: Bool

    init(snippet: Snippet, onSave: @escaping (Snippet) -> Void) {
        _snippet = State(initialValue: snippet)
        self.onSave = onSave
        _runsImmediately = State(initialValue: snippet.command.hasSuffix("\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Titel", text: $snippet.title)
                Section {
                    TextField("Befehl", text: Binding(
                        get: { snippet.command.trimmingCharacters(in: .newlines) },
                        set: { snippet.command = $0 }
                    ), axis: .vertical)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Toggle("Direkt abschicken (Enter)", isOn: $runsImmediately)
                } footer: {
                    Text("Mit {{Name}} fragst du beim Einfügen Werte ab, z. B. tail -f {{Logdatei}}")
                }
            }
            .navigationTitle(snippet.title.isEmpty ? "Neues Snippet" : snippet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        var result = snippet
                        result.command = result.command.trimmingCharacters(in: .newlines)
                        if runsImmediately { result.command += "\n" }
                        onSave(result)
                        dismiss()
                    }
                    .disabled(snippet.title.trimmingCharacters(in: .whitespaces).isEmpty ||
                              snippet.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
