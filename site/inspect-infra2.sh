#!/usr/bin/env bash
# Letzte Details für den humibeam.com-vhost (als root via sudo bash).
INFRA=/home/ali/infra
CF=$(ls "$INFRA"/docker-compose*.y*ml "$INFRA"/compose*.y*ml 2>/dev/null | head -1)
echo ">>>COMPOSE: $CF"
echo ">>>cloud-nginx VOLUMES"
sed -n '/cloud-nginx:/,/^[[:space:]]\{0,2\}[a-zA-Z_-]\+:[[:space:]]*$/p' "$CF" 2>/dev/null | grep -iE 'volumes|:/|image|container_name|ports' | grep -ivE 'password|secret|key=' | head -25
echo ">>>cloud-certbot SERVICE"
sed -n '/cloud-certbot:/,/^[[:space:]]\{0,2\}[a-zA-Z_-]\+:[[:space:]]*$/p' "$CF" 2>/dev/null | grep -ivE 'password|secret' | head -25
echo ">>>certbot-Helper-Skripte im infra?"
ls "$INFRA"/*.sh 2>/dev/null; grep -rln 'certbot certonly\|certonly --webroot\|acme' "$INFRA"/*.sh "$INFRA" 2>/dev/null | head
echo ">>>humiqa-TEMPLATE (HTTP+HTTPS server-Bloecke)"
awk 'NR>=455 && NR<=560' "$INFRA"/nginx-active.conf 2>/dev/null
echo ">>>SIEHT cloud-nginx /var/www/humibeam ?"
docker exec cloud-nginx ls -la /var/www/ 2>/dev/null | head -20
echo ">>>CONTAINER ssl/live"
docker exec cloud-nginx ls /etc/nginx/ssl/live/ 2>/dev/null
echo ">>>DONE"
