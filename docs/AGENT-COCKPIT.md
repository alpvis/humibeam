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

### Stufe 2 — Diff aus der Quelle *(implementiert)*

Humibeam hat bereits einen **Exec-Channel** parallel zum PTY (für Screenshot-Upload &
Keepalive). `GitDiffService` nutzt ihn, um den **echten** Arbeitsbaum-Diff direkt vom
Server zu holen (`git diff --no-color HEAD` + untracked Files) — unabhängig vom
TUI-Geflacker. Gerendert als farbiges Diff-Sheet (`GitDiffSheet`), erreichbar über den
Toolbar-Knopf „Änderungen" und den „Echter Diff"-Button auf der Edit-Approval-Karte.

**CWD-Strategie (wichtig):** Stock-Ubuntu-Bash sendet meist kein OSC 7, der Terminal-CWD
ist also oft unbekannt. Deshalb probiert das Skript eine **Kandidatenliste** durch — der
gemeldete CWD *plus* die Elternordner der von Claude berührten Dateien (`recentPaths`) —
und nimmt das erste Verzeichnis, das in einem Git-Repo liegt; `$HOME` als letzter Fallback.

*Grenze:* zeigt den Zustand des Arbeitsbaums (was Claude bereits geschrieben hat). Eine
*vorgeschlagene, noch nicht angewandte* Änderung lebt nur in Claudes Prompt — dafür dient
die Inline-Karte aus Stufe 1. Beide ergänzen sich.

### Stufe 3 — Strukturierte Brücke (opt-in, 100 % exakt) *(implementiert)*

Ein winziger **Claude-Code-`PreToolUse`-Hook** (`tools/humibeam-hook.sh`) schreibt jeden
Tool-Call als JSON-Zeile nach `~/.humibeam/events.jsonl`. `ClaudeBridge` liest die jüngste
Zeile über den Exec-Channel und baut eine **100 % exakte** Karte (echtes Tool, Befehl,
echter Diff aus `old_string`/`new_string`). Erkennbar am grünen „exakt"-Badge.

- **Abhängigkeitsfrei:** Hook = nur bash + coreutils (kein `jq`). Zero-Install bleibt für alle
  anderen erhalten — die Brücke ist **opt-in** (Menü „Claude-Bridge…").
- **Nicht-blockierend:** Der Hook entscheidet nichts (exit 0) — Claude zeigt seinen normalen
  Prompt, humibeams Buttons senden weiter `1`/`2`/`Esc`. Die Brücke liefert nur exakte *Anzeige*.
- **Robust gegen Feldnamen:** akzeptiert `old_string`/`old_str`, `content`/`file_text` etc.
- **settings.json-Merge** passiert in Swift (`JSONSerialization`), mit Backup, kein `jq` nötig.
- **Feldnamen-Caveat:** Claude Codes Tool-Input-Felder können je nach Version variieren —
  beim ersten Live-Test gegen die echte Claude-Version verifizieren/kalibrieren.

---

## Warum das 100x ist

Termius/iTerm2/Warp sehen einen Byte-Stream. Humibeam sieht **einen Agenten bei der Arbeit**.
Ein `rm -rf` wird zur roten Warnkarte, ein Edit zum lesbaren Diff mit einem Klick zum Freigeben.
Das verschiebt die Wahrnehmung von „Terminal mit SSH" zu „Mission Control für KI-Agenten".

---

## Status

- [x] Stufe 1: Parser (`ClaudeApproval.swift`) + Inline-Karte (`ApprovalCard` in `MainView`).
- [x] Stufe 2: Echter Diff über Exec-Channel (`GitDiffService.swift` + `GitDiffSheet`).
- [x] Stufe 3: Opt-in `PreToolUse`-Hook-Brücke (`ClaudeBridge.swift` + `tools/humibeam-hook.sh`).
