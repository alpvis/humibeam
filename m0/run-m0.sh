#!/usr/bin/env bash
#
# M0 — Validierung der humibeam-Kernannahme.
#
# Frage: Liest Claude Code (CLI) auf einem headless Ubuntu-Server ein Bild,
#        das wir als Datei hochgeladen haben, wenn wir nur einen TEXT-VERWEIS
#        auf den Pfad in den Prompt geben?
#
# Mechanismus: NICHT der [Image #N]-Clipboard-Paste (liest Server-Clipboard,
#        auf headless leer), sondern das Read-Tool von Claude Code, das PNG/JPG
#        als sichtbaren Bildinhalt zurückgibt. Wir testen, WELCHE Formulierung
#        das Read am zuverlässigsten auslöst.
#
# Erfolg = Claude nennt das im Bild stehende Wort:  WOMBAT42
#
# Voraussetzung auf dem Server:
#   - `claude` ist installiert und eingeloggt (claude -p muss ohne Nachfrage laufen)
#   - bash, base64
#
# Aufruf direkt auf dem Server:
#     ./run-m0.sh
# Oder von deinem Mac aus über SSH (Skript + b64 müssen am gleichen Ort liegen):
#     scp run-m0.sh test-image.b64 server:/tmp/  &&  ssh server 'cd /tmp && ./run-m0.sh'
#
set -u

SECRET="WOMBAT42"
WORKDIR="$HOME/.humibeam/pastes"
IMG="$WORKDIR/m0-test.png"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B64="$SCRIPT_DIR/test-image.b64"

# Erlaubt Read-Tool ohne interaktive Nachfrage. Falls deine Policy das nicht
# zulässt, siehe Hinweis am Ende.
CLAUDE_FLAGS="${CLAUDE_FLAGS:---permission-mode acceptEdits}"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }

# --- Setup: Testbild aus base64 erzeugen (simuliert den humibeam-Upload) ---
mkdir -p "$WORKDIR"
if [ ! -f "$B64" ]; then
  red "FEHLER: $B64 nicht gefunden. Lege test-image.b64 neben dieses Skript."
  exit 2
fi
base64 -d "$B64" > "$IMG" 2>/dev/null || base64 --decode "$B64" > "$IMG"
if [ ! -s "$IMG" ]; then red "FEHLER: Konnte Testbild nicht dekodieren."; exit 2; fi
grn "Testbild erzeugt: $IMG ($(wc -c < "$IMG") bytes) — enthält das Wort: $SECRET"

command -v claude >/dev/null 2>&1 || { red "FEHLER: 'claude' nicht im PATH."; exit 2; }
echo "claude version: $(claude --version 2>/dev/null || echo unbekannt)"
echo "flags: $CLAUDE_FLAGS"
echo

# --- Strategien: jeweils ein Prompt, der NUR über das Bild beantwortbar ist ---
# Reihenfolge = unsere Präferenz (oben = am liebsten in humibeam injizieren).
declare -a NAMES=(
  "bare-path"
  "path-plus-verb"
  "at-reference"
  "quoted-path"
  "explicit-read"
)
declare -a PROMPTS=(
  "$IMG"
  "Look at the image $IMG and reply with ONLY the word written in it."
  "What single word is written in @$IMG ? Reply with only that word."
  "Read the image at \"$IMG\" and output only the word shown in it."
  "Use the Read tool on $IMG (it is an image) and tell me only the word it contains."
)

PASS_LIST=()
FAIL_LIST=()

run_case() {
  local name="$1" prompt="$2"
  ylw "── Strategie: $name"
  echo "   prompt: $prompt"
  local out
  out="$(claude -p "$prompt" $CLAUDE_FLAGS 2>&1)"
  echo "   antwort: $(echo "$out" | tr '\n' ' ' | cut -c1-200)"
  if echo "$out" | grep -qi "$SECRET"; then
    grn "   => PASS (Bild wurde gelesen)"
    PASS_LIST+=("$name")
  else
    red "   => FAIL (Wort nicht erkannt)"
    FAIL_LIST+=("$name")
  fi
  echo
}

for i in "${!NAMES[@]}"; do
  run_case "${NAMES[$i]}" "${PROMPTS[$i]}"
done

# --- Ergebnis ---
echo "════════════════════════════════════════════"
echo "M0-ERGEBNIS"
echo "  PASS: ${PASS_LIST[*]:-(keine)}"
echo "  FAIL: ${FAIL_LIST[*]:-(keine)}"
echo
if [ "${#PASS_LIST[@]}" -gt 0 ]; then
  grn "KERNANNAHME BESTÄTIGT ✅ — bevorzugte Injektion in humibeam: '${PASS_LIST[0]}'"
  echo "→ Baue die PasteBridge so, dass sie nach dem Upload den Verweis im Stil von"
  echo "  '${PASS_LIST[0]}' in den PTY-Channel schreibt."
else
  red "KERNANNAHME NICHT BESTÄTIGT ❌ — keine Strategie hat das Bild gelesen."
  echo "→ Prüfe: läuft 'claude -p' überhaupt? (siehe Hinweis). Dann Fallbacks in M0-validation.md."
fi
echo "════════════════════════════════════════════"
echo
echo "Hinweis: Falls JEDE Strategie scheitert, weil Read eine Bestätigung verlangt,"
echo "setze eine permissivere Policy NUR für diesen Test, z.B.:"
echo "  CLAUDE_FLAGS='--dangerously-skip-permissions' ./run-m0.sh"
echo "(nur in einer Wegwerf-Test-VM verwenden)."
