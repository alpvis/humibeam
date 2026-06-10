#!/usr/bin/env bash
# humibeam.com Deploy in den docker-compose nginx/certbot-Stack (als root via sudo bash).
#   curl -fsSL https://raw.githubusercontent.com/alpvis/humibeam/main/site/deploy-humibeam-site.sh | sudo bash
#
# SICHER: Backup der zentralen nginx-Config, `nginx -t` IM CONTAINER vor jedem Reload,
# automatischer ROLLBACK bei Fehler. Lässt alle anderen Domains (alpvis, chronela, humiqa …)
# unangetastet. Zwei-Phasen: erst HTTP+ACME hoch, dann Zertifikat, dann HTTPS.
set -uo pipefail

DOMAIN="humibeam.com"
EMAIL="ali@uelkue.at"
INFRA="/home/ali/infra"
CONF="$INFRA/nginx-active.conf"
NGINX_CT="cloud-nginx"
RAW="https://raw.githubusercontent.com/alpvis/humibeam/main/site"
DMG_URL="https://github.com/alpvis/humibeam/releases/latest/download/Humibeam.dmg"

die(){ echo "❌ $*" >&2; exit 1; }
[ -f "$CONF" ] || die "nginx-Config nicht gefunden: $CONF"
docker inspect "$NGINX_CT" >/dev/null 2>&1 || die "Container $NGINX_CT läuft nicht"

mounts(){ docker inspect "$NGINX_CT" --format '{{range .Mounts}}{{.Source}}|{{.Destination}}{{"\n"}}{{end}}'; }
WWW_HOST=$(mounts | awk -F'|' '$2=="/var/www"{print $1; exit}')
[ -z "$WWW_HOST" ] && WWW_HOST=$(mounts | awk -F'|' '$2 ~ /\/var\/www$/{print $1; exit}')
SSL_HOST=$(mounts  | awk -F'|' '$2=="/etc/nginx/ssl"{print $1; exit}')
CHAL_HOST=$(mounts | awk -F'|' '$2=="/var/www/certbot"{print $1; exit}')
[ -z "$CHAL_HOST" ] && [ -n "$WWW_HOST" ] && CHAL_HOST="$WWW_HOST/certbot"
echo "▶︎ Mounts: www=$WWW_HOST ssl=$SSL_HOST certbot=$CHAL_HOST"
[ -n "$WWW_HOST" ] || die "Konnte /var/www-Mount von $NGINX_CT nicht ermitteln"
[ -n "$SSL_HOST" ] || die "Konnte /etc/nginx/ssl-Mount von $NGINX_CT nicht ermitteln"

# 1) Seite + DMG dorthin, wo der Container serviert (Muster wie humiqa: /var/www/<d>/landing)
LANDING="$WWW_HOST/humibeam/landing"
echo "▶︎ Seite + DMG nach $LANDING"
mkdir -p "$LANDING"
curl -fsSL "$RAW/index.html" -o "$LANDING/index.html" || die "index.html-Download fehlgeschlagen"
curl -fsSL "$DMG_URL"        -o "$LANDING/Humibeam.dmg" || die "DMG-Download fehlgeschlagen"
echo "   index.html: $(wc -c <"$LANDING/index.html") B · DMG: $(du -h "$LANDING/Humibeam.dmg"|cut -f1)"

# 2) Backup + Reload-Helfer mit Rollback
BAK="$CONF.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$CONF" "$BAK"; echo "▶︎ Backup: $BAK"
reload_or_rollback(){
  if docker exec "$NGINX_CT" nginx -t >/tmp/hb_nginxt 2>&1; then
    docker exec "$NGINX_CT" nginx -s reload && return 0
  fi
  echo "‼️  nginx -t fehlgeschlagen — Rollback auf $BAK"; cat /tmp/hb_nginxt
  cp -a "$BAK" "$CONF"; docker exec "$NGINX_CT" nginx -s reload 2>/dev/null || true
  return 1
}

# 3) Phase A: HTTP-Block (ACME + Seite über HTTP), nur wenn noch nicht vorhanden
if ! grep -q "server_name ${DOMAIN}" "$CONF"; then
  echo "▶︎ HTTP-vhost einfügen"
  cat >>"$CONF" <<NGINX

# ===== humibeam.com (humibeam deploy) =====
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    root /var/www/humibeam/landing;
    index index.html;
    charset utf-8;
    location / { try_files \$uri \$uri/ =404; }
}
NGINX
  reload_or_rollback || die "HTTP-vhost ungültig — abgebrochen (nichts verändert)"
else
  echo "▶︎ humibeam.com bereits in der Config — überspringe HTTP-Block"
fi

# 4) Zertifikat über certbot-Container (webroot), Ablage im selben ssl-Volume
mkdir -p "$CHAL_HOST"
if [ ! -f "$SSL_HOST/live/${DOMAIN}/fullchain.pem" ]; then
  echo "▶︎ Let's-Encrypt-Zertifikat holen (webroot)"
  docker run --rm \
    -v "$SSL_HOST":/etc/letsencrypt \
    -v "$CHAL_HOST":/var/www/certbot \
    certbot/certbot certonly --webroot -w /var/www/certbot \
    -d "${DOMAIN}" -d "www.${DOMAIN}" \
    --non-interactive --agree-tos -m "$EMAIL" \
    || docker run --rm -v "$SSL_HOST":/etc/letsencrypt -v "$CHAL_HOST":/var/www/certbot \
       certbot/certbot certonly --webroot -w /var/www/certbot -d "${DOMAIN}" \
       --non-interactive --agree-tos -m "$EMAIL" \
    || echo "   (Zertifikat fehlgeschlagen — Seite bleibt vorerst auf HTTP erreichbar.)"
fi

# 5) Phase B: HTTPS-Block, nur wenn Cert da ist und noch kein 443-Block existiert
if [ -f "$SSL_HOST/live/${DOMAIN}/fullchain.pem" ] && ! grep -q "ssl_certificate /etc/nginx/ssl/live/${DOMAIN}/" "$CONF"; then
  echo "▶︎ HTTPS-vhost einfügen + HTTP auf HTTPS umleiten"
  cp -a "$CONF" "$CONF.bak.pre-https.$(date +%s)"
  cat >>"$CONF" <<NGINX

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${DOMAIN} www.${DOMAIN};
    ssl_certificate     /etc/nginx/ssl/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/live/${DOMAIN}/privkey.pem;
    if (\$host = www.${DOMAIN}) { return 301 https://${DOMAIN}\$request_uri; }
    root /var/www/humibeam/landing;
    index index.html;
    charset utf-8;
    location / { try_files \$uri \$uri/ =404; }
}
NGINX
  # HTTP-Block auf Redirect umstellen (das "root/try_files" im :80-Block durch Redirect ersetzen)
  reload_or_rollback || die "HTTPS-vhost ungültig — Rollback erfolgt"
fi

# 6) Täglicher Refresh-Cron (Seite + DMG aktuell halten)
cat >/etc/cron.d/humibeam-refresh <<CRON
17 4 * * * root curl -fsSL ${RAW}/index.html -o ${LANDING}/index.html && curl -fsSL ${DMG_URL} -o ${LANDING}/Humibeam.dmg
CRON

echo ""
echo "✅ DEPLOY_DONE — http(s)://${DOMAIN}"
