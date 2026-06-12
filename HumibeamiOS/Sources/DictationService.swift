import Foundation
import AVFoundation
import UIKit

/// Sprach-Diktat fürs iPhone/iPad: aufnehmen → OpenAI Whisper → Text ins Terminal.
/// Der OpenAI-Key kommt aus dem Keychain (gleicher KeychainService wie am Mac).
extension Notification.Name {
    /// Diktat-Fehler → TerminalScreen zeigt einen Alert (die Tastenleiste hat keine eigene UI dafür).
    static let dictationFailed = Notification.Name("dictationFailed")
}

@MainActor
final class DictationService: NSObject {
    static let shared = DictationService()

    enum DictationError: LocalizedError {
        case noAPIKey, noPermission, recordingFailed, transcriptionFailed(String)
        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "Kein OpenAI API Key hinterlegt. In der Serverliste oben rechts → Einstellungen."
            case .noPermission: return "Mikrofon-Zugriff wurde nicht erlaubt (Einstellungen → Humibeam)."
            case .recordingFailed: return "Aufnahme fehlgeschlagen."
            case .transcriptionFailed(let detail): return "Transkription fehlgeschlagen: \(detail)"
            }
        }
    }

    private(set) var isRecording = false
    var onStateChange: ((Bool) -> Void)?

    private var recorder: AVAudioRecorder?
    private var fileURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dictation.m4a")
    }

    /// Erster Tap: Aufnahme starten. Zweiter Tap: stoppen, transkribieren, Text liefern.
    func toggle(completion: @escaping (Result<String, Error>) -> Void) {
        if isRecording { stopAndTranscribe(completion: completion) } else { start(completion: completion) }
    }

    private func start(completion: @escaping (Result<String, Error>) -> Void) {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else { completion(.failure(DictationError.noPermission)); return }
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.record, mode: .measurement)
                try? session.setActive(true)
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 16000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                ]
                guard let rec = try? AVAudioRecorder(url: self.fileURL, settings: settings), rec.record() else {
                    completion(.failure(DictationError.recordingFailed)); return
                }
                self.recorder = rec
                self.isRecording = true
                self.onStateChange?(true)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    private func stopAndTranscribe(completion: @escaping (Result<String, Error>) -> Void) {
        recorder?.stop()
        recorder = nil
        isRecording = false
        onStateChange?(false)
        try? AVAudioSession.sharedInstance().setActive(false)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        guard let apiKey = KeychainService.load(key: .openAIAPIKey), !apiKey.isEmpty else {
            completion(.failure(DictationError.noAPIKey)); return
        }
        guard let audio = try? Data(contentsOf: fileURL), audio.count > 1000 else {
            completion(.failure(DictationError.recordingFailed)); return
        }

        Task {
            do {
                let text = try await Self.transcribe(audio: audio, apiKey: apiKey)
                completion(.success(text))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func transcribe(audio: Data, apiKey: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = "humibeam-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", "whisper-1")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.m4a\"\r\nContent-Type: audio/m4a\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP-Fehler"
            throw DictationError.transcriptionFailed(String(detail.prefix(200)))
        }
        struct WhisperResponse: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
