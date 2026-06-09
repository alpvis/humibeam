import Cocoa
import Observation

enum HotkeyMode: String, Codable, CaseIterable, Identifiable {
    case hold    // Tasten halten = aufnehmen, loslassen = stoppen
    case toggle  // Einmal drücken = starten, nochmal/Escape = stoppen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hold: return "Halten"
        case .toggle: return "Drücken"
        }
    }

    var description: String {
        switch self {
        case .hold: return "Tasten halten zum Aufnehmen, loslassen zum Stoppen"
        case .toggle: return "Einmal drücken zum Starten, nochmal oder Escape zum Stoppen"
        }
    }
}

enum HotkeyEvent {
    case down(WorkflowType)  // Keys pressed
    case up(WorkflowType)    // Keys released (for hold mode)
    case cancel              // Escape pressed
}

@Observable
@MainActor
final class HotkeyService {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?
    private var activeCombo: WorkflowType?  // Which combo is currently held

    var onHotkeyEvent: ((HotkeyEvent) -> Void)?

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
            }
            return event
        }
        // Escape key monitor for toggle mode
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                if event.keyCode == 53 { // Escape
                    self?.handleEscape()
                }
            }
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        globalMonitor = nil
        localMonitor = nil
        keyMonitor = nil
    }

    private func handleFlags(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection([.control, .option, .shift, .command])

        // Basis: Control + Option (statt fn — fn wird von externen Tastaturen
        // wie der Logitech MX Keys S nicht als Modifier an macOS gemeldet).
        // Spezifischste Kombi zuerst pruefen.

        // Ctrl + Option + Shift + Command -> Emoji
        if flags == [.control, .option, .shift, .command] {
            if activeCombo == nil {
                activeCombo = .emojiText
                onHotkeyEvent?(.down(.emojiText))
            }
            return
        }

        // Ctrl + Option + Command -> woertliche Transkription (roh)
        if flags == [.control, .option, .command] {
            if activeCombo == nil {
                activeCombo = .transcription
                onHotkeyEvent?(.down(.transcription))
            }
            return
        }

        // Ctrl + Option + Shift -> lokales Diktat
        if flags == [.control, .option, .shift] {
            if activeCombo == nil {
                activeCombo = .localTranscription
                onHotkeyEvent?(.down(.localTranscription))
            }
            return
        }

        // Ctrl + Option -> Diktat (umformuliert/poliert, Haupt-Hotkey)
        if flags == [.control, .option] {
            if activeCombo == nil {
                activeCombo = .textImprover
                onHotkeyEvent?(.down(.textImprover))
            }
            return
        }

        // Keys released -- fire up event
        if let combo = activeCombo {
            activeCombo = nil
            onHotkeyEvent?(.up(combo))
        }
    }

    private func handleEscape() {
        activeCombo = nil
        onHotkeyEvent?(.cancel)
    }
}
