import SwiftUI

struct MenuBarView: View {
    @Bindable var appState: AppState
    let sessions: SessionManager

    var body: some View {
        VStack(spacing: 0) {
            switch appState.page {
            case .main:
                mainPage
            case .onboarding:
                onboardingPage
            case .settings:
                settingsPage
            case .workflow:
                workflowPage
            case .history:
                ExtrasPageView(appState: appState)
            }
        }
        .frame(width: 340)
        .animation(.easeInOut(duration: 0.2), value: appState.page)
    }

    // MARK: - Main Page

    private var mainPage: some View {
        VStack(spacing: 0) {
            // Branded Header
            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    BrandMark(size: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Humibeam")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.primary)

                        HStack(spacing: 5) {
                            Circle()
                                .fill(appState.isConfigured ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            Text(appState.isConfigured ? "Bereit" : "Einrichtung n\u{00F6}tig")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button {
                        appState.page = .history
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SubtleButtonStyle())
                    .help("Verlauf & Nutzung")

                    Button {
                        appState.page = .settings
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 30, height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.primary.opacity(0.05))
                                )
                                .contentShape(Rectangle())

                            if !appState.accessibilityPermissionGranted {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 6, height: 6)
                                    .offset(x: -3, y: 3)
                            }
                        }
                    }
                    .buttonStyle(SubtleButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, appState.isConfigured ? 14 : 10)

                if !appState.isConfigured {
                    unconfiguredHeader
                        .padding(.bottom, 16)
                }
            }
            .background(
                ZStack {
                    Color(nsColor: .controlBackgroundColor).opacity(0.5)
                    LinearGradient(
                        colors: [Color.humiqaIndigo.opacity(0.10), Color.humiqaCyan.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            )
            .overlay(alignment: .bottom) {
                Divider().opacity(0.5)
            }

            if let info = appState.updater.available {
                updateBanner(info)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            if HumibeamInstallLocationService.shouldOfferMoveToApplications {
                installHintBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
            }

            transcriptionModePanel
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, appState.accessibilityPermissionGranted ? 6 : 4)

            if !appState.accessibilityPermissionGranted {
                accessibilityHintBanner
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            if !appState.appSettings.secureLocalModeEnabled {
                profileSwitcher
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
            }

            // Workflow list
            VStack(spacing: 0) {
                ForEach(WorkflowType.mainMenuCases) { type in
                    let enabled = appState.isWorkflowAvailable(type)
                    WorkflowRowView(
                        type: type,
                        enabled: enabled,
                        customName: appState.displayName(for: type),
                        subtitle: appState.workflowSubtitle(for: type)
                    ) {
                        appState.startWorkflow(type)
                    }
                }
            }
            .padding(.vertical, 2)

            sessionHub
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 6)

            appFooter
        }
    }

    // MARK: - Session hub (the menu bar is the home for all sessions)

    private var sessionHub: some View {
        VStack(spacing: 8) {
            hubLaunchRow(icon: "apple.terminal.fill", title: "Lokales Terminal",
                         subtitle: "Mac-Shell", trailing: "⌘T", prominent: true) {
                sessions.openLocalSession(); dismissPopover()
            }

            if !sessions.shell.hostStore.hosts.isEmpty {
                hubSectionLabel("SSH-PROFILE")
                ForEach(sessions.shell.hostStore.hosts) { host in
                    hubProfileRow(host)
                }

                hubSectionLabel("DATEIEN (SFTP)")
                ForEach(sessions.shell.hostStore.hosts) { host in
                    hubLaunchRow(icon: "folder.fill", title: host.displayName,
                                 subtitle: "Dateien übertragen, Cyberduck-Ersatz",
                                 trailing: "", prominent: false) {
                        sessions.openFileSession(host); dismissPopover()
                    }
                }
            }

            let active = sessions.activeSessions
            if !active.isEmpty {
                hubSectionLabel("AKTIVE SITZUNGEN")
                ForEach(active) { hubActiveRow($0) }
            }

            HStack(spacing: 14) {
                Button {
                    dismissPopover(); sessions.toggleCommandPalette()
                } label: {
                    Label("Befehls-Palette ⌘K", systemImage: "command")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .buttonStyle(SubtleButtonStyle())
                Button {
                    sessions.openProfilesWindow(); dismissPopover()
                } label: {
                    Label("Profile verwalten…", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .buttonStyle(SubtleButtonStyle())
            }
            .padding(.top, 2)
        }
    }

    private func hubSectionLabel(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 4)
    }

    private func hubLaunchRow(icon: String, title: String, subtitle: String,
                              trailing: String, prominent: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(Color.humiqaIndigo))
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(prominent ? .white : .primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(prominent ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(Color.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if !trailing.isEmpty {
                    Text(trailing)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(prominent ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(Color.secondary))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Color.humiqaGradient) : AnyShapeStyle(Color.primary.opacity(0.05)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(SubtleButtonStyle())
    }

    /// A profile row: tapping the row opens a terminal; the folder button opens the SFTP manager.
    private func hubProfileRow(_ host: SSHHost) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.humiqaIndigo)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary).lineLimit(1)
                Text("\(host.username)@\(host.host):\(host.port)")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let key = host.shortcut, !key.isEmpty {
                Text("⌘\(key.uppercased())")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Button { sessions.openFileSession(host); dismissPopover() } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(SubtleButtonStyle())
            .help("Dateien (SFTP)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .contentShape(Rectangle())
        .onTapGesture { sessions.openSSHSession(host); dismissPopover() }
    }

    private func hubActiveRow(_ s: SessionManager.ActiveSession) -> some View {
        HStack(spacing: 9) {
            Circle().fill(s.connected ? Color.green : Color.orange).frame(width: 7, height: 7)
            Image(systemName: s.symbol)
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(s.title).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 4)
            Button { sessions.close(s.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(SubtleButtonStyle())
            .help("Sitzung schließen")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture { sessions.focus(s.id); dismissPopover() }
    }

    private func dismissPopover() {
        NotificationCenter.default.post(name: .dismissPopover, object: nil)
    }

    private func updateBanner(_ info: UpdateInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.humiqaIndigo)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text("Update \(info.version) verf\u{00FC}gbar")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                if !info.notes.isEmpty {
                    Text(info.notes)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            if appState.updater.isInstalling {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            } else {
                Button("Aktualisieren") { appState.updater.installAvailableUpdate() }
                    .font(.system(size: 10.5, weight: .semibold))
                    .buttonStyle(SubtleButtonStyle())
                    .foregroundStyle(Color.humiqaIndigo)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.humiqaIndigo.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.humiqaIndigo.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var profileSwitcher: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.humiqaIndigo)
                Text("STIL")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(appState.appSettings.promptProfiles) { profile in
                        let selected = profile.id == appState.appSettings.selectedProfileID
                        Button {
                            appState.appSettings.selectedProfileID = profile.id
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: profile.icon)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(profile.name)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(
                                    selected
                                        ? AnyShapeStyle(Color.humiqaGradient)
                                        : AnyShapeStyle(Color.primary.opacity(0.05))
                                )
                            )
                            .foregroundStyle(selected ? Color.white : Color.primary)
                        }
                        .buttonStyle(SubtleButtonStyle())
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private var transcriptionModePanel: some View {
        let modelOptions = LocalTranscriptionService.modelOptions()
        let selectedModelInstalled = appState.selectedLocalModelIsInstalled

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: appState.appSettings.secureLocalModeEnabled ? "lock.shield.fill" : "network")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(appState.appSettings.secureLocalModeEnabled ? .green : .blue)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.appSettings.secureLocalModeEnabled ? "Sicherer lokaler Modus" : "Online Whisper")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(modePanelSubtitle(selectedModelInstalled: selectedModelInstalled))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Toggle("", isOn: Binding(
                    get: { appState.appSettings.secureLocalModeEnabled },
                    set: { newValue in
                        if newValue {
                            appState.enableSecureLocalMode()
                        } else {
                            appState.appSettings.secureLocalModeEnabled = false
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(appState.isDownloadingLocalModel)
            }

            if appState.appSettings.secureLocalModeEnabled {
                HStack(spacing: 8) {
                    Text("Modell")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)

                    Picker("", selection: Binding(
                        get: { appState.selectedLocalModelName },
                        set: { appState.appSettings.selectedLocalTranscriptionModelName = $0 }
                    )) {
                        ForEach(modelOptions) { model in
                            Text(model.shortDisplayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .controlSize(.small)
                    .disabled(appState.isDownloadingLocalModel)
                }

                if let progress = appState.localModelDownloadProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress)
                        Text(appState.localModelDownloadStatusText ?? "Modell wird geladen...")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                } else if !selectedModelInstalled {
                    Button(appState.localModelDownloadButtonTitle) {
                        appState.installSelectedLocalModel()
                    }
                    .controlSize(.small)
                }

                if let errorText = appState.localModelDownloadErrorText {
                    Text(errorText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func modePanelSubtitle(selectedModelInstalled: Bool) -> String {
        if appState.appSettings.secureLocalModeEnabled {
            if appState.isDownloadingLocalModel {
                return appState.localModelDownloadStatusText ?? "Lokales Modell wird geladen."
            }
            if selectedModelInstalled {
                return "Lokal mit \(appState.selectedLocalModelDisplayName)."
            }
            return "\(appState.selectedLocalModelDisplayName) ist noch nicht installiert."
        }

        return "Humibeam nutzt gerade die OpenAI-Transkription."
    }

    private var accessibilityHintBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text("Einfügen braucht Bedienungshilfen.")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Nach Updates kann macOS die Freigabe neu verlangen.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button("Öffnen") {
                appState.requestAccessibilityPermission()
            }
            .font(.system(size: 10.5, weight: .medium))
            .buttonStyle(SubtleButtonStyle())
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.12), lineWidth: 0.5)
        )
    }

    private var configuredHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
            Text("Bereit")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private var installHintBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text("Für sauberen Anmeldestart nach /Applications verschieben.")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Sonst entstehen leichter doppelte Login-Items oder uneinheitliche Updates.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button("Prüfen") {
                appState.page = .settings
            }
            .font(.system(size: 10.5, weight: .medium))
            .buttonStyle(SubtleButtonStyle())
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.12), lineWidth: 0.5)
        )
    }

    private var onboardingPage: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Willkommen bei Humibeam")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Button("Später") {
                    appState.page = .main
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(SubtleButtonStyle())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.5)
            )

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    BrandMark(size: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Einmal einrichten, dann direkt loslegen.")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("Eigenen OpenAI API Key eintragen. Danach sprechen und einfügen.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    if HumibeamInstallLocationService.shouldOfferMoveToApplications {
                        onboardingInstallCard
                    }

                    onboardingStep(number: "1", title: "OpenAI Key speichern", detail: "Öffne die Einstellungen und trage deinen eigenen OpenAI API Key ein.")
                    onboardingStep(number: "2", title: "Berechtigungen erlauben", detail: "Mikrofon und Bedienungshilfen für das Einfügen freigeben.")
                    onboardingStep(number: "3", title: "Workflow wählen", detail: "Humibeam oder einen der Verbesserer-Workflows direkt aus der Menüleiste starten.")
                }

                HStack(spacing: 8) {
                    Button {
                        appState.page = .settings
                    } label: {
                        Text("Jetzt einrichten")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(SubtleButtonStyle())

                    Text("Du findest alles später im Zahnrad.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Spacer(minLength: 0)

            appFooter
        }
    }

    private var unconfiguredHeader: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.1))
                    .frame(width: 40, height: 40)
                Image(systemName: "key.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.orange)
            }

            VStack(spacing: 4) {
                Text("Einrichtung n\u{00F6}tig")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("\u{00D6}ffne die Einstellungen und hinterlege deine Zugangsdaten, um loszulegen.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }

            Button {
                appState.page = .settings
            } label: {
                Text("Einstellungen \u{00F6}ffnen")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
            }
            .buttonStyle(SubtleButtonStyle())
        }
    }

    private func onboardingStep(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.05))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var onboardingInstallCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.app")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text("Lege Humibeam zuerst nach /Applications.")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Das hält Anmeldestart, spätere Updates und das Entfernen sauber auf einer einzigen App-Kopie.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - Settings Page

    private var settingsPage: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Button {
                    appState.page = .main
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Zur\u{00FC}ck")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(SubtleButtonStyle())

                Spacer()

                Text("Einstellungen")
                    .font(.system(size: 12, weight: .semibold))

                Spacer()
                settingsQuickAction
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            SettingsContentView(appState: appState)

            Spacer(minLength: 0)

            appFooter
        }
    }

    @ViewBuilder
    private var settingsQuickAction: some View {
        if !appState.accessibilityPermissionGranted {
            Button {
                appState.requestAccessibilityPermission()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Rechte")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.orange)
            }
            .buttonStyle(SubtleButtonStyle())
        } else {
            Color.clear.frame(width: 58, height: 18)
        }
    }

    // MARK: - Workflow Page

    private var workflowPage: some View {
        VStack(spacing: 0) {
            if let workflow = appState.activeWorkflow {
                // Header bar
                HStack {
                    Button {
                        appState.resetCurrentWorkflow()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Zur\u{00FC}ck")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(SubtleButtonStyle())

                    Spacer()

                    HStack(spacing: 5) {
                        Image(systemName: workflow.type.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(workflowIconColor(workflow.type))
                        Text(appState.displayName(for: workflow.type))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                // Content
                switch workflow.type {
                case .transcription, .localTranscription:
                    if let w = workflow as? LiveTranscriptionWorkflow {
                        LiveActiveView(workflow: w)
                    } else if let w = workflow as? TranscriptionWorkflow {
                        TranscriptionActiveView(workflow: w)
                    }
                case .textImprover:
                    if let w = workflow as? TextImprovementWorkflow {
                        TextImproverActiveView(workflow: w)
                    }
                case .dampfAblassen:
                    if let w = workflow as? DampfAblassenWorkflow {
                        DampfAblassenActiveView(workflow: w)
                    }
                case .emojiText:
                    if let w = workflow as? EmojiTextWorkflow {
                        EmojiTextActiveView(workflow: w)
                    }
                }

                Spacer(minLength: 0)

                appFooter
            }
        }
    }

    private var appFooter: some View {
        HStack {
            Spacer()
            Button("Beenden") {
                NSApplication.shared.terminate(nil)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.quaternary)
            .buttonStyle(SubtleButtonStyle())
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func workflowIconColor(_ type: WorkflowType) -> Color {
        switch type {
        case .transcription: return .blue
        case .localTranscription: return .green
        case .textImprover: return .purple
        case .dampfAblassen: return .orange
        case .emojiText: return .cyan
        }
    }
}

// MARK: - Subtle Button Style

struct SubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Live Recording Hint (Timer)

struct RecordingHintView: View {
    @State private var start = Date()

    var body: some View {
        VStack(spacing: 4) {
            TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
                let elapsed = max(0, ctx.date.timeIntervalSince(start))
                Text(String(format: "%01d:%02d", Int(elapsed) / 60, Int(elapsed) % 60))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.humiqaIndigo)
                    .monospacedDigit()
            }
            Text("Ich h\u{00F6}re zu \u{2026} Klicke zum Stoppen.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Humiqa Branding

extension Color {
    static let humiqaIndigo = Color(red: 0.310, green: 0.275, blue: 0.898) // #4F46E5
    static let humiqaCyan = Color(red: 0.055, green: 0.647, blue: 0.914)   // #0EA5E9

    static var humiqaGradient: LinearGradient {
        LinearGradient(colors: [.humiqaIndigo, .humiqaCyan],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Das humiqa-Logo (Gradient-Rundquadrat mit weissem "H"), vektoriell gezeichnet.
struct BrandMark: View {
    var size: CGFloat = 28

    private let glyph: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (8.5, 10.5, 4.5, 13), (14.5, 10.5, 5, 5), (14.5, 18.5, 5, 5), (21, 10.5, 4.5, 13)
    ]

    var body: some View {
        Canvas { ctx, sz in
            let radius = sz.width * 9 / 34
            let bg = Path(roundedRect: CGRect(origin: .zero, size: sz), cornerRadius: radius)
            ctx.fill(bg, with: .linearGradient(
                Gradient(colors: [.humiqaIndigo, .humiqaCyan]),
                startPoint: .zero,
                endPoint: CGPoint(x: sz.width, y: sz.height)))
            let s = sz.width / 34
            for g in glyph {
                ctx.fill(Path(CGRect(x: g.0 * s, y: g.1 * s, width: g.2 * s, height: g.3 * s)),
                         with: .color(.white))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color.humiqaIndigo.opacity(0.25), radius: 3, x: 0, y: 1)
    }
}

// MARK: - Transcription Active View

struct TranscriptionActiveView: View {
    @Bindable var workflow: TranscriptionWorkflow

    var body: some View {
        VStack(spacing: 0) {
            switch workflow.phase {
            case .idle, .running:
                if workflow.isRecording {
                    recordingView(onStop: { workflow.stop() })
                } else {
                    processingView(message: "Wird transkribiert \u{2026}")
                }

            case .done(let text):
                autoPasteView(text: text)

            case .error(let msg):
                errorView(message: msg) {
                    workflow.reset()
                    workflow.start()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func recordingView(onStop: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 20)

            WaveformView(audioLevel: workflow.audioLevel, isRecording: true)
                .frame(height: 44)
                .padding(.horizontal, 24)

            // Monochrome stop button
            Button(action: onStop) {
                ZStack {
                    Circle()
                        .strokeBorder(.primary.opacity(0.2), lineWidth: 1.5)
                        .frame(width: 44, height: 44)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.primary.opacity(0.7))
                        .frame(width: 14, height: 14)
                }
            }
            .buttonStyle(.plain)

            RecordingHintView()

            Spacer().frame(height: 8)
        }
    }
}

// MARK: - Live Transcription Active View

struct LiveActiveView: View {
    @Bindable var workflow: LiveTranscriptionWorkflow

    var body: some View {
        VStack(spacing: 0) {
            switch workflow.phase {
            case .idle, .running:
                if workflow.isRecording {
                    VStack(spacing: 12) {
                        Spacer().frame(height: 8)

                        ScrollView {
                            Text(workflow.liveText.isEmpty ? "Sprich los \u{2026}" : workflow.liveText)
                                .font(.system(size: 13))
                                .foregroundStyle(workflow.liveText.isEmpty ? .tertiary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 130)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )

                        Button(action: { workflow.stop() }) {
                            ZStack {
                                Circle()
                                    .strokeBorder(Color.humiqaIndigo.opacity(0.3), lineWidth: 1.5)
                                    .frame(width: 44, height: 44)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.humiqaIndigo)
                                    .frame(width: 14, height: 14)
                            }
                        }
                        .buttonStyle(.plain)

                        RecordingHintView()
                        Spacer().frame(height: 8)
                    }
                } else {
                    processingView(message: "Verarbeite \u{2026}")
                }

            case .done(let text):
                autoPasteView(text: text)

            case .error(let msg):
                errorView(message: msg) {
                    workflow.reset()
                    workflow.start()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

// MARK: - Text Improver Active View

struct TextImproverActiveView: View {
    @Bindable var workflow: TextImprovementWorkflow

    var body: some View {
        VStack(spacing: 0) {
            switch workflow.phase {
            case .idle, .running:
                if workflow.isRecording {
                    recordingView(onStop: { workflow.stop() })
                } else {
                    VStack(spacing: 12) {
                        Spacer().frame(height: 24)
                        ProgressView()
                            .scaleEffect(0.7)
                            .controlSize(.small)
                        if case .running(let msg) = workflow.phase {
                            Text(msg)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer().frame(height: 24)
                    }
                }

            case .done(let text):
                autoPasteView(text: text)

            case .error(let msg):
                errorView(message: msg) {
                    workflow.reset()
                    workflow.start()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func recordingView(onStop: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 20)

            WaveformView(audioLevel: workflow.audioLevel, isRecording: true)
                .frame(height: 44)
                .padding(.horizontal, 24)

            // Monochrome stop button
            Button(action: onStop) {
                ZStack {
                    Circle()
                        .strokeBorder(.primary.opacity(0.2), lineWidth: 1.5)
                        .frame(width: 44, height: 44)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.primary.opacity(0.7))
                        .frame(width: 14, height: 14)
                }
            }
            .buttonStyle(.plain)

            RecordingHintView()

            Spacer().frame(height: 8)
        }
    }
}

// MARK: - Rage Mode Active View

struct DampfAblassenActiveView: View {
    @Bindable var workflow: DampfAblassenWorkflow

    var body: some View {
        VStack(spacing: 0) {
            switch workflow.phase {
            case .idle, .running:
                if workflow.isRecording {
                    recordingView(onStop: { workflow.stop() })
                } else {
                    VStack(spacing: 12) {
                        Spacer().frame(height: 24)
                        ProgressView()
                            .scaleEffect(0.7)
                            .controlSize(.small)
                        if case .running(let msg) = workflow.phase {
                            Text(msg)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer().frame(height: 24)
                    }
                }

            case .done(let text):
                autoPasteView(text: text)

            case .error(let msg):
                errorView(message: msg) {
                    workflow.reset()
                    workflow.start()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func recordingView(onStop: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 20)

            WaveformView(audioLevel: workflow.audioLevel, isRecording: true)
                .frame(height: 44)
                .padding(.horizontal, 24)

            // Monochrome stop button
            Button(action: onStop) {
                ZStack {
                    Circle()
                        .strokeBorder(.primary.opacity(0.2), lineWidth: 1.5)
                        .frame(width: 44, height: 44)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.primary.opacity(0.7))
                        .frame(width: 14, height: 14)
                }
            }
            .buttonStyle(.plain)

            RecordingHintView()

            Spacer().frame(height: 8)
        }
    }
}

// MARK: - Emoji Text Active View

struct EmojiTextActiveView: View {
    @Bindable var workflow: EmojiTextWorkflow

    var body: some View {
        VStack(spacing: 0) {
            switch workflow.phase {
            case .idle, .running:
                if workflow.isRecording {
                    recordingView(onStop: { workflow.stop() })
                } else {
                    VStack(spacing: 12) {
                        Spacer().frame(height: 24)
                        ProgressView()
                            .scaleEffect(0.7)
                            .controlSize(.small)
                        if case .running(let msg) = workflow.phase {
                            Text(msg)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer().frame(height: 24)
                    }
                }

            case .done(let text):
                autoPasteView(text: text)

            case .error(let msg):
                errorView(message: msg) {
                    workflow.reset()
                    workflow.start()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func recordingView(onStop: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 20)

            WaveformView(audioLevel: workflow.audioLevel, isRecording: true)
                .frame(height: 44)
                .padding(.horizontal, 24)

            // Monochrome stop button
            Button(action: onStop) {
                ZStack {
                    Circle()
                        .strokeBorder(.primary.opacity(0.2), lineWidth: 1.5)
                        .frame(width: 44, height: 44)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.primary.opacity(0.7))
                        .frame(width: 14, height: 14)
                }
            }
            .buttonStyle(.plain)

            RecordingHintView()

            Spacer().frame(height: 8)
        }
    }
}

// MARK: - Shared Result / Error Views

private func processingView(message: String) -> some View {
    VStack(spacing: 12) {
        Spacer().frame(height: 24)
        ProgressView()
            .scaleEffect(0.7)
            .controlSize(.small)
        Text(message)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        Spacer().frame(height: 24)
    }
}

private func autoPasteView(text: String) -> some View {
    VStack(spacing: 12) {
        Spacer().frame(height: 20)

        ZStack {
            Circle()
                .fill(Color.green.opacity(0.1))
                .frame(width: 44, height: 44)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.green)
        }

        Text("Eingef\u{00FC}gt")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)

        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)

        Spacer().frame(height: 12)
    }
}

private func errorView(message: String, onRetry: @escaping () -> Void) -> some View {
    VStack(spacing: 10) {
        Spacer().frame(height: 16)

        ZStack {
            Circle()
                .fill(Color.orange.opacity(0.1))
                .frame(width: 40, height: 40)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
        }

        Text(message)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)

        Button(action: onRetry) {
            Text("Nochmal versuchen")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        }
        .buttonStyle(SubtleButtonStyle())

        Spacer().frame(height: 4)
    }
}
