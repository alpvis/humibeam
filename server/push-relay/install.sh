#!/bin/bash
# Installiert das Humibeam Push-Relay auf dem Server (einmal als ali@alpvis.com ausführen).
# Danach in nginx einen Location-Block ergänzen (siehe unten) und in config.json
# den APNs-Key eintragen, sobald er existiert.
set -euo pipefail

DIR=/home/ali/humibeam-push
mkdir -p "$DIR"
# Aus dem Repo kopieren — oder, wenn per `curl | bash` gestartet, direkt von GitHub laden.
if [ -f "$(dirname "$0")/server.js" ]; then
  cp "$(dirname "$0")/server.js" "$DIR/"
else
  curl -fsSL https://raw.githubusercontent.com/alpvis/humibeam/main/server/push-relay/server.js -o "$DIR/server.js"
fi

if [ ! -f "$DIR/config.json" ]; then
  SECRET=$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)
  cat > "$DIR/config.json" << EOF
{
  "secret": "$SECRET",
  "teamId": "DC289RNL2G",
  "keyId": "",
  "p8": "AuthKey.p8",
  "bundleId": "app.humibeam.ios",
  "production": false,
  "port": 8799
}
EOF
  echo "Neues Secret erzeugt: $SECRET  (in Mac- und iOS-App eintragen!)"
fi

NODE_BIN=$(command -v node || echo /usr/bin/node)

sudo tee /etc/systemd/system/humibeam-push.service > /dev/null << EOF
[Unit]
Description=Humibeam Push Relay (APNs)
After=network.target

[Service]
ExecStart=$NODE_BIN /home/ali/humibeam-push/server.js
Restart=always
User=ali
WorkingDirectory=/home/ali/humibeam-push

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now humibeam-push
sleep 1
curl -s http://127.0.0.1:8799/health && echo

cat << 'EOF'

FERTIG. Noch zwei Schritte:
1. nginx: in den HTTPS-Server-Block von alpvis.com einfügen und neu laden:
     location /humibeam-push/ {
         proxy_pass http://127.0.0.1:8799/;
         proxy_set_header Host $host;
     }
2. APNs-Key (.p8 aus developer.apple.com → Keys → Apple Push Notifications service)
   nach /home/ali/humibeam-push/AuthKey.p8 legen und keyId in config.json eintragen,
   dann: sudo systemctl restart humibeam-push
EOF
