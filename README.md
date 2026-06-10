# humibeam

**Das macOS-Cockpit für KI-Agenten auf entfernten Servern.**
Ein SSH-Terminal, das für agentische CLIs wie **Claude Code** gebaut ist:
Sprache rein · Screenshots rein · Dateien rein/raus · und ein **Agent-Cockpit**, das
mitliest, was der Agent vorhat, und es als native UI zeigt — alles über **eine** SSH-Verbindung,
auch zu einem nackten Ubuntu-Server **ohne jede serverseitige Installation**.

macOS 13+ · SwiftUI/AppKit · aktuell **v3.4 (Build 34)** · [humibeam.com](https://humibeam.com)

---

## Warum humibeam

Wenn `claude` (Claude Code CLI) über SSH auf einem Remote-Server läuft, ist das Terminal nur
ein Text-Stream (PTY). Klassische SSH-Clients (Termius, iTerm2, Warp, Terminal.app) sehen genau
das: einen Byte-Strom. humibeam sieht **einen Agenten bei der Arbeit** — und macht daraus ein Cockpit:

- Ein Screenshot landet per `Cmd+V` direkt in der Remote-Session.
- Gesprochenes wird zu Text — im Terminal oder in jeder anderen App.
- Will der Agent etwas ausführen oder eine Datei ändern, erscheint eine **Karte mit Befehl/Diff** und Erlauben/Ablehnen — statt blindem `y/n`-Tippen.

Das Beste daran: Es braucht **nichts** auf dem Server. Stock-Ubuntu genügt.

---

## Das Agent-Cockpit (das Herzstück)

humibeam liest Claude Codes Ausgabe mit und rendert sie als echte UI — in drei sich ergänzenden Stufen:

1. **Inline-Approval-Karte** — erkennt Claude Codes Erlaubnis-Prompt und zeigt eine Karte mit
   erkanntem Aktionstyp (Befehl ausführen / Datei bearbeiten / schreiben / lesen / Web), dem
   Befehl bzw. einem farbigen Diff und **Erlauben / Ablehnen / Immer erlauben**. Gefährliche
   Befehle (`rm -rf`, `sudo rm`, `--force`, `drop table` …) färben die Karte **rot**.
   Die Knöpfe senden exakt die Tasten, die Claude erwartet (`1`/`2`/`Esc`).
2. **Echter Diff vom Server** — ein Klick holt den *tatsächlichen* Arbeitsbaum-Diff
   (`git diff HEAD` + untracked Files) über den bestehenden Exec-Channel und zeigt ihn farbig —
   unabhängig vom Terminal-Repaint-Rauschen. Auch jederzeit über den **±**-Knopf in der Toolbar.
3. **Opt-in-Bridge für 100 % exakte Daten** — ein winziger, abhängigkeitsfreier Claude-Code-
   `PreToolUse`-Hook (ein Klick: „Claude-Bridge installieren") meldet jeden Tool-Call als JSON.
   Dann zeigt die Karte das **exakte** Tool, den exakten Befehl und einen echten Diff aus
   `old_string`/`new_string` (grünes „exakt"-Badge). Bleibt optional — der Hook entscheidet nichts,
   Claude zeigt seinen normalen Prompt weiter.

> Kein klassischer SSH-Client kann das kontern, ohne sein ganzes Produkt umzubauen.
> Konzept & Architektur: [`docs/AGENT-COCKPIT.md`](docs/AGENT-COCKPIT.md).

---

## Die drei „Superkräfte"

### 1. Screenshot-Paste über SSH
`Cmd+V` mit einem Bild in der Zwischenablage lädt es über die **bestehende** SSH-Verbindung hoch
(neuer Exec-Channel, kein zweiter Login) und tippt den absoluten Remote-Pfad in die Session —
Claude Code liest das Bild über sein Read-Tool.

```
[Cmd+V im Terminal]
   ├─ Text in der Zwischenablage?  → normaler Paste in den PTY
   └─ Bild (.png/.tiff/.fileURL)?
        1. Bild lokal als PNG schreiben
        2. Exec-Channel auf der bestehenden Verbindung öffnen (kein 2. Login)
        3. Upload nach  ~/.humibeam/pastes/<ts>-<rand>.png
        4. Remote-Pfad als Text in den PTY schreiben  →  Claude liest das Bild
```

Ein Datei-Pfad ist das robusteste, protokollunabhängige Interface — zuverlässiger als OSC-52
(nur Text) oder Claude Codes `Ctrl+V` (liest das leere Server-Clipboard).

### 2. Sprach-Diktat — überall
Hotkey halten, sprechen, loslassen. Ist das humibeam-Terminal fokussiert, landet der Text **in der
Remote-Session**; bist du in einer anderen App (Mail, Notes, Browser …), wird er **global ins
Vordergrund-Programm** eingefügt. Transkription **lokal** (WhisperKit, offline) oder **online**
(OpenAI). Mit Prompt-Profilen (Nachricht, E-Mail, Stichpunkte …), die das Gesagte zugleich sauber
formulieren.

### 3. Dateitransfer ohne Server-Setup
Integrierter Datei-Browser über dieselbe Verbindung — Up/Download, Drag & Drop rein/raus, mkdir,
umbenennen, löschen, chmod, Remote-Editor (Download → Edit → Upload), Ordner als `.tar.gz`,
Dual-Pane mit Verzeichnis-Sync und Quick Look. Upload via Exec-Channel (`cat > datei`) — **kein
SFTP-Daemon nötig.**

---

## Alle Funktionen im Überblick

**Terminal:** SSH-Terminal (SwiftTerm, xterm-kompatibel) · Multi-Session mit Sidebar ·
Umschalter Terminal / Dateien / Split · Terminal-Suche (⌘F) · Themes (humibeam / Mitternacht /
Solarized / Dracula / Hell) · Schriftgröße · Broadcast-Input (an alle Sessions) ·
Befehls-Palette (⌘K) · Sitzungs-Wiederherstellung.

**Verbindung:** Auto-Reconnect mit Backoff · TCP-Keepalive (erkennt halb-offene Links) ·
netzwerk-bewusstes Pausieren/Fortsetzen · Host-Manager mit Keychain · `~/.ssh/config`-Import ·
Passwort- oder Key-Auth · ProxyJump / Bastion · Port-Weiterleitung (`ssh -L`) · known_hosts (TOFU).

**Agent-Cockpit:** Claude-Code-Erkennung · Inline-Approval-Karten (Befehl/Diff/Risiko) ·
echter `git diff` vom Server · opt-in PreToolUse-Bridge für exakte Tool-Calls ·
Benachrichtigung „Claude wartet" / „Claude fertig" · berührte-Dateien-Erkennung.

**KI-Hilfe:** Ausgabe erklären · Fehler beheben · Befehl vorschlagen · Transcript-Mitschnitt (ANSI-bereinigt).

**Dateien:** Browser pro Session · Up/Download · Drag & Drop · mkdir/umbenennen/löschen/chmod ·
Remote-Editor · `.tar.gz`-Download · Lesezeichen · Dual-Pane + Sync · Quick Look.

**humibeam-exklusiv:** Screenshot-Paste über SSH · globales Sprach-Diktat · Drag & Drop von Bildern/Dateien ins Terminal.

**App:** notarisiert (Developer ID) · **Auto-Update** mit sichtbarer Versionsanzeige und „Nach
Updates suchen" in der Seitenleiste · lebt in der Menüleiste, Terminal-Fenster auf Abruf.

---

## Installation

Neueste notarisierte Version von den [**Releases**](https://github.com/alpvis/humibeam/releases/latest)
laden (`Humibeam.dmg`), nach `/Applications` ziehen, öffnen. Updates danach automatisch in der App.

**Voraussetzungen zur Laufzeit:** macOS 13+. Für lokales Diktat das Mikrofon erlauben; fürs
**globale** Einfügen in andere Apps einmalig *Systemeinstellungen → Datenschutz & Sicherheit →
Bedienungshilfen → Humibeam* aktivieren.

**Erstes Verbinden:** Profil anlegen (Host, User, Passwort oder Key). Bei `humibeam-Schlüssel`-Auth
zeigt der Editor einen Public Key — einmalig auf dem Server in `~/.ssh/authorized_keys` eintragen.

---

## Aus dem Quellcode bauen

**Voraussetzungen:** macOS 13+, **Xcode (Full)** inkl. Metal-Toolchain
(`xcodebuild -downloadComponent MetalToolchain`), [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
./build.sh --run                       # Debug, ad-hoc oder eigene Identität, startet die App
./build.sh --install --release         # Universal (arm64+x86_64), signiert, nach /Applications
./build.sh --release --dmg --notarize  # Release-DMG + Notarisierung (braucht Developer-ID + Notary-Profil)
```

Signatur-Identität überschreibbar:

```bash
HUMIBEAM_SIGN_IDENTITY="Apple Development: Dein Name (XXXXXXXXXX)" ./build.sh --run
```

**Veröffentlichen** (baut notarisiert, legt das GitHub-Release an, aktualisiert den Auto-Update-Feed):

```bash
./release.sh 3.4 34 "Was ist neu"
```

> Das Xcode-Projekt wird aus `HumibeamMac/project.yml` generiert (XcodeGen) und ist bewusst **nicht**
> eingecheckt — `build.sh` ruft `xcodegen generate` automatisch auf.

---

## Projektstruktur

```
HumibeamMac/
  App/        AppDelegate (Fenster + Menüleiste), AppState, HumibeamShell, SessionManager
  SSH/        SSHConnection, SSHAuth, SSHChannels (PTY/Exec), SSHFileTransfer, SSHKeyManager, KnownHosts
  Terminal/   TerminalSessionController · PasteBridge (Screenshot→Upload→Pfad)
              ClaudeApproval (Approval-Parser) · GitDiffService · ClaudeBridge (PreToolUse-Hook)
  Hosts/      MainView (Studio-Layout) · FileBrowserView · FileManagerView · HostEditorView · CommandPalette
  Features/   Voice-Workflows · MenuBar · Settings · Enhancements (UpdateService)
  Services/   Aufnahme · Transkription (WhisperKit/OpenAI) · Hotkeys · Keychain · Accessibility
  Resources/  Icon & Assets · Info.plist · Entitlements · project.yml (XcodeGen-Manifest)

docs/AGENT-COCKPIT.md   Konzept & Architektur des Agent-Cockpits
tools/humibeam-hook.sh  Claude-Code PreToolUse-Hook (Stufe 3)
build.sh · release.sh   Build/Sign/Notarize · Release-Automation
appcast.json            Auto-Update-Feed (humibeam.com first, GitHub raw als Fallback)
```

## Tech-Stack

- **Terminal:** [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — native, xterm-kompatibel (Metal-Rendering)
- **SSH:** [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) — pure Swift, multiplexte Channels (Paste-Upload & `git diff` über die bestehende Verbindung, kein 2. Login)
- **Voice:** [WhisperKit](https://github.com/argmaxinc/WhisperKit) (lokal/offline) + OpenAI (online)
- **UI/Build:** SwiftUI + AppKit · XcodeGen · Swift 5.10

---

## humibeam für iOS (neu)

Die iPhone/iPad-App liegt in [`HumibeamiOS/`](HumibeamiOS/) und teilt sich den kompletten
SSH-Kern und das Agent-Cockpit (Approval-Parser, Git-Diff, Claude-Bridge) mit der Mac-App:

- **SSH-Terminal unterwegs** (SwiftTerm) mit Tasten-Leiste über der Tastatur
  (Esc · Tab · ⇧Tab · Ctrl · ^C · Pfeile · Sonderzeichen) — gemacht für die Claude-Code-TUI.
- **Approval-Karten** wie am Mac: Erlauben / Immer / Ablehnen, gefährliche Befehle rot.
- **Echter Diff vom Server** (±-Knopf) über den Exec-Channel.
- **Bild-Upload in die Session**: Zwischenablage oder Fotobibliothek → Upload über die
  bestehende Verbindung → Pfad wird eingetippt, Claude liest das Bild.
- Profile mit humibeam-Schlüssel / Passwort / eigenem Key, ProxyJump, known_hosts-Pinning,
  Auto-Reconnect — alles derselbe Code wie am Mac.

Bauen: `cd HumibeamiOS && xcodegen generate && xcodebuild -scheme HumibeamiOS \
-destination 'platform=iOS Simulator,name=iPhone 17' build`

## Roadmap

- **iOS: Push „Claude wartet auf dich"** — Benachrichtigung + Erlauben/Ablehnen vom Sperrbildschirm.
- **Fleet-View** — mehrere Agenten auf mehreren Servern in einem Dashboard.
- **Konversationelles Voice** — sprechen → Claude antwortet → TTS liest die Zusammenfassung vor.
- **Echtes SFTP via [Citadel](https://github.com/orlandos-nl/Citadel)** — byte-genauer Fortschritt, sehr große Dateien.
- **Key-Import** RSA/ECDSA + passphrasen-geschützt · Host-Key-Pinning härten · Agent-/Remote-Forwarding.

---

## Herkunft

humibeam ist aus **[humitext](https://github.com/alpvis/humitext)** hervorgegangen
(Speech-to-Text für macOS) und übernimmt dessen Voice-, Keychain-, Hotkey- und Settings-Kern.
Diktat funktioniert weiterhin **überall** (per simuliertem `Cmd+V` in Fremd-Apps) — und schreibt
zusätzlich Text/Pfade direkt in den eigenen PTY-Channel, wenn das Terminal fokussiert ist.
