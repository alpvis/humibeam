import Foundation

/// WebSocket-Verbindung zum Humibeam-Signaling-Server (wss://humibeam.com/humibeam-support/ws).
/// Reicht Nachrichten als JSON durch; die Geräte-ID bleibt über Neustarts stabil (UserDefaults).
@MainActor
final class SupportSignalClient: NSObject {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!

    /// Callbacks (vom SupportSession gesetzt).
    var onRegistered: ((_ deviceId: String, _ code: String) -> Void)?
    var onCode: ((_ code: String) -> Void)?
    var onConnectionRequest: ((_ sessionId: String, _ supporter: String) -> Void)?
    var onSessionStart: ((_ sessionId: String, _ role: String, _ ice: [[String: Any]]) -> Void)?
    var onSignal: ((_ sessionId: String, _ data: [String: Any]) -> Void)?
    var onSessionEnd: ((_ sessionId: String, _ reason: String) -> Void)?
    var onState: ((_ connected: Bool) -> Void)?

    init(url: URL) {
        self.url = url
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    func connect() {
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive()
    }

    func register(name: String) {
        let deviceId = UserDefaults.standard.string(forKey: "support.deviceId")
        var msg: [String: Any] = ["type": "register", "name": name]
        if let deviceId { msg["deviceId"] = deviceId }
        send(msg)
    }

    func accept(sessionId: String) { send(["type": "accept", "sessionId": sessionId]) }
    func reject(sessionId: String) { send(["type": "reject", "sessionId": sessionId]) }
    func hangup(sessionId: String) { send(["type": "hangup", "sessionId": sessionId]) }
    func signal(sessionId: String, data: [String: Any]) {
        send(["type": "signal", "sessionId": sessionId, "data": data])
    }

    func close() { task?.cancel(with: .goingAway, reason: nil); task = nil }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.receive()
                case .failure:
                    self.onState?(false)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = m["type"] as? String else { return }
        switch type {
        case "registered":
            if let d = m["deviceId"] as? String, let c = m["code"] as? String {
                UserDefaults.standard.set(d, forKey: "support.deviceId")
                onRegistered?(d, c)
            }
        case "code":
            if let c = m["code"] as? String { onCode?(c) }
        case "connection-request":
            onConnectionRequest?(m["sessionId"] as? String ?? "", m["supporter"] as? String ?? "")
        case "session-start":
            onSessionStart?(m["sessionId"] as? String ?? "", m["role"] as? String ?? "answerer",
                            m["iceServers"] as? [[String: Any]] ?? [])
        case "signal":
            onSignal?(m["sessionId"] as? String ?? "", m["data"] as? [String: Any] ?? [:])
        case "session-end":
            onSessionEnd?(m["sessionId"] as? String ?? "", m["reason"] as? String ?? "")
        default:
            break
        }
    }
}

extension SupportSignalClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor in self.onState?(true); self.register(name: Host.current().localizedName ?? "Mac") }
    }
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                               didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in self.onState?(false) }
    }
}
