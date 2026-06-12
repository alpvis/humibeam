# humibeam — Status & Anleitung

**humibeam = humitext (komplett) + SSH-Client für Claude Code.**
humitext wurde gerebrandet und um Terminal, Screenshot-Paste, SCP und Verbindungs-Manager erweitert.
Menüleisten-App (wie humitext) **plus** Hauptfenster mit Terminal.

## Was funktioniert (von mir verifiziert)

- ✅ **Komplette App baut** (`xcodebuild`, arm64) — humitext-Kern + alle neuen Module + alle Pakete.
- ✅ **App startet stabil** (kein Crash; Fenster + Menüleisten-Item kommen hoch).
- ✅ **SSH-Kern e2e gegen localhost getestet** (echte Shipping-Pfade, nicht nur der Spike):
  Connect + Public-Key-Auth · PTY-Shell (Bytes hin/zurück) · Upload (bit-identisch) ·
  Datei-Listing · Download (bit-identisch).
- ✅ **M0**: Claude Code liest ein per Pfad referenziertes Bild (Read-Tool) — die Grundlage der PasteBridge.

## Was du selbst testen musst (GUI / echter Server)

Eine GUI-App kann ich hier nicht anklicken und keinen externen Server erreichen. Bitte verifizieren:
1. **Verbindung** zu deinem Ubuntu-Server anlegen und verbinden.
2. **`claude` über SSH starten** und die TUI bedienen.
3. **Screenshot-Paste**: Bild kopieren → im Terminal `Cmd+V` → Pfad erscheint → Claude liest das Bild.
4. **Voice**: Hotkey halten, sprechen → Text landet im Terminal (Fenster muss fokussiert sein).
5. **Datei-Browser**: Ordner-Icon in der Toolbar → Listing, Upload, Download.

## Bauen & Starten

```bash
cd /Users/ali/humibeam/HumibeamMac
xcodegen generate          # einmalig / nach Struktur-Änderungen
# Schnell (Debug, ad-hoc):
xcodebuild -project HumibeamMac.xcodeproj -scheme HumibeamMac \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath .dd CODE_SIGNING_ALLOWED=NO build
open .dd/Build/Products/Debug/Humibeam.app
```

Oder das vollständige Skript (universal + signiert). Default-Signatur ist die Developer-ID;
mit eigener Identität bzw. ad-hoc überschreibbar:

```bash
cd /Users/ali/humibeam
HUMIBEAM_SIGN_IDENTITY="Apple Development: Ali Uelkue (7TL96JH8X6)" ./build.sh --run
# oder Release/Notarisierung wie bei humitext: ./build.sh --release --dmg --notarize
```

**Voraussetzung:** Beim ersten Verbinden mit `humibeam-Schlüssel`-Auth zeigt der Host-Editor
einen Public Key — den einmalig auf dem Server in `~/.ssh/authorized_keys` eintragen
(oder Passwort/eigenen Key wählen).

## Projektstruktur (neu)

```
HumibeamMac/
  App/        AppDelegate (Fenster + Menüleiste), AppState, HumibeamShell (Koordinator)
  SSH/        SSHConnection, SSHAuth, SSHChannels (PTY/Exec), SSHFileTransfer, SSHKeyManager, KnownHosts
  Terminal/   TerminalSessionController, PasteBridge (Screenshot→Upload→Pfad), TerminalRepresentable
  Hosts/      HostStore, MainView (Split-View), HostEditorView, FileBrowserView
  Features/   Voice-Workflows, MenuBar, Settings (aus humitext)
  Services/   Aufnahme, Transkription (WhisperKit/OpenAI), Hotkeys, Keychain (aus humitext)
```

## Feature-Stand — alle 6 Wellen gebaut (kompiliert, App startet, Release universal)

**Welle 0/1 — Basis:** SSH-Terminal (SwiftTerm) · Tabs/Multi-Session · Hauptmenü + Shortcuts ·
Schriftgröße · Host-Manager (Keychain) · `~/.ssh/config`-Import · Snippets · neues Icon.
**Welle 2 — Terminal-Power:** **Auto-Reconnect** (Backoff) + TCP-Keep-Alive · **Terminal-Suche** (Cmd+F) ·
**Split-Panes** (2 Sessions) · **Themes** (humibeam/Mitternacht/Solarized/Dracula/Hell) · **Broadcast-Input**.
**Welle 3 — KI-Layer:** **Claude-Code-Erkennung** (Badge) · **Ausgabe erklären** · **Fehler beheben** ·
**Befehl vorschlagen** (über OpenAI/LLMService) · Transcript-Mitschnitt (ANSI-bereinigt).
**Welle 4 — Datei-Power:** Browser pro Tab · Up/Download · mkdir/umbenennen/löschen · **chmod** ·
**Remote-Datei-Editor** (Download→Edit→Upload) · **Ordner als .tar.gz** · **Lesezeichen**.
**Welle 5 — SSH-Power:** **Port-Forwarding** (`ssh -L`, directTCPIP — e2e getestet) mit Verwaltungs-Sheet.
**Welle 6 — Politur:** Einstellungen-Menü (Cmd+,) · **Landing-Page** (`site/index.html`) · Release universal verifiziert.

**humibeam-exklusiv durchgängig:** Screenshot-Paste (`Cmd+V` Bild→Upload→Pfad) · Voice-Diktat ins Terminal ·
Drag & Drop von Dateien/Bildern ins Terminal.

## Verifiziert (von mir)
- Voller `xcodebuild` grün nach **jeder** Welle · Release-Build **universal (arm64+x86_64)** · App startet ohne Crash.
- **SSH e2e gegen localhost** (echte Shipping-Pfade): Connect · PTY · Upload (bit-identisch) · Listing · Download · **Port-Forward** (SSH-Banner durch den Tunnel).

## Marktreifer Release (dein Schritt — braucht deine Developer-ID)
```bash
cd /Users/ali/humibeam
./build.sh --release --dmg --notarize     # nutzt deine "Developer ID Application: … (DC289RNL2G)" + Notary-Profil
```
Hier konnte ich nur ad-hoc/Apple-Development signieren (keine Developer-ID im Keychain), daher Release universal verifiziert, aber nicht notarisiert.

## v5 „Symbiose" — Mac 5.0 / iOS 2.0 (2026-06-12)

Großes Update: Mac und iOS arbeiten als ein System. 25 Funktionen in 7 Wellen (Details: `PLAN-V5.md`).

**Fundament — Humibeam-Konto + Sync (E2E-verschlüsselt):** Anmelden/Registrieren, Profile · Snippets ·
Lesezeichen · Theme/Schrift syncen über alle Macs + iPhones + iPads. Server `server/sync/` (Node, ohne
Dependencies, PBKDF2 600k → HKDF → AES-GCM; der Server sieht nie Passwort/Klartext). Secrets bleiben im Keychain.

**iOS auf Mac-Niveau:** Datei-Browser (Up-/Download/Teilen/Editor/chmod) · Multi-Session + iPad-Shortcuts ·
Transcript-Archiv · Server-Health-Ampel · Port-Forwarding · Schriftart/Größe · Face-ID-Schutz · lokales
Apple-Diktat. **KI-Cockpit:** Agent-Inbox (wartende Freigaben), „erklären/beheben/vorschlagen", Claude-Status Plus.

**Symbiose Mac ↔ iOS:** „Mein Mac als Server" per QR-Pairing (Mac trägt Key selbst in authorized_keys ein) ·
Session-Handoff (tmux) · iOS-Fleet-Übersicht · **MacBeam** (Mac-Bildschirm vom iPhone steuern, H.264 + CGEvent,
direkt im WLAN oder via `server/beam-tunnel/`, alles E2E-verschlüsselt).

**Push & Glanz:** Freigaben aus der iOS-Mitteilung (Rückkanal Relay → Mac) · Apple-Watch-App · Widget +
Live Activity (Dynamic Island) · Siri/Kurzbefehle. **Mac-Härtung:** Key-Import ed25519 + ECDSA + Passphrase
(via ssh-keygen), known_hosts-Pinning, Menüleisten-Cockpit.

**Verifiziert von mir:** Mac- + iOS-Build grün nach jeder Welle (inkl. Watch- + Widget-Target). iOS startet
stabil. Server-Logik e2e-getestet: Sync-API (register/login/blob/Konflikt) + Krypto-Roundtrip · Push-Relay
Aktions-Rückkanal · Beam-Tunnel-Rendezvous · Key-Import (4 Kurven + Passphrase). **Dein Test (GUI/echte Geräte):**
QR-Pairing, MacBeam-Bild/Steuerung, Konto-Sync zwischen zwei Geräten, Push-Aktionen, Watch — brauchen physische
Geräte + Berechtigungen (Bildschirmaufnahme/Bedienungshilfen für MacBeam).

**Server-Deploy noch offen** (wartet auf SSH-Key in authorized_keys auf alpvis.com): `server/sync/install.sh`
und `server/beam-tunnel/install.sh` ausführen + nginx-Location für `/humibeam-sync/`.

## iOS 1.1 — Parität-Update (2026-06-12)

- **Snippets auf iOS**: gleiche Daten/Logik wie am Mac (`SnippetStore` geteilt), inkl.
  `{{Platzhalter}}`-Abfrage, Anlegen/Bearbeiten/Löschen, „Direkt abschicken"-Toggle.
  Toolbar-Knopf `{}` im Terminal.
- **Befehls-Verlauf auf iOS**: Zeilenpuffer-Aufzeichnung wie am Mac (`CommandHistoryStore`
  geteilt, gleiche JSON-Datei pro Gerät); durchsuchbares Sheet, Tap tippt den Befehl ohne Enter.
  Auf iOS läuft auch die Tasten-Leiste/Diktat/Snippets durch den Puffer (vieles kommt dort
  nicht über die Hardware-Tastatur).
- **Pfad-Chips**: Dateien, die Claude zuletzt angefasst hat (`recentPaths`), als antippbare
  Chips über der Statuszeile — Tap tippt den Pfad ins Terminal.
- Geteilter Kern erweitert: `CommandHistoryStore.swift` aus der Mac-Palette herausgelöst
  (Mac-UI unverändert in `CommandHistory.swift`).

## Bewusst offen (nächste Iteration, dokumentiert)
- **known_hosts Key-Pinning**: swift-nio-ssh exponiert Host-Key-Bytes nicht öffentlich → aktuell TOFU. Härten vor Public-Release.
- **Key-Import** RSA/ECDSA + passphrasen-geschützt (braucht bcrypt-pbkdf); aktuell ed25519 ohne Passphrase.
- **Jump-Hosts (ProxyJump)** · **SOCKS/Remote-Forwarding** · **Agent-Forwarding**.
- **Echtes SFTP via Citadel** (byte-genauer Transfer-Fortschritt, sehr große Dateien) · **dual-pane** lokal↔remote.
- **Metal-Toolchain** war für WhisperKit nötig (`xcodebuild -downloadComponent MetalToolchain`).

## Domain
`humibeam.com` ist vorhanden — Landing-Page analog zu humitext (`docs/landing-page-brief.md`) als nächster Marketing-Schritt.
