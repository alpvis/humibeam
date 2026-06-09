import SwiftUI
import AppKit
import Observation

// MARK: - Sound Feedback (Feature 6)

enum SoundService {
    static func play(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }
    static func recordStart() { play("Pop") }
    static func recordStop() { play("Tink") }
    static func done() { play("Glass") }
    static func failure() { play("Basso") }
}

// MARK: - History (Feature 1)

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var date: Date
    var text: String
    var workflowRaw: String

    var workflow: WorkflowType? { WorkflowType(rawValue: workflowRaw) }
}

@Observable
@MainActor
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []
    private let maxEntries = 30
    private let url = AppSupportPaths.appSupportDirectoryURL.appendingPathComponent("history.json")

    init() { load() }

    func record(_ text: String, type: WorkflowType) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.insert(HistoryEntry(date: Date(), text: trimmed, workflowRaw: type.rawValue), at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        try? AppSupportPaths.ensureAppSupportDirectoryExists()
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url)
        }
    }
}

// MARK: - Usage / Cost Tracking (Feature 8)

@Observable
@MainActor
final class UsageTracker {
    private(set) var totalCount: Int = 0
    private(set) var todayCount: Int = 0
    private(set) var totalCharacters: Int = 0
    private var dayKey: String = ""

    // grobe Schaetzung pro Diktat (Whisper + GPT-4o-mini, kurzer Clip) in USD
    private let estPerDictationUSD = 0.0015
    private let url = AppSupportPaths.appSupportDirectoryURL.appendingPathComponent("usage.json")

    init() { load(); rolloverIfNeeded() }

    var estimatedTotalCostUSD: Double { Double(totalCount) * estPerDictationUSD }
    var estimatedTotalCostText: String {
        String(format: "ca. %.2f $", estimatedTotalCostUSD)
    }

    func recordDictation(characters: Int) {
        rolloverIfNeeded()
        totalCount += 1
        todayCount += 1
        totalCharacters += max(0, characters)
        save()
    }

    func reset() {
        totalCount = 0; todayCount = 0; totalCharacters = 0
        save()
    }

    private func currentDayKey() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    private func rolloverIfNeeded() {
        let today = currentDayKey()
        if dayKey != today {
            dayKey = today
            todayCount = 0
            save()
        }
    }

    private struct Snapshot: Codable {
        var totalCount: Int; var todayCount: Int; var totalCharacters: Int; var dayKey: String
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        totalCount = s.totalCount; todayCount = s.todayCount
        totalCharacters = s.totalCharacters; dayKey = s.dayKey
    }

    private func save() {
        try? AppSupportPaths.ensureAppSupportDirectoryExists()
        let s = Snapshot(totalCount: totalCount, todayCount: todayCount,
                         totalCharacters: totalCharacters, dayKey: dayKey)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: url)
        }
    }
}

// MARK: - Extras Page (Verlauf, Nutzung, Schnelleinstellungen)

struct ExtrasPageView: View {
    @Bindable var appState: AppState
    @State private var editingProfileID: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button {
                    appState.page = .main
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text("Zur\u{00FC}ck").font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(SubtleButtonStyle())
                Spacer()
                Text("Verlauf & Nutzung").font(.system(size: 12, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 52, height: 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    usageCard
                    updateSection
                    quickToggles
                    profilesSection
                    vocabularySection
                    historySection
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.humiqaIndigo).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Version \(appState.updater.currentVersion)")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.primary)
                    if let s = appState.updater.statusText {
                        Text(s).font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if appState.updater.isChecking {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Button("Pr\u{00FC}fen") {
                        Task { await appState.updater.check(silent: false) }
                    }
                    .font(.system(size: 10.5)).buttonStyle(SubtleButtonStyle())
                    .foregroundStyle(Color.humiqaIndigo)
                }
            }

            if let info = appState.updater.available {
                Button {
                    appState.updater.installAvailableUpdate()
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Update \(info.version) installieren").fontWeight(.semibold)
                    }
                    .font(.system(size: 11.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.humiqaIndigo.opacity(0.12)))
                    .foregroundStyle(Color.humiqaIndigo)
                }
                .buttonStyle(SubtleButtonStyle())
                .disabled(appState.updater.isInstalling)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    // MARK: Prompt-Profile (Feature 2)

    private var vocabularyBinding: Binding<String> {
        Binding(
            get: { appState.textImprovementSettings.customTerms.joined(separator: ", ") },
            set: { newValue in
                appState.textImprovementSettings.customTerms = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    @ViewBuilder
    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EIGENE BEGRIFFE").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
            Text("Komma-getrennt. Diese Namen/Begriffe werden immer korrekt geschrieben.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("IBELSA, Levante, Adyen, ...", text: vocabularyBinding, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
                .lineLimit(1...3)
        }
    }

    @ViewBuilder
    private var profilesSection: some View {
        HStack {
            Text("STIL-PROFILE").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Button {
                let new = PromptProfile(id: UUID().uuidString, name: "Neues Profil",
                                        icon: "sparkles", prompt: "")
                appState.appSettings.promptProfiles.append(new)
                editingProfileID = new.id
            } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 13))
            }
            .buttonStyle(SubtleButtonStyle()).foregroundStyle(Color.humiqaIndigo)
            .help("Profil hinzuf\u{00FC}gen")
        }

        VStack(spacing: 6) {
            ForEach(appState.appSettings.promptProfiles) { profile in
                profileRow(profile)
            }
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: PromptProfile) -> some View {
        let isActive = profile.id == appState.appSettings.selectedProfileID
        let isEditing = editingProfileID == profile.id
        let idx = appState.appSettings.promptProfiles.firstIndex { $0.id == profile.id }

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: profile.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isActive ? Color.humiqaIndigo : .secondary)
                    .frame(width: 16)
                Text(profile.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.primary)
                if isActive {
                    Text("aktiv").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.humiqaIndigo)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.humiqaIndigo.opacity(0.12)))
                }
                Spacer()
                if !isActive {
                    Button("W\u{00E4}hlen") { appState.appSettings.selectedProfileID = profile.id }
                        .font(.system(size: 10)).buttonStyle(SubtleButtonStyle())
                        .foregroundStyle(Color.humiqaIndigo)
                }
                Button {
                    editingProfileID = isEditing ? nil : profile.id
                } label: {
                    Image(systemName: isEditing ? "chevron.up" : "pencil").font(.system(size: 10.5))
                }
                .buttonStyle(SubtleButtonStyle()).foregroundStyle(.secondary)
            }

            if isEditing, let idx {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: Binding(
                        get: { appState.appSettings.promptProfiles[idx].name },
                        set: { appState.appSettings.promptProfiles[idx].name = $0 }
                    ))
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))

                    TextEditor(text: Binding(
                        get: { appState.appSettings.promptProfiles[idx].prompt },
                        set: { appState.appSettings.promptProfiles[idx].prompt = $0 }
                    ))
                    .font(.system(size: 11))
                    .frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))

                    Toggle(isOn: Binding(
                        get: { appState.appSettings.promptProfiles[idx].smart },
                        set: { appState.appSettings.promptProfiles[idx].smart = $0 }
                    )) {
                        Text("St\u{00E4}rkeres Modell (GPT-4o) \u{2013} besser f\u{00FC}r Aufgaben, etwas teurer")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .toggleStyle(.switch).controlSize(.mini)

                    if appState.appSettings.promptProfiles.count > 1 {
                        Button(role: .destructive) {
                            appState.appSettings.promptProfiles.removeAll { $0.id == profile.id }
                            if appState.appSettings.selectedProfileID == profile.id {
                                appState.appSettings.selectedProfileID =
                                    appState.appSettings.promptProfiles.first?.id ?? "nachricht"
                            }
                            editingProfileID = nil
                        } label: {
                            Text("Profil l\u{00F6}schen").font(.system(size: 10.5))
                        }
                        .buttonStyle(SubtleButtonStyle()).foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isActive ? 0.05 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isActive ? Color.humiqaIndigo.opacity(0.25) : Color.clear, lineWidth: 1)
        )
    }

    private var usageCard: some View {
        HStack(spacing: 0) {
            statTile(value: "\(appState.usage.todayCount)", label: "Heute")
            Divider().frame(height: 30)
            statTile(value: "\(appState.usage.totalCount)", label: "Gesamt")
            Divider().frame(height: 30)
            statTile(value: appState.usage.estimatedTotalCostText, label: "Kosten (ca.)")
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.humiqaIndigo.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.humiqaIndigo.opacity(0.12), lineWidth: 0.5)
        )
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 15, weight: .bold)).foregroundStyle(.primary)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var quickToggles: some View {
        VStack(spacing: 0) {
            Toggle(isOn: Binding(
                get: { appState.launchAtLogin.isEnabled },
                set: { appState.launchAtLogin.setEnabled($0) }
            )) {
                toggleLabel("power", "Bei Anmeldung starten", appState.launchAtLogin.helperText)
            }
            .toggleStyle(.switch).controlSize(.small)
            .padding(.vertical, 8)

            Divider()

            Toggle(isOn: Binding(
                get: { appState.appSettings.soundFeedbackEnabled },
                set: { appState.appSettings.soundFeedbackEnabled = $0 }
            )) {
                toggleLabel("speaker.wave.2.fill", "Sound-Feedback", "Toene bei Start, Stopp und Fertig.")
            }
            .toggleStyle(.switch).controlSize(.small)
            .padding(.vertical, 8)

            Divider()

            Toggle(isOn: Binding(
                get: { appState.appSettings.liveTranscriptionEnabled },
                set: { appState.appSettings.liveTranscriptionEnabled = $0 }
            )) {
                toggleLabel("waveform.badge.mic", "Live-Mitschrift",
                            "Text erscheint wortweise beim Sprechen. Nur lokal (Ctrl+Option+Shift), lokales Modell n\u{00F6}tig.")
            }
            .toggleStyle(.switch).controlSize(.small)
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private func toggleLabel(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.humiqaIndigo)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        HStack {
            Text("Verlauf").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            if !appState.history.entries.isEmpty {
                Button("Leeren") { appState.history.clear() }
                    .font(.system(size: 10.5)).buttonStyle(SubtleButtonStyle())
                    .foregroundStyle(.secondary)
            }
        }

        if appState.history.entries.isEmpty {
            Text("Noch keine Diktate. Sobald du etwas diktierst, erscheint es hier.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 8) {
                ForEach(appState.history.entries) { entry in
                    historyRow(entry)
                }
            }
        }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.text)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if let wf = entry.workflow {
                    Text(wf.displayName).font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    appState.copyToClipboard(entry.text)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(SubtleButtonStyle()).foregroundStyle(.secondary)
                .help("Kopieren")

                Button {
                    appState.reinsertFromHistory(entry.text)
                } label: {
                    Image(systemName: "arrow.down.doc").font(.system(size: 11))
                }
                .buttonStyle(SubtleButtonStyle()).foregroundStyle(Color.humiqaIndigo)
                .help("Erneut einf\u{00FC}gen")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }
}
