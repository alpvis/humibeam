import SwiftUI

/// Agenten-Protokolle: jedes Sitzungs-Transkript landet auf der Platte
/// (Application Support/Humibeam/Transcripts/<Host>/<Datum>.log) und ist hier durchsuchbar —
/// gleiche Ablage wie am Mac.
struct TranscriptArchiveSheet: View {
    struct Entry: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let host: String
        let name: String
        let size: Int
        let date: Date
    }

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry] = []
    @State private var query = ""
    @State private var contentMatches: Set<URL> = []
    @State private var searching = false
    @State private var selected: Entry?
    @State private var content = ""

    private static var rootURL: URL {
        AppSupportPaths.appSupportDirectoryURL.appendingPathComponent("Transcripts", isDirectory: true)
    }

    private var filtered: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.host.lowercased().contains(q) || contentMatches.contains($0.url) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("Keine Protokolle", systemImage: "doc.text.magnifyingglass",
                                           description: Text("Sobald du dich mit einem Server verbindest, wird das Sitzungs-Transkript hier archiviert."))
                } else {
                    List(filtered) { entry in
                        Button {
                            load(entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.host).font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                try? FileManager.default.removeItem(at: entry.url)
                                reload()
                            } label: { Label("Löschen", systemImage: "trash") }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Host oder Inhalt…")
            .onSubmit(of: .search) { runContentSearch() }
            .overlay(alignment: .top) { if searching { ProgressView().padding() } }
            .navigationTitle("Protokolle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .sheet(item: $selected) { entry in
                NavigationStack {
                    ScrollView {
                        Text(content)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .textSelection(.enabled)
                    }
                    .navigationTitle(entry.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") { selected = nil }
                        }
                        ToolbarItem(placement: .topBarLeading) {
                            ShareLink(item: entry.url) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
                }
            }
            .onAppear { reload() }
        }
    }

    private func reload() {
        let fm = FileManager.default
        var found: [Entry] = []
        let hosts = (try? fm.contentsOfDirectory(at: Self.rootURL, includingPropertiesForKeys: nil)) ?? []
        for hostDir in hosts where hostDir.hasDirectoryPath {
            let files = (try? fm.contentsOfDirectory(at: hostDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "log" {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                found.append(Entry(url: file,
                                   host: hostDir.lastPathComponent,
                                   name: file.deletingPathExtension().lastPathComponent,
                                   size: values?.fileSize ?? 0,
                                   date: values?.contentModificationDate ?? .distantPast))
            }
        }
        entries = found.sorted { $0.date > $1.date }
    }

    private func load(_ entry: Entry) {
        content = (try? String(contentsOf: entry.url, encoding: .utf8)) ?? ""
        // Riesige Protokolle kappen — die letzten 200k Zeichen sind die interessanten.
        if content.count > 200_000 { content = String(content.suffix(200_000)) }
        selected = entry
    }

    private func runContentSearch() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { contentMatches = []; return }
        searching = true
        let candidates = entries
        Task.detached(priority: .userInitiated) {
            var matches: Set<URL> = []
            for entry in candidates {
                if let text = try? String(contentsOf: entry.url, encoding: .utf8),
                   text.lowercased().contains(q) {
                    matches.insert(entry.url)
                }
            }
            let result = matches
            await MainActor.run {
                contentMatches = result
                searching = false
            }
        }
    }
}
