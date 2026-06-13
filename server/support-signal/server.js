#!/usr/bin/env node
'use strict';
// Humibeam Remote-Support — WebRTC-Signaling-Server.
//
// Vermittelt zwischen einem Mac (Rolle "host", der Kunde, der gesteuert wird) und einem
// eingeloggten Supporter (Rolle "supporter", der Browser auf humibeam.com). Der Server
// transportiert NUR Signaling (SDP/ICE) + verwaltet Geräte-ID, Einmalcode, Session-Token und
// das Audit-Log. Der Bildschirm-/Steuer-Datenstrom läuft direkt per WebRTC (oder TURN-Relay),
// niemals durch diesen Server.
//
// Sicherheitsmodell (siehe Spec):
//   - Host registriert sich mit einer stabilen Geräte-ID; der Server vergibt einen kurzlebigen Code.
//   - Supporter muss eingeloggt sein (Bearer-Token, gegen den Sync-Dienst geprüft).
//   - Verbindung nur mit gültiger Geräte-ID + gültigem, nicht abgelaufenem Code.
//   - Host muss die Verbindung optional bestätigen ("Verbindung zulassen").
//   - Code wird nach Session-Ende (und beim Rotationsintervall) ungültig.
//   - Jede Sitzung landet im Audit-Log.
//
// Protokoll (WebSocket, JSON-Nachrichten):
//   Host →   {type:"register", deviceId?, name?}
//   Host ←   {type:"registered", deviceId, code, codeTtl}
//   Host ←   {type:"code", code, codeTtl}                     (Rotation)
//   Host ←   {type:"connection-request", sessionId, supporter}
//   Host →   {type:"accept", sessionId} | {type:"reject", sessionId}
//   Supp →   {type:"auth", token}
//   Supp ←   {type:"authed", email}
//   Supp →   {type:"connect", deviceId, code}
//   Supp ←   {type:"connect-pending", sessionId} | {type:"connect-error", reason}
//   beide ←  {type:"session-start", sessionId, role}
//   beide →  {type:"signal", sessionId, data}   →  an die Gegenseite weitergereicht
//   beide →  {type:"hangup", sessionId}
//   beide ←  {type:"session-end", sessionId, reason}
//   GET /health → {ok, devices, sessions}

const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { WebSocketServer } = require('ws');

const DIR = __dirname;
const config = JSON.parse(fs.readFileSync(path.join(DIR, 'config.json'), 'utf8'));
const PORT = config.port || 8796;
const BIND = config.bindHost || '127.0.0.1';
// URL des Sync-Dienstes, gegen den Supporter-Token geprüft werden (GET /me mit Bearer).
const SYNC_VERIFY_URL = config.syncVerifyUrl || 'http://127.0.0.1:8798/me';
const CODE_TTL_MS = (config.codeTtlSeconds || 300) * 1000;        // Einmalcode: 5 Min Standard
const SESSION_MAX_MS = (config.sessionMaxSeconds || 4 * 3600) * 1000;

const DATA = path.join(DIR, 'data');
fs.mkdirSync(DATA, { recursive: true });
const AUDIT_FILE = path.join(DATA, 'sessions.log');

// --- Zustand (im Speicher; Geräte-IDs sind clientseitig stabil) ---
const devices = new Map();   // deviceId → {ws, name, code, codeExp, status, sessionId}
const sessions = new Map();  // sessionId → {deviceId, supporterEmail, supWs, startedAt, status}

function log(...a) { console.log(new Date().toISOString(), ...a); }

function audit(entry) {
  try { fs.appendFileSync(AUDIT_FILE, JSON.stringify(entry) + '\n'); }
  catch (e) { log('audit-Fehler:', e.message); }
}

function newDeviceId() {
  // Gut lesbare 9-stellige ID in 3er-Gruppen (z. B. 481-205-937).
  const n = crypto.randomInt(0, 1e9).toString().padStart(9, '0');
  return `${n.slice(0, 3)}-${n.slice(3, 6)}-${n.slice(6, 9)}`;
}

function newCode() {
  return crypto.randomInt(0, 1e6).toString().padStart(6, '0');
}

function rotateCode(dev) {
  dev.code = newCode();
  dev.codeExp = Date.now() + CODE_TTL_MS;
  return dev.code;
}

function send(ws, obj) {
  if (ws && ws.readyState === ws.OPEN) ws.send(JSON.stringify(obj));
}

// Supporter-Token gegen den Sync-Dienst prüfen (Zero-Knowledge-Konto). Gibt {email} oder null.
async function verifySupporter(token) {
  if (!token) return null;
  try {
    const res = await fetch(SYNC_VERIFY_URL, { headers: { authorization: 'Bearer ' + token } });
    if (!res.ok) return null;
    const me = await res.json();
    return me && me.accountId ? me : null;
  } catch (e) {
    log('Token-Prüfung fehlgeschlagen:', e.message);
    return null;
  }
}

function endSession(sessionId, reason) {
  const s = sessions.get(sessionId);
  if (!s) return;
  sessions.delete(sessionId);
  const dev = devices.get(s.deviceId);
  if (dev && dev.sessionId === sessionId) {
    dev.status = 'idle';
    dev.sessionId = null;
    rotateCode(dev);  // Code nach Sitzungsende ungültig machen → neuer Code
    send(dev.ws, { type: 'session-end', sessionId, reason });
    send(dev.ws, { type: 'code', code: dev.code, codeTtl: CODE_TTL_MS / 1000 });
  }
  send(s.supWs, { type: 'session-end', sessionId, reason });
  audit({ event: 'session-end', sessionId, deviceId: s.deviceId,
          supporter: s.supporterEmail, startedAt: s.startedAt,
          endedAt: new Date().toISOString(), status: s.status, reason });
  log(`Sitzung beendet ${sessionId} (${reason})`);
}

// --- HTTP (nur Health) ---
const httpServer = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const route = url.pathname.replace(/^\/humibeam-support/, '') || '/';
  if (req.method === 'GET' && route === '/health') {
    const body = JSON.stringify({ ok: true, devices: devices.size, sessions: sessions.size });
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(body);
  }
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end('{"error":"unbekannte Route"}');
});

// --- WebSocket-Signaling ---
const wss = new WebSocketServer({ server: httpServer, path: config.wsPath || '/humibeam-support/ws' });

wss.on('connection', (ws) => {
  // Pro Verbindung: Rolle + Bindung an Gerät/Sitzung.
  const ctx = { role: null, deviceId: null, supporterEmail: null };

  ws.on('message', async (raw) => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }

    // ----- HOST (Mac/Kunde) -----
    if (msg.type === 'register') {
      ctx.role = 'host';
      let deviceId = typeof msg.deviceId === 'string' && /^\d{3}-\d{3}-\d{3}$/.test(msg.deviceId)
        ? msg.deviceId : newDeviceId();
      // Falls die ID schon mit anderer Verbindung belegt ist, alte ersetzen (neuer Start gewinnt).
      const existing = devices.get(deviceId);
      if (existing && existing.ws !== ws) { try { existing.ws.close(); } catch {} }
      const dev = { ws, name: String(msg.name || 'Mac').slice(0, 80),
                    code: null, codeExp: 0, status: 'idle', sessionId: null };
      rotateCode(dev);
      devices.set(deviceId, dev);
      ctx.deviceId = deviceId;
      send(ws, { type: 'registered', deviceId, code: dev.code, codeTtl: CODE_TTL_MS / 1000 });
      audit({ event: 'register', deviceId, name: dev.name, at: new Date().toISOString() });
      log(`Gerät registriert ${deviceId} (${dev.name})`);
      return;
    }

    if (ctx.role === 'host' && (msg.type === 'accept' || msg.type === 'reject')) {
      const s = sessions.get(msg.sessionId);
      if (!s || s.deviceId !== ctx.deviceId || s.status !== 'pending') return;
      if (msg.type === 'reject') return endSession(msg.sessionId, 'vom-kunden-abgelehnt');
      s.status = 'active';
      const dev = devices.get(ctx.deviceId);
      if (dev) { dev.status = 'connected'; dev.sessionId = msg.sessionId; rotateCode(dev); }
      // Beide Seiten dürfen jetzt Signaling austauschen; Supporter ist der WebRTC-Anbieter (Offer).
      send(s.supWs, { type: 'session-start', sessionId: msg.sessionId, role: 'offerer' });
      send(ws, { type: 'session-start', sessionId: msg.sessionId, role: 'answerer' });
      audit({ event: 'session-accepted', sessionId: msg.sessionId, deviceId: ctx.deviceId,
              supporter: s.supporterEmail, at: new Date().toISOString() });
      log(`Sitzung aktiv ${msg.sessionId}`);
      return;
    }

    // ----- SUPPORTER (Browser, eingeloggt) -----
    if (msg.type === 'auth') {
      const me = await verifySupporter(msg.token);
      if (!me) { send(ws, { type: 'auth-error' }); return; }
      ctx.role = 'supporter';
      ctx.supporterEmail = me.email || me.accountId;
      send(ws, { type: 'authed', email: ctx.supporterEmail });
      return;
    }

    if (msg.type === 'connect') {
      if (ctx.role !== 'supporter') { send(ws, { type: 'connect-error', reason: 'nicht-eingeloggt' }); return; }
      const dev = devices.get(String(msg.deviceId || ''));
      if (!dev) return send(ws, { type: 'connect-error', reason: 'geraet-offline' });
      if (dev.status !== 'idle') return send(ws, { type: 'connect-error', reason: 'geraet-belegt' });
      if (!dev.code || dev.code !== String(msg.code || '') || Date.now() > dev.codeExp)
        return send(ws, { type: 'connect-error', reason: 'code-ungueltig' });

      const sessionId = crypto.randomUUID();
      sessions.set(sessionId, {
        deviceId: msg.deviceId, supporterEmail: ctx.supporterEmail, supWs: ws,
        startedAt: new Date().toISOString(), status: 'pending',
      });
      dev.status = 'requested';
      ctx.sessionId = sessionId;
      // Kunde muss bestätigen.
      send(dev.ws, { type: 'connection-request', sessionId, supporter: ctx.supporterEmail });
      send(ws, { type: 'connect-pending', sessionId });
      audit({ event: 'connect-request', sessionId, deviceId: msg.deviceId,
              supporter: ctx.supporterEmail, at: new Date().toISOString() });
      // Auto-Timeout, falls der Kunde nicht reagiert.
      setTimeout(() => {
        const s = sessions.get(sessionId);
        if (s && s.status === 'pending') endSession(sessionId, 'keine-bestaetigung');
      }, 60_000);
      return;
    }

    // ----- Signaling-Relay (SDP/ICE) zwischen den beiden Seiten -----
    if (msg.type === 'signal') {
      const s = sessions.get(msg.sessionId);
      if (!s || s.status !== 'active') return;
      const dev = devices.get(s.deviceId);
      const target = ctx.role === 'supporter' ? (dev && dev.ws) : s.supWs;
      send(target, { type: 'signal', sessionId: msg.sessionId, data: msg.data });
      return;
    }

    if (msg.type === 'hangup') {
      if (msg.sessionId) endSession(msg.sessionId, 'getrennt');
      return;
    }
  });

  ws.on('close', () => {
    if (ctx.role === 'host' && ctx.deviceId) {
      const dev = devices.get(ctx.deviceId);
      if (dev && dev.ws === ws) {
        if (dev.sessionId) endSession(dev.sessionId, 'kunde-getrennt');
        devices.delete(ctx.deviceId);
        log(`Gerät weg ${ctx.deviceId}`);
      }
    }
    if (ctx.role === 'supporter' && ctx.sessionId) {
      endSession(ctx.sessionId, 'supporter-getrennt');
    }
  });
});

// Abgelaufene Codes laufend erneuern, damit ein wartendes Gerät immer einen gültigen Code zeigt.
setInterval(() => {
  const now = Date.now();
  for (const dev of devices.values()) {
    if (dev.status === 'idle' && now > dev.codeExp) {
      rotateCode(dev);
      send(dev.ws, { type: 'code', code: dev.code, codeTtl: CODE_TTL_MS / 1000 });
    }
  }
  // Sitzungs-Obergrenze hart durchsetzen.
  for (const [id, s] of sessions) {
    if (now - Date.parse(s.startedAt) > SESSION_MAX_MS) endSession(id, 'max-dauer');
  }
}, 30_000);

httpServer.listen(PORT, BIND, () => {
  log(`Humibeam Support-Signaling läuft auf ${BIND}:${PORT} (ws ${config.wsPath || '/humibeam-support/ws'})`);
});
