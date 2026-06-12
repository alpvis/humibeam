import AppIntents
import Foundation

/// Siri/Kurzbefehle: „Führe Snippet X auf Server Y aus" und „Wie geht's meinen Servern?"

struct RunSnippetIntent: AppIntent {
    static let title: LocalizedStringResource = "Snippet ausführen"
    static let description = IntentDescription("Tippt ein gespeichertes Snippet in eine Server-Sitzung.")
    static let openAppWhenRun = true

    @Parameter(title: "Snippet") var snippetTitle: String
    @Parameter(title: "Server") var serverName: String

    static var parameterSummary: some ParameterSummary {
        Summary("Führe \(\.$snippetTitle) auf \(\.$serverName) aus")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared else {
            return .result(dialog: "humibeam ist noch nicht bereit — bitte App öffnen.")
        }
        let sTitle = snippetTitle.lowercased()
        let hName = serverName.lowercased()
        guard let snippet = model.snippets.snippets.first(where: { $0.title.lowercased().contains(sTitle) }) else {
            return .result(dialog: "Snippet \(snippetTitle) nicht gefunden.")
        }
        guard let host = model.hostStore.hosts.first(where: {
            $0.displayName.lowercased().contains(hName) || $0.host.lowercased().contains(hName)
        }) else {
            return .result(dialog: "Server \(serverName) nicht gefunden.")
        }
        guard snippet.placeholders.isEmpty else {
            return .result(dialog: "\(snippet.title) braucht Platzhalter-Werte — bitte in der App ausfüllen.")
        }
        let session = model.primarySession(for: host)
        if !session.controller.isConnected && session.controller.connection == nil {
            model.connect(session)
            // Verbindung braucht einen Moment — Snippet folgt, sobald die Shell steht.
            let command = snippet.command
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                session.controller.sendToShell(command)
            }
        } else {
            session.controller.sendToShell(snippet.command)
        }
        model.requestedSessionID = session.id
        return .result(dialog: "\(snippet.title) auf \(host.displayName) getippt.")
    }
}

struct ServerStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Server-Status"
    static let description = IntentDescription("Letzter bekannter Zustand deiner Server und offene Claude-Freigaben.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snapshot = StatusSnapshot.load() else {
            return .result(dialog: "Noch keine Daten — öffne humibeam einmal.")
        }
        return .result(dialog: IntentDialog(stringLiteral: snapshot.summaryText))
    }
}

struct HumibeamShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ServerStatusIntent(),
                    phrases: ["Wie geht es meinen Servern in \(.applicationName)",
                              "\(.applicationName) Server-Status"],
                    shortTitle: "Server-Status",
                    systemImageName: "server.rack")
        AppShortcut(intent: RunSnippetIntent(),
                    phrases: ["Führe ein Snippet in \(.applicationName) aus"],
                    shortTitle: "Snippet ausführen",
                    systemImageName: "curlybraces")
    }
}
