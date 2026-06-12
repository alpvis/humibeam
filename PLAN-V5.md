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

### Welle 2 — iOS-Parität  ☐
- [ ] **P11** Datei-Browser iOS (geteilte SSHFileTransfer; Listing/Up-/Download/Share-Sheet)
- [ ] **P12** Multi-Session/Tabs + iPad Split View + Hardware-Tastatur-Shortcuts
- [ ] **P13** Transcript-Archiv iOS (Mitschnitt auf Platte + durchsuchbare Liste)
- [ ] **P14** Server-Health in der Hostliste (Load/RAM/Disk-Ampel, exec-Kanal, 30 s)
- [ ] **P15** Port-Forwarding iOS (directTCPIP wie Mac, Verwaltungs-Sheet)
- [ ] **P16** Terminal-Schriftarten + Größen-Presets iOS
- [ ] **P17** Face-ID-Schutz (App-weit, LocalAuthentication)
- [ ] **P18** On-Device-Diktat (SFSpeechRecognizer lokal als Alternative zu OpenAI-Whisper)

### Welle 3 — KI-Cockpit  ☐
- [ ] **P5** Agent-Inbox: wartende Approvals über alle Sessions (Mac-Fenster + iOS-Tab)
- [ ] **P19** KI-Knöpfe iOS: Ausgabe erklären / Fehler beheben / Befehl vorschlagen (LLMService teilen)
- [ ] **P20** Claude-Status Plus: liest/editiert/baut/wartet als Live-Status (Liste + Statuszeile)

### Welle 4 — Push & Glanz  ☐
- [ ] **P7** Actionable Push: Erlauben/Immer/Ablehnen aus der iOS-Mitteilung; Rückkanal über
      Push-Relay → Mac (Relay um /actions-Polling o. WebSocket erweitern)
- [ ] **P8** Apple-Watch-App (Approvals + Server-Ampel; WatchConnectivity)
- [ ] **P9** Widgets + Live Activity (Agent-Status, Dynamic Island; WidgetKit-Extension)
- [ ] **P10** App Intents/Siri: Snippet auf Server ausführen, Server-Status

### Welle 5 — Symbiose Mac ↔ iOS  ☐
- [ ] **P2** „Mein Mac als Server": Mac-App zeigt QR (Host/Port/User + Public Key →
      authorized_keys lokal eintragen, Remote-Login-Anleitung), iOS scannt → Profil fertig
- [ ] **P4** Session-Handoff: tmux-Sessions als Handoff-Activity (NSUserActivity) Mac↔iOS
- [ ] **P6** Fleet-Übersicht iOS (Server + Agenten + Freigaben, wie Mac ⌘⇧F)

### Welle 6 — MacBeam Remote Desktop  ☐
- [ ] **P3** Mac: ScreenCaptureKit → VideoToolbox H.264 → TCP (Bonjour `_macbeam._tcp`) ·
      iOS: Decode + AVSampleBufferDisplayLayer, Touch→Maus, Tastatur, Scroll, Pinch-Zoom ·
      Eingabe am Mac via CGEvent (braucht Bedienungshilfen + Bildschirmaufnahme — Ali erteilt einmalig) ·
      unterwegs: Tunnel-Dienst auf alpvis.com (`server/beam-tunnel/`, Token-Auth, E2E via Noise/AES)
      — pragmatisch: Wiederverwendung des SSH-Port-Forwards über einen beliebigen SSH-Host

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
