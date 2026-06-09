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

    // MARK: - Import existing OpenSSH private key

    enum ImportError: LocalizedError {
        case notOpenSSH
        case encryptedUnsupported
        case unsupportedKeyType(String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .notOpenSSH: return "Keine OpenSSH-Privatschlüsseldatei."
            case .encryptedUnsupported: return "Passphrase-geschützte Schlüssel werden noch nicht unterstützt. Nutze einen humibeam-Schlüssel oder einen Schlüssel ohne Passphrase."
            case .unsupportedKeyType(let t): return "Schlüsseltyp \(t) wird noch nicht unterstützt (nur ed25519)."
            case .malformed: return "Schlüsseldatei konnte nicht gelesen werden."
            }
        }
    }

    /// Imports an unencrypted OpenSSH ed25519 private key (the common `~/.ssh/id_ed25519`).
    /// RSA/ECDSA and passphrase-protected keys are a documented follow-up.
    static func importPrivateKey(pem: String) throws -> NIOSSHPrivateKey {
        let lines = pem.split(separator: "\n").map(String.init)
        guard lines.first?.contains("BEGIN OPENSSH PRIVATE KEY") == true else { throw ImportError.notOpenSSH }
        let body = lines.dropFirst().prefix { !$0.contains("END OPENSSH PRIVATE KEY") }.joined()
        guard let blob = Data(base64Encoded: body) else { throw ImportError.malformed }

        var reader = ByteReader(blob)
        guard reader.readBytes(15) == Array("openssh-key-v1\0".utf8) else { throw ImportError.malformed }
        guard let cipher = reader.readSSHString(), String(decoding: cipher, as: UTF8.self) == "none" else {
            throw ImportError.encryptedUnsupported
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
        guard typeStr == "ssh-ed25519" else { throw ImportError.unsupportedKeyType(typeStr) }
        _ = pr.readSSHString() // public key (32)
        guard let privField = pr.readSSHString(), privField.count >= 32 else { throw ImportError.malformed }
        let seed = Data(privField.prefix(32))
        guard let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { throw ImportError.malformed }
        return NIOSSHPrivateKey(ed25519Key: signing)
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
