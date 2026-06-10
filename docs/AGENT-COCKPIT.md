# Agent Cockpit — Konzept (Prio 1)

> **Aus dem Text-Stream wird ein Cockpit.** Humibeam liest Claude Codes Ausgabe mit,
> erkennt was der Agent vorhat, und rendert es als native macOS-UI statt als nacktes
> `y/n`-Getippe. Das ist der eine Sprung, den kein klassischer SSH-Client kontern kann.

---

## Das Problem

Claude Code über SSH ist ein **PTY-Text-Stream**. Wenn der Agent etwas tun will
(Befehl ausführen, Datei ändern), zeichnet er eine Box ins Terminal:

```
╭─────────────────────────────────────────────╮
│ Bash command                                 │
│   rm -rf build/                               │
│ Do you want to proceed?                       │
│ ❯ 1. Yes                                      │
│   2. Yes, and don't ask again                 │
│   3. No, and tell Claude what to do…          │
╰─────────────────────────────────────────────╯
```

Heute musst du das lesen und blind `1`/`2`/`Esc` tippen. Bei einem `rm -rf` ist das
fahrlässig — du siehst den Befehl in einer Box-Zeichen-Wüste, nicht als klares Signal.

## Die Lösung (3 Stufen)

### Stufe 1 — Inline-Approval-Karte *(dieser Prototyp)*

Humibeam parst den (ANSI-bereinigten) Stream und erkennt:
- **Aktionstyp** — Bash-Befehl, Datei-Edit, Datei schreiben, lesen, Web-Fetch …
- **Subjekt** — der konkrete Befehl bzw. der betroffene Dateipfad (aus der „Do you want…?"-Frage).
- **Vorschau** — die Inhaltszeilen der Box; bei Edits werden `+`/`-`-Diff-Zeilen grün/rot eingefärbt.
- **„Immer erlauben"** verfügbar? (Option 2 / „don't ask again").

Daraus wird eine **Karte** über dem Terminal mit `Ablehnen` / `Erlauben` / `Immer erlauben`.
Die Buttons senden weiterhin exakt die Tasten, die Claude Code erwartet (`1`, `2`, `Esc`) —
keine Server-Installation, funktioniert mit Stock-Ubuntu. Genau Humibeams Prinzip.

**Architektur:**
```
PTYSession.onOutput
  → TerminalSessionController.captureTranscript()      (ANSI strippen, Ringpuffer)
    → ClaudeApproval.parse(tail)                        (Heuristik-Parser, NEU)
      → controller.approval: ClaudeApproval?            (NEU)
        → onApprovalChange → TerminalTab.approval        (Observable)
          → MainView.ApprovalCard                        (native UI, NEU)
            → controller.approve()/approveAlways()/deny() (sendet 1/2/Esc)
```

**Ehrliche Grenze:** Claude Code ist eine Vollbild-TUI, die per Cursor-Positionierung
neu zeichnet. Der bereinigte Stream ist deshalb keine saubere Zeilenfolge, sondern teils
„Suppe" aus Repaints. Der Parser ist robust für **Aktionstyp + Frage + Befehl** und
*best-effort* für den Diff. Erkennt er nichts Strukturiertes, fällt die Karte auf die
generische Variante zurück (nie schlechter als heute).

### Stufe 2 — Berührte Dateien & Diff aus der Quelle *(nächster Schritt)*

Humibeam hat bereits einen **Exec-Channel** parallel zum PTY (für Screenshot-Upload &
Keepalive). Den nutzen wir, um bei einem Edit den echten Kontext zu holen:
`git diff --stat`, `git diff <file>` oder `sed -n` für die betroffenen Zeilen — ein
verlässlicher Diff direkt vom Server, unabhängig vom TUI-Geflacker. Die `recentPaths`
(schon geparst) werden zur anklickbaren Datei-Leiste „in dieser Session berührt".

### Stufe 3 — Strukturierte Brücke (opt-in, 100 % exakt)

Für Power-User ein winziger **Claude-Code-Hook** (`PreToolUse`), der die Tool-Calls als
JSON über einen Seitenkanal (Unix-Socket / Datei in `~/.humibeam/`) ausgibt. Dann sind
die Karten 100 % exakt (Tool, Argumente, vollständiger Diff) — ohne PTY-Scraping.
Bleibt optional, damit der Zero-Install-Vorteil für den Normalfall erhalten bleibt.

---

## Warum das 100x ist

Termius/iTerm2/Warp sehen einen Byte-Stream. Humibeam sieht **einen Agenten bei der Arbeit**.
Ein `rm -rf` wird zur roten Warnkarte, ein Edit zum lesbaren Diff mit einem Klick zum Freigeben.
Das verschiebt die Wahrnehmung von „Terminal mit SSH" zu „Mission Control für KI-Agenten".

---

## Status

- [x] Stufe 1: Parser (`ClaudeApproval.swift`) + Inline-Karte (`ApprovalCard` in `MainView`).
- [ ] Stufe 2: Diff/Datei-Kontext über Exec-Channel.
- [ ] Stufe 3: Opt-in `PreToolUse`-Hook-Brücke.
