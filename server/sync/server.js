#!/usr/bin/env node
// Humibeam Konto-Sync — Ende-zu-Ende-verschlüsselter Geräte-Sync (Profile, Snippets, Darstellung).
//
// Der Server sieht NIE Klartext-Daten und NIE das Passwort:
//   Client: masterKey = PBKDF2-SHA256(passwort, kdfSalt, 600000)
//           authKey   = HKDF(masterKey, "humibeam-auth")   → geht zum Server (der hasht ihn nochmal)
//           encKey    = HKDF(masterKey, "humibeam-enc")    → bleibt auf dem Gerät (AES-GCM fürs Blob)
//   Server: speichert scrypt(authKey, serverSalt) + das verschlüsselte Blob (Base64-Chiffrat).
//
// API (hinter nginx unter /humibeam-sync/):
//   POST /register   {email, kdfSalt, authKey}          → {token}
//   GET  /salt?email=…                                  → {kdfSalt}
//   POST /login      {email, authKey}                   → {token}
//   POST /change-password {email, oldAuthKey, newKdfSalt, newAuthKey, payload?} → {token}
//   GET  /sessions   (Bearer)                           → {sessions:[{id,createdAt,current}]}
//   POST /logout-all (Bearer)                           → {revoked}
//   POST /delete     (Bearer)                           → {ok}
//   POST /logout     (Bearer)                           → {}
//   DELETE /admin/account?email=… (x-admin-token)       → {ok}
//   GET  /blob       (Bearer)                           → {rev, payload, updatedAt, device} | 204
//   PUT  /blob       (Bearer) {rev, payload, device}    → {rev} | 409 + aktuelles Blob
//   GET  /health                                        → ok
//   GET  /admin/stats (x-admin-token)                   → Betreiber-Statistik (nur Metadaten, kein Klartext)
//
// Konfiguration: ./config.json  { "port": 8798, "adminToken": "<geheim, optional>" }
// Ohne adminToken ist der Admin-Endpoint deaktiviert (503).
'use strict';

const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const DIR = __dirname;
const DATA = path.join(DIR, 'data');
const BLOBS = path.join(DATA, 'blobs');
fs.mkdirSync(BLOBS, { recursive: true });

const config = JSON.parse(fs.readFileSync(path.join(DIR, 'config.json'), 'utf8'));
const PORT = config.port || 8798;
const ADMIN_TOKEN = config.adminToken || '';   // leer = Admin-Endpoint deaktiviert

// Konstant-zeitiger Vergleich des Admin-Tokens (verhindert Timing-Lecks).
function adminAuthorized(req) {
  if (!ADMIN_TOKEN) return false;
  const given = String(req.headers['x-admin-token'] || '');
  const a = Buffer.from(given);
  const b = Buffer.from(ADMIN_TOKEN);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

const ACCOUNTS_FILE = path.join(DATA, 'accounts.json');
const TOKENS_FILE = path.join(DATA, 'tokens.json');
const TOKEN_TTL_MS = 1000 * 60 * 60 * 24 * 90; // 90 Tage

function loadJSON(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}
function saveJSON(file, value) {
  fs.writeFileSync(file + '.tmp', JSON.stringify(value, null, 1));
  fs.renameSync(file + '.tmp', file);
}

let accounts = loadJSON(ACCOUNTS_FILE, {});   // email → {id, kdfSalt, serverSalt, authHash, createdAt}
let tokens = loadJSON(TOKENS_FILE, {});       // token → {accountId, createdAt}

function normalizeEmail(e) { return String(e || '').trim().toLowerCase(); }
function validEmail(e) { return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(e) && e.length <= 200; }

function hashAuthKey(authKeyHex, serverSalt) {
  return crypto.scryptSync(Buffer.from(authKeyHex, 'hex'), Buffer.from(serverSalt, 'hex'), 32).toString('hex');
}

function newToken(accountId) {
  const token = crypto.randomBytes(32).toString('hex');
  tokens[token] = { accountId, createdAt: Date.now() };
  // abgelaufene Tokens gelegentlich ausmisten
  for (const [t, info] of Object.entries(tokens)) {
    if (Date.now() - info.createdAt > TOKEN_TTL_MS) delete tokens[t];
  }
  saveJSON(TOKENS_FILE, tokens);
  return token;
}

function accountForToken(req) {
  const auth = req.headers.authorization || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
  const info = tokens[token];
  if (!info || Date.now() - info.createdAt > TOKEN_TTL_MS) return null;
  return { token, accountId: info.accountId };
}

function emailForAccountId(id) {
  return Object.keys(accounts).find((e) => accounts[e].id === id);
}

// Alle Tokens eines Kontos widerrufen (optional eines behalten, z. B. das aktuelle).
function revokeTokens(accountId, keepToken) {
  let n = 0;
  for (const [t, info] of Object.entries(tokens)) {
    if (info.accountId === accountId && t !== keepToken) { delete tokens[t]; n++; }
  }
  if (n) saveJSON(TOKENS_FILE, tokens);
  return n;
}

// Konto + Blob + alle Tokens restlos entfernen.
function deleteAccount(email) {
  const acct = accounts[email];
  if (!acct) return false;
  revokeTokens(acct.id, null);
  try { fs.unlinkSync(blobFile(acct.id)); } catch { /* kein Blob */ }
  delete accounts[email];
  saveJSON(ACCOUNTS_FILE, accounts);
  return true;
}

// Naives Rate-Limit für Auth-Endpunkte: 20 Versuche / 10 Minuten pro IP.
const attempts = new Map();
function rateLimited(ip) {
  const now = Date.now();
  const list = (attempts.get(ip) || []).filter((t) => now - t < 10 * 60 * 1000);
  list.push(now);
  attempts.set(ip, list);
  return list.length > 20;
}

function blobFile(accountId) { return path.join(BLOBS, accountId + '.json'); }

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > 4 * 1024 * 1024) { reject(new Error('payload too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}); }
      catch (e) { reject(e); }
    });
    req.on('error', reject);
  });
}

function send(res, status, obj) {
  const body = obj === undefined ? '' : JSON.stringify(obj);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  // nginx proxyt /humibeam-sync/… → /…; beide Formen akzeptieren.
  const url = new URL(req.url, 'http://localhost');
  const route = url.pathname.replace(/^\/humibeam-sync/, '') || '/';
  const ip = req.headers['x-forwarded-for'] || req.socket.remoteAddress || '?';

  try {
    if (req.method === 'GET' && route === '/health') return send(res, 200, { ok: true });

    // Betreiber-Statistik — nur Metadaten (E-Mail, Anlagedatum, Sync-Meta). Niemals authHash,
    // serverSalt, Token oder das verschlüsselte Blob selbst. Geschützt per x-admin-token.
    if (req.method === 'GET' && route === '/admin/stats') {
      if (!ADMIN_TOKEN) return send(res, 503, { error: 'Admin-Endpoint nicht konfiguriert' });
      if (!adminAuthorized(req)) return send(res, 401, { error: 'kein gültiges Admin-Token' });
      const now = Date.now();
      let withSync = 0;
      const list = Object.entries(accounts).map(([email, a]) => {
        const blob = loadJSON(blobFile(a.id), null);
        if (blob) withSync++;
        return {
          email,
          id: a.id,
          createdAt: a.createdAt || null,
          sync: blob ? {
            rev: blob.rev,
            updatedAt: blob.updatedAt || null,
            device: blob.device || null,
            bytes: typeof blob.payload === 'string' ? blob.payload.length : 0,
          } : null,
        };
      });
      list.sort((x, y) => String(y.createdAt || '').localeCompare(String(x.createdAt || '')));
      const activeTokens = Object.values(tokens).filter((t) => now - t.createdAt <= TOKEN_TTL_MS).length;
      return send(res, 200, {
        ok: true,
        summary: {
          accounts: list.length,
          withSync,
          activeTokens,
          serverTime: new Date().toISOString(),
        },
        accounts: list,
      });
    }

    // Admin: Konto löschen (Aufräumen/Sperren). ?email=…
    if (req.method === 'DELETE' && route === '/admin/account') {
      if (!ADMIN_TOKEN) return send(res, 503, { error: 'Admin-Endpoint nicht konfiguriert' });
      if (!adminAuthorized(req)) return send(res, 401, { error: 'kein gültiges Admin-Token' });
      const email = normalizeEmail(url.searchParams.get('email'));
      const ok = deleteAccount(email);
      if (ok) console.log(`- Konto gelöscht (admin): ${email}`);
      return send(res, ok ? 200 : 404, ok ? { ok: true } : { error: 'unbekanntes Konto' });
    }

    if (req.method === 'POST' && route === '/register') {
      if (rateLimited(ip)) return send(res, 429, { error: 'zu viele Versuche' });
      const { email: rawEmail, kdfSalt, authKey } = await readBody(req);
      const email = normalizeEmail(rawEmail);
      if (!validEmail(email)) return send(res, 400, { error: 'ungültige E-Mail' });
      if (!/^[0-9a-f]{32}$/.test(kdfSalt || '') || !/^[0-9a-f]{64}$/.test(authKey || ''))
        return send(res, 400, { error: 'ungültige Parameter' });
      if (accounts[email]) return send(res, 409, { error: 'Konto existiert bereits' });
      const serverSalt = crypto.randomBytes(16).toString('hex');
      accounts[email] = {
        id: crypto.randomUUID(),
        kdfSalt,
        serverSalt,
        authHash: hashAuthKey(authKey, serverSalt),
        createdAt: new Date().toISOString(),
      };
      saveJSON(ACCOUNTS_FILE, accounts);
      console.log(`+ Konto registriert: ${email}`);
      return send(res, 200, { token: newToken(accounts[email].id) });
    }

    if (req.method === 'GET' && route === '/salt') {
      if (rateLimited(ip)) return send(res, 429, { error: 'zu viele Versuche' });
      const email = normalizeEmail(url.searchParams.get('email'));
      const acct = accounts[email];
      if (!acct) return send(res, 404, { error: 'unbekanntes Konto' });
      return send(res, 200, { kdfSalt: acct.kdfSalt });
    }

    if (req.method === 'POST' && route === '/login') {
      if (rateLimited(ip)) return send(res, 429, { error: 'zu viele Versuche' });
      const { email: rawEmail, authKey } = await readBody(req);
      const email = normalizeEmail(rawEmail);
      const acct = accounts[email];
      if (!acct || !/^[0-9a-f]{64}$/.test(authKey || '')) return send(res, 401, { error: 'Anmeldung fehlgeschlagen' });
      const expected = Buffer.from(acct.authHash, 'hex');
      const actual = Buffer.from(hashAuthKey(authKey, acct.serverSalt), 'hex');
      if (!crypto.timingSafeEqual(expected, actual)) return send(res, 401, { error: 'Anmeldung fehlgeschlagen' });
      console.log(`→ Anmeldung: ${email}`);
      return send(res, 200, { token: newToken(acct.id) });
    }

    // Passwort ändern: Client weist altes Passwort nach (oldAuthKey), liefert neuen Salt+AuthKey
    // und das mit dem NEUEN encKey neu verschlüsselte Blob. Server bleibt Zero-Knowledge.
    if (req.method === 'POST' && route === '/change-password') {
      if (rateLimited(ip)) return send(res, 429, { error: 'zu viele Versuche' });
      const { email: rawEmail, oldAuthKey, newKdfSalt, newAuthKey, payload, device } = await readBody(req);
      const email = normalizeEmail(rawEmail);
      const acct = accounts[email];
      if (!acct || !/^[0-9a-f]{64}$/.test(oldAuthKey || '')) return send(res, 401, { error: 'Anmeldung fehlgeschlagen' });
      const expected = Buffer.from(acct.authHash, 'hex');
      const actual = Buffer.from(hashAuthKey(oldAuthKey, acct.serverSalt), 'hex');
      if (!crypto.timingSafeEqual(expected, actual)) return send(res, 401, { error: 'altes Passwort falsch' });
      if (!/^[0-9a-f]{32}$/.test(newKdfSalt || '') || !/^[0-9a-f]{64}$/.test(newAuthKey || ''))
        return send(res, 400, { error: 'ungültige Parameter' });
      const serverSalt = crypto.randomBytes(16).toString('hex');
      acct.kdfSalt = newKdfSalt;
      acct.serverSalt = serverSalt;
      acct.authHash = hashAuthKey(newAuthKey, serverSalt);
      saveJSON(ACCOUNTS_FILE, accounts);
      if (typeof payload === 'string' && payload.length && payload.length <= 3 * 1024 * 1024) {
        const file = blobFile(acct.id);
        const current = loadJSON(file, { rev: 0 });
        saveJSON(file, {
          rev: current.rev + 1, payload,
          device: String(device || '').slice(0, 100), updatedAt: new Date().toISOString(),
        });
      }
      revokeTokens(acct.id, null);   // Sicherheit: alle alten Sitzungen beenden
      console.log(`~ Passwort geändert: ${email}`);
      return send(res, 200, { token: newToken(acct.id) });
    }

    // Aktive Sitzungen dieses Kontos auflisten (ohne Token-Werte preiszugeben).
    if (req.method === 'GET' && route === '/sessions') {
      const auth = accountForToken(req);
      if (!auth) return send(res, 401, { error: 'nicht angemeldet' });
      const list = Object.entries(tokens)
        .filter(([, info]) => info.accountId === auth.accountId)
        .map(([t, info]) => ({ id: t.slice(0, 8), createdAt: new Date(info.createdAt).toISOString(), current: t === auth.token }))
        .sort((a, b) => b.createdAt.localeCompare(a.createdAt));
      return send(res, 200, { sessions: list });
    }

    // Überall abmelden: alle anderen Sitzungen widerrufen, aktuelle behalten.
    if (req.method === 'POST' && route === '/logout-all') {
      const auth = accountForToken(req);
      if (!auth) return send(res, 401, { error: 'nicht angemeldet' });
      const n = revokeTokens(auth.accountId, auth.token);
      return send(res, 200, { revoked: n });
    }

    // Eigenes Konto löschen (inkl. Blob + aller Sitzungen).
    if (req.method === 'POST' && route === '/delete') {
      const auth = accountForToken(req);
      if (!auth) return send(res, 401, { error: 'nicht angemeldet' });
      const email = emailForAccountId(auth.accountId);
      if (email) { deleteAccount(email); console.log(`- Konto gelöscht (self): ${email}`); }
      return send(res, 200, { ok: true });
    }

    // Token-Prüfung für andere Humibeam-Dienste (z. B. Support-Signaling: "Supporter muss eingeloggt sein").
    if (req.method === 'GET' && route === '/me') {
      const auth = accountForToken(req);
      if (!auth) return send(res, 401, { error: 'nicht angemeldet' });
      const email = Object.keys(accounts).find((e) => accounts[e].id === auth.accountId);
      return send(res, 200, { accountId: auth.accountId, email });
    }

    if (req.method === 'POST' && route === '/logout') {
      const auth = accountForToken(req);
      if (auth) { delete tokens[auth.token]; saveJSON(TOKENS_FILE, tokens); }
      return send(res, 200, {});
    }

    if (route === '/blob') {
      const auth = accountForToken(req);
      if (!auth) return send(res, 401, { error: 'nicht angemeldet' });
      const file = blobFile(auth.accountId);

      if (req.method === 'GET') {
        const blob = loadJSON(file, null);
        if (!blob) return send(res, 204);
        return send(res, 200, blob);
      }

      if (req.method === 'PUT') {
        const { rev, payload, device } = await readBody(req);
        if (typeof payload !== 'string' || payload.length > 3 * 1024 * 1024)
          return send(res, 400, { error: 'ungültiges Payload' });
        const current = loadJSON(file, { rev: 0 });
        if ((rev || 0) !== current.rev) return send(res, 409, current);
        const next = {
          rev: current.rev + 1,
          payload,
          device: String(device || '').slice(0, 100),
          updatedAt: new Date().toISOString(),
        };
        saveJSON(file, next);
        return send(res, 200, { rev: next.rev });
      }
    }

    send(res, 404, { error: 'unbekannte Route' });
  } catch (e) {
    console.error('Fehler:', e.message);
    if (e instanceof SyntaxError) return send(res, 400, { error: 'ungültiges JSON' });
    send(res, 500, { error: 'Serverfehler' });
  }
});

server.listen(PORT, config.bindHost || '127.0.0.1', () => {
  console.log(`Humibeam Sync läuft auf Port ${PORT} (${Object.keys(accounts).length} Konten)`);
});
