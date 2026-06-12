import WidgetKit
import SwiftUI
#if canImport(ActivityKit)
import ActivityKit
#endif

@main
struct HumibeamWidgetBundle: WidgetBundle {
    var body: some Widget {
        ServerStatusWidget()
        #if canImport(ActivityKit)
        ClaudeLiveActivity()
        #endif
    }
}

// MARK: - Server-Status-Widget (Homescreen/Sperrbildschirm)

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: StatusSnapshot?
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), snapshot: StatusSnapshot(
            servers: [.init(name: "zürich-1", connected: true, load: 0.4, mem: 38, disk: 61, critical: false)],
            waiting: [], date: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: Date(), snapshot: StatusSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let entry = StatusEntry(date: Date(), snapshot: StatusSnapshot.load())
        // Die App stößt bei Änderungen selbst reload an; sonst alle 15 Minuten auffrischen.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct ServerStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HumibeamServerStatus", provider: StatusProvider()) { entry in
            ServerStatusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Server & Agenten")
        .description("Vitalwerte deiner Server und offene Claude-Freigaben.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ServerStatusView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot, !snapshot.servers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !snapshot.waiting.isEmpty {
                    Label("\(snapshot.waiting.count) Freigabe\(snapshot.waiting.count == 1 ? "" : "n") offen",
                          systemImage: "hand.raised.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                ForEach(snapshot.servers.prefix(family == .systemSmall ? 3 : 5), id: \.name) { server in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(server.critical ? Color.red : (server.connected ? .green : .gray))
                            .frame(width: 7, height: 7)
                        Text(server.name)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        if family != .systemSmall, let load = server.load {
                            Text(String(format: "%.1f", load))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let disk = server.disk {
                            Text("\(disk)%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(server.critical ? .red : .secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Text(snapshot.date, style: .relative)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "server.rack").font(.title3).foregroundStyle(.cyan)
                Text("humibeam öffnen,\num Daten zu laden")
                    .font(.caption2).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Live Activity (Dynamic Island: „Claude arbeitet…")

#if canImport(ActivityKit)
struct ClaudeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClaudeActivityAttributes.self) { context in
            // Sperrbildschirm
            HStack(spacing: 10) {
                Image(systemName: context.state.waiting ? "hand.raised.fill" : "sparkles")
                    .foregroundStyle(context.state.waiting ? .orange : .cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.hostName).font(.caption.weight(.semibold))
                    Text(context.state.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(12)
            .activityBackgroundTint(.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.waiting ? "hand.raised.fill" : "sparkles")
                        .foregroundStyle(context.state.waiting ? .orange : .cyan)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.hostName).font(.caption.weight(.semibold))
                        Text(context.state.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.waiting ? "hand.raised.fill" : "sparkles")
                    .foregroundStyle(context.state.waiting ? .orange : .cyan)
            } compactTrailing: {
                Text(context.attributes.hostName.prefix(8))
                    .font(.caption2)
            } minimal: {
                Image(systemName: context.state.waiting ? "hand.raised.fill" : "sparkles")
                    .foregroundStyle(context.state.waiting ? .orange : .cyan)
            }
        }
    }
}
#endif
