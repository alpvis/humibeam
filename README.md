# humibeam

**Der SSH-Client, der für agentische CLIs (Claude Code & Co.) gebaut ist.**
Sprache rein · Screenshots rein · Dateien rein/raus — alles über **eine** SSH-Verbindung,
auch zu einem nackten Ubuntu-Server ohne jede serverseitige Installation.

macOS · SwiftUI/AppKit · aktuell **v2.1 (Build 21)** · Domain: [humibeam.com](https://humibeam.com)

---

## Warum humibeam

Wenn `claude` (Claude Code CLI) über SSH auf einem Remote-Server läuft, ist das Terminal nur
ein Text-Stream (PTY). Ein Screenshot im lokalen Mac-Clipboard ist für den entfernten
`claude`-Prozess unsichtbar — Claude Codes eigenes Bild-Einfügen liest immer das Clipboard
*der Maschine, auf der es läuft* (= der Server). Deshalb kann heute **kein** klassischer
SSH-Client (Termius, iTerm2, Warp, Terminal.app) Screenshots in eine Remote-Claude-Code-Session geben.

humibeam schließt genau diese Lücke — und kombiniert sie mit Voice-Diktat und vollem
Dateitransfer zu einem Remote-Cockpit für agentische CLIs.

### Alleinstellungsmerkmale
1. **Screenshot-Paste über SSH** — `Cmd+V` mit Bild lädt es automatisch hoch und tippt den Remote-Pfad in die Session. Claude Code liest das Bild über den Pfad.
2. **Voice-Diktat in die Remote-Session** — Hotkey halten, sprechen, transkribierter Text landet im Terminal (WhisperKit lokal / OpenAI online).
3. **Dateitransfer integriert** — Datei-Browser, Drag & Drop rein/raus, über dieselbe Verbindung.
4. **Zero-Install auf dem Server** — funktioniert mit Stock-Ubuntu, nichts muss remote installiert werden (Upload via Exec-Channel `cat > datei`, kein SFTP-Daemon nötig).

---

## Der Kern-Trick: Screenshot-Paste-Bridge

```
[Cmd+V im Terminal]
   │
   ├─ Clipboard enthält Text?  → normaler Paste in den PTY-Channel
   │
   └─ Clipboard enthält Bild (.png/.tiff/.fileURL)?
        1. Bild als PNG lokal in temp schreiben
        2. Über bestehende SSH-Verbindung neuen Exec-Channel öffnen (kein 2. Login!)
        3. Upload nach  ~/.humibeam/pastes/<ts>-<rand>.png
        4. Absoluten Remote-Pfad als Text in den PTY-Channel schreiben
   →  Claude Code liest das Bild über sein Read-Tool. Funktioniert auf Stock-Ubuntu.
```

Ein Datei-Pfad ist das robusteste, protokollunabhängige Interface — zuverlässiger als
OSC-52-Clipboard-Sync (überträgt nur Text) oder Claude Codes `Ctrl+V` (liest das leere
Server-Clipboard). Validiert in Meilenstein M0, siehe [`m0/M0-validation.md`](m0/M0-validation.md).

---

## Features

**Basis:** SSH-Terminal (SwiftTerm) · Tabs / Multi-Session · Host-Manager (Keychain) ·
`~/.ssh/config`-Import · Snippets · Hauptmenü + Shortcuts · Schriftgröße.

**Terminal-Power:** Auto-Reconnect (Backoff) + TCP-Keep-Alive · Terminal-Suche (Cmd+F) ·
Split-Panes · Themes (humibeam / Mitternacht / Solarized / Dracula / Hell) · Broadcast-Input ·
Befehls-Palette (Cmd+K) · Sitzungs-Wiederherstellung.

**KI-Layer:** Claude-Code-Erkennung (Badge) · Ausgabe erklären · Fehler beheben ·
Befehl vorschlagen (OpenAI / LLMService) · Claude-Benachrichtigungen · Transcript-Mitschnitt (ANSI-bereinigt).

**Datei-Power:** Browser pro Tab · Up/Download · mkdir / umbenennen / löschen / chmod ·
Remote-Datei-Editor (Download→Edit→Upload) · Ordner als `.tar.gz` · Lesezeichen ·
Dual-Pane + Verzeichnis-Sync · Quick Look.

**SSH-Power:** Port-Forwarding (`ssh -L`, directTCPIP) · ProxyJump / Bastion · known_hosts (TOFU).

**humibeam-exklusiv:** Screenshot-Paste · Voice-Diktat ins Terminal · Drag & Drop von Dateien/Bildern ins Terminal.

---

## Bauen & Starten

**Voraussetzungen:** macOS 13+, Xcode 16 (Full, mit Command Line Tools), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
cd HumibeamMac
xcodegen generate          # einmalig / nach Struktur-Änderungen (project.yml → .xcodeproj)

# Schnell (Debug, ad-hoc signiert):
xcodebuild -project HumibeamMac.xcodeproj -scheme HumibeamMac \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath .dd CODE_SIGNING_ALLOWED=NO build
open .dd/Build/Products/Debug/Humibeam.app
```

Oder das vollständige Build-Skript (universal arm64+x86_64, signiert):

```bash
./build.sh --run                                   # Debug, ad-hoc/eigene Identität
./build.sh --release --dmg --notarize              # Release-DMG + Notarisierung (braucht Developer-ID)
```

Signatur-Identität überschreibbar:

```bash
HUMIBEAM_SIGN_IDENTITY="Apple Development: Dein Name (XXXXXXXXXX)" ./build.sh --run
```

> **Hinweis:** Das Xcode-Projekt (`HumibeamMac.xcodeproj`) wird aus `project.yml` generiert und
> ist bewusst **nicht** eingecheckt — immer zuerst `xcodegen generate` ausführen.

**Erstes Verbinden:** Bei `humibeam-Schlüssel`-Auth zeigt der Host-Editor einen Public Key —
einmalig auf dem Server in `~/.ssh/authorized_keys` eintragen (oder Passwort / eigenen Key wählen).

---

## Projektstruktur

```
HumibeamMac/
  App/        AppDelegate (Fenster + Menüleiste), AppState, HumibeamShell (Koordinator)
  SSH/        SSHConnection, SSHAuth, SSHChannels (PTY/Exec), SSHFileTransfer, SSHKeyManager, KnownHosts
  Terminal/   TerminalSessionController, PasteBridge (Screenshot→Upload→Pfad), TerminalRepresentable
  Hosts/      HostStore, MainView (Split-View), HostEditorView, FileBrowserView
  Features/   Voice-Workflows, MenuBar, Settings (aus humitext portiert)
  Services/   Aufnahme, Transkription (WhisperKit/OpenAI), Hotkeys, Keychain (aus humitext)
  Views/      SwiftUI-Views · Resources/  Icon & Assets · project.yml  XcodeGen-Manifest

PLAN.md       Architektur- & Implementierungsplan
STATUS.md     Aktueller Stand, verifizierte Features, Build-Anleitung
m0/ m1/       Meilenstein-Spikes (M0 Paste-Validierung, M1 SSH-Spike) mit Doku
site/         Landing-Page (index.html) + appcast.json
tools/        make_icons.swift, Hilfsskripte
build.sh      Build/Sign/Notarize · release.sh  Release-Automation
appcast.json  Auto-Update-Feed (humibeam.com first, GitHub fallback)
```

## Tech-Stack

- **Terminal:** [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — native, xterm-kompatibel
- **SSH:** [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) — pure Swift, multiplexte Channels (Paste-Upload über bestehende Verbindung ohne 2. Login)
- **Voice:** WhisperKit (lokal) + OpenAI (online)
- **UI/Build:** SwiftUI + AppKit, XcodeGen, Swift 5.10

---

## Roadmap / bewusst offen

- **known_hosts Key-Pinning** — swift-nio-ssh exponiert Host-Key-Bytes nicht öffentlich → aktuell TOFU; vor Public-Release härten.
- **Key-Import** RSA/ECDSA + passphrasen-geschützt (bcrypt-pbkdf); aktuell ed25519 ohne Passphrase.
- **Echtes SFTP via [Citadel](https://github.com/orlandos-nl/Citadel)** — byte-genauer Transfer-Fortschritt, sehr große Dateien.
- **SOCKS / Remote-Forwarding · Agent-Forwarding.**
- Multi-Image-Paste · Paste-Vorschau-Overlay · kombiniertes Voice+Screenshot-Prompting.

Details und Meilenstein-Historie: [`PLAN.md`](PLAN.md) · [`STATUS.md`](STATUS.md).

---

## Herkunft

humibeam ist aus **[humitext](https://github.com/alpvis/humitext)** hervorgegangen
(Speech-to-Text für macOS) und übernimmt dessen Voice-, Keychain-, Hotkey- und Settings-Kern.
Der zentrale Architektur-Bruch: humitext fügt Text per simuliertem `Cmd+V` in Fremd-Apps ein —
humibeam schreibt Text/Pfad direkt in den eigenen PTY-Channel, was die gesamte
Accessibility-/CGEvent-Maschinerie überflüssig macht.
