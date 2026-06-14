import AppKit

/// Color scheme for the terminal (foreground / background / caret).
struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let foreground: NSColor
    let background: NSColor
    let caret: NSColor

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(calibratedRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
    }

    /// Whether the terminal background reads as dark — drives the whole window chrome
    /// (titlebar, sidebar, bars) so chrome and terminal form one surface.
    var isDark: Bool {
        let c = background.usingColorSpace(.sRGB) ?? background
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance < 0.5
    }

    /// Bar color (session toolbar / status bar): the terminal background, lifted a touch for depth.
    var chrome: NSColor {
        let base = background.usingColorSpace(.sRGB) ?? background
        return (isDark ? base.blended(withFraction: 0.08, of: .white)
                       : base.blended(withFraction: 0.05, of: .black)) ?? base
    }

    static let system = TerminalTheme(
        id: "system", name: "System",
        foreground: .textColor, background: .textBackgroundColor, caret: .selectedControlColor)

    static let midnight = TerminalTheme(
        id: "midnight", name: "Mitternacht",
        foreground: rgb(220, 223, 228), background: rgb(13, 17, 23), caret: rgb(88, 166, 255))

    static let solarizedDark = TerminalTheme(
        id: "solarized", name: "Solarized Dark",
        foreground: rgb(131, 148, 150), background: rgb(0, 43, 54), caret: rgb(38, 139, 210))

    static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula",
        foreground: rgb(248, 248, 242), background: rgb(40, 42, 54), caret: rgb(255, 121, 198))

    static let beam = TerminalTheme(
        id: "beam", name: "humibeam",
        foreground: rgb(233, 238, 255), background: rgb(18, 16, 38), caret: rgb(0, 209, 255))

    static let black = TerminalTheme(
        id: "black", name: "Schwarz",
        foreground: rgb(235, 235, 235), background: .black, caret: rgb(0, 209, 255))

    static let light = TerminalTheme(
        id: "light", name: "Hell",
        foreground: rgb(40, 42, 54), background: rgb(253, 253, 250), caret: rgb(91, 43, 224))

    static let all: [TerminalTheme] = [black, beam, system, midnight, solarizedDark, dracula, light]

    /// Vom Nutzer angelegte Themes — zur Laufzeit aus dem CustomThemeStore gefüllt.
    static var custom: [TerminalTheme] = []

    /// Alle wählbaren Themes (eingebaut + eigene).
    static var selectable: [TerminalTheme] { all + custom }

    static func by(id: String) -> TerminalTheme { selectable.first { $0.id == id } ?? system }

    // MARK: - Hex ⇄ NSColor (sRGB) — für eigene Themes & Import.

    static func color(hex: String) -> NSColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return .black }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                       green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
