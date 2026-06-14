import SwiftUI

/// Manage command snippets. Commands may contain `{{name}}` placeholders that are prompted for
/// before the snippet is sent into a terminal.
struct SnippetsView: View {
    @Bindable var store: SnippetStore
    @State private var selection: Snippet.ID?

    private var selectedIndex: Int? {
        store.snippets.firstIndex { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 200, idealWidth: 230)
            editor
                .frame(minWidth: 320)
        }
        .frame(minWidth: 600, minHeight: 380)
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.snippets) { s in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title.isEmpty ? "(ohne Titel)" : s.title).font(.body)
                        if !s.placeholders.isEmpty {
                            Text(s.placeholders.map { "{{\($0)}}" }.joined(separator: " "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .tag(s.id)
                }
                .onMove { store.snippets.move(fromOffsets: $0, toOffset: $1) }
            }
            Divider()
            HStack {
                Button { addSnippet() } label: { Image(systemName: "plus") }
                Button { if let i = selectedIndex { store.snippets.remove(at: i); selection = nil } }
                    label: { Image(systemName: "minus") }
                    .disabled(selectedIndex == nil)
                Spacer()
            }
            .buttonStyle(.borderless).padding(6)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let i = selectedIndex {
            Form {
                TextField("Titel", text: Binding(
                    get: { store.snippets[i].title },
                    set: { store.snippets[i].title = $0 }))
                Section("Befehl") {
                    TextEditor(text: Binding(
                        get: { store.snippets[i].command },
                        set: { store.snippets[i].command = $0 }))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                }
                Picker("Auslöser", selection: Binding(
                    get: { store.snippets[i].effectiveTrigger },
                    set: { store.snippets[i].trigger = $0 })) {
                    ForEach(SnippetTrigger.allCases) { Text($0.label).tag($0) }
                }
                if store.snippets[i].effectiveTrigger == .onConnect {
                    Text("Wird automatisch ausgeführt, sobald eine Sitzung verbunden ist (nur ohne Platzhalter).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("Tipp: `\\n` am Ende führt aus. Platzhalter wie {{branch}} werden vor dem Senden abgefragt.")
                    .font(.caption).foregroundStyle(.secondary)
                if !store.snippets[i].placeholders.isEmpty {
                    Text("Variablen: " + store.snippets[i].placeholders.joined(separator: ", "))
                        .font(.caption).foregroundStyle(Color.accentColor)
                }
            }
            .formStyle(.grouped)
            .padding()
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.append").font(.largeTitle).foregroundStyle(.secondary)
                Text("Snippet wählen oder anlegen").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func addSnippet() {
        let s = Snippet(title: "Neues Snippet", command: "")
        store.snippets.append(s)
        selection = s.id
    }
}
