import Foundation
import AppKit
import SwiftTerm

/// TerminalView subclass that lets humibeam intercept Cmd+V before SwiftTerm's own paste,
/// so an image on the clipboard can be uploaded to the server instead of pasted as garbage.
/// Also accepts drag & drop of files/images → upload to the server and inject the path.
final class HumibeamTerminalView: TerminalView {
    /// Return true if the paste was handled (image upload); false to fall back to normal text paste.
    var pasteInterceptor: (() -> Bool)?
    /// Handle dropped file URLs (upload + inject path). Return true if consumed.
    var fileDropHandler: (([URL]) -> Bool)?

    override func paste(_ sender: Any?) {
        if pasteInterceptor?() == true { return }
        super.paste(sender)
    }

    private func droppedFileURLs(_ sender: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(sender)
        if !urls.isEmpty, fileDropHandler?(urls) == true { return true }
        return super.performDragOperation(sender)
    }
}

/// The humibeam superpower: paste a screenshot into a remote Claude Code session.
/// On Cmd+V with an image on the clipboard → upload it over the SSH connection →
/// type the remote path into the shell so Claude Code reads it via its Read tool.
/// (Mechanism validated in M0; upload path validated in M1.)
@MainActor
final class PasteBridge {
    private weak var controller: TerminalSessionController?
    private var counter = 0
    /// Absolute remote paste directory, resolved once per connection (no `$HOME` literal issues).
    private var resolvedPasteDir: String?

    init(controller: TerminalSessionController) {
        self.controller = controller
    }

    /// Called from the terminal's drag&drop. Uploads dropped files and injects their remote paths.
    func handleDroppedFiles(_ urls: [URL]) -> Bool {
        let files = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
        guard !files.isEmpty else { return false }
        guard let controller, controller.connection?.isConnected == true else {
            controller?.onStatus?("Datei abgelegt, aber keine Verbindung.")
            return true
        }
        Task { await uploadDropped(files, via: controller) }
        return true
    }

    private func uploadDropped(_ urls: [URL], via controller: TerminalSessionController) async {
        guard let connection = controller.connection else { return }
        let dir = await pasteDir(connection)
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let remotePath = "\(dir)/\(url.lastPathComponent)"
            controller.onStatus?("lade \(url.lastPathComponent) hoch (\(data.count / 1024) KB)…")
            do {
                try await connection.upload(data, to: remotePath)
                controller.sendToShell(remotePath + " ")
                controller.onStatus?("hochgeladen: \(url.lastPathComponent)")
            } catch {
                controller.onStatus?("Upload fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    /// Called from the terminal's overridden paste(_:). Returns true if it consumed an image.
    func handlePasteFromClipboard() -> Bool {
        guard let images = imagesOnPasteboard(), !images.isEmpty else { return false }
        guard let controller, controller.connection?.isConnected == true else {
            controller?.onStatus?("Bild im Clipboard, aber keine Verbindung.")
            return true // consume: we don't want raw image bytes dumped into the shell
        }
        Task { await uploadAll(images, via: controller) }
        return true
    }

    /// Resolves the absolute `~/.humibeam/pastes` once (the server's real $HOME), so the
    /// single-quoted upload path is unambiguous and the injected path actually exists.
    private func pasteDir(_ connection: SSHConnection) async -> String {
        if let dir = resolvedPasteDir { return dir }
        let home = (try? await connection.remoteHome()) ?? "."
        let dir = "\(home)/.humibeam/pastes"
        resolvedPasteDir = dir
        return dir
    }

    private func uploadAll(_ images: [Data], via controller: TerminalSessionController) async {
        guard let connection = controller.connection else { return }
        let dir = await pasteDir(connection)
        for png in images {
            counter += 1
            let stamp = Int(Date().timeIntervalSince1970)
            let name = "paste-\(stamp)-\(counter).png"
            let remotePath = "\(dir)/\(name)"
            controller.onStatus?("lade Screenshot hoch (\(png.count / 1024) KB)…")
            do {
                try await connection.upload(png, to: remotePath)
                // Inject the bare absolute path (M0: this triggers Claude Code's Read tool) + trailing space.
                controller.sendToShell(remotePath + " ")
                controller.onStatus?("Screenshot eingefügt: \(name)")
            } catch {
                controller.onStatus?("Upload fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Clipboard image extraction

    private func imagesOnPasteboard() -> [Data]? {
        let pb = NSPasteboard.general

        // Fast path: raw PNG already on the clipboard.
        if let png = pb.data(forType: .png) {
            return [png]
        }

        // Image objects (covers TIFF screenshots, copied images, image file URLs).
        guard pb.canReadObject(forClasses: [NSImage.self], options: nil),
              let objects = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              !objects.isEmpty else {
            return nil
        }
        let pngs = objects.compactMap { pngData(from: $0) }
        return pngs.isEmpty ? nil : pngs
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
