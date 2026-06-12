import SwiftUI
import LocalAuthentication

/// Face-ID/Touch-ID-Schutz: Beim Start und bei Rückkehr aus dem Hintergrund wird
/// entsperrt (Einstellungen → Sicherheit). Ohne Biometrie fällt LAContext auf den Code zurück.
extension View {
    func appLock() -> some View { modifier(AppLockModifier()) }
}

private struct AppLockModifier: ViewModifier {
    @AppStorage("lock.enabled") private var lockEnabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var unlocked = false
    @State private var checking = false

    func body(content: Content) -> some View {
        ZStack {
            content
                .blur(radius: locked ? 24 : 0)
                .allowsHitTesting(!locked)

            if locked {
                VStack(spacing: 14) {
                    Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(.cyan)
                    Text("humibeam ist gesperrt").font(.headline)
                    Button("Entsperren") { authenticate() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial)
            }
        }
        .onAppear { if lockEnabled { authenticate() } else { unlocked = true } }
        .onChange(of: scenePhase) { _, phase in
            guard lockEnabled else { unlocked = true; return }
            switch phase {
            case .background: unlocked = false
            case .active: if !unlocked { authenticate() }
            default: break
            }
        }
        .onChange(of: lockEnabled) { _, enabled in
            if !enabled { unlocked = true }
        }
    }

    private var locked: Bool { lockEnabled && !unlocked }

    private func authenticate() {
        guard !checking else { return }
        checking = true
        let context = LAContext()
        context.localizedReason = "humibeam entsperren"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Kein Code/Biometrie eingerichtet → nicht aussperren.
            unlocked = true; checking = false
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "humibeam entsperren") { success, _ in
            Task { @MainActor in
                unlocked = success
                checking = false
            }
        }
    }
}
