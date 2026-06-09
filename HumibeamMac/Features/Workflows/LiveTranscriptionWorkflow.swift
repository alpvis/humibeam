import Foundation
import Observation
import WhisperKit

/// Echte Live-Mitschrift: zeigt den Text wortweise waehrend des Sprechens (lokal, WhisperKit-Streaming).
@Observable
@MainActor
final class LiveTranscriptionWorkflow: Workflow {
    let type = WorkflowType.localTranscription
    var phase: WorkflowPhase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    var onOutput: WorkflowOutputHandler?
    var onPhaseChange: WorkflowPhaseChangeHandler?

    private(set) var liveText: String = ""

    private let modelName: String
    private let language: String
    private var transcriber: AudioStreamTranscriber?
    private var streamTask: Task<Void, Never>?
    private var recording = false

    var isRecording: Bool { recording }

    init(modelName: String, language: String = "de") {
        self.modelName = modelName
        self.language = language
    }

    func start() {
        guard !recording else { return }
        recording = true
        liveText = ""
        phase = .running("H\u{00F6}re zu \u{2026}")

        let model = modelName
        let lang = language

        streamTask = Task { [weak self] in
            do {
                let transcriber = try await LocalTranscriptionService.shared.makeLiveTranscriber(
                    modelName: model,
                    language: lang
                ) { _, newState in
                    let text = (newState.confirmedSegments + newState.unconfirmedSegments)
                        .map { $0.text }
                        .joined(separator: " ")
                    Task { @MainActor [weak self] in
                        self?.applyLiveText(text)
                    }
                }
                self?.transcriber = transcriber
                try await transcriber.startStreamTranscription()
            } catch {
                self?.phase = .error("Live-Mitschrift fehlgeschlagen: \(error.localizedDescription)")
                self?.recording = false
            }
        }
    }

    private func applyLiveText(_ text: String) {
        let cleaned = text
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        liveText = cleaned
    }

    func stop() {
        guard recording else { return }
        recording = false
        phase = .running("Verarbeite \u{2026}")
        let current = transcriber
        Task { [weak self] in
            await current?.stopStreamTranscription()
            self?.streamTask?.cancel()
            guard let self else { return }
            let final = TranscriptionQualityService.cleanedTranscript(self.liveText)
            if final.isEmpty {
                self.phase = .error("Keine Aufnahme erkannt.")
            } else {
                self.phase = .done(final)
                self.onOutput?(final)
            }
        }
    }

    func reset() {
        recording = false
        streamTask?.cancel()
        let current = transcriber
        transcriber = nil
        Task { await current?.stopStreamTranscription() }
        liveText = ""
        phase = .idle
    }
}
