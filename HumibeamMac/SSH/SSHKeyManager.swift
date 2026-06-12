import Foundation
import Security
import NIOSSH
import Crypto

/// Manages SSH secrets in the macOS Keychain and imports existing OpenSSH keys.
enum SSHKeyManager {
    private static let service = "app.humibeam.ssh"
    private static let managedKeyAccount = "managed-ed25519-raw"

    // MARK: - humibeam-managed key

    /// Returns the app's ed25519 private key, generating + persisting one on first use.
    static func managedKeyRaw() -> Data {
        if let existing = loadSecret(account: managedKeyAccount) { return existing }
        let key = Curve25519.Signing.PrivateKey()
        let raw = key.rawRepresentation
        saveSecret(raw, account: managedKeyAccount)
        return raw
    }

    /// `ssh-ed25519 <base64> humibeam@<host>` line for the user to add to a server's authorized_keys.
    static func managedAuthorizedKeysLine(comment: String = "humibeam") -> String {
        let key = (try? Curve25519.Signing.PrivateKey(rawRepresentation: managedKeyRaw()))
            ?? Curve25519.Signing.PrivateKey()
        return authorizedKeysLine(ed25519PublicKey: key.publicKey, comment: comment)
    }

    static func authorizedKeysLine(ed25519PublicKey pub: Curve25519.Signing.PublicKey, comment: String) -> String {
        func sshString(_ data: Data) -> Data {
            var out = Data()
            var len = UInt32(data.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(data)
            return out
        }
        var blob = Data()
        blob.append(sshString(Data("ssh-ed25519".utf8)))
        blob.append(sshString(pub.rawRepresentation))
        return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
    }

    // MARK: - Host passwords

    static func savePassword(_ password: String, hostID: String) {
        saveSecret(Data(password.utf8), account: "pw-\(hostID)")
    }
    static func loadPassword(hostID: String) -> String? {
        loadSecret(account: "pw-\(hostID)").flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - Gekoppelte Schlüssel (QR-Pairing „Mein Mac als Server")
    // Der Mac erzeugt das Schlüsselpaar, trägt den Public Key selbst in seine
    // authorized_keys ein und reicht den Private Key per QR an das iPhone weiter.

    static func savePairedKey(_ raw: Data, hostID: String) {
        saveSecret(raw, account: "paired-\(hostID)")
    }
    static func loadPairedKey(hostID: String) -> Data? {
        loadSecret(account: "paired-\(hostID)")
    }

    // MARK: - MacBeam-Geheimnis (E2E-Schlüssel fürs Bildschirm-Streaming)
    // Mac: ein globales Secret (er ist der Server). iOS: pro gekoppeltem Host gespeichert.

    static func ensureBeamSecret() -> Data {
        if let existing = loadSecret(account: "beam-secret") { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        let data = Data(bytes)
        saveSecret(data, account: "beam-secret")
        return data
    }
    static func loadBeamSecret() -> Data? { loadSecret(account: "beam-secret") }
    static func saveBeamSecret(_ raw: Data, hostID: String) { saveSecret(raw, account: "beam-\(hostID)") }
    static func loadBeamSecret(hostID: String) -> Data? { loadSecret(account: "beam-\(hostID)") }

    // MARK: - Import existing OpenSSH private key

    enum ImportError: LocalizedError {
        case notOpenSSH
        case encryptedUnsupported
        case wrongPassphrase
        case unsupportedKeyType(String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .notOpenSSH: return "Keine OpenSSH-Privatschlüsseldatei."
            case .encryptedUnsupported: return "Dieser Schlüssel ist passphrasen-geschützt — bitte Passphrase eingeben."
            case .wrongPassphrase: return "Falsche Passphrase."
            case .unsupportedKeyType(let t): return "Schlüsseltyp \(t) wird nicht unterstützt (ed25519 und ECDSA p256/p384/p521)."
            case .malformed: return "Schlüsseldatei konnte nicht gelesen werden."
            }
        }
    }

    /// Imports an OpenSSH private key (ed25519 or ECDSA p256/p384/p521). Passphrase-protected
    /// keys are decrypted via the system `ssh-keygen` (robust, uses OpenSSH's own crypto) and
    /// then parsed unencrypted.
    static func importPrivateKey(pem: String, passphrase: String? = nil) throws -> NIOSSHPrivateKey {
        let lines = pem.split(separator: "\n").map(String.init)
        guard lines.first?.contains("BEGIN OPENSSH PRIVATE KEY") == true else { throw ImportError.notOpenSSH }
        let body = lines.dropFirst().prefix { !$0.contains("END OPENSSH PRIVATE KEY") }.joined()
        guard let blob = Data(base64Encoded: body) else { throw ImportError.malformed }

        var reader = ByteReader(blob)
        guard reader.readBytes(15) == Array("openssh-key-v1\0".utf8) else { throw ImportError.malformed }
        guard let cipher = reader.readSSHString() else { throw ImportError.malformed }
        let cipherName = String(decoding: cipher, as: UTF8.self)

        if cipherName != "none" {
            // Verschlüsselt → mit ssh-keygen entschlüsseln, dann den Klartext-PEM parsen.
            guard let passphrase, !passphrase.isEmpty else { throw ImportError.encryptedUnsupported }
            let decrypted = try decryptWithSSHKeygen(pem: pem, passphrase: passphrase)
            return try importPrivateKey(pem: decrypted, passphrase: nil)
        }

        _ = reader.readSSHString() // kdfname
        _ = reader.readSSHString() // kdfoptions
        guard reader.readUInt32() == 1 else { throw ImportError.malformed }
        _ = reader.readSSHString() // public key blob
        guard let priv = reader.readSSHString() else { throw ImportError.malformed }

        var pr = ByteReader(Data(priv))
        _ = pr.readUInt32() // check1
        _ = pr.readUInt32() // check2
        guard let keyType = pr.readSSHString() else { throw ImportError.malformed }
        let typeStr = String(decoding: keyType, as: UTF8.self)

        switch typeStr {
        case "ssh-ed25519":
            _ = pr.readSSHString() // public key (32)
            guard let privField = pr.readSSHString(), privField.count >= 32 else { throw ImportError.malformed }
            let seed = Data(privField.prefix(32))
            guard let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { throw ImportError.malformed }
            return NIOSSHPrivateKey(ed25519Key: signing)

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = pr.readSSHString() // curve name
            _ = pr.readSSHString() // public point Q
            guard let dField = pr.readSSHString() else { throw ImportError.malformed }
            // mpint kann ein führendes 0x00 (Vorzeichen) tragen; auf Kurvenlänge normalisieren.
            let d = Data(stripLeadingZero(dField))
            switch typeStr {
            case "ecdsa-sha2-nistp256":
                guard let k = try? P256.Signing.PrivateKey(rawRepresentation: leftPad(d, to: 32)) else { throw ImportError.malformed }
                return NIOSSHPrivateKey(p256Key: k)
            case "ecdsa-sha2-nistp384":
                guard let k = try? P384.Signing.PrivateKey(rawRepresentation: leftPad(d, to: 48)) else { throw ImportError.malformed }
                return NIOSSHPrivateKey(p384Key: k)
            default:
                guard let k = try? P521.Signing.PrivateKey(rawRepresentation: leftPad(d, to: 66)) else { throw ImportError.malformed }
                return NIOSSHPrivateKey(p521Key: k)
            }

        default:
            throw ImportError.unsupportedKeyType(typeStr)
        }
    }

    private static func stripLeadingZero(_ bytes: [UInt8]) -> [UInt8] {
        var b = bytes
        while b.first == 0, b.count > 1 { b.removeFirst() }
        return b
    }

    private static func leftPad(_ data: Data, to length: Int) -> Data {
        if data.count >= length { return data.suffix(length) }
        return Data(repeating: 0, count: length - data.count) + data
    }

    /// Entschlüsselt einen passphrasen-geschützten Key mit dem systemeigenen ssh-keygen
    /// (kopiert ihn in eine temporäre Datei, entfernt die Passphrase, liest ihn zurück).
    /// Nur macOS — iOS hat kein Process/ssh-keygen (dort werden verschlüsselte Keys abgelehnt).
    private static func decryptWithSSHKeygen(pem: String, passphrase: String) throws -> String {
        #if os(macOS)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("humibeam-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try pem.write(to: tmp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        // -p ändert die Passphrase: alte (-P) → neue leere (-N "").
        process.arguments = ["-p", "-P", passphrase, "-N", "", "-f", tmp.path]
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ImportError.wrongPassphrase
        }
        return try String(contentsOf: tmp, encoding: .utf8)
        #else
        throw ImportError.encryptedUnsupported
        #endif
    }

    // MARK: - Keychain helpers

    private static func saveSecret(_ data: Data, account: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(
                [kSecClass as String: kSecClassGenericPassword,
                 kSecAttrService as String: service,
                 kSecAttrAccount as String: account] as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
    }

    private static func loadSecret(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return data
    }
}

/// Minimal big-endian SSH wire reader.
private struct ByteReader {
    private let data: [UInt8]
    private var offset = 0
    init(_ data: Data) { self.data = Array(data) }

    mutating func readBytes(_ n: Int) -> [UInt8]? {
        guard offset + n <= data.count else { return nil }
        defer { offset += n }
        return Array(data[offset..<offset + n])
    }

    mutating func readUInt32() -> UInt32 {
        guard let b = readBytes(4) else { return 0 }
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    mutating func readSSHString() -> [UInt8]? {
        let len = Int(readUInt32())
        return readBytes(len)
    }
}
