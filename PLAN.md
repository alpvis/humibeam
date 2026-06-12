# humibeam — Architektur- & Implementierungsplan

> **Positionierung:** Der SSH-Client, der für agentische CLIs (Claude Code & Co.) gebaut ist.
> Sprache rein · Screenshots rein · Dateien rein/raus — alles über **eine** SSH-Verbindung,
> auch zu einem nackten Ubuntu-Server ohne jede Server-seitige Installation.

Status: Plan v1 · macOS-only zum Start · baut auf dem wiederverwendbaren Kern von Humitext auf.

---

## 1. Warum humibeam existiert

Wenn `claude` (Claude Code CLI) über SSH auf einem Remote-Server läuft, ist das Terminal nur
ein Text-Stream (PTY). Ein Screenshot im lokalen Mac-Clipboard ist für den entfernten
`claude`-Prozess unsichtbar — Claude Codes eigenes Bild-Einfügen liest immer das Clipboard
*der Maschine, auf der es läuft* (= der Server). Deshalb kann heute **kein** SSH-Client
(Termius, iTerm2, Warp, Terminal.app) Screenshots in eine Remote-Claude-Code-Session geben.

humibeam schließt genau diese Lücke — und kombiniert sie mit Voice-Diktat (aus Humitext)
und vollem SFTP-Dateitransfer zu einem Remote-Cockpit für agentische CLIs.

### Alleinstellungsmerkmale
1. **Screenshot-Paste über SSH** — `Cmd+V` mit Bild lädt es automatisch hoch und tippt den Remote-Pfad.
2. **Voice-Diktat in die Remote-Session** — Hotkey halten, sprechen, transkribierter Text landet im Terminal.
3. **SFTP/SCP integriert** — Datei-Browser, Drag & Drop rein/raus, über dieselbe Verbindung.
4. **Zero-Install auf dem Server** — funktioniert mit Stock-Ubuntu, nichts muss remote installiert werden.

---

## 2. Der Kern-Trick: Screenshot-Paste-Bridge

Der heikelste und wichtigste Mechanismus. So funktioniert er konkret:

```
[Cmd+V im Terminal]
   │
   ├─ NSPasteboard enthält Text?  → normaler Paste in den PTY-Channel (wie gewohnt)
   │
   └─ NSPasteboard enthält Bild (.png/.tiff/.fileURL)?
        1. Bild als PNG in temp schreiben (lokal)
        2. Über bestehende SSH-Verbindung NEUEN SFTP-/Exec-Channel öffnen (kein 2. Login!)
        3. Upload nach  ~/.humibeam/pastes/<unix-ts>-<rand>.png  (Verzeichnis lazy anlegen)
        4. Remote-Pfad als Text in den PTY-Channel schreiben:  /home/user/.humibeam/pastes/...png
        5. (optional) ein Leerzeichen anhängen, damit Claude Code den Pfad sauber parst
   →  Claude Code liest das Bild über den Pfad. Funktioniert auf Stock-Ubuntu.
```

### Warum „Pfad einfügen" statt „Clipboard syncen"?
- OSC 52 (Clipboard-Sync übers Terminal) überträgt **Text**, keine Bild-Bytes zuverlässig.
- Claude Codes Ctrl+V liest das *Server*-Clipboard — auf einem headless-Server leer.
- Ein Datei-Pfad ist das robusteste, protokollunabhängige Interface: Claude Code liest
  referenzierte Bilddateien zuverlässig (gleiches Verhalten wie Drag & Drop eines Bildes).

### Validierung (Meilenstein 0) — ✅ BESTANDEN
Verifiziert (lokal, Claude Code 2.1.168): Claude Code liest ein per Pfad referenziertes Bild
über sein **Read-Tool** zuverlässig — schon das Einfügen des **nackten Pfads** löst das Lesen
aus. Der dokumentierte `[Image #N]`-Clipboard-Paste liest dagegen das Server-Clipboard und ist
auf headless Servern wirkungslos. Details, Server-Test-Skript und Fallback-Reihenfolge:
siehe [`m0/M0-validation.md`](m0/M0-validation.md).

**Befund mit Designfolge:** Read braucht eine Freigabe, wenn das Bild außerhalb des
Session-cwd liegt → MVP: eine Enter-Bestätigung pro Bild; V1: Upload ins `<cwd>/.humibeam/pastes/`
oder Paste-Dir per Allowlist freigeben.

### Aufräumen
- `~/.humibeam/pastes/` bekommt eine Größen-/Alters-Obergrenze; beim Verbinden alte Pastes löschen.
- Optional: Datei nach erfolgreichem Senden behalten (Claude Code braucht sie ggf. später erneut).

---

## 3. Architektur & Module

```
humibeam/
  App/
    HumibeamApp.swift            App-Entry, NSApplicationDelegate
    AppState.swift               zentraler @Observable State (Verbindungen, aktive Session)
    MenuBar / Window             Hauptfenster mit Tabs/Sessions (statt nur Popover)
  Terminal/
    TerminalView.swift           SwiftTerm-Wrapper (PTY-Darstellung)
    TerminalController.swift     Eingabe/Ausgabe, Cmd+V-Interception
  SSH/
    SSHConnection.swift          swift-nio-ssh: Auth, Channel-Management, Keepalive
    SSHChannel+PTY.swift         interaktiver Shell-Channel
    SFTPClient.swift             Upload/Download, Verzeichnis-Listing
    PasteBridge.swift            ← DER KERN: Bild erkennen → Upload → Pfad einfügen
    KnownHosts.swift             Host-Key-Verifikation
  Files/
    FileBrowserView.swift        SFTP-Browser, Drag & Drop rein/raus
  Hosts/
    HostStore.swift              gespeicherte Verbindungen (Keychain für Secrets)
    HostEditorView.swift         Verbindung anlegen/bearbeiten
  Voice/                         ← aus Humitext portiert
    VoiceInputService.swift      Aufnahme → Transkription → Text-Callback
    (WhisperKit lokal / OpenAI online)
  Shared/
    KeychainService.swift        (aus Humitext)
    HotkeyService.swift          (aus Humitext)
    ClipboardService.swift       NEU: Text- UND Bild-Erkennung
    Settings, History, Update    (aus Humitext)
```

### Datenfluss einer Session
```
HostStore → SSHConnection (auth) → PTY-Channel ↔ TerminalView
                                  └→ SFTP-Channel ← PasteBridge ← ClipboardService (Cmd+V)
                                                  ← FileBrowser (Drag&Drop)
VoiceInputService (Hotkey) → transkribierter Text → PTY-Channel
```

---

## 4. Migration aus Humitext (was wir direkt übernehmen)

| Humitext-Komponente | In humibeam | Anpassung |
|---|---|---|
| `HotkeyService` | Voice-Hotkey + evtl. Paste-Hotkey | 1:1 übernehmen |
| `KeychainService` | SSH-Keys, Passwörter, API-Keys | Key-Typen erweitern |
| Auto-Paste-Engine (`CGEvent`) | **entfällt** | wir schreiben direkt in den PTY-Channel statt System-Paste |
| Voice-Pipeline (Workflows) | `VoiceInputService` | auf „liefere Text an Terminal" reduzieren |
| WhisperKit/OpenAI Transkription | identisch | 1:1 |
| `NSPasteboard`-Handling | `ClipboardService` | **Bild-Typen ergänzen** (.png/.tiff/.fileURL) |
| Settings/History/Update/Onboarding | identisch | UI an Terminal-Kontext anpassen |
| Menüleisten-Pattern | Hauptfenster + optional Menüleiste | von Popover → echtes Fenster mit Tabs |

**Architektur-Bruch:** Humitext fügt Text per simuliertem `Cmd+V` in *fremde* Apps ein.
humibeam schreibt Text/Pfad direkt in den eigenen PTY-Channel — die ganze
`PasteTarget`/`CGEvent`-Maschinerie entfällt, was viel Accessibility-Komplexität spart.

---

## 5. Tech-Stack & Dependencies

- **Terminal-Emulator:** [`SwiftTerm`](https://github.com/migueldeicaza/SwiftTerm) — ausgereift, native macOS-View, xterm-kompatibel.
- **SSH:** [`swift-nio-ssh`](https://github.com/apple/swift-nio-ssh) — pure Swift, von Apple, **multiplexte Channels** (entscheidend: Paste-Upload über bestehende Verbindung ohne 2. Login). **In M1 bestätigt** (Auth, PTY, Multi-Channel).
  - **Paste-Upload:** Exec-Channel `cat > datei` — kein SFTP, läuft auf Stock-Ubuntu (M1 bewiesen, bit-identisch).
  - **Datei-Browser (V1):** echtes SFTP via [`Citadel`](https://github.com/orlandos-nl/Citadel) auf nio-ssh; Fallback Exec-`ls`/`cat`.
- **Voice:** WhisperKit (lokal) + OpenAI (online) — aus Humitext.
- **UI:** SwiftUI + AppKit-Brücken, Build via XcodeGen (`project.yml`) wie Humitext.
- **Min. macOS 14**, Xcode 16, ad-hoc signiert fürs Dev, später Developer-ID + Notarisierung.

---

## 6. Feature-Set: MVP → Ultimativ

### MVP (beweist die Kern-Story)
- [ ] SSH-Verbindung per Key & Passwort, Host-Key-Prüfung (known_hosts).
- [ ] Interaktives Terminal (SwiftTerm) mit funktionierender `claude`-TUI.
- [ ] **Screenshot-Paste-Bridge** — `Cmd+V` mit Bild → Upload → Pfad einfügen.
- [ ] Verbindungen speichern (Keychain).

### V1 (rund)
- [ ] SFTP-Datei-Browser, Drag & Drop rein/raus.
- [ ] Voice-Diktat in die Session (Hotkey, lokal via WhisperKit).
- [ ] Mehrere Tabs/Sessions, Reconnect/Keepalive.
- [ ] Paste-Verzeichnis-Cleanup.

### „Ultimativ" (Differenzierung)
- [ ] Multi-Image-Paste, Paste-Vorschau-Overlay vor dem Senden.
- [ ] Drag & Drop eines lokalen Bildes direkt ins Terminal (= gleicher Upload-Pfad).
- [ ] Voice + Screenshot kombiniert: sprechen *und* Bild in einem Prompt.
- [ ] „Claude-Code-Mode": erkennt laufende `claude`-Session, optimiertes Pfad-Format/Hints.
- [ ] Port-Forwarding, SSH-Config-Import (`~/.ssh/config`), Jump-Hosts.
- [ ] Snippet-/Prompt-Bibliothek, Session-Logging/History (aus Humitext).
- [ ] Sync der Hosts über Geräte (später, mit Backend — vorerst lokal).

---

## 7. Meilensteine

| M | Ziel | Erfolgskriterium |
|---|---|---|
| **M0** ✅ | Tech-Annahme validieren | **BESTANDEN** — Bild per Pfad-Verweis (nackter Pfad) wird via Read gelesen; siehe `m0/` |
| **M1** ✅ | SSH-Spike | **BESTANDEN** — nio-ssh: Auth, PTY-Shell, Upload via Exec-Channel (bit-identisch); SFTP-Entscheidung getroffen; siehe `m1/` |
| **M2** ✅ | Terminal | **GEBAUT** — SwiftTerm an SSH-PTY gekoppelt (bidirektional + Resize); kompiliert |
| **M3** ✅ | **Paste-Bridge** | **GEBAUT** — `Cmd+V` Bild → Exec-Upload → absoluter Pfad in Session; Upload-Pfad e2e getestet |
| **M4** ✅ | Host-Management | **GEBAUT** — HostStore (Keychain), Editor, managed/Passwort/importierter Key, known_hosts (TOFU) |
| **M5** ✅ | Datei-Browser | **GEBAUT** — Listing/Upload/Download über Exec-Channel; e2e gegen localhost getestet |
| **M6** ✅ | Voice | **GEBAUT** — Humitext-Voice portiert, schreibt bei fokussiertem Terminal direkt in die Session |
| **M7** ◐ | Politur | App-Shell (Fenster + Menüleiste) gebaut, baut + startet; offen: Icon, Tabs, Reconnect, Drag&Drop |

---

## 8. Risiken & Gegenmaßnahmen

- **R1 — Claude Code liest Remote-Pfad nicht zuverlässig.** → M0 zuerst. Fallbacks: `@pfad`, Drag&Drop-Pfadformat, Anführungszeichen/Space.
- **R2 — swift-nio-ssh hat kein fertiges SFTP.** → Citadel oder libssh2 evaluieren; im Notfall Bild-Upload per `cat > datei` über Exec-Channel + base64.
- **R3 — Terminal-Kompatibilität mit TUIs (claude, vim, htop).** → SwiftTerm ist xterm-kompatibel; früh mit echtem `claude` testen.
- **R4 — Accessibility/Signierung.** → Entfällt weitgehend, da kein Fremd-App-Paste mehr; nur Mikrofon-Permission für Voice.
- **R5 — Performance großer Uploads blockiert UI.** → Upload async auf eigenem Channel, Fortschritts-Overlay.

---

## 9. Offene Fragen (vor Bau zu klären)

1. ~~**SFTP-Lib:** nio-ssh+Citadel vs. libssh2~~ → **in M1 geklärt:** Paste-Upload via Exec-Channel (kein SFTP), Datei-Browser via Citadel in V1.
2. **UI-Form:** Vollwertiges Fenster mit Tabs (wie Terminal/iTerm) — ja, vs. Menüleisten-only (nein, zu klein für ein Terminal).
3. **Voice von Anfang an** oder erst nach SSH-Kern? → Plan: SSH-Kern zuerst (MVP), Voice in M6.
4. ~~**Open Source?**~~ → **Entschieden (2026-06-12): Proprietär.** Code öffentlich sichtbar, aber alle Rechte bei der HUMIQA GmbH (siehe LICENSE).
5. **Zielgruppe-Scope:** nur Claude Code, oder generisch für jede agentische CLI (Aider, etc.)?

---

## 10. Sofort-Nächster-Schritt

**M0 ausführen** — die einzige Annahme verifizieren, die alles trägt:
Auf einem echten Ubuntu-Server `claude` starten, ein hochgeladenes Bild per Pfad in den
Prompt tippen, prüfen ob es gelesen wird. Erst danach lohnt der SSH/Terminal-Bau.
