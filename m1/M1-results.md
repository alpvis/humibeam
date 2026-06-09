# M1 — SSH-Spike: Ergebnis

**Ziel:** `swift-nio-ssh` evaluieren — verbinden, interaktive PTY-Shell (Bytes hin/zurück),
Datei-Transfer-Weg klären.

**Ergebnis: ALLE TESTS BESTANDEN ✅** — live gegen einen echten SSH-Server (localhost-sshd)
verifiziert, nicht nur kompiliert. Swift 6.3.2, swift-nio-ssh 0.13.0.

---

## 1. Was bewiesen wurde

| Test | Mechanismus | Ergebnis |
|---|---|---|
| **Connect + Auth** | `swift-nio-ssh` Client, **ed25519 Public-Key-Auth** | ✅ verbunden + authentifiziert |
| **PTY-Shell** | PTY-Request (`xterm-256color`, 120×40) + Shell-Request, stdin→Befehl, stdout→Ausgabe | ✅ Bytes hin **und** zurück; echte xterm-Escapes + Prompt empfangen |
| **Datei-Upload** | **Exec-Channel** `cat > datei` mit Bild-Bytes als stdin + EOF (Half-Close) | ✅ exit 0 |
| **Integrität** | Remote-`sha256sum` vs. lokaler Hash | ✅ **bit-identisch** |

Der PTY-Test lieferte rohe Terminal-Sequenzen (`[?2004h`, Cursor-Steuerung, Prompt) — exakt
das, was der Terminal-Emulator (SwiftTerm) in M2 rendern wird. Die SSH-Transport-Schicht liefert
also einen voll funktionsfähigen interaktiven PTY-Stream.

Außerdem implizit bewiesen: **mehrere Channels über eine Verbindung** (3 Sessions nacheinander
auf demselben Socket) — die Grundlage für „Upload läuft, während die Terminal-Session offen bleibt".

---

## 2. Die SFTP-Entscheidung (M1-Kernfrage „SFTP-Weg geklärt")

`swift-nio-ssh` ist eine **reine SSH-Transport-Bibliothek ohne SFTP**. Das ist für humibeam
genau richtig, weil wir Low-Level-Kontrolle über PTY- + Exec-Channels und Multiplexing brauchen.
Für Datei-Transfer gilt:

### Für den Screenshot-Paste-Upload (M3): **Exec-Channel `cat > datei`** — kein SFTP nötig.
- In M1 bewiesen, **bit-identisch**, **null Server-Installation** (Stock-Ubuntu hat `cat`/`sha256sum`).
- Genau Fallback #5 aus M0 — jetzt nicht nur Fallback, sondern **bevorzugter Upload-Weg** für Pastes,
  weil er dependency-frei ist und auf jedem Server läuft.
- Upload läuft auf einem **zweiten, parallelen Channel**, während die PTY-Session live bleibt.

### Für den Datei-Browser (V1: Listing, Browsen, Download): **echtes SFTP via [Citadel](https://github.com/orlandos-nl/Citadel)**.
- Citadel setzt einen SFTP-Client auf `swift-nio-ssh` auf → Verzeichnis-Listing, Stat, Download.
- **In der V1-Phase zu evaluieren** (API-Reife, Koexistenz mit unseren rohen nio-ssh-Channels).
- Fallback, falls Citadel hakt oder der Server SFTP deaktiviert hat: alles über Exec-Channels
  (`ls -la`, `cat`, `stat`) — funktioniert immer, nur weniger komfortabel.

**Fazit:** Paste-Upload braucht **kein** SFTP (Exec-Channel reicht und ist robuster).
SFTP (Citadel) ist nur für den komfortablen Datei-Browser nötig und kommt in V1.

---

## 3. Bestätigte API-Bausteine (für die humibeam-SSH-Schicht wiederverwendbar)

- **Auth:** `NIOSSHClientUserAuthenticationDelegate.nextAuthenticationType(...)` → `NIOSSHUserAuthenticationOffer(.privateKey(...))`. (Achtung: Methode heißt `nextAuthenticationType`, nicht `...Request`.)
- **Host-Key:** `NIOSSHClientServerAuthenticationDelegate.validateHostKey(...)` → hier known_hosts-Prüfung einklinken (Spike akzeptiert alles).
- **Key:** `NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey)`. ed25519 voll unterstützt.
- **Channel:** `NIOSSHHandler.createChannel(_:channelType:.session) { child, _ in child.pipeline.addHandler(...) }`.
- **PTY:** `SSHChannelRequestEvent.PseudoTerminalRequest` + `.ShellRequest` via `triggerUserOutboundEvent`.
- **Exec + stdin-EOF:** `.ExecRequest`, Daten als `SSHChannelData(type:.channel, data:.byteBuffer)`, dann `channel.close(mode: .output)` sendet EOF.
- **Exit-Status:** kommt als Inbound-User-Event `SSHChannelRequestEvent.ExitStatus`.
- **Half-Close empfangen:** `ChannelOptions.allowRemoteHalfClosure = true`.

### Offene Punkte für die Produktivschicht (nicht spike-blockierend)
- **OpenSSH-Private-Keys importieren** (`~/.ssh/id_ed25519`, RSA, ecdsa, mit Passphrase): der Spike
  generiert seinen eigenen ed25519-Key; das Parsen vorhandener OpenSSH-Keys ist noch zu bauen.
- **known_hosts** real prüfen + TOFU-Dialog.
- **Passwort- und keyboard-interactive-Auth** als Alternativen.
- **Sendable/Swift-6-Concurrency:** Spike läuft im Swift-5-Modus (nur Warnungen). Für die App
  saubere Aktor-/EventLoop-Isolation der nicht-Sendable `NIOSSHHandler`-Nutzung.

---

## 4. Artefakte

- `SSHSpike/` — Swift-Package (Package.swift + Sources/SSHSpike/main.swift). Baut mit `swift build`.
- `run-m1.sh` — end-to-end-Test: Key erzeugen → autorisieren → connect → PTY + Upload + Verify → cleanup.
  - localhost: `./run-m1.sh`  ·  echter Server: `HOST=server USER=ubuntu ./run-m1.sh`
- Test-Setup räumt sich selbst auf (Test-Key wird aus `authorized_keys` entfernt).

## 5. Auswirkung auf den Bauplan
- **M1 bestanden** → `swift-nio-ssh` ist die SSH-Schicht; Citadel optional für SFTP in V1.
- **M3 (PasteBridge) vereinfacht sich:** Upload = Exec-Channel `cat`, kein SFTP-Risiko.
- **Nächster Schritt M2:** SwiftTerm an den verifizierten PTY-Stream anschließen → echtes Terminal,
  in dem `claude` über SSH läuft.
