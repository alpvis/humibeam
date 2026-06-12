#!/bin/bash
# Installiert den Humibeam Konto-Sync auf dem Server (einmal als ali@alpvis.com ausführen).
# Danach in nginx den Location-Block ergänzen (siehe Ausgabe unten).
set -euo pipefail

DIR=/home/ali/humibeam-sync
mkdir -p "$DIR"
if [ -f "$(dirname "$0")/server.js" ]; then
  cp "$(dirname "$0")/server.js" "$DIR/"
else
  curl -fsSL https://raw.githubusercontent.com/alpvis/humibeam/main/server/sync/server.js -o "$DIR/server.js"
fi

if [ ! -f "$DIR/config.json" ]; then
  cat > "$DIR/config.json" << 'EOF'
{
  "port": 8798,
  "bindHost": "127.0.0.1"
}
EOF
fi
# Hinweis: Läuft nginx als Docker-Container, muss bindHost auf die Docker-Gateway-IP
# (z. B. 172.17.0.1 oder 0.0.0.0 + Firewall) gestellt werden — wie beim Push-Relay.

NODE_BIN=$(command -v node || echo /usr/bin/node)

sudo tee /etc/systemd/system/humibeam-sync.service > /dev/null << EOF
[Unit]
Description=Humibeam Konto-Sync (E2E-verschlüsselt)
After=network.target

[Service]
ExecStart=$NODE_BIN /home/ali/humibeam-sync/server.js
WorkingDirectory=/home/ali/humibeam-sync
Restart=always
RestartSec=3
User=ali

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now humibeam-sync
sleep 1
systemctl --no-pager -l status humibeam-sync | head -5
curl -fsS http://127.0.0.1:8798/health && echo

cat << 'EOF'

✅ Dienst läuft. Jetzt in der nginx-Config (alpvis.com-Server-Block) ergänzen:

    location /humibeam-sync/ {
        proxy_pass http://DOCKER_GATEWAY_ODER_127:8798/;
        proxy_set_header X-Forwarded-For $remote_addr;
        client_max_body_size 8m;
    }

…und nginx neu laden (docker exec cloud-nginx nginx -s reload).
EOF
