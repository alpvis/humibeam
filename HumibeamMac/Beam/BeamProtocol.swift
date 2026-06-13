import Foundation
import CryptoKit

/// MacBeam-Protokoll (Mac-Bildschirm aufs iPhone): längen-präfixierte, AES-GCM-verschlüsselte
/// Pakete über TCP. Der Schlüssel kommt per HKDF aus dem beim QR-Pairing geteilten beamSecret —
/// Ende-zu-Ende, auch durch einen Tunnel-Server hindurch lesbar nur für Mac und iPhone.
///
/// Paket: [4 Byte BE Länge][AES-GCM combined (nonce+ciphertext+tag)]
/// Klartext: [1 Byte Typ][Payload]
enum BeamPacketType: UInt8 {
    case hello = 0x01        // JSON {v, name, width, height}
    case videoConfig = 0x02  // [2B BE spsLen][sps][2B BE ppsLen][pps]
    case videoFrame = 0x03   // [1B keyframe][AVCC NALUs (länge-präfixiert)]
    case input = 0x10        // JSON BeamInput
    case control = 0x11      // JSON {quality?, fps?}
}

enum BeamCrypto {
    static func key(fromSecret secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                               info: Data("humibeam-beam".utf8), outputByteCount: 32)
    }

    /// Kanal-ID für den Beam-Tunnel (Rendezvous unterwegs): SHA-256 des Geheimnisses.
    /// Verrät dem Server nichts über den Schlüssel (der wird per HKDF separat abgeleitet).
    static func channelID(fromSecret secret: Data) -> String {
        SHA256.hash(data: secret).map { String(format: "%02x", $0) }.joined()
    }

    /// Standard-Rendezvous: der Humibeam-Server (ausschließlich humibeam.com, früher alpvis.com).
    /// In den Apps überschreibbar (beam.relay).
    static let defaultRelay = "humibeam.com:8797"

    /// Liest den konfigurierten Relay und migriert eine alte alpvis-Adresse einmalig auf humibeam.com.
    static var relay: String {
        let stored = UserDefaults.standard.string(forKey: "beam.relay")
        if let s = stored, s.contains("alpvis.com") {
            UserDefaults.standard.set(defaultRelay, forKey: "beam.relay")
            return defaultRelay
        }
        return stored ?? defaultRelay
    }

    static func seal(type: BeamPacketType, payload: Data, key: SymmetricKey) -> Data? {
        var plain = Data([type.rawValue])
        plain.append(payload)
        guard let sealed = try? AES.GCM.seal(plain, using: key), let combined = sealed.combined else { return nil }
        var out = Data()
        var len = UInt32(combined.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(combined)
        return out
    }

    static func open(_ combined: Data, key: SymmetricKey) -> (BeamPacketType, Data)? {
        guard let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: key),
              let first = plain.first, let type = BeamPacketType(rawValue: first) else { return nil }
        return (type, plain.dropFirst())
    }
}

/// Eingabe-Ereignisse vom iPhone → Mac (Koordinaten normalisiert 0…1).
struct BeamInput: Codable {
    enum Kind: String, Codable {
        case move, click, rightClick, doubleClick, dragStart, dragMove, dragEnd
        case scroll, text, key
    }

    var kind: Kind
    var x: Double = 0
    var y: Double = 0
    /// scroll: Delta in Punkten
    var dx: Double = 0
    var dy: Double = 0
    /// text: getippter Text · key: Sondertaste ("return", "backspace", "esc", "tab",
    /// "up", "down", "left", "right") + optionale Modifier
    var text: String?
    var keyName: String?
    var command = false
    var option = false
    var controlKey = false
    var shift = false
}

/// Sammelt eingehende Bytes und zerlegt sie in Pakete (4-Byte-Längenpräfix).
struct BeamFrameAssembler {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let len = buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            guard len <= 16_000_000 else { buffer.removeAll(); break }   // korrupt → reset
            guard buffer.count >= 4 + Int(len) else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(Int(len))))
            buffer.removeFirst(4 + Int(len))
        }
        return frames
    }
}
