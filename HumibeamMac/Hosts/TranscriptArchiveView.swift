import SwiftUI

/// Agenten-Protokolle: jedes Sitzungs-Transkript landet vollständig auf der Platte
/// (Application Support/Humibeam/Transcripts/<Host>/<Datum>.log) und ist hier durchsuchbar.
struct TranscriptArchiveView: View {
    struct Entry: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let host: String
        let name: String
        let size: Int
        let date: Date
    }

    @State private var entries: [Entry] = []
    @State private var query = ""
    @State private var selected: Entry?
    @State private var content = ""
    @State private var searching = false
    /// URLs, deren Inhalt die Suche trifft (nur bei nicht-leerer Suche relevant).
    @State private var contentMatches: Set<URL> = []

    private static var rootURL: URL {
        AppSupportPaths.appSupportDirectoryURL.appendingPathComponent("Transcripts", isDirectory: true)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("In Protokollen suchen…", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .onSubmit { runSearch() }
                    if searching { ProgressView().controlSize(.small).scaleEffect(0.6) }
                }
                .padding(8)
                Divider()
                List(filtered, selection: $selected) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.host).font(.system(size: 12, weight: .semibold))
                        Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(entry)
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 230, maxWidth: 320)

            ScrollView {
                Text(content.isEmpty ? "Protokoll auswählen." : content)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minWidth: 380)
        }
        .frame(minWidth: 680, minHeight: 400)
        .onAppear(perform: reload)
        .onChange(of: selected) { _, entry in
            guard let entry else { content = ""; return }
            content = (try? String(contentsOf: entry.url, encoding: .utf8)) ?? "(nicht lesbar)"
        }
        .onChange(of: query) { _, q in
            if q.isEmpty { contentMatches = [] } else { runSearch() }
        }
    }

    private var filtered: [Entry] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return entries }
        return entries.filter { contentMatches.contains($0.url) || $0.host.localizedCaseInsensitiveContains(query) }
    }

    private func reload() {
        let fm = FileManager.default
        var found: [Entry] = []
        let hosts = (try? fm.contentsOfDirectory(at: Self.rootURL, includingPropertiesForKeys: nil)) ?? []
        for hostDir in hosts where hostDir.hasDirectoryPath {
            let files = (try? fm.contentsOfDirectory(at: hostDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            for f in files where f.pathExtension == "log" {
                let values = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                found.append(Entry(url: f,
                                   host: hostDir.lastPathComponent,
                                   name: f.lastPathComponent,
                                   size: values?.fileSize ?? 0,
                                   date: values?.contentModificationDate ?? .distantPast))
            }
        }
        entries = found.sorted { $0.date > $1.date }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { contentMatches = []; return }
        searching = true
        let candidates = entries
        Task.detached(priority: .userInitiated) {
            var hits: Set<URL> = []
            for entry in candidates {
                if let text = try? String(contentsOf: entry.url, encoding: .utf8),
                   text.localizedCaseInsensitiveContains(q) {
                    hits.insert(entry.url)
                }
            }
            let result = hits
            await MainActor.run {
                contentMatches = result
                searching = false
            }
        }
    }
}
