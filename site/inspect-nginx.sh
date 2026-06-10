#!/usr/bin/env bash
# Findet heraus, wie nginx auf diesem Server wirklich läuft (als root via sudo bash).
echo ">>>NGINX-BINARY"; command -v nginx; readlink -f "$(command -v nginx)" 2>/dev/null
echo ">>>NGINX-V (conf-path/prefix)"; nginx -V 2>&1 | tr ' ' '\n' | grep -E 'conf-path|prefix|error-log'
echo ">>>NGINX-T (welche config wird getestet)"; nginx -t 2>&1
echo ">>>NGINX-PROZESS"; ps aux | grep -i '[n]ginx' | head
echo ">>>SNAP?"; snap list 2>/dev/null | grep -iE 'nginx|openresty'
echo ">>>DOCKER?"; if command -v docker >/dev/null 2>&1; then docker ps --format '{{.Names}} | {{.Image}} | {{.Ports}}' 2>/dev/null; else echo 'kein docker'; fi
echo ">>>/etc/nginx INHALT"; ls -la /etc/nginx/ 2>/dev/null
echo ">>>WO STEHT humiqa.com IN DER CONFIG?"; grep -rlE 'humiqa\.com' /etc/nginx/ /usr/local/nginx/ /usr/local/openresty/ /var/snap/ /opt/ 2>/dev/null | head
echo ">>>WEBROOT VORHANDEN?"; ls -la /var/www/humibeam/ 2>/dev/null
echo ">>>DONE"
