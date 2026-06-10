#!/usr/bin/env bash
# humibeam Landingpage Deploy — als root ausführen:
#   curl -fsSL https://raw.githubusercontent.com/alpvis/humibeam/main/site/deploy-humibeam-site.sh | sudo bash
#
# Richtet humibeam.com auf diesem Server ein (eigener nginx-vhost, lässt die Humiqa-Seite
# unangetastet), zieht die Landingpage + das aktuelle macOS-DMG von GitHub, holt ein
# Let's-Encrypt-Zertifikat und legt einen täglichen Refresh-Cron an.
set -euo pipefail

DOMAIN="humibeam.com"
WEBROOT="/var/www/humibeam"
RAW="https://raw.githubusercontent.com/alpvis/humibeam/main/site"
DMG_URL="https://github.com/alpvis/humibeam/releases/latest/download/Humibeam.dmg"
EMAIL="ali@uelkue.at"

echo "▶︎ Web-Root anlegen: $WEBROOT"
mkdir -p "$WEBROOT"

echo "▶︎ Landingpage + DMG von GitHub holen"
curl -fsSL "$RAW/index.html" -o "$WEBROOT/index.html"
curl -fsSL "$DMG_URL" -o "$WEBROOT/Humibeam.dmg"
chown -R www-data:www-data "$WEBROOT" 2>/dev/null || true
echo "   index.html: $(wc -c <"$WEBROOT/index.html") Bytes · Humibeam.dmg: $(du -h "$WEBROOT/Humibeam.dmg" | cut -f1)"

echo "▶︎ nginx-vhost schreiben (HTTP; certbot ergänzt HTTPS)"
cat >/etc/nginx/conf.d/humibeam.conf <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};
    root ${WEBROOT};
    index index.html;
    charset utf-8;
    location / { try_files \$uri \$uri/ =404; }
}
NGINX

nginx -t && systemctl reload nginx
echo "   nginx neu geladen."

echo "▶︎ Let's-Encrypt-Zertifikat für ${DOMAIN}"
if ! command -v certbot >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y certbot python3-certbot-nginx
fi
# www nur einbeziehen, wenn es auf diesen Server zeigt (sonst schlägt certbot sonst fehl)
DOMAIN_ARGS="-d ${DOMAIN}"
if getent hosts "www.${DOMAIN}" >/dev/null 2>&1; then DOMAIN_ARGS="$DOMAIN_ARGS -d www.${DOMAIN}"; fi
certbot --nginx $DOMAIN_ARGS --non-interactive --agree-tos -m "$EMAIL" --redirect || \
    echo "   (Zertifikat konnte nicht automatisch geholt werden — Seite läuft erstmal über HTTP.)"
nginx -t && systemctl reload nginx

echo "▶︎ Täglichen Refresh-Cron einrichten (Seite + DMG aktuell halten)"
cat >/etc/cron.d/humibeam-refresh <<CRON
# humibeam: Landingpage & DMG täglich von GitHub aktualisieren
17 4 * * * root curl -fsSL ${RAW}/index.html -o ${WEBROOT}/index.html && curl -fsSL ${DMG_URL} -o ${WEBROOT}/Humibeam.dmg && chown www-data:www-data ${WEBROOT}/index.html ${WEBROOT}/Humibeam.dmg
CRON

echo ""
echo "✅ DEPLOY_DONE — https://${DOMAIN}"
