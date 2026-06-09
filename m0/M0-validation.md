# M0 — Validierung der Kernannahme (Screenshot-Paste-Bridge)

**Frage:** Liest Claude Code ein per Datei hochgeladenes Bild, wenn humibeam nur einen
**Text-Verweis auf den Pfad** in die Session schreibt — auf einem Server, der nur die CLI hat?

**Antwort: JA. Kernannahme bestätigt.** ✅ (lokal auf macOS verifiziert, Claude Code 2.1.168)

---

## 1. Was wir herausgefunden haben

### Der dokumentierte Clipboard-Weg ist für uns tot
Claude Codes offizieller Bild-Input (`Cmd/Ctrl+V` → `[Image #N]`-Chip) liest das Clipboard
**der Maschine, auf der `claude` läuft**. Auf einem headless Ubuntu-Server gibt es kein
Clipboard / kein `DISPLAY` → dieser Weg liefert nichts. Bestätigt unsere ursprüngliche These.

### Der echte Mechanismus: Read-Tool über Pfad-Verweis
Claude Code liest Bilddateien über sein **Read-Tool** und bekommt sie „as visual content that
Claude can see" zurück (PNG/JPG). Es genügt, einen **Text-Verweis auf den Pfad** in den Prompt
zu schreiben — Claude ruft dann Read auf und sieht das Bild. Das ist plattformunabhängig und
genau der Hebel für humibeam.

### Getestete Einfüge-Strategien (alle bestanden)
Testbild enthielt das Wort `WOMBAT42`; Erfolg = Claude nennt das Wort.

| Strategie | Was humibeam einfügt | Ergebnis |
|---|---|---|
| **bare-path** | `/pfad/zu/bild.png` (nur der Pfad, sonst nichts) | ✅ Claude liest sofort |
| path-plus-verb | `Look at the image /pfad/...png` | ✅ |
| at-reference | `@/pfad/...png` | ✅ |

**→ Bevorzugte Injektion in humibeam: `bare-path`.** Am unauffälligsten, kein Text-Rauschen
im Prompt, der Nutzer kann direkt weiterschreiben/-sprechen. Fallback-Reihenfolge unten.

---

## 2. Kritischer Nebenbefund: Read-Berechtigung

Im Test musste die Read-Berechtigung erteilt werden, wenn die Datei **außerhalb des
Arbeitsverzeichnisses** der `claude`-Session lag (`--dangerously-skip-permissions` war im
Headless-`-p`-Test nötig). **Konsequenz fürs Produktdesign:**

In einer echten interaktiven Session bedeutet das **eine Enter-Bestätigung pro Bild** —
akzeptabel, aber nicht „magisch". Drei Wege, das zu glätten (in Reihenfolge der Eleganz):

1. **Upload ins Arbeitsverzeichnis der Session.** humibeam erkennt das cwd der Remote-Session
   und legt Pastes unter `<cwd>/.humibeam/pastes/` ab → Reads im Projektbaum brauchen seltener
   eine Nachfrage. (Erfordert, das Remote-cwd zu kennen — via `pwd`-Probe beim Verbinden.)
2. **Einmalige Allowlist.** humibeam schlägt dem Nutzer vor, `~/.humibeam/pastes/` (bzw. das
   Paste-Dir) zu Claude Codes erlaubten Read-Pfaden hinzuzufügen (`/permissions` bzw.
   `settings.json` `permissions.allow`: `Read(~/.humibeam/pastes/**)`).
3. **Nichts tun** — der Nutzer drückt einmal Enter pro Bild. Funktioniert sofort, kein Setup.

**MVP-Entscheidung:** Weg 3 (funktioniert ohne alles), mit Weg 1 als Politur in V1.

---

## 3. Was noch auf einem echten Server zu verifizieren ist

Lokal (macOS) ist der Mechanismus bewiesen. Auf dem Zielsystem noch gegenzuprüfen — dafür ist
`run-m0.sh` da:

- [ ] **Interaktiver Modus** (nicht nur `claude -p`): Pfad in die laufende REPL tippen → liest
      Claude ihn ohne weiteres? (Im `-p`-Modus bestätigt; REPL sollte identisch sein.)
- [ ] **Headless Ubuntu** ohne `DISPLAY`: bestätigt, dass nichts am Clipboard hängt.
- [ ] **Große Screenshots** (z. B. 4K-Retina): Claude downscaled automatisch — prüfen, dass
      Text noch lesbar bleibt (ggf. lokal vor Upload nicht hochskalieren).
- [ ] **Permission-Flow** in der konkreten Server-Policy (Punkt 2 oben).

### So führst du es aus
```bash
# auf dem Server liegen run-m0.sh + test-image.b64 nebeneinander:
scp m0/run-m0.sh m0/test-image.b64 server:/tmp/
ssh server 'cd /tmp && ./run-m0.sh'
```
Das Skript erzeugt das Testbild aus base64 (simuliert den humibeam-Upload), legt es in
`~/.humibeam/pastes/`, jagt alle Strategien durch `claude -p` und meldet PASS/FAIL +
die empfohlene Injektions-Strategie.

---

## 4. Fallback-Varianten (falls eine Strategie auf dem Server scheitert)

Gereiht von „am liebsten" zu „Notnagel". Jede ist unabhängig in der PasteBridge umschaltbar.

| # | Variante | Wann einsetzen | Implementierungs-Notiz |
|---|---|---|---|
| 1 | **Nackter Pfad** | Default | Pfad-String + ein abschließendes Leerzeichen in den PTY schreiben. |
| 2 | **Pfad + Verb** | wenn nackter Pfad in REPL nicht auto-liest | Prefix `Look at the image ` voranstellen. |
| 3 | **@-Referenz** | wenn `@`-Autocomplete sauberer matcht | `@` + Pfad; ggf. Tab zum Vervollständigen unterdrücken. |
| 4 | **Upload ins cwd + relativer Pfad** | wenn Permission-Nachfragen nerven | Remote-cwd via `pwd` proben, nach `<cwd>/.humibeam/pastes/` laden, relativen Pfad einfügen. |
| 5 | **Exec-Channel statt SFTP** | wenn SFTP-Subsystem am Server deaktiviert | Bild base64 über Exec-Channel pipen: `base64 -d > datei` — kein SFTP nötig. |
| 6 | **Drag&Drop-Pfadformat nachbilden** | wenn Claude ein Spezialformat erwartet | führendes/quotiertes Pfadformat wie beim Terminal-Drop; in M-Spike empirisch ermitteln. |
| 7 | **Clipboard-Bridge mit `xclip`/`wl-copy`** | nur bei Server MIT GUI/DISPLAY (selten) | Bild ins Server-Clipboard schreiben, dann `Ctrl+V` → `[Image #N]`. Für headless NICHT nutzbar. |

**Wichtig:** Varianten 1–5 brauchen **null Server-Installation** (Stock-Ubuntu). Variante 7 ist
nur der Vollständigkeit halber dokumentiert und für unseren Zielfall (headless) bewusst raus.

---

## 5. Fazit & Auswirkung auf den Bauplan

- **M0 ist bestanden** — der gesamte humibeam-Bauplan steht auf festem Grund.
- **PasteBridge-Spezifikation steht jetzt fest:** Bild aus `NSPasteboard` → temp-PNG →
  SFTP-Upload nach Paste-Dir → **nackten Remote-Pfad** in den PTY-Channel schreiben.
- **Neue Design-Anforderung** (aus dem Permission-Befund): humibeam sollte das Remote-cwd
  kennen (V1) und/oder dem Nutzer das Allowlisten des Paste-Dirs anbieten — sonst eine
  Enter-Bestätigung pro Bild (MVP ok).
- **Nächster Meilenstein M1:** SSH-Spike mit `swift-nio-ssh` — verbinden, PTY-Shell, und den
  SFTP-Weg klären (nio-ssh + Citadel vs. libssh2 vs. Exec-Channel-base64 als Fallback #5).

### Artefakte in diesem Ordner
- `run-m0.sh` — automatischer Server-Test (alle Strategien, PASS/FAIL).
- `test-image.b64` — Testbild (Wort `WOMBAT42`) als base64, vom Skript dekodiert.
- `test-image.png` — dasselbe Bild zum Ansehen.
