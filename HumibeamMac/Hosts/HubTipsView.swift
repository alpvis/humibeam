import SwiftUI

/// One-time tips explaining the menu-bar session hub (shown once after the redesign).
struct HubTipsView: View {
    var onClose: () -> Void

    private let tips: [(String, String, String)] = [
        ("menubar.arrow.up.rectangle", "humibeam lebt in der Menüleiste",
         "Klick oben rechts aufs Icon — von dort startest du alles."),
        ("server.rack", "Terminal vs. Dateien",
         "Klick auf den Profil-Namen → Terminal. Klick auf das Ordner-Symbol → SFTP-Datei-Manager."),
        ("command", "Befehls-Palette (⌘K)",
         "Server, Dateien, Sitzungen und Aktionen blitzschnell per Tippen."),
        ("photo.on.rectangle", "Screenshot an Claude",
         "Im Terminal mit ⌘V einen Screenshot hochladen — Claude liest ihn."),
        ("mic.fill", "Mit Claude sprechen",
         "Mikrofon-Knopf im Terminal diktiert direkt in die Sitzung."),
        ("hand.raised.fill", "Tool-Calls per Knopf",
         "Fragt Claude nach Erlaubnis, erscheint eine Erlauben/Ablehnen-Leiste."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                BrandMark(size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Willkommen bei humibeam").font(.title2).bold()
                    Text("Das Wichtigste in 30 Sekunden").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: tip.0)
                            .font(.system(size: 16)).foregroundStyle(Color.humiqaIndigo)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tip.1).font(.system(size: 13, weight: .semibold))
                            Text(tip.2).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding()
            Divider()
            HStack {
                Spacer()
                Button("Los geht's") { onClose() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460)
    }
}
