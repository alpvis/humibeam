import SwiftUI

/// Remote file browser (exec-channel based): navigate, upload, download, mkdir, rename, delete,
/// chmod, edit-in-place, recursive folder download (.tar.gz), bookmarks.
struct FileBrowserView: View {
    @Bindable var shell: HumibeamShell
    @Bindable var tab: TerminalTab

    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var renaming: RemoteFile?
    @State private var renameText = ""
    @State private var chmodFile: RemoteFile?
    @State private var chmodMode = "644"

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            list
        }
        .alert("Neuer Ordner", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Anlegen") { Task { await shell.makeDirectory(tab, name: newFolderName); newFolderName = "" } }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("Umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Neuer Name", text: $renameText)
            Button("Umbenennen") {
                if let f = renaming { Task { await shell.rename(tab, file: f, to: renameText) } }
                renaming = nil
            }
            Button("Abbrechen", role: .cancel) { renaming = nil }
        }
        .alert("Rechte ändern (chmod)", isPresented: Binding(get: { chmodFile != nil }, set: { if !$0 { chmodFile = nil } })) {
            TextField("Modus (z.B. 644)", text: $chmodMode)
            Button("Anwenden") {
                if let f = chmodFile { Task { await shell.chmod(tab, file: f, mode: chmodMode) } }
                chmodFile = nil
            }
            Button("Abbrechen", role: .cancel) { chmodFile = nil }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { Task { await shell.navigateUp(tab) } } label: { Image(systemName: "arrow.up") }
                .help("Übergeordneter Ordner")
            Menu {
                ForEach(shell.bookmarks.bookmarks) { bm in
                    Button(bm.label) { Task { await shell.navigateToBookmark(tab, path: bm.path) } }
                }
                if !shell.bookmarks.bookmarks.isEmpty { Divider() }
                Button("Aktuellen Pfad merken") { shell.bookmarks.add(path: tab.browserPath) }
            } label: { Image(systemName: "bookmark") }
                .menuStyle(.borderlessButton).fixedSize().help("Lesezeichen")
            Text(tab.browserPath).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.head)
            Spacer()
            if tab.browserBusy { ProgressView().controlSize(.small) }
            Button { showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }.help("Neuer Ordner")
            Button { Task { await shell.refreshBrowser(tab) } } label: { Image(systemName: "arrow.clockwise") }.help("Aktualisieren")
        }
        .padding(.horizontal, 10).padding(.vertical, 6).background(.bar)
    }

    private var list: some View {
        List(tab.browserFiles) { file in
            HStack {
                Image(systemName: file.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(file.isDirectory ? .blue : .secondary)
                Text(file.name)
                Spacer()
                if !file.isDirectory {
                    Button { downloadFileViaPanel(file) } label: { Image(systemName: "arrow.down.circle") }
                        .buttonStyle(.borderless).help("Herunterladen")
                }
            }
            .contentShape(Rectangle())
            // macOS: List frisst den Einfach-Klick für die Zeilen-Auswahl, wodurch
            // `.onTapGesture(count: 2)` oft nicht feuert. `simultaneousGesture` läuft
            // parallel zur Auswahl und macht den Doppelklick zuverlässig.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if file.isDirectory { Task { await shell.navigate(tab, into: file) } }
                else { Task { await shell.openForEdit(tab, file: file) } }
            })
            .contextMenu {
                if file.isDirectory {
                    Button("Als .tar.gz herunterladen…") { downloadFolderViaPanel(file) }
                } else {
                    Button("Bearbeiten…") { Task { await shell.openForEdit(tab, file: file) } }
                    Button("Herunterladen…") { downloadFileViaPanel(file) }
                }
                Button("Rechte ändern…") { chmodMode = "644"; chmodFile = file }
                Button("Umbenennen…") { renameText = file.name; renaming = file }
                Button("Löschen", role: .destructive) { Task { await shell.delete(tab, file: file) } }
            }
        }
        .listStyle(.inset)
    }

    private func downloadFileViaPanel(_ file: RemoteFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        if panel.runModal() == .OK, let url = panel.url {
            Task { await shell.downloadFile(tab, file: file, to: url) }
        }
    }

    private func downloadFolderViaPanel(_ file: RemoteFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name + ".tar.gz"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await shell.downloadFolder(tab, file: file, to: url) }
        }
    }
}

/// Built-in editor for remote text files (download → edit → upload on save).
struct RemoteEditor: View {
    @Bindable var shell: HumibeamShell
    @Bindable var tab: TerminalTab

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(tab.editFileName, systemImage: "doc.text").font(.headline)
                Spacer()
                if tab.editBusy { ProgressView().controlSize(.small) }
            }
            .padding()
            Divider()
            TextEditor(text: $tab.editContent)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 560, minHeight: 380)
            Divider()
            HStack {
                Text(tab.editPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Abbrechen") { tab.showEditor = false }
                Button("Speichern") { Task { await shell.saveEdit(tab) } }
                    .buttonStyle(.borderedProminent).disabled(tab.editBusy)
            }
            .padding()
        }
        .frame(width: 640, height: 520)
    }
}
