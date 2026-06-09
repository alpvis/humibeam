import Foundation
import AppKit
import Observation

/// A standalone SFTP-style file session — its own SSH connection (no terminal PTY), driving
/// the file manager window. All operations are defensive: guard the connection, catch every
/// error into `status`, never force-unwrap, so a flaky link can't take the app down.
@Observable
@MainActor
final class FileSession: Identifiable {
    let id = UUID()
    let host: SSHHost
    var title: String
    var path: String = ""
    var entries: [RemoteEntry] = []
    var connected = false
    var busy = false
    var status = "verbinde…"
    var transfers: [Transfer] = []

    // Navigation history (back / forward like Cyberduck).
    @ObservationIgnored private var backStack: [String] = []
    @ObservationIgnored private var forwardStack: [String] = []
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored weak var window: NSWindow?

    struct Transfer: Identifiable {
        let id = UUID()
        let name: String
        let isUpload: Bool
        var total: Int64
        var transferred: Int64 = 0
        var state: State = .running
        var startedAt = Date()
        enum State { case running, done, failed }

        var fraction: Double {
            if state == .done { return 1 }
            return total > 0 ? Swift.min(1, Double(transferred) / Double(total)) : 0
        }
        /// Average bytes/sec since the transfer started.
        var bytesPerSecond: Double {
            let dt = Date().timeIntervalSince(startedAt)
            return dt > 0.2 ? Double(transferred) / dt : 0
        }
    }

    /// A tiny event-loop-side throttle so we don't spawn a main-actor hop per 64 KB chunk.
    private final class ProgressThrottle {
        private var last = 0
        func shouldReport(_ value: Int, total: Int) -> Bool {
            let step = Swift.max(131_072, total / 100)
            if value >= total || value - last >= step { last = value; return true }
            return false
        }
    }

    init(host: SSHHost, credentials: SSHCredentials, knownHosts: KnownHostsStore,
         proxy: SSHConnection.ProxyJump? = nil) {
        self.host = host
        self.title = "Dateien — \(host.displayName)"
        self.connection = SSHConnection(credentials: credentials, hostKeyVerifier: knownHosts, proxyJump: proxy)
    }

    // MARK: - Lifecycle

    func start() async {
        guard let conn = connection else { return }
        do {
            try await conn.connect()
            // First real command: surfaces auth/channel failure as an error (with timeout) instead
            // of leaving the UI hanging. Requires the Mac unlocked so the Keychain password is readable.
            let home = try await conn.remoteHome()
            connected = true
            status = "verbunden"
            path = home
            await refresh()
        } catch {
            connected = false
            status = "Verbindung fehlgeschlagen: \(error.localizedDescription)"
            disconnect()
        }
    }

    func disconnect() {
        connected = false
        let conn = connection
        connection = nil
        Task { await conn?.close() }
    }

    // MARK: - Navigation

    func refresh() async {
        guard let conn = connection, !path.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            entries = try await conn.listDetailed(path)
            status = "\(entries.count) Einträge — \(path)"
        } catch {
            status = "Listing fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func open(_ entry: RemoteEntry) async {
        guard entry.isDirectory else { return }
        await go(to: join(path, entry.name))
    }

    func goUp() async {
        guard path != "/" else { return }
        var up = (path as NSString).deletingLastPathComponent
        if up.isEmpty { up = "/" }
        await go(to: up)
    }

    func navigate(to newPath: String) async {
        let trimmed = newPath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != path else { return }
        await go(to: trimmed)
    }

    func goHome() async {
        guard let conn = connection else { return }
        await go(to: (try? await conn.remoteHome()) ?? "/")
    }

    func goBack() async {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        path = previous
        await refresh()
    }

    func goForward() async {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        path = next
        await refresh()
    }

    /// Navigate to a new path, recording history for back/forward.
    private func go(to newPath: String) async {
        if newPath != path {
            backStack.append(path)
            forwardStack.removeAll()
        }
        path = newPath
        await refresh()
    }

    private func join(_ base: String, _ name: String) -> String {
        (base as NSString).appendingPathComponent(name)
    }

    // MARK: - Operations

    func upload(urls: [URL]) async {
        guard let conn = connection else { return }
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let name = url.lastPathComponent
            let transfer = Transfer(name: name, isUpload: true, total: Int64(data.count))
            transfers.insert(transfer, at: 0)
            let id = transfer.id
            status = "lade \(name) hoch (\(byteString(data.count)))…"
            let throttle = ProgressThrottle()
            do {
                try await conn.upload(data, to: join(path, name), onProgress: { sent in
                    if throttle.shouldReport(sent, total: data.count) {
                        Task { @MainActor in self.setProgress(id, bytes: Int64(sent)) }
                    }
                })
                setProgress(id, bytes: Int64(data.count))
                setTransfer(id, .done)
            } catch {
                setTransfer(id, .failed)
                status = "Upload fehlgeschlagen: \(error.localizedDescription)"
            }
        }
        await refresh()
    }

    func download(_ entry: RemoteEntry, to localURL: URL) async {
        guard let conn = connection else { return }
        let transfer = Transfer(name: entry.name, isUpload: false, total: entry.size)
        transfers.insert(transfer, at: 0)
        let id = transfer.id
        status = "lade \(entry.name) herunter…"
        let throttle = ProgressThrottle()
        let total = Int(entry.size)
        do {
            let data = try await conn.download(join(path, entry.name), onProgress: { received in
                if throttle.shouldReport(received, total: total) {
                    Task { @MainActor in self.setProgress(id, bytes: Int64(received)) }
                }
            })
            try data.write(to: localURL)
            setProgress(id, bytes: Int64(data.count))
            setTransfer(id, .done)
            status = "geladen: \(entry.name) (\(byteString(data.count)))"
        } catch {
            setTransfer(id, .failed)
            status = "Download fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// Downloads an entry to a local URL and reports success — used by drag-to-Finder file promises.
    func fetch(_ entry: RemoteEntry, to url: URL) async -> Bool {
        await download(entry, to: url)
        return FileManager.default.fileExists(atPath: url.path)
    }

    func downloadFolder(_ entry: RemoteEntry, to localURL: URL) async {
        guard let conn = connection else { return }
        let transfer = Transfer(name: "\(entry.name).tar.gz", isUpload: false, total: 0)
        transfers.insert(transfer, at: 0)
        let id = transfer.id
        status = "packe & lade \(entry.name) …"
        let throttle = ProgressThrottle()
        do {
            let data = try await conn.downloadFolderTarGz(join(path, entry.name), onProgress: { received in
                if throttle.shouldReport(received, total: Int.max) {
                    Task { @MainActor in self.setProgress(id, bytes: Int64(received)) }
                }
            })
            try data.write(to: localURL)
            setProgress(id, bytes: Int64(data.count))
            setTransfer(id, .done)
            status = "Ordner geladen: \(entry.name).tar.gz (\(byteString(data.count)))"
        } catch {
            setTransfer(id, .failed)
            status = "Ordner-Download fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func makeDirectory(_ name: String) async {
        guard let conn = connection, !name.isEmpty else { return }
        do { try await conn.makeDirectory(join(path, name)); await refresh() }
        catch { status = "Ordner anlegen fehlgeschlagen: \(error.localizedDescription)" }
    }

    func rename(_ entry: RemoteEntry, to newName: String) async {
        guard let conn = connection, !newName.isEmpty else { return }
        do { try await conn.rename(join(path, entry.name), to: join(path, newName)); await refresh() }
        catch { status = "Umbenennen fehlgeschlagen: \(error.localizedDescription)" }
    }

    func remove(_ entry: RemoteEntry) async {
        guard let conn = connection else { return }
        do { try await conn.remove(join(path, entry.name), recursive: entry.isDirectory); await refresh() }
        catch { status = "Löschen fehlgeschlagen: \(error.localizedDescription)" }
    }

    func chmod(_ entry: RemoteEntry, mode: String) async {
        guard let conn = connection, !mode.isEmpty else { return }
        do { try await conn.chmod(join(path, entry.name), mode: mode); await refresh() }
        catch { status = "chmod fehlgeschlagen: \(error.localizedDescription)" }
    }

    func readTextFile(_ entry: RemoteEntry) async -> String? {
        guard let conn = connection else { return nil }
        do { return String(decoding: try await conn.download(join(path, entry.name)), as: UTF8.self) }
        catch { status = "Konnte Datei nicht laden: \(error.localizedDescription)"; return nil }
    }

    func writeTextFile(_ entry: RemoteEntry, content: String) async {
        guard let conn = connection else { return }
        do { try await conn.upload(Data(content.utf8), to: join(path, entry.name)); status = "gespeichert: \(entry.name)" }
        catch { status = "Speichern fehlgeschlagen: \(error.localizedDescription)" }
    }

    // MARK: - Helpers

    private func setTransfer(_ id: UUID, _ state: Transfer.State) {
        if let i = transfers.firstIndex(where: { $0.id == id }) { transfers[i].state = state }
    }

    private func setProgress(_ id: UUID, bytes: Int64) {
        if let i = transfers.firstIndex(where: { $0.id == id }) {
            transfers[i].transferred = bytes
            if transfers[i].total < bytes { transfers[i].total = bytes }
        }
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
