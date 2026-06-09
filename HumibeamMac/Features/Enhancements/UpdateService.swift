import Foundation
import AppKit
import Observation

// MARK: - Auto-Update (Feature: Auto-Update)
// Prueft eine statische JSON-Datei (appcast) auf eine neuere Build-Nummer,
// laedt die notarisierte DMG, installiert sie nach /Applications und startet neu.

struct UpdateInfo: Codable, Equatable {
    var version: String      // Marketing-Version, z.B. "1.6"
    var build: Int           // CFBundleVersion als Zahl
    var dmgURL: String       // direkter Download-Link zur .dmg
    var notes: String        // Was ist neu
    var minOS: String?       // optional, z.B. "14.0"
}

@Observable
@MainActor
final class UpdateService {
    // Hosting der Update-Info (anpassbar). GitHub raw der Humibeam-Releases.
    static let feedURL = URL(string: "https://raw.githubusercontent.com/alpvis/humibeam/main/appcast.json")!

    var available: UpdateInfo?
    var isChecking = false
    var isInstalling = false
    var statusText: String?
    var lastError: String?

    var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    func checkInBackground() {
        Task { await check(silent: true) }
    }

    func check(silent: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        lastError = nil
        if !silent { statusText = "Suche nach Updates \u{2026}" }
        defer { isChecking = false }

        do {
            var request = URLRequest(url: Self.feedURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                if !silent { statusText = "Keine Update-Info erreichbar." }
                return
            }
            let info = try JSONDecoder().decode(UpdateInfo.self, from: data)
            if info.build > currentBuild {
                available = info
                statusText = "Update \(info.version) verf\u{00FC}gbar."
            } else {
                available = nil
                if !silent { statusText = "Humibeam ist aktuell (\(currentVersion))." }
            }
        } catch {
            if !silent { statusText = "Update-Pr\u{00FC}fung fehlgeschlagen." }
            lastError = error.localizedDescription
        }
    }

    func installAvailableUpdate() {
        guard let info = available, let url = URL(string: info.dmgURL), !isInstalling else { return }
        isInstalling = true
        statusText = "Lade Update \u{2026}"
        lastError = nil

        Task {
            do {
                // 1) DMG laden
                let (tmpFile, _) = try await URLSession.shared.download(from: url)
                let dmgPath = NSTemporaryDirectory() + "Humibeam-update.dmg"
                try? FileManager.default.removeItem(atPath: dmgPath)
                try FileManager.default.moveItem(atPath: tmpFile.path, toPath: dmgPath)

                statusText = "Installiere \u{2026}"
                // 2) Installation + Neustart an Hilfsskript uebergeben (laeuft weiter, wenn App beendet)
                try runInstaller(dmgPath: dmgPath)

                // 3) Diese Instanz beenden, Skript startet die neue
                statusText = "Neustart \u{2026}"
                try? await Task.sleep(for: .milliseconds(400))
                NSApplication.shared.terminate(nil)
            } catch {
                isInstalling = false
                lastError = error.localizedDescription
                statusText = "Update fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    /// Schreibt ein Shell-Skript, das wartet bis die App beendet ist, die DMG mountet,
    /// die App nach /Applications kopiert und neu startet. Laeuft unabhaengig weiter.
    private func runInstaller(dmgPath: String) throws {
        let scriptPath = NSTemporaryDirectory() + "humibeam-update.sh"
        let appPath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let mount = NSTemporaryDirectory() + "humibeam-update-mnt"

        let script = """
        #!/bin/bash
        set -e
        # warten bis Humibeam beendet ist
        for i in $(seq 1 50); do
            if ! kill -0 \(pid) 2>/dev/null; then break; fi
            sleep 0.2
        done
        rm -rf "\(mount)"
        mkdir -p "\(mount)"
        hdiutil attach "\(dmgPath)" -nobrowse -mountpoint "\(mount)" >/dev/null
        NEWAPP=$(/usr/bin/find "\(mount)" -maxdepth 1 -name "*.app" | head -1)
        if [ -n "$NEWAPP" ]; then
            rm -rf "\(appPath)"
            cp -R "$NEWAPP" "\(appPath)"
            xattr -dr com.apple.quarantine "\(appPath)" 2>/dev/null || true
        fi
        hdiutil detach "\(mount)" >/dev/null 2>&1 || true
        rm -rf "\(mount)" "\(dmgPath)"
        open "\(appPath)"
        """

        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptPath]
        try proc.run()
    }
}
