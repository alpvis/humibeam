import Foundation
import CryptoKit
import CommonCrypto

/// Schlüsselableitung fürs Humibeam-Konto — der Server sieht nie das Passwort und nie Klartext:
/// masterKey = PBKDF2-SHA256(passwort, kdfSalt, 600k) → authKey (geht zum Server, wird dort
/// nochmal gehasht) und encKey (bleibt auf dem Gerät, AES-GCM für das Sync-Blob).
enum AccountCrypto {
    static let pbkdf2Rounds: UInt32 = 600_000

    struct DerivedKeys {
        let authKeyHex: String     // 32 Bytes hex — Login-Beweis
        let encKey: SymmetricKey   // 32 Bytes — Blob-Verschlüsselung
    }

    static func randomSaltHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func deriveKeys(password: String, kdfSaltHex: String) throws -> DerivedKeys {
        guard let salt = Data(hex: kdfSaltHex) else { throw AccountError.crypto("ungültiges Salt") }
        let master = try pbkdf2(password: password, salt: salt)
        let auth = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: master),
                                          info: Data("humibeam-auth".utf8), outputByteCount: 32)
        let enc = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: master),
                                         info: Data("humibeam-enc".utf8), outputByteCount: 32)
        return DerivedKeys(authKeyHex: auth.withUnsafeBytes { Data($0) }.hexString, encKey: enc)
    }

    static func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> String {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw AccountError.crypto("Verschlüsselung fehlgeschlagen") }
        return combined.base64EncodedString()
    }

    static func decrypt(_ base64: String, key: SymmetricKey) throws -> Data {
        guard let combined = Data(base64Encoded: base64) else { throw AccountError.crypto("ungültiges Blob") }
        return try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: key)
    }

    private static func pbkdf2(password: String, salt: Data) throws -> Data {
        var out = Data(repeating: 0, count: 32)
        let pw = Array(password.utf8)
        let status = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password.cString(using: .utf8), pw.count,
                    saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    Self.pbkdf2Rounds,
                    outPtr.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        guard status == kCCSuccess else { throw AccountError.crypto("PBKDF2 fehlgeschlagen (\(status))") }
        return out
    }
}

enum AccountError: LocalizedError, Equatable {
    case crypto(String)
    case server(String)
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .crypto(let m): return m
        case .server(let m): return m
        case .notLoggedIn: return "Nicht angemeldet."
        }
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
