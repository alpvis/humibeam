import SwiftUI
import UniformTypeIdentifiers

/// Datei-Browser über die laufende SSH-Verbindung (gleiche geteilte Transfer-Schicht wie am Mac):
/// Navigation, Upload (Dateien/Fotos), Download mit Teilen-Sheet, Editor, mkdir/umbenennen/
/// chmod/löschen, Lesezeichen (synct über das Humibeam-Konto).
struct FilesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let controller: TerminalController

    @State private var path = ""
    @State private var entries: [RemoteEntry] = []
    @State private var busy = false
    @State private var status: String?
    @State private var showsImporter = false
    @State private var shareURL: URL?
    @State private var renameTarget: RemoteEntry?
    @State private var renameText = ""
    @State private var newFolderActive = false
    @State private var newFolderName = ""
    @State private var editTarget: RemoteEntry?
    @State private var editContent = ""

    var body: some View {
        NavigationStack {
            Group {
                if busy && entries.isEmpty {
                    ProgressView("Lade \(path)…")
                } else {
                    List {
                        if path != "/" {
                            Button { navigate(to: (path as NSString).deletingLastPathComponent) } label: {
                                Label("Übergeordneter Ordner", systemImage: "arrow.turn.left.up")
                            }
                        }
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                    .refreshable { await refresh() }
                }
            }
            .navigationTitle((path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            model.bookmarks.add(path: path)
                        } label: { Label("Diesen Ordner merken", systemImage: "bookmark") }
                        if !model.bookmarks.bookmarks.isEmpty {
                            Divider()
                            ForEach(model.bookmarks.bookmarks) { bookmark in
                                Button(bookmark.label) { navigate(to: bookmark.path) }
                            }
                            Divider()
                            Menu("Lesezeichen löschen") {
                                ForEach(model.bookmarks.bookmarks) { bookmark in
                                    Button(role: .destructive) {
                                        model.bookmarks.delete(bookmark)
                                    } label: { Text(bookmark.label) }
                                }
                            }
                        }
                    } label: { Image(systemName: "bookmark") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button { showsImporter = true } label: {
                            Label("Datei hochladen…", systemImage: "square.and.arrow.up")
                        }
                        Button { newFolderActive = true } label: {
                            Label("Neuer Ordner…", systemImage: "folder.badge.plus")
                        }
                    } label: { Image(systemName: "plus") }
                    Button("Fertig") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let status {
                    Text(status)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(6)
                        .background(.bar)
                }
            }
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { Task { await upload(url) } }
            }
            .sheet(item: $shareURL) { url in
                ShareSheet(items: [url])
            }
            .sheet(item: $editTarget) { entry in
                editorSheet(entry)
            }
            .alert("Umbenennen", isPresented: Binding(get: { renameTarget != nil },
                                                      set: { if !$0 { renameTarget = nil } })) {
                TextField("Name", text: $renameText)
                Button("Umbenennen") {
                    if let target = renameTarget { Task { await rename(target, to: renameText) } }
                }
                Button("Abbrechen", role: .cancel) {}
            }
            .alert("Neuer Ordner", isPresented: $newFolderActive) {
                TextField("Name", text: $newFolderName)
                Button("Anlegen") { Task { await makeFolder(newFolderName) } }
                Button("Abbrechen", role: .cancel) {}
            }
            .task {
                if path.isEmpty {
                    if let cwd = controller.currentDirectory {
                        path = cwd
                    } else if let home = try? await controller.connection?.remoteHome() {
                        path = home
                    } else {
                        path = "/"
                    }
                }
                await refresh()
            }
        }
    }

    private func row(_ entry: RemoteEntry) -> some View {
        Button {
            if entry.isDirectory {
                navigate(to: (path as NSString).appendingPathComponent(entry.name))
            } else {
                Task { await openEditorIfText(entry) }
            }
        } label: {
            HStack {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(entry.isDirectory ? .cyan : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).foregroundStyle(.primary)
                    Text("\(entry.displaySize)\(entry.permissions.isEmpty ? "" : " · \(entry.permissions)")\(entry.modified.isEmpty ? "" : " · \(entry.modified)")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu {
            if !entry.isDirectory {
                Button { Task { await download(entry) } } label: {
                    Label("Herunterladen & teilen", systemImage: "square.and.arrow.up")
                }
                Button { Task { await openEditorIfText(entry, force: true) } } label: {
                    Label("Bearbeiten", systemImage: "pencil")
                }
            } else {
                Button { Task { await downloadFolder(entry) } } label: {
                    Label("Als .tar.gz laden & teilen", systemImage: "archivebox")
                }
            }
            Button { controller.sendToShell((path as NSString).appendingPathComponent(entry.name)) } label: {
                Label("Pfad ins Terminal tippen", systemImage: "terminal")
            }
            Menu("chmod") {
                ForEach(["644", "755", "600", "777"], id: \.self) { mode in
                    Button(mode) { Task { await chmod(entry, mode: mode) } }
                }
            }
            Button {
                renameText = entry.name
                renameTarget = entry
            } label: { Label("Umbenennen", systemImage: "pencil.line") }
            Button(role: .destructive) {
                Task { await remove(entry) }
            } label: { Label("Löschen", systemImage: "trash") }
        }
    }

    private func editorSheet(_ entry: RemoteEntry) -> some View {
        NavigationStack {
            TextEditor(text: $editContent)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .navigationTitle(entry.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen") { editTarget = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Sichern") { Task { await saveEdit(entry) } }
                    }
                }
        }
    }

    // MARK: - Aktionen (alle über die geteilte SSHFileTransfer-Schicht)

    private func navigate(to newPath: String) {
        path = newPath.isEmpty ? "/" : newPath
        Task { await refresh() }
    }

    private func refresh() async {
        guard let conn = controller.connection else { status = "Keine Verbindung."; return }
        busy = true; defer { busy = false }
        do { entries = try await conn.listDetailed(path) }
        catch { status = "Listing fehlgeschlagen: \(error.localizedDescription)" }
    }

    private func upload(_ url: URL) async {
        guard let conn = controller.connection else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            status = "lade \(url.lastPathComponent) hoch…"
            try await conn.upload(data, to: (path as NSString).appendingPathComponent(url.lastPathComponent))
            status = "hochgeladen: \(url.lastPathComponent)"
            await refresh()
        } catch { status = "Upload fehlgeschlagen: \(error.localizedDescription)" }
    }

    private func download(_ entry: RemoteEntry) async {
        guard let conn = controller.connection else { return }
        do {
            status = "lade \(entry.name)…"
            let data = try await conn.download((path as NSString).appendingPathComponent(entry.name))
            let local = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name)
            try data.write(to: local)
            status = nil
            shareURL = local
        } catch { status = "Download fehlgeschlagen: \(error.localizedDescription)" }
    }

    private func downloadFolder(_ entry: RemoteEntry) async {
        guard let conn = controller.connection else { return }
        do {
            status = "packe & lade \(entry.name)…"
            let data = try await conn.downloadFolderTarGz((path as NSString).appendingPathComponent(entry.name))
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("\(entry.name).tar.gz")
            try data.write(to: local)
            status = nil
            shareURL = local
        } catch { status = "Ordner-Download fehlgeschlagen: \(error.localizedDescription)" }
    }

    /// Textdateien direkt öffnen; alles andere nur per Kontextmenü (force).
    private func openEditorIfText(_ entry: RemoteEntry, force: Bool = false) async {
        guard let conn = controller.connection else { return }
        guard force || entry.size < 512_000 else { status = "Zu groß zum Bearbeiten — per Kontextmenü laden."; return }
        do {
            let data = try await conn.download((path as NSString).appendingPathComponent(entry.name))
            if let text = String(data: data, encoding: .utf8) {
                editContent = text
                editTarget = entry
            } else {
                let local = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name)
                try data.write(to: local)
                shareURL = local
            }
        } catch { status = "Öffnen fehlgeschlagen: \(error.localizedDescription)" }
    }

    private func saveEdit(_ entry: RemoteEntry) async {
        guard let conn = controller.connection else { return }
        do {
            try await conn.upload(Data(editContent.utf8), to: (path as NSString).appendingPathComponent(entry.name))
            status = "gespeichert: \(entry.name)"
            editTarget = nil
        } catch { status = "Speichern fehlgeschlagen: \(error.localizedDescription)" }
    }

    private func makeFolder(_ name: String) async {
        guard let conn = controller.connection, !name.isEmpty else { return }
        do {
            try await conn.makeDirectory((path as NSString).appendingPathComponent(name))
            newFolderName = ""
            await refresh()
        } catch { status = "Ordner anlegen fehlgeschlagen: \(error.localizedDescription)" }
    }

    private func rename(_ entry: RemoteEntry, to newName: String) async {
        guard let conn = controller.connection, !newName.isEmpty else { return }
        let base = path as NSString
        do {
            try await conn.rename(base.appendingPathComponent(entry.name), to: base.appendingPathComponent(newName))
            await refresh()
        } catch { status = "Umbenennen fehlgeschlagen: \(error.localizedDescription)" }
    }

    private func chmod(_ entry: RemoteEntry, mode: String) async {
        guard let conn = controller.connection else { return }
        do {
            try await conn.chmod((path as NSString).appendingPathComponent(entry.name), mode: mode)
            await refresh()
        } catch { status = "chmod fehlgeschlagen: \(error.localizedDescription)" }
    }

    private func remove(_ entry: RemoteEntry) async {
        guard let conn = controller.connection else { return }
        do {
            try await conn.remove((path as NSString).appendingPathComponent(entry.name),
                                  recursive: entry.isDirectory)
            await refresh()
        } catch { status = "Löschen fehlgeschlagen: \(error.localizedDescription)" }
    }
}

/// UIActivityViewController-Brücke fürs Teilen heruntergeladener Dateien.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
