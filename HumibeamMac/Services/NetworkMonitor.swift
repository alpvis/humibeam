import Foundation
import Network
import Observation

/// Watches overall network reachability via `NWPathMonitor`. Drives humibeam's network-aware
/// reconnect: when the link drops we pause reconnect loops, and the moment it returns we kick all
/// disconnected sessions to reconnect immediately (instead of waiting out a backoff timer).
@Observable
@MainActor
final class NetworkMonitor {
    private(set) var isOnline: Bool = true

    /// Fired only on an actual change of reachability. `true` = online, `false` = offline.
    var onChange: ((Bool) -> Void)?

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "app.humibeam.network-monitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                self.onChange?(online)
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
