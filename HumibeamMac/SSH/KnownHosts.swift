import Foundation
import NIOCore
import NIOSSH

/// Trust-on-first-use host verification.
///
/// NOTE (security follow-up): swift-nio-ssh does not expose host-key raw bytes
/// in a stable public API across versions, so this MVP pins by host:port only and
/// accepts on first use. Real key-pinning (compare stored fingerprint, warn on change)
/// is tracked in PLAN.md §9 and should land before any non-developer release.
final class KnownHostsStore: SSHHostKeyVerifier {
    private let fileURL: URL
    private var trusted: Set<String>
    private let queue = DispatchQueue(label: "app.humibeam.knownhosts")

    init() {
        let dir = AppSupportPaths.appSupportDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("known_hosts.json")
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            self.trusted = Set(list)
        } else {
            self.trusted = []
        }
    }

    private func key(_ host: String, _ port: Int) -> String { "\(host):\(port)" }

    func isTrusted(host: String, port: Int) -> Bool {
        queue.sync { trusted.contains(key(host, port)) }
    }

    func trust(host: String, port: Int) {
        queue.sync {
            trusted.insert(key(host, port))
            if let data = try? JSONEncoder().encode(Array(trusted)) {
                try? data.write(to: fileURL)
            }
        }
    }

    // MARK: SSHHostKeyVerifier

    func verify(host: String, port: Int, hostKey: NIOSSHPublicKey, promise: EventLoopPromise<Void>) {
        // TOFU: accept and remember. (Key-byte pinning is a documented follow-up.)
        trust(host: host, port: port)
        promise.succeed(())
    }
}
