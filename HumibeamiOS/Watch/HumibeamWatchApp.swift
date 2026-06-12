import SwiftUI
import WatchConnectivity

/// humibeam fürs Handgelenk: offene Claude-Freigaben beantworten + Server-Ampel.
/// Datenfluss: iPhone schiebt den StatusSnapshot per WCSession-ApplicationContext;
/// Aktionen gehen als sendMessage zurück (weckt die iPhone-App im Hintergrund).
@main
struct HumibeamWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                content
            }
            .environmentObject(model)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = model.snapshot {
            List {
                if !snapshot.waiting.isEmpty {
                    Section("Freigaben") {
                        ForEach(snapshot.waiting, id: \.sessionID) { waiting in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(waiting.title).font(.headline)
                                if !waiting.question.isEmpty {
                                    Text(waiting.question).font(.caption2)
                                        .foregroundStyle(.secondary).lineLimit(3)
                                }
                                HStack {
                                    Button {
                                        model.send(action: "approve", sessionID: waiting.sessionID)
                                    } label: { Image(systemName: "checkmark") }
                                        .tint(.green)
                                    Button {
                                        model.send(action: "deny", sessionID: waiting.sessionID)
                                    } label: { Image(systemName: "xmark") }
                                        .tint(.red)
                                }
                                .controlSize(.mini)
                            }
                        }
                    }
                }
                Section("Server") {
                    if snapshot.servers.isEmpty {
                        Text("Keine Server").foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.servers, id: \.name) { server in
                        HStack {
                            Circle()
                                .fill(server.critical ? Color.red : (server.connected ? .green : .gray))
                                .frame(width: 8, height: 8)
                            Text(server.name).font(.caption)
                            Spacer()
                            if let disk = server.disk {
                                Text("\(disk)%").font(.caption2.monospacedDigit())
                                    .foregroundStyle(server.critical ? .red : .secondary)
                            }
                        }
                    }
                }
                Text("Stand \(snapshot.date.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .navigationTitle("humibeam")
        } else {
            VStack(spacing: 8) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.title2).foregroundStyle(.cyan)
                Text("Öffne humibeam auf dem iPhone, um Daten zu laden.")
                    .font(.caption2).multilineTextAlignment(.center)
            }
        }
    }
}

@MainActor
final class WatchModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published var snapshot: StatusSnapshot?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func send(action: String, sessionID: String) {
        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.sendMessage(["action": action, "sessionID": sessionID],
                                      replyHandler: nil, errorHandler: nil)
        // Optimistisch aus der Liste nehmen — das iPhone schickt gleich den echten Stand.
        snapshot?.waiting.removeAll { $0.sessionID == sessionID }
    }

    private func apply(_ context: [String: Any]) {
        guard let data = context["snapshot"] as? Data,
              let decoded = try? JSONDecoder().decode(StatusSnapshot.self, from: data) else { return }
        snapshot = decoded
    }

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in self.apply(context) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }
}
