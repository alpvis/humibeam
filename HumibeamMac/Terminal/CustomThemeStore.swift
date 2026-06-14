import AppKit
import Observation

/// Codable-Definition eines eigenen Terminal-Themes. Farben als Hex (#rrggbb),
/// da NSColor nicht Codable ist. Wird in eine `TerminalTheme` umgewandelt.
struct CustomThemeDef: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var fg: String
    var bg: String
    var caret: String

    init(id: String? = nil, name: String = "Mein Theme",
         fg: String = "#E9EEFF", bg: String = "#12100F", caret: String = "#00D1FF") {
        self.id = id ?? "custom-\(UUID().uuidString.prefix(8))"
        self.name = name
        self.fg = fg
        self.bg = bg
        self.caret = caret
    }

    var theme: TerminalTheme {
        TerminalTheme(id: id, name: name,
                      foreground: TerminalTheme.color(hex: fg),
                      background: TerminalTheme.color(hex: bg),
                      caret: TerminalTheme.color(hex: caret))
    }
}

/// Speichert die eigenen Themes (themes.json) und hält die Laufzeit-Registry
/// `TerminalTheme.custom` aktuell, damit Auswahl/Anwendung sie kennen.
@Observable
@MainActor
final class CustomThemeStore {
    var themes: [CustomThemeDef] {
        didSet { save(); refreshRegistry(); onChanged?() }
    }
    @ObservationIgnored var onChanged: (() -> Void)?

    private static var fileURL: URL {
        let dir = AppSupportPaths.appSupportDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("themes.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let list = try? JSONDecoder().decode([CustomThemeDef].self, from: data) {
            themes = list
        } else {
            themes = []
        }
        refreshRegistry()
    }

    func add(_ d: CustomThemeDef) { themes.append(d) }
    func delete(_ d: CustomThemeDef) { themes.removeAll { $0.id == d.id } }
    func update(_ d: CustomThemeDef) {
        if let i = themes.firstIndex(where: { $0.id == d.id }) { themes[i] = d }
    }

    private func refreshRegistry() { TerminalTheme.custom = themes.map(\.theme) }

    private func save() {
        if let data = try? JSONEncoder().encode(themes) { try? data.write(to: Self.fileURL) }
    }

    // MARK: - Import: iTerm2 `.itermcolors` (XML-Plist mit sRGB-Komponenten 0…1).

    /// Parst eine iTerm2-Farbdatei in ein eigenes Theme. Nimmt Foreground/Background/Cursor.
    static func importITerm(url: URL) throws -> CustomThemeDef {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ImportError.format
        }
        func color(_ key: String, fallback: String) -> String {
            guard let c = plist[key] as? [String: Any] else { return fallback }
            let r = (c["Red Component"] as? Double) ?? 0
            let g = (c["Green Component"] as? Double) ?? 0
            let b = (c["Blue Component"] as? Double) ?? 0
            return String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
        }
        let name = url.deletingPathExtension().lastPathComponent
        return CustomThemeDef(
            name: name,
            fg: color("Foreground Color", fallback: "#E9EEFF"),
            bg: color("Background Color", fallback: "#12100F"),
            caret: color("Cursor Color", fallback: "#00D1FF"))
    }

    enum ImportError: LocalizedError {
        case format
        var errorDescription: String? { "Datei ist kein gültiges iTerm2-Farbschema (.itermcolors)." }
    }
}
