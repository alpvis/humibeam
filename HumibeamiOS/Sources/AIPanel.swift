import SwiftUI

/// KI-Werkzeuge (Parität zur Mac-Welle 3): Ausgabe erklären · Fehler beheben ·
/// Befehl vorschlagen. Nutzt den geteilten LLMService mit dem OpenAI-Key aus dem Keychain.
@MainActor
final class AIPanelModel: ObservableObject {
    @Published var title = ""
    @Published var result = ""
    @Published var busy = false

    private func transcript(_ controller: TerminalController) -> String {
        String(controller.transcript.suffix(5000))
    }

    func explain(_ controller: TerminalController) async {
        await run(title: "Ausgabe erklärt",
                  system: "Du bist ein erfahrener Linux/DevOps-Assistent. Erkläre dem Nutzer knapp und klar auf Deutsch, was die folgende Terminal-Ausgabe bedeutet. Wenn Fehler oder Warnungen sichtbar sind, nenne die wahrscheinliche Ursache und einen konkreten nächsten Schritt. Kein Markdown-Code-Block, nur Fließtext.",
                  user: "Terminal-Ausgabe:\n\n\(transcript(controller))")
    }

    func fix(_ controller: TerminalController) async {
        await run(title: "Lösungsvorschlag",
                  system: "Du bist ein Linux/DevOps-Assistent. Analysiere die folgende Terminal-Ausgabe auf Fehler. Gib auf Deutsch (1) die Ursache in einem Satz und (2) einen konkreten Befehl oder Schritt zur Behebung. Knapp.",
                  user: "Terminal-Ausgabe:\n\n\(transcript(controller))")
    }

    /// Schlägt einen Befehl vor und tippt ihn (ohne Enter) ins Terminal.
    func suggest(_ controller: TerminalController, intent: String) async {
        guard !intent.isEmpty else { return }
        title = "Befehlsvorschlag"; busy = true; result = ""
        defer { busy = false }
        do {
            let cmd = try await LLMService.ask(
                system: "Gib AUSSCHLIESSLICH einen einzelnen Shell-Befehl für Linux/Ubuntu zurück, der das Ziel erfüllt. Keine Erklärung, kein Markdown, keine Anführungszeichen, kein führendes $.",
                user: "Ziel: \(intent)\n\nKontext (letzte Terminal-Ausgabe):\n\(transcript(controller))")
            let clean = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            result = clean
            if controller.isConnected { controller.sendToShell(clean) }
        } catch {
            result = "Fehler: \(error.localizedDescription)"
        }
    }

    private func run(title: String, system: String, user: String) async {
        self.title = title; busy = true; result = ""
        defer { busy = false }
        do { result = try await LLMService.ask(system: system, user: user, model: .rageMode, temperature: 0.2) }
        catch { result = "Fehler: \(error.localizedDescription)" }
    }
}

struct AIPanelSheet: View {
    @ObservedObject var panel: AIPanelModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if panel.busy {
                    ProgressView("Denke nach…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    Text(panel.result.isEmpty ? "—" : panel.result)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle(panel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = panel.result
                    } label: { Image(systemName: "doc.on.doc") }
                        .disabled(panel.result.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
