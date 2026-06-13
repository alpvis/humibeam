# Remote-Support-Backend — Deploy auf humibeam.com (187.124.171.131)

Live seit 2026-06-13. Box `cloud`, Ubuntu 24.04, nginx im Docker-Container `cloud-nginx`
(monolithische Config `/home/ali/infra/nginx-cloud.conf`, Gateway 172.18.0.1).

## Dienste (systemd, als Node auf dem Host)

| Dienst | Unit | Bind | nginx-Location |
|---|---|---|---|
| Konto-Sync | `humibeam-sync` | 172.18.0.1:8798 | `/humibeam-sync/` |
| Support-Signaling | `humibeam-support` | 172.18.0.1:8796 | `/humibeam-support/` + `/humibeam-support/ws` (WS-Upgrade) |
| coturn (TURN) | `coturn` | 187.124.171.131:3478 (UDP+TCP) | — (turn.humibeam.com) |

Code unter `/home/ali/humibeam-services/{sync,support-signal}/`. An 172.18.0.1 gebunden →
erreichbar für cloud-nginx + Host, **nicht** öffentlich. ufw lässt 8798/8796 nur aus 172.18.0.0/16.

## coturn

`/etc/turnserver.conf`: `use-auth-secret`, `static-auth-secret` = Inhalt von
`/home/ali/humibeam-services/turn-secret.txt` (NICHT im Repo). `realm=humibeam.com`,
`listening-ip=187.124.171.131`, `external-ip=187.124.171.131`, Relay-Ports 49152–65535,
`no-tls`/`no-dtls` (Medien sind ohnehin DTLS-SRTP-verschlüsselt). Dasselbe Secret steht als
`turnSecret` in `support-signal/config.json`; `/humibeam-support/ice` liefert daraus
zeitbegrenzte Credentials (HMAC-SHA1, 600 s).
ufw offen: 3478/udp, 3478/tcp, 49152:65535/udp.

## nginx-Eingriff (inode-erhaltend!)

`sed -i` ersetzt die Inode → der ro-Bind-Mount im Container sieht die Änderung nie. Stattdessen:
Backup, `awk` fügt die Location-Blöcke nach der eindeutigen `location = /Humibeam.dmg`-Zeile ein,
dann `cat tmp > nginx-cloud.conf`, `docker exec cloud-nginx nginx -t`, bei Erfolg
`nginx -s reload`, sonst Rollback aus Backup. Backups: `nginx-cloud.conf.bak.<ts>`.

## Supporter-Web-App

`site/support/` → `/home/ali/humibeam-landing/support/` (gemountet als
`/var/www/humibeam/landing/support`), erreichbar unter https://humibeam.com/support/.

## Verifiziert (extern)

- https://humibeam.com/ → 200 (Landing intakt), Nachbarseiten unberührt
- https://humibeam.com/support/ → 200
- https://humibeam.com/humibeam-sync/health → `{"ok":true}`
- https://humibeam.com/humibeam-support/health → `{"ok":true,...}`
- WS `/humibeam-support/ws` → 101 (HTTP/1.1)
- turn.humibeam.com:3478/udp → offen
