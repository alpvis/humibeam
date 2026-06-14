#!/bin/bash
# Installiert den Humibeam Konto-Sync auf dem Server (einmal als ali@humibeam.com ausführen).
# Danach in nginx den Location-Block ergänzen (siehe Ausgabe unten).
set -euo pipefail

# Echter Pfad auf dem Produktions-Server (alle Backend-Dienste liegen unter humibeam-services/).
DIR=/home/ali/humibeam-services/sync
# nginx läuft im Docker-Container (cloud-nginx) → der Dienst bindet an die Docker-Gateway-IP,
# nicht an 127.0.0.1, damit der Container ihn erreicht.
BIND_HOST=172.18.0.1
PORT=8798

mkdir -p "$DIR"
if [ -f "$(dirname "$0")/server.js" ]; then
  cp "$(dirname "$0")/server.js" "$DIR/"
else
  curl -fsSL https://raw.githubusercontent.com/alpvis/humibeam/main/server/sync/server.js -o "$DIR/server.js"
fi

# config.json NICHT überschreiben, falls vorhanden (bewahrt u. a. das adminToken).
if [ ! -f "$DIR/config.json" ]; then
  cat > "$DIR/config.json" << EOF
{
  "port": $PORT,
  "bindHost": "$BIND_HOST",
  "adminToken": ""
}
EOF
  echo "ℹ️  Neue config.json angelegt. Für den Betreiber-Admin (/admin) ein adminToken setzen:"
  echo "    TOK=\$(openssl rand -hex 24); sed -i \"s/\\\"adminToken\\\": \\\"\\\"/\\\"adminToken\\\": \\\"\$TOK\\\"/\" $DIR/config.json"
  echo "    (Token notieren — leeres adminToken deaktiviert den Admin-Endpoint.)"
fi
# Hinweis: Bei anderem Docker-Setup ggf. Gateway-IP prüfen:
#   docker network inspect bridge | grep Gateway   (oder das infra-Netz von cloud-nginx)

NODE_BIN=$(command -v node || echo /usr/bin/node)

sudo tee /etc/systemd/system/humibeam-sync.service > /dev/null << EOF
[Unit]
Description=Humibeam Konto-Sync (E2E-verschlüsselt)
After=network.target

[Service]
ExecStart=$NODE_BIN $DIR/server.js
WorkingDirectory=$DIR
Restart=always
RestartSec=3
User=ali

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now humibeam-sync
sudo systemctl restart humibeam-sync   # bei Update der server.js neu laden
sleep 1
systemctl --no-pager -l status humibeam-sync | head -5
curl -fsS "http://$BIND_HOST:$PORT/health" && echo

cat << EOF

✅ Dienst läuft auf $BIND_HOST:$PORT. Jetzt in der nginx-Config (humibeam.com-Server-Block) ergänzen:

    location /humibeam-sync/ {
        proxy_pass http://$BIND_HOST:$PORT/;
        proxy_set_header X-Forwarded-For \$remote_addr;
        client_max_body_size 8m;
    }

…und nginx neu laden (docker exec cloud-nginx nginx -s reload).
EOF
