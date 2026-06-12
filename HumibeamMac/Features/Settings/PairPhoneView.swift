import SwiftUI
import CoreImage.CIFilterBuiltins
import Crypto
import Network

/// „iPhone koppeln": macht diesen Mac zu einem humibeam-Server fürs iPhone.
/// 1) prüft Entfernte Anmeldung (Port 22), 2) trägt einen frischen Public Key in
/// ~/.ssh/authorized_keys ein, 3) zeigt den Private Key als QR für die iOS-App.
struct PairPhoneView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var sshReachable: Bool?
    @State private var keyInstalled = false
    @State private var error: String?
    @State private var payload: MacPairingPayload?

    private static let pairKey = Curve25519.Signing.PrivateKey()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iPhone mit diesem Mac koppeln")
                .font(.system(size: 13, weight: .semibold))

            step(number: "1", done: sshReachable == true,
                 text: sshReachable == true
                 ? "Entfernte Anmeldung (SSH) ist aktiv."
                 : "Entfernte Anmeldung aktivieren: Systemeinstellungen → Allgemein → Teilen → Entfernte Anmeldung.")
            if sshReachable == false {
                Button("Systemeinstellungen öffnen") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!)
                }
                .controlSize(.small)
                Button("Erneut prüfen") { checkSSH() }
                    .controlSize(.small)
            }

            step(number: "2", done: keyInstalled,
                 text: keyInstalled
                 ? "Schlüssel ist in authorized_keys eingetragen."
                 : "humibeam trägt einen frischen Schlüssel in ~/.ssh/authorized_keys ein.")

            if let payload, keyInstalled {
                step(number: "3", done: false,
                     text: "In der iPhone-App: + → Mac koppeln → diesen Code scannen.")
                if let qr = Self.qrImage(payload.qrString) {
                    HStack {
                        Spacer()
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 200, height: 200)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Spacer()
                    }
                }
                Text("Verbindung: \(payload.user)@\(payload.host):\(String(payload.port)) — funktioniert im selben Netz (WLAN). Der QR enthält den privaten Schlüssel: nur mit dem eigenen iPhone scannen.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            checkSSH()
            installKey()
        }
    }

    private func step(number: String, done: Bool, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(done ? .green : .secondary)
            Text(text).font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func checkSSH() {
        sshReachable = nil
        let connection = NWConnection(host: "127.0.0.1", port: 22, using: .tcp)
        connection.stateUpdateHandler = { state in
            DispatchQueue.main.async {
                switch state {
                case .ready: sshReachable = true; connection.cancel()
                case .failed, .waiting: sshReachable = false; connection.cancel()
                default: break
                }
            }
        }
        connection.start(queue: .global())
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if sshReachable == nil { sshReachable = false; connection.cancel() }
        }
    }

    private func installKey() {
        let fm = FileManager.default
        let sshDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        let authFile = sshDir.appendingPathComponent("authorized_keys")
        let line = SSHKeyManager.authorizedKeysLine(ed25519PublicKey: Self.pairKey.publicKey,
                                                    comment: "humibeam-iphone")
        do {
            try fm.createDirectory(at: sshDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let existing = (try? String(contentsOf: authFile, encoding: .utf8)) ?? ""
            if !existing.contains(line) {
                let updated = existing.isEmpty ? line + "\n" : existing.trimmingCharacters(in: .newlines) + "\n" + line + "\n"
                try updated.write(to: authFile, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)
            }
            keyInstalled = true
            payload = MacPairingPayload(host: Self.bonjourHostname(),
                                        user: NSUserName(),
                                        key: Self.pairKey.rawRepresentation.base64EncodedString(),
                                        beam: SSHKeyManager.ensureBeamSecret().base64EncodedString())
        } catch {
            self.error = "authorized_keys konnte nicht geschrieben werden: \(error.localizedDescription)"
        }
    }

    /// "<name>.local" — erreichbar im selben Netz, unabhängig von wechselnden IPs.
    private static func bonjourHostname() -> String {
        if let local = Host.current().names.first(where: { $0.hasSuffix(".local") }) { return local }
        return ProcessInfo.processInfo.hostName
    }

    private static func qrImage(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
