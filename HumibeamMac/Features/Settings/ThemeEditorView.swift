import SwiftUI
import UniformTypeIdentifiers

/// Eigene Terminal-Farbschemata anlegen/bearbeiten + iTerm2-Import. Auswahl wirkt sofort.
struct ThemeEditorView: View {
    @Bindable var store: CustomThemeStore
    @Binding var selectedThemeID: String
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?
    @State private var showImporter = false
    @State private var importError: String?

    private var selectedIndex: Int? { store.themes.firstIndex { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Eigene Themes").font(.headline)
                Spacer()
                Button("Importieren…") { showImporter = true }
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            HSplitView {
                listColumn.frame(minWidth: 180, idealWidth: 200)
                editorColumn.frame(minWidth: 300)
            }
            if let importError {
                Text(importError).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .frame(width: 560, height: 400)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "itermcolors") ?? .xml, .xml, .propertyList, .data],
                      allowsMultipleSelection: false) { handleImport($0) }
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.themes) { t in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: TerminalTheme.color(hex: t.bg)))
                            .overlay(Text("Aa").font(.system(size: 9))
                                .foregroundStyle(Color(nsColor: TerminalTheme.color(hex: t.fg))))
                            .frame(width: 26, height: 18)
                        Text(t.name.isEmpty ? "(ohne Name)" : t.name).font(.body)
                        if selectedThemeID == t.id {
                            Spacer(); Image(systemName: "checkmark").foregroundStyle(.green).font(.caption)
                        }
                    }
                    .tag(t.id)
                }
            }
            Divider()
            HStack {
                Button { addTheme() } label: { Image(systemName: "plus") }
                Button {
                    if let i = selectedIndex { store.delete(store.themes[i]); selection = nil }
                } label: { Image(systemName: "minus") }.disabled(selectedIndex == nil)
                Spacer()
            }
            .buttonStyle(.borderless).padding(6)
        }
    }

    @ViewBuilder
    private var editorColumn: some View {
        if let i = selectedIndex {
            Form {
                TextField("Name", text: Binding(
                    get: { store.themes[i].name },
                    set: { store.themes[i].name = $0 }))
                ColorPicker("Vordergrund", selection: colorBinding(\.fg, i), supportsOpacity: false)
                ColorPicker("Hintergrund", selection: colorBinding(\.bg, i), supportsOpacity: false)
                ColorPicker("Cursor", selection: colorBinding(\.caret, i), supportsOpacity: false)
                Section("Vorschau") { previewBox(store.themes[i]) }
                Button("Dieses Theme verwenden") { selectedThemeID = store.themes[i].id }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedThemeID == store.themes[i].id)
            }
            .formStyle(.grouped)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "paintpalette").font(.largeTitle).foregroundStyle(.secondary)
                Text("Theme wählen oder anlegen").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func previewBox(_ def: CustomThemeDef) -> some View {
        let t = def.theme
        return VStack(alignment: .leading, spacing: 2) {
            Text("ali@server:~$ claude").font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(nsColor: t.foreground))
            HStack(spacing: 0) {
                Text("> ").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(nsColor: t.foreground))
                Rectangle().fill(Color(nsColor: t.caret)).frame(width: 7, height: 14)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: t.background))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func colorBinding(_ keyPath: WritableKeyPath<CustomThemeDef, String>, _ i: Int) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: TerminalTheme.color(hex: store.themes[i][keyPath: keyPath])) },
            set: { store.themes[i][keyPath: keyPath] = TerminalTheme.hex(NSColor($0)) })
    }

    private func addTheme() {
        let def = CustomThemeDef(name: "Mein Theme \(store.themes.count + 1)")
        store.add(def)
        selection = def.id
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        importError = nil
        guard case .success(let urls) = result, let url = urls.first else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let def = try CustomThemeStore.importITerm(url: url)
            store.add(def)
            selection = def.id
        } catch {
            importError = error.localizedDescription
        }
    }
}
