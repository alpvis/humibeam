import Foundation
import NIOCore
import NIOSSH
import Crypto

/// Host-key pinning (like OpenSSH `known_hosts`).
///
/// On first connection to a host we record its public key (trust-on-first-use). On every later
/// connection we compare the presented key against the pinned one: a match is accepted, a
/// **mismatch is rejected** (possible man-in-the-middle or a re-provisioned server). A legitimately
/// changed key can be re-trusted by forgetting the host (see `forget`).
final class KnownHostsStore: SSHHostKeyVerifier {
    private let fileURL: URL
    /// host:port → pinned OpenSSH public key string ("algorithm base64").
    private var pinned: [String: String]
    private let queue = DispatchQueue(label: "app.humibeam.knownhosts")

    /// The most recent rejected key change, for the UI to surface. Accessed on the main thread.
    private(set) var lastMismatch: Mismatch?

    struct Mismatch {
        let host: String
        let port: Int
        let pinnedFingerprint: String
        let presentedFingerprint: String
    }

    init() {
        let dir = AppSupportPaths.appSupportDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("known_hosts.json")
        self.pinned = Self.load(fileURL)
    }

    private static func load(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        // Current format: { "host:port": "algo base64" }
        if let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            return dict
        }
        // Legacy format: ["host:port", …] (TOFU host list, no key pinned). Keep the hosts but
        // leave the key empty so the real key gets pinned on the next connection.
        if let list = try? JSONDecoder().decode([String].self, from: data) {
            return Dictionary(uniqueKeysWithValues: list.map { ($0, "") })
        }
        return [:]
    }

    private func key(_ host: String, _ port: Int) -> String { "\(host):\(port)" }

    private func persist() {
        if let data = try? JSONEncoder().encode(pinned) { try? data.write(to: fileURL) }
    }

    /// Removes a host's pinned key so its current key is trusted fresh on the next connection.
    func forget(host: String, port: Int) {
        queue.sync { pinned.removeValue(forKey: key(host, port)); persist() }
    }

    /// SHA256 fingerprint in OpenSSH style ("SHA256:base64") of an "algo base64" key string.
    static func fingerprint(of opensshKey: String) -> String {
        let parts = opensshKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "—" }
        let digest = SHA256.hash(data: blob)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    func pinnedFingerprint(host: String, port: Int) -> String? {
        queue.sync {
            guard let k = pinned[key(host, port)], !k.isEmpty else { return nil }
            return Self.fingerprint(of: k)
        }
    }

    // MARK: SSHHostKeyVerifier

    func verify(host: String, port: Int, hostKey: NIOSSHPublicKey, promise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        let k = key(host, port)
        queue.sync {
            if let stored = pinned[k], !stored.isEmpty {
                if stored == presented {
                    promise.succeed(())
                } else {
                    let mismatch = Mismatch(host: host, port: port,
                                            pinnedFingerprint: Self.fingerprint(of: stored),
                                            presentedFingerprint: Self.fingerprint(of: presented))
                    DispatchQueue.main.async { self.lastMismatch = mismatch }
                    promise.fail(SSHError.hostKeyChanged(
                        host: k,
                        pinned: mismatch.pinnedFingerprint,
                        presented: mismatch.presentedFingerprint))
                }
            } else {
                // Trust on first use (or first time we can pin a legacy host).
                pinned[k] = presented
                persist()
                promise.succeed(())
            }
        }
    }
}
