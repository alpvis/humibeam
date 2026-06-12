import Foundation
import AppKit
import Observation

/// Synchronisiert Profile, Snippets und Darstellung über iCloud Drive auf alle Macs.
/// Geheimnisse (Passwörter, Keys) bleiben im Keychain und werden NIE synchronisiert.
/// Semantik: letzter Schreiber gewinnt (Datei-Zeitstempel im Payload).
@MainActor
@Observable
final class CloudSyncService {
    struct Payload: Codable {
        var hosts: [SSHHost]
        var snippets: [Snippet]
        var fontName: String?
        var fontSize: Double?
        var themeID: String?
        var updatedAt: Date
        var device: String
    }

    private(set) var available = false
    private(set) var lastSync: Date?

    @ObservationIgnored private weak var shell: HumibeamShell?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watchedFD: Int32 = -1
    @ObservationIgnored private var exportWork: DispatchWorkItem?
    @ObservationIgnored private var applyingRemote = false

    private static var cloudRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }
    private static var folderURL: URL { cloudRoot.appendingPathComponent("Humibeam", isDirectory: true) }
    private static var fileURL: URL { folderURL.appendingPathComponent("humibeam-sync.json") }
    private static let lastAppliedKey = "cloudsync.lastApplied"

    private var deviceName: String { Host.current().localizedName ?? "Mac" }

    func start(shell: HumibeamShell) {
        self.shell = shell
        guard FileManager.default.fileExists(atPath: Self.cloudRoot.path) else { return }
        try? FileManager.default.createDirectory(at: Self.folderURL, withIntermediateDirectories: true)
        available = true
        importIfNewer()
        startWatching()
    }

    /// Debounced: mehrere schnelle Änderungen → ein Schreibvorgang.
    func scheduleExport() {
        guard available, !applyingRemote else { return }
        exportWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.export() }
        }
        exportWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func export() {
        guard let shell, available, !applyingRemote else { return }
        let payload = Payload(hosts: shell.hostStore.hosts,
                              snippets: shell.snippets.snippets,
                              fontName: shell.terminalFontName,
                              fontSize: Double(shell.terminalFontSize),
                              themeID: shell.selectedThemeID,
                              updatedAt: Date(),
                              device: deviceName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
        UserDefaults.standard.set(payload.updatedAt, forKey: Self.lastAppliedKey)
        lastSync = payload.updatedAt
    }

    private func importIfNewer() {
        guard let shell,
              let data = try? Data(contentsOf: Self.fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return }

        let lastApplied = UserDefaults.standard.object(forKey: Self.lastAppliedKey) as? Date ?? .distantPast
        guard payload.updatedAt > lastApplied.addingTimeInterval(1), payload.device != deviceName else { return }

        applyingRemote = true
        defer { applyingRemote = false }
        shell.hostStore.hosts = payload.hosts
        shell.snippets.snippets = payload.snippets
        if let f = payload.fontName { shell.terminalFontName = f }
        if let s = payload.fontSize { shell.terminalFontSize = CGFloat(s) }
        if let t = payload.themeID { shell.selectedThemeID = t }
        UserDefaults.standard.set(payload.updatedAt, forKey: Self.lastAppliedKey)
        lastSync = payload.updatedAt
    }

    private func startWatching() {
        // iCloud schreibt die Datei atomar neu → Ordner beobachten, nicht die Datei.
        watchedFD = open(Self.folderURL.path, O_EVTONLY)
        guard watchedFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: watchedFD,
                                                               eventMask: [.write],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.importIfNewer() }
        }
        source.setCancelHandler { [fd = watchedFD] in close(fd) }
        source.resume()
        watcher = source
    }
}
