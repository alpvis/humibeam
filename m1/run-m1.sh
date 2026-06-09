#!/usr/bin/env bash
#
# M1 — SSH-Spike end-to-end gegen einen SSH-Server.
#
# Default: testet gegen localhost (macOS "Remote Login" muss an sein).
# Für einen echten Server: HOST/PORT/USER überschreiben, dann muss der erzeugte
# Public Key dort in ~/.ssh/authorized_keys stehen (das Skript hängt ihn lokal an;
# für einen Remote-Host musst du die gedruckte Zeile dort selbst eintragen).
#
#   HOST=meinserver USER=ubuntu ./run-m1.sh
#
set -euo pipefail

HOST="${HOST:-localhost}"
PORT="${PORT:-22}"
USER_NAME="${USER:-$(whoami)}"
SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$SPIKE_DIR/SSHSpike"
RAWKEY="$SPIKE_DIR/spike_swift.rawkey"
LOCAL_FILE="${LOCAL_FILE:-$SPIKE_DIR/../m0/test-image.png}"
REMOTE_PATH="${REMOTE_PATH:-\$HOME/.humibeam/pastes/m1-upload.png}"
MARKER="humibeam-m1-swift-DELETE-ME"
AUTHKEYS="$HOME/.ssh/authorized_keys"
LOCALHOST_MODE=0
[ "$HOST" = "localhost" ] || [ "$HOST" = "127.0.0.1" ] && LOCALHOST_MODE=1

echo "== Build =="
swift build --package-path "$PKG" 2>&1 | grep -E "Build complete|error:" || true
BIN="$(swift build --package-path "$PKG" --show-bin-path)/SSHSpike"

echo "== Key erzeugen =="
PUBLINE="$("$BIN" genkey "$RAWKEY")"
echo "  $PUBLINE"

cleanup() {
  if [ "$LOCALHOST_MODE" = "1" ] && [ -f "$AUTHKEYS" ]; then
    grep -v "$MARKER" "$AUTHKEYS" > "$AUTHKEYS.tmp" 2>/dev/null && mv "$AUTHKEYS.tmp" "$AUTHKEYS" || true
    echo "(cleanup: Test-Key aus authorized_keys entfernt)"
  fi
  rm -f "$RAWKEY"
}
trap cleanup EXIT

if [ "$LOCALHOST_MODE" = "1" ]; then
  echo "== Public Key lokal autorisieren (localhost) =="
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; touch "$AUTHKEYS"; chmod 600 "$AUTHKEYS"
  grep -v "$MARKER" "$AUTHKEYS" > "$AUTHKEYS.tmp" 2>/dev/null || true; mv -f "$AUTHKEYS.tmp" "$AUTHKEYS" 2>/dev/null || true
  echo "$PUBLINE" >> "$AUTHKEYS"
else
  echo "!! Remote-Host: trage diese Zeile auf $HOST in ~/.ssh/authorized_keys ein und drücke Enter:"
  echo "   $PUBLINE"
  read -r _
fi

echo "== Connect + Tests =="
"$BIN" connect "$HOST" "$PORT" "$USER_NAME" "$RAWKEY" "$LOCAL_FILE" "$REMOTE_PATH"
