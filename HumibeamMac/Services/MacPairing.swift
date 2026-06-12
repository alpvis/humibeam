import Foundation

/// „Mein Mac als Server": Der Mac erzeugt ein ed25519-Schlüsselpaar, trägt den Public Key
/// in seine eigene ~/.ssh/authorized_keys ein und zeigt den Private Key als QR — das iPhone
/// scannt ihn und hat damit sofort SSH-Zugang (im Heimnetz über <hostname>.local).
/// Geteilt zwischen Mac (erzeugen) und iOS (scannen/parsen).
struct MacPairingPayload: Codable {
    var v: Int = 1
    var host: String
    var port: Int = 22
    var user: String
    /// Base64 des rohen ed25519-Private-Keys (32 Bytes).
    var key: String
    /// tmux direkt aktivieren (Sitzungen überleben App-Wechsel auf dem iPhone).
    var tmux: Bool = true
    /// Base64 des MacBeam-Geheimnisses (32 Bytes) — E2E-Schlüssel fürs Bildschirm-Streaming.
    var beam: String?

    var qrString: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return "humibeam-pair:" + data.base64EncodedString()
    }

    static func parse(_ string: String) -> MacPairingPayload? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("humibeam-pair:"),
              let data = Data(base64Encoded: String(trimmed.dropFirst("humibeam-pair:".count))),
              let payload = try? JSONDecoder().decode(MacPairingPayload.self, from: data),
              payload.v == 1, !payload.host.isEmpty, !payload.user.isEmpty,
              let raw = Data(base64Encoded: payload.key), raw.count == 32 else { return nil }
        return payload
    }

    var rawKey: Data? { Data(base64Encoded: key) }
}
