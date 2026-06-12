#!/bin/bash
# Humibeam v5 — kompletter Server-Deploy in einem Lauf (auf alpvis.com / 187.77.83.55).
# Richtet Konto-Sync (8798, hinter nginx /humibeam-sync/) und Beam-Tunnel (8797, direkter TCP-Port)
# ein. Idempotent, mit nginx-Test + Rollback. Bewusst an die vorhandene Push-Relay-Topologie angelehnt.
#
#   curl -fsSL https://raw.githubusercontent.com/alpvis/humibeam/main/server/deploy-v5.sh | bash
set -uo pipefail

GW=172.18.0.1                 # Docker-Gateway (wie Push-Relay: 172.18.0.1:8799)
NGINX_CT=ll-nginx
NGINX_CONF=/home/ali/levantes-living/infra/nginx-active.conf
RAW=https://raw.githubusercontent.com/alpvis/humibeam/main
say(){ printf '\n▶︎ %s\n' "$*"; }
die(){ printf '\n❌ %s\n' "$*" >&2; exit 1; }

command -v node >/dev/null || die "node fehlt"
NODE=$(command -v node)

# ---------- 1) Konto-Sync (8798) ----------
say "Konto-Sync nach /home/ali/humibeam-sync"
mkdir -p /home/ali/humibeam-sync/data
curl -fsSL "$RAW/server/sync/server.js" -o /home/ali/humibeam-sync/server.js || die "sync server.js"
[ -f /home/ali/humibeam-sync/config.json ] || \
  printf '{ "port": 8798, "bindHost": "%s" }\n' "$GW" > /home/ali/humibeam-sync/config.json

sudo tee /etc/systemd/system/humibeam-sync.service >/dev/null <<EOF
[Unit]
Description=Humibeam Konto-Sync (E2E)
After=network.target
[Service]
ExecStart=$NODE /home/ali/humibeam-sync/server.js
WorkingDirectory=/home/ali/humibeam-sync
Restart=always
RestartSec=3
User=$USER
[Install]
WantedBy=multi-user.target
EOF

# ---------- 2) Beam-Tunnel (8797, direkter Port) ----------
say "Beam-Tunnel nach /home/ali/humibeam-beam"
mkdir -p /home/ali/humibeam-beam
curl -fsSL "$RAW/server/beam-tunnel/server.js" -o /home/ali/humibeam-beam/server.js || die "beam server.js"
[ -f /home/ali/humibeam-beam/config.json ] || \
  printf '{ "port": 8797, "bindHost": "0.0.0.0" }\n' > /home/ali/humibeam-beam/config.json

sudo tee /etc/systemd/system/humibeam-beam.service >/dev/null <<EOF
[Unit]
Description=Humibeam Beam-Tunnel (MacBeam Rendezvous, E2E)
After=network.target
[Service]
ExecStart=$NODE /home/ali/humibeam-beam/server.js
WorkingDirectory=/home/ali/humibeam-beam
Restart=always
RestartSec=3
User=$USER
[Install]
WantedBy=multi-user.target
EOF

say "Dienste starten"
sudo systemctl daemon-reload
sudo systemctl enable --now humibeam-sync humibeam-beam
sleep 1
sudo systemctl is-active humibeam-sync humibeam-beam || die "Dienst nicht aktiv (journalctl -u humibeam-sync prüfen)"
curl -fsS "http://$GW:8798/health" >/dev/null && echo "   sync /health ok" || echo "   ⚠ sync /health (noch) nicht erreichbar"

# ---------- 3) Firewall für den Beam-Tunnel ----------
if command -v ufw >/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  sudo ufw allow 8797/tcp >/dev/null 2>&1 && say "ufw: 8797/tcp freigegeben"
fi

# ---------- 4) nginx: /humibeam-sync/ neben /humibeam-push/ ----------
if [ -f "$NGINX_CONF" ]; then
  if grep -q "humibeam-sync" "$NGINX_CONF"; then
    say "nginx: /humibeam-sync/ bereits vorhanden"
  elif grep -q "location /humibeam-push/" "$NGINX_CONF"; then
    say "nginx: /humibeam-sync/ ergänzen (Backup + Test + Rollback)"
    sudo cp -a "$NGINX_CONF" "$NGINX_CONF.bak.$(date +%s)"
    sudo sed -i "/location \/humibeam-push\//a\\        location /humibeam-sync/ { proxy_pass http://$GW:8798/; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$remote_addr; client_max_body_size 8m; }" "$NGINX_CONF"
    if sudo docker exec "$NGINX_CT" nginx -t >/dev/null 2>&1; then
      sudo docker exec "$NGINX_CT" nginx -s reload && echo "   nginx neu geladen ✓"
    else
      LAST=$(ls -t "$NGINX_CONF".bak.* | head -1)
      sudo cp -a "$LAST" "$NGINX_CONF"
      die "nginx -t schlug fehl → zurückgerollt ($LAST). Bitte manuell prüfen."
    fi
  else
    echo "   ⚠ Kein /humibeam-push/-Block gefunden — bitte /humibeam-sync/ manuell ergänzen:"
    echo "     location /humibeam-sync/ { proxy_pass http://$GW:8798/; proxy_set_header Host \$host; client_max_body_size 8m; }"
  fi
else
  echo "   ⚠ $NGINX_CONF nicht gefunden — nginx-Location bitte manuell setzen."
fi

say "Fertig. Status:"
sudo systemctl is-active humibeam-sync humibeam-beam
echo "   Sync extern testen:  curl -fsS https://alpvis.com/humibeam-sync/health"
echo "   Beam-Tunnel lauscht: $(ss -tlnp 2>/dev/null | grep -c ':8797') Listener auf :8797"
