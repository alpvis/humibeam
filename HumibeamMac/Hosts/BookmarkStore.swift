import Foundation
import Observation

struct PathBookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var label: String
    var path: String
}

/// Quick remote-path bookmarks for the file browser.
@Observable
@MainActor
final class BookmarkStore {
    var bookmarks: [PathBookmark] { didSet { save() } }

    private static var fileURL: URL {
        let dir = AppSupportPaths.appSupportDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bookmarks.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let list = try? JSONDecoder().decode([PathBookmark].self, from: data) {
            bookmarks = list
        } else {
            bookmarks = []
        }
    }

    func add(path: String) {
        let label = (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
        guard !bookmarks.contains(where: { $0.path == path }) else { return }
        bookmarks.append(PathBookmark(label: label, path: path))
    }

    func delete(_ b: PathBookmark) { bookmarks.removeAll { $0.id == b.id } }

    private func save() {
        if let data = try? JSONEncoder().encode(bookmarks) { try? data.write(to: Self.fileURL) }
    }
}
