#!/usr/bin/env bash
# humibeam Claude-Code-Brücke (Stufe 3) — PreToolUse-Hook.
#
# Schreibt jeden Tool-Call, den Claude Code ausführen will, als eine JSON-Zeile nach
# ~/.humibeam/events.jsonl. humibeam liest die jüngste Zeile über den vorhandenen
# Exec-Channel und rendert daraus eine EXAKTE Approval-Karte (Tool, Befehl, echter Diff).
#
# Bewusst abhängigkeitsfrei (kein jq): nur bash + coreutils, läuft auf Stock-Ubuntu.
# Der Hook ENTSCHEIDET NICHT (exit 0 ohne JSON) — Claude Code zeigt seinen normalen
# Erlaubnis-Dialog weiter, und humibeams Buttons senden wie gehabt 1/2/Esc. Die Brücke
# liefert nur die exakten Daten für die Anzeige.

dir="$HOME/.humibeam"
mkdir -p "$dir"

# stdin = das PreToolUse-JSON (evtl. pretty-printed). Whitespace zwischen Tokens ist
# bedeutungslos; tr flacht es zu einer JSONL-Zeile ab (escapte \n in Strings bleiben intakt).
payload="$(cat | tr '\n' ' ')"
printf '%s\n' "$payload" >> "$dir/events.jsonl"

# Ringpuffer: Datei nicht unbegrenzt wachsen lassen.
tail -n 200 "$dir/events.jsonl" > "$dir/events.jsonl.tmp" 2>/dev/null && mv "$dir/events.jsonl.tmp" "$dir/events.jsonl"

exit 0
