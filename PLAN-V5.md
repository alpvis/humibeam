# humibeam v5 — „Symbiose": 25 Funktionen, 7 Wellen

> Auftrag (2026-06-12): Alle 25 Funktionen umsetzen. **Ein großes Release am Ende**
> (TestFlight + notarisiertes DMG + appcast). Bis dahin nur Commits.
> **WICHTIG:** Ali arbeitet selbst über das Humibeam-Terminal → die laufende Mac-App
> in /Applications NIEMALS anfassen/neustarten; Updates stößt Ali selbst an.
> Entscheidungen: eigenes Konto-Backend auf alpvis.com (E2E-verschlüsselt) ·
> Remote Desktop lokal (Bonjour) + unterwegs (Tunnel über Server) · Deploy per SSH durch Claude
> (Key liegt bereit: ~/.ssh/id_ed25519.pub muss in authorized_keys auf alpvis.com — Ali gefragt).

## Fortschritt

### Welle 1 — Fundament: Konto + Sync v2  ✅ (Code fertig + e2e-getestet; Server-Deploy offen, wartet auf SSH-Zugang)
- [x] **P1** Humibeam-Konto: Server `server/sync/` (Node, ohne deps, Port 8798, systemd
      `humibeam-sync`, nginx-Location `/humibeam-sync/` auf alpvis.com).
      Schema Bitwarden-artig: PBKDF2(600k) → masterKey; HKDF→authKey (Server speichert Hash),
      HKDF→encKey (nur Client, AES-GCM). Endpunkte: POST /register, POST /login (→ Token),
      GET /salt, GET/PUT /blob (rev-basiert, Last-Writer-Wins wie CloudSyncService).
- [x] **P1** Client: `HumibeamMac/Services/AccountSync/` (AccountCrypto + AccountSyncService,
      CommonCrypto PBKDF2 + CryptoKit HKDF/AES-GCM), geteilt mit iOS via project.yml.
      Payload: hosts, snippets, themeID, fontName/fontSize, Lesezeichen; Secrets bleiben im Keychain.
      Carry-forward: nil-Felder werden beim Push vom letzten Server-Stand übernommen.
- [x] **P1** UI: Mac Settings-Tab „Konto" (AccountSettingsView), iOS Settings-Sektion (AccountSection).
      CloudSyncService (iCloud-Drive-Datei) bleibt parallel bestehen.
- [x] **P21** Snippet-/Prompt-Bibliothek synchronisiert (steckt im Payload).
- [x] e2e verifiziert: Swift-Crypto (AccountCrypto kompiliert standalone) gegen lokalen Server —
      register/login/Blob-Roundtrip/falsches Passwort. Test: /tmp/acct-e2e/main.swift
- [ ] OFFEN: Deploy auf alpvis.com (server/sync/install.sh + nginx-Location) — SSH-Key von Ali nötig

### Welle 2 — iOS-Parität  ✅
- [x] **P11** Datei-Browser iOS: FilesSheet (listDetailed, Up-/Download, Teilen, Editor,
      mkdir/umbenennen/chmod/löschen, Lesezeichen aus BookmarkStore — synct übers Konto)
- [x] **P12** Multi-Session: TerminalSession-Modell, Navigation über Session-UUIDs,
      Session-Leiste im Terminal, „Neue Sitzung zu diesem Server" (⌘T), Liste „Aktive
      Sitzungen", Shortcuts ⌘N/⌘T/⌘J/⌘⇧D für iPad-Hardware-Tastatur
- [x] **P13** Transcript-Archiv iOS: TerminalController archiviert wie der Mac nach
      Application Support/Humibeam/Transcripts/<Host>/; TranscriptArchiveSheet mit Inhaltssuche
- [x] **P14** Server-Health: ServerHealth.swift geteilt, AppModel pollt 30 s, Ampel in HostRow
- [x] **P15** Port-Forwarding: AppModel.forwards + ForwardsSheet („In Safari öffnen")
- [x] **P16** Schriftarten: fontName im AppModel (synct mit Mac terminal.fontName),
      Monospace-Picker + Größen-Presets in den Einstellungen
- [x] **P17** Face-ID: appLock()-Modifier (LocalAuthentication, Sperre bei Hintergrund)
- [x] **P18** On-Device-Diktat: SFSpeechRecognizer-Pfad in DictationService
      (Einstellungen → „Lokal transkribieren"), Whisper bleibt Alternative

### Welle 3 — KI-Cockpit  ✅
- [x] **P5** Agent-Inbox: iOS-Sektion „Wartet auf Freigabe" (Inline Erlauben/Ablehnen, Tap öffnet
      Sitzung); Mac: Dock-Badge mit Anzahl wartender Freigaben (FleetView hatte Karten schon)
- [x] **P19** KI-Knöpfe iOS: AIPanel (erklären/beheben/vorschlagen), LLMService gesplittet →
      LLMCore.swift geteilt (humitext-Funktionen bleiben Mac-only in LLMService.swift)
- [x] **P20** Claude-Status Plus: ClaudeActivity.swift (geteilt) parst „liest X / bearbeitet Y /
      führt aus: Z / wartet" — iOS-Statuszeile + Sitzungsliste

### Welle 4 — Push & Glanz  ✅
- [x] **P7** Actionable Push: Relay sendet category HUMIBEAM_APPROVAL + sessionID,
      iOS beantwortet aus der Mitteilung (POST /action), Mac pollt /actions alle 3 s solange
      Freigaben offen sind und drückt 1/2/Esc — e2e-getestet (Relay lokal)
- [x] **P8** Watch-App: HumibeamWatch-Target (Freigaben beantworten + Server-Ampel),
      PhoneWatchBridge (WCSession, ApplicationContext hin / sendMessage zurück)
- [x] **P9** Widget (ServerStatusWidget, App-Group group.app.humibeam, StatusSnapshot) +
      Live Activity (ClaudeLiveActivity, Dynamic Island; App-getriebene Updates via 5-s-Abgleich)
- [x] **P10** App Intents: RunSnippetIntent + ServerStatusIntent + AppShortcuts (Siri)

### Welle 5 — Symbiose Mac ↔ iOS  ✅
- [x] **P2** QR-Pairing: Mac (Einstellungen → Konto → „iPhone koppeln") erzeugt ed25519-Paar,
      trägt Public Key selbst in ~/.ssh/authorized_keys ein, prüft Port 22, zeigt QR
      (MacPairingPayload, geteilt); iOS scannt (PairScanSheet, AVFoundation) → Profil mit
      AuthKind.pairedKey + tmux fertig. ACHTUNG: neuer AuthKind-Fall — alte App-Versionen
      können gesyncte hosts.json damit nicht lesen → beide Apps zusammen releasen.
- [x] **P4** Handoff: NSUserActivity app.humibeam.session in beide Richtungen
      (Mac publiziert bei Tab-Wechsel, AppDelegate empfängt; iOS .userActivity/.onContinue);
      iOS-Info.plist auf xcodegen info:-Block migriert (App-Info.plist generiert)
- [x] **P6** Fleet-Übersicht iOS (FleetSheet: Vitalwerte, Sitzungen, Claude-Status, Freigaben)

### Welle 6 — MacBeam Remote Desktop  ✅ (Code fertig; echtes Video/Input braucht physische Geräte + Berechtigungen — Alis Test)
- [x] **P3** Geteilt: BeamProtocol.swift (AES-GCM-Pakete, HKDF aus Pairing-beamSecret, Kanal-ID)
      · Mac: MacBeamServer (ScreenCaptureKit 20fps ≤1728px → VTCompression H.264 → TCP :8765
      + Bonjour, CGEvent-Injektion Maus/Tastatur/Scroll/Drag; Toggle in Einstellungen → Konto)
      · iOS: BeamClient (direkt → 4s-Fallback Tunnel) + BeamScreen (AVSampleBufferDisplayLayer,
      Gesten: Tap/Doppeltipp/LongPress-Drag/2-Finger-Scroll/Rechtsklick, Tastatur + ⌘-Leiste;
      Einstieg: Swipe/Kontextmenü auf gekoppelten Hosts)
      · Tunnel: server/beam-tunnel (Rendezvous, nur Chiffrat; lokal e2e-getestet) + install.sh
      · beamSecret steckt im Pairing-QR (MacPairingPayload.beam) — alte Kopplungen neu scannen

### Welle 7 — Mac-Härtung  ☐
- [ ] **P22** known_hosts Key-Pinning (Host-Key-Bytes aus nio-ssh ziehen, pinnen, Mismatch-Warnung)
- [ ] **P23** Key-Import RSA/ECDSA + Passphrase (OpenSSH-Format, bcrypt-pbkdf)
- [ ] **P24** Echtes SFTP via Citadel (Fortschritt, große Dateien, Dual-Pane)
- [ ] **P25** Menüleisten-Mini-Cockpit (Approvals + Server-Ampel im MenuBarView)

### Release (ganz am Ende)  ☐
- [ ] Mac 5.0 (Build 50): build.sh --release --dmg --notarize, appcast.json + site aktualisieren,
      GitHub-Release — Ali installiert selbst über die Update-Funktion
- [ ] iOS 2.0: tools/testflight.sh
- [ ] STATUS.md/README aktualisieren, Push

## Architektur-Notizen
- Sync-URL-Default: `https://alpvis.com/humibeam-sync` (analog Push: `https://alpvis.com/humibeam-push`)
- Server-Layout: /home/ali/humibeam-sync (Daten ./data/<account>.json), Dienst humibeam-sync (8798)
- iOS teilt Mac-Code über HumibeamiOS/project.yml `sources:` — neue geteilte Dateien dort eintragen
- Beide Apps nach jeder Welle bauen (Mac: HumibeamMac/.dd, iOS: HumibeamiOS/.dd, CODE_SIGNING_ALLOWED=NO)
