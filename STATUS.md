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

## Bewusst offen (nächste Iteration, dokumentiert)
- **known_hosts Key-Pinning**: swift-nio-ssh exponiert Host-Key-Bytes nicht öffentlich → aktuell TOFU. Härten vor Public-Release.
- **Key-Import** RSA/ECDSA + passphrasen-geschützt (braucht bcrypt-pbkdf); aktuell ed25519 ohne Passphrase.
- **Jump-Hosts (ProxyJump)** · **SOCKS/Remote-Forwarding** · **Agent-Forwarding**.
- **Echtes SFTP via Citadel** (byte-genauer Transfer-Fortschritt, sehr große Dateien) · **dual-pane** lokal↔remote.
- **Metal-Toolchain** war für WhisperKit nötig (`xcodebuild -downloadComponent MetalToolchain`).

## Domain
`humibeam.com` ist vorhanden — Landing-Page analog zu humitext (`docs/landing-page-brief.md`) als nächster Marketing-Schritt.
