import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Standalone SFTP file manager window — the Cyberduck replacement.
/// Single-pane browser with breadcrumb path, sortable detail list, full file operations,
/// Finder drag-&-drop upload, and a transfer log. Built on the exec-based file API.
struct FileManagerView: View {
    @Bindable var session: FileSession
    let sessions: SessionManager

    @State private var selection: RemoteEntry.ID?
    @State private var pathField = ""
    @State private var dropTargeted = false
    @State private var showHidden = true
    @State private var sortKey: SortKey = .name
    @State private var sortAscending = true
    @State private var infoEntry: RemoteEntry?

    enum SortKey { case name, size, modified }

    private var displayedEntries: [RemoteEntry] {
        var list = showHidden ? session.entries : session.entries.filter { !$0.name.hasPrefix(".") }
        list.sort { a, b in
            // Directories always first, then by the chosen key.
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let result: Bool
            switch sortKey {
            case .name: result = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .size: result = a.size < b.size
            case .modified: result = a.modified < b.modified
            }
            return sortAscending ? result : !result
        }
        return list
    }

    private func toggleSort(_ key: SortKey) {
        if sortKey == key { sortAscending.toggle() } else { sortKey = key; sortAscending = true }
    }

    // Sheets
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renaming: RemoteEntry?
    @State private var renameText = ""
    @State private var chmodding: RemoteEntry?
    @State private var chmodText = "644"
    @State private var editing: RemoteEntry?
    @State private var editText = ""
    @State private var editLoading = false
    @State private var showTransfers = false

    private var selectedEntry: RemoteEntry? {
        session.entries.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            pathBar
            Divider()
            fileList
            Divider()
            statusBar
        }
        .frame(minWidth: 640, minHeight: 420)
        .task { pathField = session.path }
        .onChange(of: session.path) { _, new in pathField = new }
        .sheet(isPresented: $showNewFolder) { newFolderSheet }
        .sheet(item: $renaming) { entry in renameSheet(entry) }
        .sheet(item: $chmodding) { entry in chmodSheet(entry) }
        .sheet(item: $editing) { entry in editorSheet(entry) }
        .sheet(item: $infoEntry) { entry in infoSheet(entry) }
        .sheet(isPresented: $showTransfers) { transfersSheet }
    }

    private func infoSheet(_ entry: RemoteEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon(for: entry))
                    .font(.system(size: 30))
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.headline).lineLimit(2)
                    Text(entry.isDirectory ? "Ordner" : (entry.isSymlink ? "Verknüpfung" : "Datei"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                infoRow("Pfad", "\((session.path as NSString).appendingPathComponent(entry.name))")
                infoRow("Größe", entry.isDirectory ? "—" : "\(byteStr(entry.size)) (\(entry.size) Bytes)")
                infoRow("Geändert", entry.modified)
                infoRow("Rechte", entry.permissions)
            }
            .padding()
            Divider()
            HStack {
                Button("Rechte ändern…") { chmodText = "644"; infoEntry = nil; chmodding = entry }
                Spacer()
                Button("Schließen") { infoEntry = nil }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 380)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            Text(value).font(.caption).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { Task { await session.goBack() } } label: { Image(systemName: "chevron.left") }
                .help("Zurück").disabled(!session.canGoBack).keyboardShortcut("[", modifiers: .command)
            Button { Task { await session.goForward() } } label: { Image(systemName: "chevron.right") }
                .help("Vor").disabled(!session.canGoForward).keyboardShortcut("]", modifiers: .command)
            Button { Task { await session.goUp() } } label: { Image(systemName: "arrow.up") }
                .help("Übergeordneter Ordner").keyboardShortcut(.upArrow, modifiers: .command)
            Button { Task { await session.goHome() } } label: { Image(systemName: "house") }
                .help("Home")
            Button { Task { await session.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Aktualisieren").keyboardShortcut("r", modifiers: .command)

            Divider().frame(height: 16)

            Button { showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                .help("Neuer Ordner").disabled(!session.connected)
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button { uploadViaPanel() } label: { Image(systemName: "arrow.up.doc") }
                .help("Hochladen…").disabled(!session.connected)
            Button { downloadSelected() } label: { Image(systemName: "arrow.down.doc") }
                .help("Herunterladen").disabled(selectedEntry == nil)
            Button { if let e = selectedEntry { infoEntry = e } } label: { Image(systemName: "info.circle") }
                .help("Informationen").disabled(selectedEntry == nil)
                .keyboardShortcut("i", modifiers: .command)

            Spacer()

            Button { showHidden.toggle() } label: {
                Image(systemName: showHidden ? "eye" : "eye.slash")
            }
            .help(showHidden ? "Versteckte Dateien ausblenden" : "Versteckte Dateien zeigen")

            if session.busy { ProgressView().controlSize(.small).scaleEffect(0.7) }

            Button { showTransfers = true } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.arrow.down.circle")
                    if !session.transfers.isEmpty { Text("\(session.transfers.count)").font(.caption2) }
                }
            }
            .help("Übertragungen")

            Circle().fill(session.connected ? .green : .orange).frame(width: 8, height: 8)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            TextField("Pfad", text: $pathField)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { Task { await session.navigate(to: pathField) } }
            Button("Gehe zu") { Task { await session.navigate(to: pathField) } }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    // MARK: - File list

    private var fileList: some View {
        List(selection: $selection) {
            Section {
                ForEach(displayedEntries) { entry in
                    fileRow(entry)
                        .tag(entry.id)
                        .contextMenu { rowMenu(entry) }
                        .onTapGesture(count: 2) { handleOpen(entry) }
                }
            } header: {
                HStack(spacing: 0) {
                    sortHeader("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
                    sortHeader("Größe", .size).frame(width: 90, alignment: .trailing)
                    sortHeader("Geändert", .modified).frame(width: 140, alignment: .leading)
                    Text("Rechte").frame(width: 96, alignment: .leading)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay { if displayedEntries.isEmpty && session.connected { emptyOverlay } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers); return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.06))
                    .allowsHitTesting(false)
            }
        }
    }

    private func fileRow(_ entry: RemoteEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: entry))
                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 18)
            Text(entry.name).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.displaySize).font(.caption).foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(entry.modified).font(.caption).foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(entry.permissions).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func sortHeader(_ title: String, _ key: SortKey) -> some View {
        Button { toggleSort(key) } label: {
            HStack(spacing: 3) {
                Text(title)
                if sortKey == key {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down").font(.system(size: 8))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func icon(for entry: RemoteEntry) -> String {
        if entry.isSymlink { return "arrow.uturn.right.circle" }
        if entry.isDirectory { return "folder.fill" }
        return "doc"
    }

    private var emptyOverlay: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray").font(.title).foregroundStyle(.secondary)
            Text("Ordner ist leer").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func rowMenu(_ entry: RemoteEntry) -> some View {
        Button {
            let path = (session.path as NSString).appendingPathComponent(entry.name)
            if !sessions.giveToTerminal(path: path, host: session.host) {
                session.status = "Kein Terminal für \(session.host.displayName) offen — öffne ein Terminal und starte claude."
            }
        } label: {
            Label("An Claude senden", systemImage: "sparkles")
        }
        Divider()
        if entry.isDirectory {
            Button("Öffnen") { Task { await session.open(entry) } }
            Button("Als .tar.gz laden…") { downloadFolder(entry) }
        } else {
            Button("Herunterladen…") { download(entry) }
            Button("Bearbeiten…") { startEdit(entry) }
        }
        Divider()
        Button("Umbenennen…") { renameText = entry.name; renaming = entry }
        Button("Rechte ändern…") { chmodText = "644"; chmodding = entry }
        Divider()
        Button("Löschen", role: .destructive) { Task { await session.remove(entry) } }
    }

    // MARK: - Status / transfers

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(session.connected ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(session.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if let active = session.transfers.first(where: { $0.state == .running }) {
                Text("\(active.isUpload ? "↑" : "↓") \(active.name)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                ProgressView(value: active.fraction).frame(width: 90)
                Text("\(Int(active.fraction * 100)) %").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5).background(.bar)
    }

    private func byteStr(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var transfersSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Übertragungen").font(.headline)
                Spacer()
                Button("Schließen") { showTransfers = false }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            if session.transfers.isEmpty {
                Text("Noch keine Übertragungen.").foregroundStyle(.secondary).padding()
            } else {
                List(session.transfers) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Image(systemName: t.isUpload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                .foregroundStyle(t.state == .failed ? .red : (t.state == .done ? .green : Color.accentColor))
                            Text(t.name).lineLimit(1)
                            Spacer()
                            switch t.state {
                            case .running: Text("\(Int(t.fraction * 100)) %").font(.caption).foregroundStyle(.secondary)
                            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            }
                        }
                        if t.state == .running {
                            ProgressView(value: t.fraction)
                            HStack {
                                Text("\(byteStr(t.transferred)) / \(byteStr(t.total))")
                                Spacer()
                                if t.bytesPerSecond > 0 { Text("\(byteStr(Int64(t.bytesPerSecond)))/s") }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text(byteStr(t.total)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(width: 460, height: 360)
    }

    // MARK: - Sheets

    private var newFolderSheet: some View {
        sheetForm(title: "Neuer Ordner", confirm: "Anlegen", isValid: !newFolderName.isEmpty, onConfirm: {
            let name = newFolderName; newFolderName = ""
            Task { await session.makeDirectory(name) }
        }) {
            TextField("Name", text: $newFolderName)
        }
    }

    private func renameSheet(_ entry: RemoteEntry) -> some View {
        sheetForm(title: "Umbenennen", confirm: "Umbenennen", isValid: !renameText.isEmpty, onConfirm: {
            let to = renameText
            Task { await session.rename(entry, to: to) }
        }) {
            TextField("Neuer Name", text: $renameText)
        }
    }

    private func chmodSheet(_ entry: RemoteEntry) -> some View {
        sheetForm(title: "Rechte ändern (chmod)", confirm: "Anwenden", isValid: !chmodText.isEmpty, onConfirm: {
            let mode = chmodText
            Task { await session.chmod(entry, mode: mode) }
        }) {
            TextField("Modus (z. B. 644)", text: $chmodText)
            Text("Aktuell: \(entry.permissions)").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func editorSheet(_ entry: RemoteEntry) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label(entry.name, systemImage: "doc.text").font(.headline)
                Spacer()
                if editLoading { ProgressView().controlSize(.small) }
            }
            .padding()
            Divider()
            TextEditor(text: $editText)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 560, minHeight: 360)
            Divider()
            HStack {
                Button("Abbrechen") { editing = nil }
                Spacer()
                Button("Speichern") {
                    let content = editText
                    Task { await session.writeTextFile(entry, content: content); editing = nil }
                }
                .buttonStyle(.borderedProminent)
                .disabled(editLoading)
            }
            .padding()
        }
        .task {
            editLoading = true
            editText = await session.readTextFile(entry) ?? ""
            editLoading = false
        }
    }

    private func sheetForm<Content: View>(title: String, confirm: String, isValid: Bool,
                                          onConfirm: @escaping () -> Void,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content()
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) {
                    showNewFolder = false; renaming = nil; chmodding = nil
                }
                Button(confirm) {
                    onConfirm()
                    showNewFolder = false; renaming = nil; chmodding = nil
                }
                .buttonStyle(.borderedProminent).disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 380)
    }

    // MARK: - Actions

    private func handleOpen(_ entry: RemoteEntry) {
        if entry.isDirectory { Task { await session.open(entry) } }
        else { download(entry) }
    }

    private func downloadSelected() {
        guard let entry = selectedEntry else { return }
        if entry.isDirectory { downloadFolder(entry) } else { download(entry) }
    }

    private func download(_ entry: RemoteEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        if panel.runModal() == .OK, let url = panel.url {
            Task { await session.download(entry, to: url) }
        }
    }

    private func downloadFolder(_ entry: RemoteEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name + ".tar.gz"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await session.downloadFolder(entry, to: url) }
        }
    }

    private func startEdit(_ entry: RemoteEntry) {
        editText = ""
        editing = entry
    }

    private func uploadViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await session.upload(urls: urls) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            Task { await session.upload(urls: urls) }
        }
    }
}
