import Foundation

// MARK: - Workflow Types

enum WorkflowType: String, CaseIterable, Identifiable, Codable {
    case transcription
    case localTranscription
    case textImprover
    case dampfAblassen
    case emojiText

    var id: String { rawValue }

    static var mainMenuCases: [WorkflowType] {
        allCases.filter { $0 != .localTranscription }
    }

    var displayName: String {
        switch self {
        case .transcription: return "Humibeam"
        case .localTranscription: return "Humibeam Lokal"
        case .textImprover: return "Humibeam+"
        case .dampfAblassen: return "Humibeam $%&!"
        case .emojiText: return "Humibeam :)"
        }
    }

    var icon: String {
        switch self {
        case .transcription: return "mic.fill"
        case .localTranscription: return "lock.shield.fill"
        case .textImprover: return "text.badge.checkmark"
        case .dampfAblassen: return "flame.fill"
        case .emojiText: return "face.smiling"
        }
    }

    var subtitle: String {
        switch self {
        case .transcription: return "Sprache rein. Text raus."
        case .localTranscription: return "Nur lokal. Kein Server."
        case .textImprover: return "Geschrieben sprechen."
        case .dampfAblassen: return "Frust rein. Entspannt raus."
        case .emojiText: return "Text rein. Emojis dazu."
        }
    }

    var hotkeyLabel: String {
        switch self {
        case .transcription: return "Ctrl + Option + Cmd"
        case .localTranscription: return "Ctrl + Option + Shift"
        case .textImprover: return "Ctrl + Option"
        case .dampfAblassen: return "nur Men\u{00FC}"
        case .emojiText: return "Ctrl + Option + Shift + Cmd"
        }
    }

    var accentColor: String {
        switch self {
        case .transcription: return "blue"
        case .localTranscription: return "green"
        case .textImprover: return "purple"
        case .dampfAblassen: return "orange"
        case .emojiText: return "cyan"
        }
    }
}

// MARK: - Workflow State

enum WorkflowPhase: Equatable {
    case idle
    case running(String)
    case done(String)
    case error(String)

    var isActive: Bool {
        switch self {
        case .idle: return false
        default: return true
        }
    }
}

enum WorkflowLaunchSource: Equatable {
    case manual
    case hotkeyBackground

    var presentsWorkflowPage: Bool {
        switch self {
        case .manual:
            return true
        case .hotkeyBackground:
            return false
        }
    }
}

typealias WorkflowOutputHandler = @MainActor (String) -> Void
typealias WorkflowPhaseChangeHandler = @MainActor (WorkflowPhase) -> Void

// MARK: - Workflow Protocol

@MainActor
protocol Workflow: AnyObject, Observable {
    var type: WorkflowType { get }
    var phase: WorkflowPhase { get set }
    var isRecording: Bool { get }
    var onOutput: WorkflowOutputHandler? { get set }
    var onPhaseChange: WorkflowPhaseChangeHandler? { get set }

    func start()
    func stop()
    func reset()
}

// MARK: - Prompt Profiles (umschaltbare Diktat-Stile)

struct PromptProfile: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var icon: String
    var prompt: String
    var smart: Bool = false

    enum CodingKeys: String, CodingKey { case id, name, icon, prompt, smart }

    init(id: String, name: String, icon: String, prompt: String, smart: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.prompt = prompt
        self.smart = smart
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "text.bubble"
        prompt = try c.decode(String.self, forKey: .prompt)
        smart = try c.decodeIfPresent(Bool.self, forKey: .smart) ?? false
    }

    static var defaults: [PromptProfile] {
        [
            PromptProfile(
                id: "nachricht",
                name: "Nachricht",
                icon: "text.bubble",
                prompt: "Transkribiere meine Sprache nicht wortwörtlich. Verstehe zuerst den Inhalt und formuliere daraus eine grammatikalisch korrekte, natürliche und gut lesbare deutsche Nachricht. Korrigiere Satzbau, Grammatik, Rechtschreibung und Zeichensetzung. Entferne unnötige Füllwörter und Wiederholungen. Der Sinn meiner Aussage muss gleich bleiben. Gib ausschließlich den fertigen Text aus, ohne Erklärung, ohne Überschrift und ohne Alternativen."
            ),
            PromptProfile(
                id: "aktion",
                name: "Aktion",
                icon: "wand.and.rays",
                prompt: "Behandle meine gesprochene Eingabe als Anweisung, nicht als Text zum Abtippen. Verstehe die Absicht und führe sie aus: Liefere das fertige, einsatzbereite Ergebnis auf Deutsch. Beispiele: \"Antworte X, dass …\" → schreibe die vollständige Nachricht oder E-Mail mit Anrede und Gruß. \"Fasse zusammen …\" → liefere die Zusammenfassung. \"Mach eine Liste …\" → liefere die Liste. Stelle keine Rückfragen. Gib ausschließlich das fertige Ergebnis aus, ohne Erklärung und ohne Einleitung.",
                smart: true
            ),
            PromptProfile(
                id: "email",
                name: "E-Mail formell",
                icon: "envelope",
                prompt: "Formuliere aus meiner gesprochenen Eingabe eine professionelle, höfliche deutsche E-Mail. Verwende eine passende Anrede und Grußformel, einen klaren Aufbau und fehlerfreie Grammatik, Rechtschreibung und Zeichensetzung. Bleibe sachlich und freundlich. Gib ausschließlich den fertigen E-Mail-Text aus, ohne Betreffzeile, ohne Erklärung und ohne Alternativen."
            ),
            PromptProfile(
                id: "whatsapp",
                name: "WhatsApp",
                icon: "message",
                prompt: "Formuliere aus meiner Eingabe eine kurze, lockere und natürliche Nachricht wie für WhatsApp. Nutze die Du-Form, freundlich und knapp, mit korrekter Rechtschreibung und passenden Satzzeichen. Ein passendes Emoji ist erlaubt, aber sparsam. Gib ausschließlich die fertige Nachricht aus."
            ),
            PromptProfile(
                id: "stichpunkte",
                name: "Stichpunkte",
                icon: "list.bullet",
                prompt: "Fasse meine gesprochene Eingabe in klaren, knappen deutschen Stichpunkten zusammen. Jeder Punkt steht in einer eigenen Zeile und beginnt mit \"- \". Nur das Wesentliche, korrekte Rechtschreibung. Gib ausschließlich die Stichpunkte aus, ohne Einleitung und ohne Erklärung."
            )
        ]
    }
}

// MARK: - App Settings

struct AppSettings: Codable {
    var hotkeyMode: HotkeyMode = .hold
    var hasSeenOnboarding: Bool = false
    var secureLocalModeEnabled: Bool = false
    var selectedLocalTranscriptionModelName: String = LocalTranscriptionService.recommendedFastModelName
    var hasAutoSelectedFastLocalModel: Bool = false
    var soundFeedbackEnabled: Bool = true
    var promptProfiles: [PromptProfile] = PromptProfile.defaults
    var selectedProfileID: String = "nachricht"
    var liveTranscriptionEnabled: Bool = false

    init(
        hotkeyMode: HotkeyMode = .hold,
        hasSeenOnboarding: Bool = false,
        secureLocalModeEnabled: Bool = false,
        selectedLocalTranscriptionModelName: String = LocalTranscriptionService.recommendedFastModelName,
        hasAutoSelectedFastLocalModel: Bool = false,
        soundFeedbackEnabled: Bool = true,
        promptProfiles: [PromptProfile] = PromptProfile.defaults,
        selectedProfileID: String = "nachricht",
        liveTranscriptionEnabled: Bool = false
    ) {
        self.hotkeyMode = hotkeyMode
        self.hasSeenOnboarding = hasSeenOnboarding
        self.secureLocalModeEnabled = secureLocalModeEnabled
        self.selectedLocalTranscriptionModelName = selectedLocalTranscriptionModelName
        self.hasAutoSelectedFastLocalModel = hasAutoSelectedFastLocalModel
        self.soundFeedbackEnabled = soundFeedbackEnabled
        self.promptProfiles = promptProfiles
        self.selectedProfileID = selectedProfileID
        self.liveTranscriptionEnabled = liveTranscriptionEnabled
    }

    enum CodingKeys: String, CodingKey {
        case hotkeyMode
        case hasSeenOnboarding
        case secureLocalModeEnabled
        case selectedLocalTranscriptionModelName
        case hasAutoSelectedFastLocalModel
        case soundFeedbackEnabled
        case promptProfiles
        case selectedProfileID
        case liveTranscriptionEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkeyMode = try container.decodeIfPresent(HotkeyMode.self, forKey: .hotkeyMode) ?? .hold
        hasSeenOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasSeenOnboarding) ?? false
        secureLocalModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .secureLocalModeEnabled) ?? false
        selectedLocalTranscriptionModelName = try container.decodeIfPresent(
            String.self,
            forKey: .selectedLocalTranscriptionModelName
        ) ?? LocalTranscriptionService.recommendedFastModelName
        hasAutoSelectedFastLocalModel = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasAutoSelectedFastLocalModel
        ) ?? false
        soundFeedbackEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundFeedbackEnabled) ?? true
        let decodedProfiles = try container.decodeIfPresent([PromptProfile].self, forKey: .promptProfiles) ?? []
        promptProfiles = decodedProfiles.isEmpty ? PromptProfile.defaults : decodedProfiles
        selectedProfileID = try container.decodeIfPresent(String.self, forKey: .selectedProfileID) ?? "nachricht"
        liveTranscriptionEnabled = try container.decodeIfPresent(Bool.self, forKey: .liveTranscriptionEnabled) ?? false
    }
}

enum TranscriptionBackend: String, Codable {
    case remote
    case local
}

// MARK: - Workflow Settings

struct TranscriptionSettings: Codable {
    var language: String = "de"
}

struct DampfAblassenSettings: Codable {
    var systemPrompt: String = "Du erhältst ein emotional gesprochenes Transkript. Erkenne zuerst das eigentliche Ziel, Anliegen und den wahren Frust der Person. Formuliere daraus eine klare, respektvolle und wirksame Nachricht, mit der die Person ihr Ziel eher erreicht. Bewahre relevante Fakten, konkrete Probleme, Grenzen, Erwartungen und die nötige Dringlichkeit. Entferne Beleidigungen, Drohungen, Sarkasmus, Unterstellungen und unnötige Eskalation. Wenn mehrere Vorwürfe genannt werden, verdichte sie auf die entscheidenden Kernpunkte. Der Ton soll ruhig, menschlich, bestimmt und lösungsorientiert sein. Gib NUR die fertige Nachricht zurück."
    var customName: String = ""
}

struct EmojiTextSettings: Codable {
    var emojiDensity: EmojiDensity = .mittel
    var customName: String = ""

    enum EmojiDensity: String, Codable, CaseIterable, Identifiable {
        case wenig
        case mittel
        case viel

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .wenig: return "Wenig"
            case .mittel: return "Mittel"
            case .viel: return "Viel"
            }
        }
    }
}

struct TextImprovementSettings: Codable {
    var systemPrompt: String = ""
    var customTerms: [String] = []
    var context: String = ""
    var tone: TextTone = .neutral
    var customName: String = ""

    enum TextTone: String, Codable, CaseIterable, Identifiable {
        case formal
        case neutral
        case casual

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .formal: return "Formell"
            case .neutral: return "Neutral"
            case .casual: return "Locker"
            }
        }
    }
}
