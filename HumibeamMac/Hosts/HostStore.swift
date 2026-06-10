import Foundation
import Observation

enum AuthKind: String, Codable, CaseIterable, Identifiable {
    case managedKey   // humibeam-managed ed25519 key (paste public key to server once)
    case password
    case importedKey  // user's existing OpenSSH private key file

    var id: String { rawValue }
    var label: String {
        switch self {
        case .managedKey: return "humibeam-Schlüssel"
        case .password: return "Passwort"
        case .importedKey: return "Eigener SSH-Key"
        }
    }
}

struct SSHHost: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var authKind: AuthKind = .managedKey
    var importedKeyPath: String? = nil
    /// Single character that, combined with ⌘, launches/focuses this session (e.g. "1", "h"). Optional.
    var shortcut: String? = nil
    /// Optional bastion: route this connection through another saved host (SSH ProxyJump).
    var proxyJumpHostID: UUID? = nil

    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "\(username.isEmpty ? "user" : username)@\(host.isEmpty ? "host" : host)" : n
    }
}

@Observable
@MainActor
final class HostStore {
    var hosts: [SSHHost] {
        didSet { save(); onHostsChanged?() }
    }
    /// Fired whenever the saved profiles change (used to rebuild the shortcut menu).
    @ObservationIgnored var onHostsChanged: (() -> Void)?

    private static var fileURL: URL {
        let dir = AppSupportPaths.appSupportDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hosts.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let list = try? JSONDecoder().decode([SSHHost].self, from: data) {
            self.hosts = list
        } else {
            self.hosts = []
        }
    }

    func add(_ host: SSHHost) { hosts.append(host) }

    func update(_ host: SSHHost) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) { hosts[i] = host }
    }

    func delete(_ host: SSHHost) {
        hosts.removeAll { $0.id == host.id }
        SSHKeyManager.savePassword("", hostID: host.id.uuidString) // overwrite stored secret
    }

    /// Builds the SSH credentials for a host, pulling secrets from the Keychain / key files.
    /// Credentials for the bastion this host jumps through, if any (and it isn't itself).
    func proxyCredentials(for host: SSHHost) throws -> SSHCredentials? {
        guard let jumpID = host.proxyJumpHostID, jumpID != host.id,
              let jump = hosts.first(where: { $0.id == jumpID }) else { return nil }
        return try credentials(for: jump)
    }

    func credentials(for host: SSHHost) throws -> SSHCredentials {
        let auth: SSHAuthMethod
        switch host.authKind {
        case .managedKey:
            auth = .ed25519Raw(SSHKeyManager.managedKeyRaw())
        case .password:
            auth = .password(SSHKeyManager.loadPassword(hostID: host.id.uuidString) ?? "")
        case .importedKey:
            guard let path = host.importedKeyPath else { throw SSHKeyManager.ImportError.malformed }
            let pem = try String(contentsOfFile: path, encoding: .utf8)
            auth = .privateKey(try SSHKeyManager.importPrivateKey(pem: pem))
        }
        return SSHCredentials(host: host.host, port: host.port, username: host.username, auth: auth)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) {
            try? data.write(to: Self.fileURL)
        }
    }

    // MARK: - SSH config import

    #if os(macOS)
    /// Imports hosts from `~/.ssh/config` (skips wildcard patterns; de-dupes by host:user:port).
    func importSSHConfig() {
        for host in Self.parseSSHConfig() {
            let exists = hosts.contains {
                $0.host == host.host && $0.username == host.username && $0.port == host.port
            }
            if !exists { hosts.append(host) }
        }
    }

    static func parseSSHConfig() -> [SSHHost] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }

        var result: [SSHHost] = []
        var aliases: [String] = []
        var hostName: String?, user: String?, port: Int?, identity: String?

        func flush() {
            for alias in aliases where !alias.contains("*") && !alias.contains("?") {
                var h = SSHHost()
                h.name = alias
                h.host = hostName ?? alias
                h.username = user ?? NSUserName()
                h.port = port ?? 22
                if let identity {
                    h.authKind = .importedKey
                    h.importedKeyPath = (identity as NSString).expandingTildeInPath
                } else {
                    h.authKind = .managedKey
                }
                result.append(h)
            }
            aliases = []; hostName = nil; user = nil; port = nil; identity = nil
        }

        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1]
            switch key {
            case "host": flush(); aliases = value.split(separator: " ").map(String.init)
            case "hostname": hostName = value
            case "user": user = value
            case "port": port = Int(value)
            case "identityfile": identity = value
            default: break
            }
        }
        flush()
        return result
    }
    #endif
}
