#!/usr/bin/env node
// Humibeam Push-Relay — nimmt Geräte-Tokens entgegen und schickt APNs-Pushes
// ("Claude wartet auf dich") an alle registrierten iPhones/iPads.
//
// Bewusst ohne npm-Dependencies: APNs über node:http2, JWT (ES256) über node:crypto.
//
// Endpunkte:
//   GET  /health                      → ok
//   POST /register {secret, token, device}   → Token speichern
//   POST /notify   {secret, title, body, host} → Push an alle Tokens
//
// config.json (neben server.js):
//   { "secret": "…", "teamId": "DC289RNL2G", "keyId": "<APNs Key ID>",
//     "p8": "AuthKey_XXXX.p8", "bundleId": "app.humibeam.ios", "production": false, "port": 8799 }

const http = require('http');
const http2 = require('http2');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const CONFIG_PATH = path.join(__dirname, 'config.json');
const TOKENS_PATH = path.join(__dirname, 'tokens.json');

const config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
let tokens = {};
try { tokens = JSON.parse(fs.readFileSync(TOKENS_PATH, 'utf8')); } catch { tokens = {}; }

// Vom iPhone beantwortete Freigaben, bis der Mac sie abholt (in-memory reicht).
let pendingActions = [];

function saveTokens() {
  fs.writeFileSync(TOKENS_PATH, JSON.stringify(tokens, null, 2));
}

// --- APNs JWT (ES256), 50 Min gecacht (Apple erlaubt 20–60 Min) ---
let cachedJWT = null;
let jwtIssuedAt = 0;

function apnsJWT() {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJWT && now - jwtIssuedAt < 3000) return cachedJWT;
  const p8 = fs.readFileSync(path.join(__dirname, config.p8), 'utf8');
  const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: config.keyId })).toString('base64url');
  const claims = Buffer.from(JSON.stringify({ iss: config.teamId, iat: now })).toString('base64url');
  const unsigned = `${header}.${claims}`;
  const signature = crypto.sign('sha256', Buffer.from(unsigned), {
    key: p8, dsaEncoding: 'ieee-p1363',
  }).toString('base64url');
  cachedJWT = `${unsigned}.${signature}`;
  jwtIssuedAt = now;
  return cachedJWT;
}

function apnsHost() {
  return config.production ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com';
}

function sendPush(token, title, body, hostLabel, kind, sessionID) {
  return new Promise((resolve) => {
    let client;
    try {
      client = http2.connect(apnsHost());
    } catch (e) { return resolve({ token, ok: false, reason: String(e) }); }
    client.on('error', (e) => resolve({ token, ok: false, reason: String(e) }));

    const aps = {
      alert: { title, body },
      sound: 'default',
      'interruption-level': 'time-sensitive',
    };
    // Freigabe-Pushes bekommen Aktions-Buttons (Erlauben/Immer/Ablehnen) auf dem iPhone.
    if (kind === 'approval') aps.category = 'HUMIBEAM_APPROVAL';
    const payload = JSON.stringify({
      aps,
      host: hostLabel || '',
      kind: kind || '',
      sessionID: sessionID || '',
    });
    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${token}`,
      'authorization': `bearer ${apnsJWT()}`,
      'apns-topic': config.bundleId,
      'apns-push-type': 'alert',
      'apns-priority': '10',
      'content-type': 'application/json',
    });
    let status = 0;
    let data = '';
    req.on('response', (headers) => { status = headers[':status']; });
    req.on('data', (c) => { data += c; });
    req.on('end', () => {
      client.close();
      if (status === 200) return resolve({ token, ok: true });
      // 410 = Token nicht mehr gültig → aufräumen
      if (status === 410) { delete tokens[token]; saveTokens(); }
      resolve({ token, ok: false, status, reason: data });
    });
    req.end(payload);
  });
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (c) => { data += c; if (data.length > 65536) req.destroy(); });
    req.on('end', () => { try { resolve(JSON.parse(data)); } catch { resolve(null); } });
  });
}

const server = http.createServer(async (req, res) => {
  const send = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };

  if (req.method === 'GET' && req.url === '/health') {
    return send(200, { ok: true, devices: Object.keys(tokens).length, apnsConfigured: !!config.keyId });
  }
  if (req.method !== 'POST') return send(404, { error: 'not found' });

  const body = await readBody(req);
  if (!body || body.secret !== config.secret) return send(403, { error: 'forbidden' });

  if (req.url === '/register' && typeof body.token === 'string' && /^[0-9a-fA-F]{32,}$/.test(body.token)) {
    tokens[body.token] = { device: String(body.device || 'iPhone').slice(0, 64), registered: new Date().toISOString() };
    saveTokens();
    return send(200, { ok: true });
  }
  if (req.url === '/notify') {
    if (!config.keyId) return send(503, { error: 'APNs-Key fehlt noch (config.json: keyId/teamId/p8)' });
    const title = String(body.title || 'Humibeam').slice(0, 100);
    const text = String(body.body || '').slice(0, 200);
    const results = await Promise.all(Object.keys(tokens).map((t) =>
      sendPush(t, title, text, body.host, body.kind, body.sessionID)));
    return send(200, { ok: true, sent: results.filter((r) => r.ok).length, total: results.length });
  }
  // Rückkanal: iPhone beantwortet einen Freigabe-Push → Mac holt die Aktion per Poll ab.
  if (req.url === '/action' && typeof body.sessionID === 'string' && typeof body.action === 'string') {
    pendingActions.push({
      sessionID: body.sessionID.slice(0, 64),
      action: body.action.slice(0, 32),          // approve | approve_always | deny
      ts: Date.now(),
    });
    if (pendingActions.length > 100) pendingActions.splice(0, pendingActions.length - 100);
    return send(200, { ok: true });
  }
  if (req.url === '/actions') {
    // Abholen leert die Liste; veraltete Aktionen (>10 Min) verwerfen.
    const fresh = pendingActions.filter((a) => Date.now() - a.ts < 10 * 60 * 1000);
    pendingActions = [];
    return send(200, { actions: fresh });
  }
  send(404, { error: 'not found' });
});

// Bei dockerisiertem nginx auf die Docker-Gateway-IP binden (z.B. "host": "172.18.0.1"),
// sonst erreicht der Container den Host nicht. ufw-Freigabe nicht vergessen.
const bindHost = config.host || '127.0.0.1';
server.listen(config.port || 8799, bindHost, () => {
  console.log(`humibeam-push läuft auf ${bindHost}:${config.port || 8799} (APNs ${config.keyId ? 'konfiguriert' : 'WARTET AUF KEY'})`);
});
