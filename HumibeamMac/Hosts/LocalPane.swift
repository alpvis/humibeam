import SwiftUI
import Observation

struct LocalEntry: Identifiable, Hashable {
    let url: URL
    var isDirectory: Bool
    var size: Int64
    var name: String { url.lastPathComponent }
    var id: String { url.path }
    var displaySize: String {
        isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// The local side of the dual-pane file manager: browses the Mac filesystem.
@Observable
@MainActor
final class LocalPane {
    var path: URL
    var entries: [LocalEntry] = []

    init() {
        path = FileManager.default.homeDirectoryForCurrentUser
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let urls = (try? fm.contentsOfDirectory(at: path, includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])) ?? []
        entries = urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return LocalEntry(url: url, isDirectory: v?.isDirectory ?? false, size: Int64(v?.fileSize ?? 0))
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    func open(_ e: LocalEntry) { if e.isDirectory { path = e.url; refresh() } }
    func goUp() { path = path.deletingLastPathComponent(); refresh() }
    func goHome() { path = FileManager.default.homeDirectoryForCurrentUser; refresh() }
}

/// The local pane view shown to the left of the remote list in dual-pane mode.
struct LocalPaneView: View {
    @Bindable var local: LocalPane
    @Binding var selection: LocalEntry.ID?
    var onUpload: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { local.goUp() } label: { Image(systemName: "arrow.up") }.help("Hoch")
                Button { local.goHome() } label: { Image(systemName: "house") }.help("Home")
                Button { local.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Aktualisieren")
                Text("Lokal").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let e = selected, !e.isDirectory { onUpload(e.url) }
                } label: { Image(systemName: "arrow.right.circle") }
                .help("Auswahl auf den Server hochladen").disabled(selected?.isDirectory != false)
            }
            .padding(.horizontal, 10).padding(.vertical, 7).background(.bar)
            Divider()
            Text(local.path.path).font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 4)
            Divider()
            List(selection: $selection) {
                ForEach(local.entries) { e in
                    HStack(spacing: 8) {
                        Image(systemName: e.isDirectory ? "folder.fill" : "doc")
                            .foregroundStyle(e.isDirectory ? Color.accentColor : .secondary).frame(width: 16)
                        Text(e.name).lineLimit(1)
                        Spacer()
                        Text(e.displaySize).font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(e.id)
                    .onTapGesture(count: 2) { local.open(e) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .frame(minWidth: 220)
    }

    private var selected: LocalEntry? { local.entries.first { $0.id == selection } }
}
