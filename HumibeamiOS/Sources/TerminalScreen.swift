import SwiftUI
import PhotosUI
import Combine

/// Eine laufende Session: Terminal, Statuszeile, Agent-Cockpit (Approval-Karte) und Werkzeuge.
struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost

    @StateObject private var holder = ControllerHolder()
    @State private var showsDiff = false
    @State private var showsSnippets = false
    @State private var showsHistory = false
    @State private var photoItem: PhotosPickerItem?
    @State private var dictationError: String?

    var body: some View {
        let controller = holder.controller(for: host, model: model)

        VStack(spacing: 0) {
            TerminalHostView(controller: controller)
                .ignoresSafeArea(.container, edges: .bottom)

            if !controller.recentPaths.isEmpty {
                recentPathChips(controller)
            }
            statusBar(controller)
        }
        .background(Color(model.theme.background))
        .overlay(alignment: .bottom) {
            if let approval = controller.approval {
                ApprovalCard(approval: approval, controller: controller)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 56)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: controller.approval)
        .onReceive(NotificationCenter.default.publisher(for: .dictationFailed)) { note in
            dictationError = note.userInfo?["message"] as? String ?? "Diktat fehlgeschlagen."
        }
        .alert("Diktat", isPresented: Binding(get: { dictationError != nil },
                                              set: { if !$0 { dictationError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dictationError ?? "")
        }
        .navigationTitle(host.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showsSnippets = true
                } label: { Image(systemName: "curlybraces") }

                Button {
                    showsDiff = true
                } label: { Image(systemName: "plusminus") }
                    .disabled(!controller.isConnected)

                Menu {
                    Button {
                        Task { await ImagePaste.pasteFromClipboard(into: controller) }
                    } label: { Label("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard") }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Foto hochladen…", systemImage: "photo")
                    }
                    Button {
                        showsHistory = true
                    } label: { Label("Befehls-Verlauf…", systemImage: "clock.arrow.circlepath") }
                    Divider()
                    if controller.isConnected {
                        Button(role: .destructive) {
                            controller.disconnect()
                        } label: { Label("Trennen", systemImage: "xmark.circle") }
                    } else {
                        Button {
                            model.connect(host, controller: controller)
                        } label: { Label("Verbinden", systemImage: "bolt") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showsDiff) {
            DiffSheet(controller: controller)
        }
        .sheet(isPresented: $showsSnippets) {
            SnippetsSheet(controller: controller)
        }
        .sheet(isPresented: $showsHistory) {
            HistorySheet(controller: controller)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data), let png = image.pngData() {
                    await ImagePaste.upload([png], into: controller)
                }
                photoItem = nil
            }
        }
        .onAppear {
            if !controller.isConnected && controller.connection == nil {
                model.connect(host, controller: controller)
            }
            _ = controller.terminalView.becomeFirstResponder()
        }
    }

    /// Dateien, die Claude zuletzt angefasst hat, als antippbare Chips — Tap tippt den Pfad
    /// ins Terminal (z. B. um ihn in den nächsten Prompt zu übernehmen).
    private func recentPathChips(_ controller: TerminalController) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(controller.recentPaths, id: \.self) { path in
                    Button {
                        controller.sendToShell(path)
                    } label: {
                        Label((path as NSString).lastPathComponent, systemImage: "doc.text")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.cyan.opacity(0.15)))
                            .foregroundStyle(.cyan)
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func statusBar(_ controller: TerminalController) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.isConnected ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(controller.status)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            if controller.claudeDetected {
                Label("Claude", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.cyan)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Hält die Controller-Referenz über View-Updates stabil (Session lebt im AppModel weiter).
@MainActor
private final class ControllerHolder: ObservableObject {
    private var cached: TerminalController?

    func controller(for host: SSHHost, model: AppModel) -> TerminalController {
        if let cached { return cached }
        let controller = model.controller(for: host)
        cached = controller
        // Status-Änderungen des Controllers an SwiftUI durchreichen.
        controller.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        return controller
    }

    private var bag = Set<AnyCancellable>()
}

// MARK: - Approval-Karte (Agent-Cockpit Stufe 1)

/// Native Karte für Claude Codes Erlaubnis-Prompt: Aktionstyp, Befehl/Diff,
/// Erlauben / Immer erlauben / Ablehnen. Gefährliche Befehle färben die Karte rot.
struct ApprovalCard: View {
    let approval: ClaudeApproval
    let controller: TerminalController

    private var tint: Color { approval.looksDangerous ? .red : .cyan }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: approval.action.symbol)
                Text(approval.action.label).font(.subheadline.weight(.semibold))
                if approval.exact {
                    Text("exakt")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.green.opacity(0.25)))
                        .foregroundStyle(.green)
                }
                Spacer()
                if approval.looksDangerous {
                    Label("Vorsicht", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            .foregroundStyle(tint)

            if !approval.question.isEmpty {
                Text(approval.question)
                    .font(.footnote)
                    .foregroundStyle(.primary)
            }

            if !approval.preview.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(approval.preview.prefix(40)) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(background(for: line.kind))
                        }
                    }
                }
                .frame(maxHeight: 150)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.25)))
            }

            HStack(spacing: 8) {
                Button {
                    controller.approve()
                } label: {
                    Label("Erlauben", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(approval.looksDangerous ? .red : .green)

                if approval.allowAlways {
                    Button {
                        controller.approveAlways()
                    } label: {
                        Text("Immer")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    controller.deny()
                } label: {
                    Label("Ablehnen", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.5)))
        )
        .shadow(radius: 8, y: 4)
    }

    private func color(for kind: ClaudeApproval.Line.Kind) -> Color {
        switch kind {
        case .add: return .green
        case .remove: return .red
        case .context: return .primary.opacity(0.85)
        }
    }

    private func background(for kind: ClaudeApproval.Line.Kind) -> Color {
        switch kind {
        case .add: return .green.opacity(0.12)
        case .remove: return .red.opacity(0.12)
        case .context: return .clear
        }
    }
}

// MARK: - Diff-Sheet (Agent-Cockpit Stufe 2)

/// Holt den echten Arbeitsbaum-Diff (`git diff HEAD` + untracked) über den Exec-Channel.
struct DiffSheet: View {
    let controller: TerminalController
    @Environment(\.dismiss) private var dismiss
    @State private var result: GitDiffResult?

    var body: some View {
        NavigationStack {
            Group {
                switch result {
                case nil:
                    ProgressView("Hole Diff vom Server…")
                case .clean:
                    ContentUnavailableView("Keine Änderungen",
                                           systemImage: "checkmark.circle",
                                           description: Text("Der Arbeitsbaum ist sauber."))
                case .notARepo:
                    ContentUnavailableView("Kein Git-Repository",
                                           systemImage: "questionmark.folder",
                                           description: Text("Im Arbeitsverzeichnis wurde kein Repo gefunden."))
                case .noLocation:
                    ContentUnavailableView("Verzeichnis unbekannt",
                                           systemImage: "questionmark.folder",
                                           description: Text("Konnte das Remote-Arbeitsverzeichnis nicht bestimmen."))
                case .error(let message):
                    ContentUnavailableView("Fehler", systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                case .diff(let lines, let untracked):
                    diffList(lines: lines, untracked: untracked)
                }
            }
            .navigationTitle("Änderungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        result = nil
                        Task { await load() }
                    } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        var candidates: [String] = []
        if let cwd = controller.currentDirectory { candidates.append(cwd) }
        for path in controller.recentPaths where path.hasPrefix("/") {
            candidates.append((path as NSString).deletingLastPathComponent)
        }
        result = await GitDiffService.fetch(connection: controller.connection, candidates: candidates)
    }

    private func diffList(lines: [DiffHunkLine], untracked: [String]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !untracked.isEmpty {
                    Text("Neue Dateien: \(untracked.joined(separator: ", "))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                        .padding(.bottom, 6)
                }
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(for: line.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(for: line.kind))
                }
            }
            .padding(10)
        }
    }

    private func color(for kind: DiffHunkLine.Kind) -> Color {
        switch kind {
        case .add: return .green
        case .remove: return .red
        case .hunk: return .cyan
        case .file: return .primary
        case .context: return .secondary
        }
    }

    private func background(for kind: DiffHunkLine.Kind) -> Color {
        switch kind {
        case .add: return .green.opacity(0.12)
        case .remove: return .red.opacity(0.12)
        case .file: return .white.opacity(0.06)
        default: return .clear
        }
    }
}
