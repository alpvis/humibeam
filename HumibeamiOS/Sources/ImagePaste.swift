import UIKit

/// Die humibeam-Superkraft auf iOS: ein Bild (Zwischenablage oder Fotobibliothek) über die
/// bestehende SSH-Verbindung hochladen und den Remote-Pfad in die Session tippen, damit
/// Claude Code es per Read-Tool liest. Port der Mac-PasteBridge ohne AppKit.
@MainActor
enum ImagePaste {

    /// Bilder aus der Zwischenablage hochladen. Gibt eine Statusmeldung zurück.
    static func pasteFromClipboard(into controller: TerminalController) async {
        let board = UIPasteboard.general
        var pngs: [Data] = []
        if let images = board.images, !images.isEmpty {
            pngs = images.compactMap { $0.pngData() }
        } else if let data = board.data(forPasteboardType: "public.png") {
            pngs = [data]
        }
        guard !pngs.isEmpty else {
            // Kein Bild → normalen Text einfügen.
            if let text = board.string, !text.isEmpty {
                controller.sendToShell(text)
            } else {
                controller.setStatus("Kein Bild/Text in der Zwischenablage.")
            }
            return
        }
        await upload(pngs, into: controller)
    }

    /// Bilddaten (z. B. aus dem PhotosPicker) hochladen und Pfad eintippen.
    static func upload(_ images: [Data], into controller: TerminalController) async {
        guard let connection = controller.connection, connection.isConnected else {
            controller.setStatus("Bild vorhanden, aber keine Verbindung.")
            return
        }
        let home = (try? await connection.remoteHome()) ?? "."
        let dir = "\(home)/.humibeam/pastes"
        for (i, png) in images.enumerated() {
            let stamp = Int(Date().timeIntervalSince1970)
            let name = "paste-\(stamp)-\(i + 1).png"
            let remotePath = "\(dir)/\(name)"
            controller.setStatus("lade Bild hoch (\(png.count / 1024) KB)…")
            do {
                try await connection.upload(png, to: remotePath)
                controller.sendToShell(remotePath + " ")
                controller.setStatus("Bild eingefügt: \(name)")
            } catch {
                controller.setStatus("Upload fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }
}
