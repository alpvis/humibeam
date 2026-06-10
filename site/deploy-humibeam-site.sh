#!/usr/bin/env bash
# humibeam.com Deploy in den docker-compose nginx/certbot-Stack (/home/ali/infra), als root.
#   curl -fsSL https://raw.githubusercontent.com/alpvis/humibeam/main/site/deploy-humibeam-site.sh | sudo bash
#
# SICHER & idempotent: Backup von nginx-cloud.conf + docker-compose.yml, `nginx -t` IM CONTAINER
# vor jedem Reload, ROLLBACK bei Fehler. Lässt alle anderen Domains unangetastet.
set -uo pipefail
INFRA="/home/ali/infra"
CONF="$INFRA/nginx-cloud.conf"
COMPOSE="$INFRA/docker-compose.yml"
NGINX_CT="cloud-nginx"
DOMAIN="humibeam.com"
EMAIL="ali@uelkue.at"
LANDING_HOST="/home/ali/humibeam-landing"
SSL_HOST="$INFRA/ssl"
CERT_VOL="infra_certbot_webroot"
RAW="https://raw.githubusercontent.com/alpvis/humibeam/main/site"
DMG_URL="https://github.com/alpvis/humibeam/releases/latest/download/Humibeam.dmg"

die(){ echo "❌ $*" >&2; exit 1; }
cd "$INFRA" || die "kein $INFRA"
[ -f "$CONF" ] || die "fehlt: $CONF"
[ -f "$COMPOSE" ] || die "fehlt: $COMPOSE"

# 1) Landing-Dateien
echo "▶︎ 1) Landing nach $LANDING_HOST"
mkdir -p "$LANDING_HOST"
curl -fsSL "$RAW/index.html" -o "$LANDING_HOST/index.html" || die "index.html download"
curl -fsSL "$DMG_URL"        -o "$LANDING_HOST/Humibeam.dmg" || die "dmg download"
echo "   index.html $(wc -c <"$LANDING_HOST/index.html")B · DMG $(du -h "$LANDING_HOST/Humibeam.dmg"|cut -f1)"

# 2a) compose: ro-Mount ergänzen (idempotent)
if ! grep -q "humibeam-landing:/var/www/humibeam/landing" "$COMPOSE"; then
  cp -a "$COMPOSE" "$COMPOSE.bak.$(date +%s)"
  sed -i "/fronela-landing:\/var\/www\/fronela\/landing:ro/a\\      - $LANDING_HOST:/var/www/humibeam/landing:ro" "$COMPOSE"
  echo "▶︎ 2a) Mount in compose ergänzt"
else
  echo "▶︎ 2a) Mount in compose bereits vorhanden"
fi
# 2b) cloud-nginx NUR neu aufsetzen (ohne Abhängigkeiten!), wenn der laufende Container den Mount noch nicht hat
if ! docker inspect "$NGINX_CT" --format '{{range .Mounts}}{{.Destination}} {{end}}' 2>/dev/null | grep -q '/var/www/humibeam/landing'; then
  echo "▶︎ 2b) cloud-nginx neu aufsetzen (--no-deps, nur dieser Container)"
  docker compose up -d --no-deps --force-recreate "$NGINX_CT" || die "compose up (cloud-nginx) fehlgeschlagen"
  sleep 2
else
  echo "▶︎ 2b) cloud-nginx hat den Mount bereits"
fi

# 3) Zertifikat (ACME läuft über den vorhandenen Catch-all-:80-Block)
if [ ! -f "$SSL_HOST/live/$DOMAIN/fullchain.pem" ]; then
  echo "▶︎ 3) Let's-Encrypt-Zertifikat holen"
  docker run --rm \
    -v "$SSL_HOST":/etc/letsencrypt \
    -v "${CERT_VOL}":/var/www/certbot \
    certbot/certbot certonly --webroot -w /var/www/certbot \
    -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" \
    || echo "   ⚠️ Zertifikat fehlgeschlagen — Block wird übersprungen, Seite ggf. nur über Default-Cert."
else
  echo "▶︎ 3) Zertifikat existiert bereits"
fi

# 4) nginx-Server-Block für humibeam.com einfügen (vor dem letzten '}' = Ende des http{})
if [ -f "$SSL_HOST/live/$DOMAIN/fullchain.pem" ] && ! grep -q "server_name $DOMAIN;" "$CONF"; then
  echo "▶︎ 4) HTTPS-Server-Block einfügen"
  BAK="$CONF.bak.$(date +%Y%m%d-%H%M%S)"; cp -a "$CONF" "$BAK"; echo "   Backup: $BAK"
  BLOCK=$(cat <<NGINX

    # ====== HUMIBEAM.COM — HTTPS (humibeam deploy) ======
    server {
        listen 443 ssl;
        http2 on;
        server_name $DOMAIN;

        ssl_certificate /etc/nginx/ssl/live/$DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/nginx/ssl/live/$DOMAIN/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;
        ssl_prefer_server_ciphers on;

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

        root /var/www/humibeam/landing;
        index index.html;
        charset utf-8;

        location = /Humibeam.dmg { add_header Content-Disposition 'attachment; filename="Humibeam.dmg"'; }
        location / { try_files \$uri \$uri/ =404; }
    }
NGINX
)
  LAST=$(grep -n '^}' "$CONF" | tail -1 | cut -d: -f1)
  [ -n "$LAST" ] || { cp -a "$BAK" "$CONF"; die "konnte http{}-Ende nicht finden"; }
  TMP=$(mktemp)
  head -n $((LAST-1)) "$CONF" > "$TMP"
  printf '%s\n' "$BLOCK" >> "$TMP"
  tail -n +"$LAST" "$CONF" >> "$TMP"
  cat "$TMP" > "$CONF"; rm -f "$TMP"

  if docker exec "$NGINX_CT" nginx -t >/tmp/hb_ngt 2>&1; then
    docker exec "$NGINX_CT" nginx -s reload && echo "   ✅ nginx neu geladen"
  else
    echo "‼️  nginx -t FEHLER — Rollback:"; cat /tmp/hb_ngt
    cp -a "$BAK" "$CONF"; docker exec "$NGINX_CT" nginx -s reload 2>/dev/null || true
    die "Server-Block ungültig — zurückgerollt, nichts kaputt"
  fi
else
  echo "▶︎ 4) Block existiert schon oder kein Cert — übersprungen"
fi

# 5) Täglicher Refresh-Cron
cat >/etc/cron.d/humibeam-refresh <<CRON
17 4 * * * root curl -fsSL ${RAW}/index.html -o ${LANDING_HOST}/index.html && curl -fsSL ${DMG_URL} -o ${LANDING_HOST}/Humibeam.dmg
CRON

echo ""; echo "✅ DEPLOY_DONE — https://$DOMAIN"
