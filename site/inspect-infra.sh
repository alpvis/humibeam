#!/usr/bin/env bash
# Zeigt die nginx/certbot-Struktur des docker-compose-Stacks (als root via sudo bash).
# Bewusst ohne Secrets: nur Verzeichnisbaum, nginx-Service-Mounts und vhost-Configs.
INFRA=/home/ali/infra
echo ">>>INFRA-BAUM"; ls -la "$INFRA" 2>/dev/null
echo ">>>COMPOSE-DATEI?"; ls "$INFRA"/docker-compose*.y*ml "$INFRA"/compose*.y*ml 2>/dev/null
CF=$(ls "$INFRA"/docker-compose*.y*ml "$INFRA"/compose*.y*ml 2>/dev/null | head -1)
echo ">>>cloud-nginx SERVICE-BLOCK (Mounts/Command)"
awk '/cloud-nginx:|^[[:space:]]*nginx:/{f=1} f&&/^[[:space:]]{0,4}[a-zA-Z_-]+:[[:space:]]*$/&&!/nginx/&&NR>1{if(seen)exit} {if(f)print} /cloud-nginx:|nginx:/{seen=1}' "$CF" 2>/dev/null | grep -ivE 'password|secret|key|token' | head -40
echo ">>>cloud-certbot SERVICE-BLOCK"
awk '/cloud-certbot:|certbot:/{f=1} f&&/^[[:space:]]{0,4}[a-zA-Z_-]+:[[:space:]]*$/&&!/certbot/&&NR>1{if(seen)exit} {if(f)print} /cloud-certbot:|certbot:/{seen=1}' "$CF" 2>/dev/null | grep -ivE 'password|secret|token' | head -30
echo ">>>NGINX-CONFIG-DATEIEN IM INFRA"
find "$INFRA" -type f \( -name '*.conf' -o -name 'nginx.conf' -o -path '*nginx*' \) 2>/dev/null | grep -iE 'nginx|conf' | head -40
echo ">>>SERVER_NAME / ROOT / PROXY IN DEN CONFIGS"
grep -rnE 'server_name|root |proxy_pass|ssl_certificate ' $(find "$INFRA" -type f -name '*.conf' 2>/dev/null) 2>/dev/null | grep -ivE 'password|secret' | head -60
echo ">>>WIE WIRD humiqa SERVIERT?"
grep -rnE 'humiqa' $(find "$INFRA" -type f 2>/dev/null) 2>/dev/null | grep -ivE 'password|secret|env' | head
echo ">>>CERT-VERZEICHNIS (live)"
find "$INFRA" -type d -name 'live' 2>/dev/null; ls "$INFRA"/*/live/ "$INFRA"/letsencrypt/live/ 2>/dev/null
echo ">>>DONE"
