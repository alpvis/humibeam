import Foundation
import CoreGraphics

/// Eingabe-Ereignis vom Supporter-Browser — exakt die JSON-Struktur, die site/support/app.js
/// über den WebRTC-Daten-Kanal schickt (gespiegelt aus HumibeamMac BeamInput).
struct RemoteInput: Codable {
    enum Kind: String, Codable {
        case move, click, rightClick, doubleClick, dragStart, dragMove, dragEnd
        case scroll, text, key
    }
    var kind: Kind
    var x: Double = 0
    var y: Double = 0
    var dx: Double = 0
    var dy: Double = 0
    var text: String?
    var keyName: String?
    var command = false
    var option = false
    var controlKey = false
    var shift = false
}

/// Führt RemoteInput als CGEvents aus (braucht Bedienungshilfen-Berechtigung). Koordinaten
/// kommen normalisiert 0…1 und werden auf die Bildschirmgröße skaliert.
@MainActor
final class RemoteInputInjector {
    /// Pixelgröße des aufgenommenen Displays — vom Capture gesetzt.
    var screenSize = CGSize(width: 1, height: 1)
    private var dragging = false

    func handle(_ input: RemoteInput) {
        let point = CGPoint(x: input.x * screenSize.width, y: input.y * screenSize.height)
        switch input.kind {
        case .move:
            post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                         mouseCursorPosition: point, mouseButton: .left))
        case .click:
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                         mouseCursorPosition: point, mouseButton: .left))
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left))
        case .doubleClick:
            for _ in 0..<2 {
                let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                   mouseCursorPosition: point, mouseButton: .left)
                down?.setIntegerValueField(.mouseEventClickState, value: 2); post(down)
                let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                 mouseCursorPosition: point, mouseButton: .left)
                up?.setIntegerValueField(.mouseEventClickState, value: 2); post(up)
            }
        case .rightClick:
            post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
                         mouseCursorPosition: point, mouseButton: .right))
            post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp,
                         mouseCursorPosition: point, mouseButton: .right))
        case .dragStart:
            dragging = true
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                         mouseCursorPosition: point, mouseButton: .left))
        case .dragMove:
            let type: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
            post(CGEvent(mouseEventSource: nil, mouseType: type,
                         mouseCursorPosition: point, mouseButton: .left))
        case .dragEnd:
            dragging = false
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left))
        case .scroll:
            post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                         wheel1: Int32(input.dy), wheel2: Int32(input.dx), wheel3: 0))
        case .text:
            guard let text = input.text else { return }
            for char in text.unicodeScalars {
                var utf16 = Array(String(char).utf16)
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
                down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16); post(down)
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
                up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16); post(up)
            }
        case .key:
            guard let name = input.keyName, let code = Self.keyCodes[name] else { return }
            var flags: CGEventFlags = []
            if input.command { flags.insert(.maskCommand) }
            if input.option { flags.insert(.maskAlternate) }
            if input.controlKey { flags.insert(.maskControl) }
            if input.shift { flags.insert(.maskShift) }
            let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
            down?.flags = flags; post(down)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
            up?.flags = flags; post(up)
        }
    }

    private func post(_ event: CGEvent?) { event?.post(tap: .cghidEventTap) }

    private static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "backspace": 51, "esc": 53, "tab": 48, "space": 49,
        "up": 126, "down": 125, "left": 123, "right": 124, "delete": 117, "home": 115, "end": 119,
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38,
        "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17,
        "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    ]
}
