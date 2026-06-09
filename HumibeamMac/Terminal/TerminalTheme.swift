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

    static func by(id: String) -> TerminalTheme { all.first { $0.id == id } ?? system }
}
