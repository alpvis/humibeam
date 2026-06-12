#!/bin/bash
# Installiert den Humibeam Beam-Tunnel auf dem Server (einmal als ali@alpvis.com ausführen).
# Achtung: Port 8797/tcp in der Firewall freigeben (ufw allow 8797/tcp) — der Verkehr
# selbst ist Ende-zu-Ende-verschlüsselt, der Server sieht nur Chiffrat.
set -euo pipefail

DIR=/home/ali/humibeam-beam
mkdir -p "$DIR"
if [ -f "$(dirname "$0")/server.js" ]; then
  cp "$(dirname "$0")/server.js" "$DIR/"
else
  curl -fsSL https://raw.githubusercontent.com/alpvis/humibeam/main/server/beam-tunnel/server.js -o "$DIR/server.js"
fi

[ -f "$DIR/config.json" ] || echo '{ "port": 8797, "bindHost": "0.0.0.0" }' > "$DIR/config.json"

NODE_BIN=$(command -v node || echo /usr/bin/node)
sudo tee /etc/systemd/system/humibeam-beam.service > /dev/null << EOF
[Unit]
Description=Humibeam Beam-Tunnel (MacBeam Rendezvous, E2E-verschlüsselt)
After=network.target

[Service]
ExecStart=$NODE_BIN /home/ali/humibeam-beam/server.js
WorkingDirectory=/home/ali/humibeam-beam
Restart=always
RestartSec=3
User=ali

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now humibeam-beam
sudo ufw allow 8797/tcp 2>/dev/null || true
systemctl --no-pager status humibeam-beam | head -4
