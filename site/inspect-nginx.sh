#!/usr/bin/env bash
# Diagnose: wie ist nginx auf diesem Server strukturiert? (als root via sudo bash)
echo ">>>INCLUDES (nginx.conf)"
grep -nE 'include' /etc/nginx/nginx.conf
echo ">>>VHOST-VERZEICHNISSE"
ls -d /etc/nginx/sites-enabled /etc/nginx/sites-available /etc/nginx/conf.d 2>/dev/null
echo ">>>EFFEKTIVE SERVER-BLOECKE (server_name / cert / root)"
nginx -T 2>/dev/null | grep -nE 'server_name|ssl_certificate |root /var/www' | head -40
echo ">>>HUMIBEAM IM EFFEKTIVEN CONFIG?"
nginx -T 2>/dev/null | grep -c humibeam
echo ">>>WO LIEGT DER HUMIQA-VHOST?"
grep -rlE 'humiqa\.com' /etc/nginx/ 2>/dev/null
echo ">>>CERTBOT-LOG (letzte Zeilen)"
tail -n 15 /var/log/letsencrypt/letsencrypt.log 2>/dev/null
echo ">>>DONE"
