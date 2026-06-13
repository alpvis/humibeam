// Humibeam Remote-Support — Supporter-Seite (Browser).
// Login (Zero-Knowledge) → ID+Code → WebRTC: Mac-Bildschirm empfangen, Maus/Tastatur senden.
import { deriveKeys, randomSaltHex } from './crypto.js';

const SYNC = '/humibeam-sync';
const WS_URL = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/humibeam-support/ws';
// ICE: öffentlicher STUN + eigenes TURN (coturn auf humibeam.com). Wird vom Server-Endpoint gefüllt.
let ICE = [{ urls: 'stun:stun.l.google.com:19302' }];

const $ = (id) => document.getElementById(id);
const show = (id) => { for (const s of ['login', 'connect', 'session']) $(s).hidden = (s !== id); };
function status(msg, kind = '') { const e = $('status'); e.textContent = msg; e.className = 'status ' + kind; }

let token = null, ws = null, pc = null, channel = null, sessionId = null;

// ---- 1) Login bzw. Registrieren gegen das Humibeam-Konto (gleiche Konten wie die App) ----
let mode = 'login';
function setMode(m) {
  mode = m;
  const reg = m === 'register';
  $('tabLogin').classList.toggle('active', !reg);
  $('tabRegister').classList.toggle('active', reg);
  $('authSubmit').textContent = reg ? 'Konto anlegen' : 'Anmelden';
  $('pwHint').hidden = !reg;
  $('password').autocomplete = reg ? 'new-password' : 'current-password';
  status('');
}
$('tabLogin').addEventListener('click', () => setMode('login'));
$('tabRegister').addEventListener('click', () => setMode('register'));

$('loginForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const email = $('email').value.trim().toLowerCase();
  const password = $('password').value;
  try {
    if (mode === 'register') {
      if (password.length < 8) throw new Error('Passwort braucht mindestens 8 Zeichen');
      status('Lege Konto an…');
      const kdfSalt = randomSaltHex();
      const { authKeyHex } = await deriveKeys(password, kdfSalt);
      const res = await fetch(`${SYNC}/register`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, kdfSalt, authKey: authKeyHex }),
      });
      if (res.status === 409) throw new Error('Konto existiert schon — bitte anmelden');
      if (!res.ok) throw new Error('Registrierung fehlgeschlagen');
      token = (await res.json()).token;
    } else {
      status('Melde an…');
      const saltRes = await fetch(`${SYNC}/salt?email=${encodeURIComponent(email)}`);
      if (!saltRes.ok) throw new Error('Konto nicht gefunden');
      const { kdfSalt } = await saltRes.json();
      const { authKeyHex } = await deriveKeys(password, kdfSalt);
      const loginRes = await fetch(`${SYNC}/login`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, authKey: authKeyHex }),
      });
      if (!loginRes.ok) throw new Error('Anmeldung fehlgeschlagen');
      token = (await loginRes.json()).token;
    }
    await loadIceConfig();
    show('connect');
    status('Angemeldet als ' + email, 'ok');
  } catch (err) { status(err.message, 'err'); }
});

async function loadIceConfig() {
  try {
    const res = await fetch('/humibeam-support/ice', { headers: { authorization: 'Bearer ' + token } });
    if (res.ok) { const cfg = await res.json(); if (Array.isArray(cfg.iceServers)) ICE = cfg.iceServers; }
  } catch { /* STUN-only-Fallback */ }
}

// ---- 2) Verbinden: ID + Code an den Signaling-Server ----
$('connectForm').addEventListener('submit', (e) => {
  e.preventDefault();
  openSignaling(() => {
    ws.send(JSON.stringify({ type: 'auth', token }));
  });
});

function openSignaling(onOpen) {
  ws = new WebSocket(WS_URL);
  ws.onopen = onOpen;
  ws.onerror = () => status('Signaling-Verbindung fehlgeschlagen', 'err');
  ws.onclose = () => { if ($('session').hidden === false) teardown('Verbindung getrennt'); };
  ws.onmessage = async (ev) => {
    const m = JSON.parse(ev.data);
    switch (m.type) {
      case 'authed':
        ws.send(JSON.stringify({ type: 'connect',
          deviceId: $('deviceId').value.trim(), code: $('code').value.trim() }));
        status('Warte auf Bestätigung des Kunden…');
        break;
      case 'auth-error': status('Nicht eingeloggt — bitte neu anmelden', 'err'); break;
      case 'connect-pending': sessionId = m.sessionId; status('Warte auf Bestätigung des Kunden…'); break;
      case 'connect-error': status('Verbindung abgelehnt: ' + reason(m.reason), 'err'); break;
      case 'session-start': await startWebRTC(); break;
      case 'signal': await onSignal(m.data); break;
      case 'session-end': teardown('Sitzung beendet: ' + reason(m.reason)); break;
    }
  };
}

function reason(r) {
  return ({ 'geraet-offline': 'Gerät ist offline', 'geraet-belegt': 'Gerät ist gerade belegt',
    'code-ungueltig': 'Code ungültig oder abgelaufen', 'vom-kunden-abgelehnt': 'vom Kunden abgelehnt',
    'keine-bestaetigung': 'keine Bestätigung', 'kunde-getrennt': 'Kunde hat getrennt' }[r] || r);
}

// ---- 3) WebRTC: Supporter ist der Offerer; empfängt Video, sendet Eingaben per Daten-Kanal ----
async function startWebRTC() {
  show('session');
  status('Stelle Verbindung her…');
  overlay('Warte auf den Bildschirm des Kunden…', 'Verbindung wird aufgebaut');
  $('connState').textContent = 'verbinde…';
  pc = new RTCPeerConnection({ iceServers: ICE });
  pc.addTransceiver('video', { direction: 'recvonly' });
  channel = pc.createDataChannel('input', { ordered: true });
  channel.onopen = () => status('Verbunden — du steuerst den Mac', 'ok');

  let gotVideo = false;
  pc.ontrack = (ev) => {
    gotVideo = true;
    $('screen').srcObject = ev.streams[0];
    $('videoOverlay').hidden = true;
  };
  pc.onicecandidate = (ev) => {
    if (ev.candidate) ws.send(JSON.stringify({ type: 'signal', sessionId, data: { candidate: ev.candidate } }));
  };
  pc.oniceconnectionstatechange = () => {
    $('connState').textContent = 'ICE: ' + pc.iceConnectionState;
    if (pc.iceConnectionState === 'failed') {
      overlay('Verbindung fehlgeschlagen',
        'Kein Netzwerkpfad (NAT/Firewall). TURN-Relay sollte greifen — prüfe die Internetverbindung.');
    }
  };
  pc.onconnectionstatechange = () => {
    if (['failed', 'disconnected', 'closed'].includes(pc.connectionState)) teardown('Verbindung verloren');
  };

  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  ws.send(JSON.stringify({ type: 'signal', sessionId, data: { sdp: pc.localDescription } }));

  // Diagnose: wenn nach 8 s kein Video-Track ankam, dem Supporter sagen, wo es vermutlich klemmt.
  setTimeout(() => {
    if (!gotVideo) {
      overlay('Kein Video empfangen',
        'Häufigste Ursache: Bildschirmaufnahme am Mac nicht erlaubt — der Kunde muss sie in den ' +
        'Systemeinstellungen erteilen UND die App „Humibeam Support" danach neu starten. ' +
        '(ICE-Status unten zeigt, ob die Verbindung steht.)');
    }
  }, 8000);
}

function overlay(title, hint) {
  $('videoOverlay').hidden = false;
  $('overlayTitle').textContent = title;
  $('overlayHint').textContent = hint;
}

async function onSignal(data) {
  if (!pc) return;
  if (data.sdp) await pc.setRemoteDescription(data.sdp);
  else if (data.candidate) { try { await pc.addIceCandidate(data.candidate); } catch {} }
}

// ---- 4) Eingaben erfassen → BeamInput (gleiche Struktur wie HumibeamMac BeamInput) ----
function sendInput(obj) { if (channel && channel.readyState === 'open') channel.send(JSON.stringify(obj)); }
function norm(e) {
  const r = $('screen').getBoundingClientRect();
  return { x: Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)),
           y: Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)) };
}

function wireInput() {
  const v = $('screen');
  let dragging = false;
  v.addEventListener('mousemove', (e) => {
    const p = norm(e); sendInput({ kind: dragging ? 'dragMove' : 'move', ...p });
  });
  v.addEventListener('mousedown', (e) => {
    e.preventDefault(); dragging = true; sendInput({ kind: 'dragStart', ...norm(e) });
  });
  v.addEventListener('mouseup', (e) => {
    const p = norm(e);
    if (dragging) { dragging = false; sendInput({ kind: 'dragEnd', ...p }); }
    if (e.button === 2) sendInput({ kind: 'rightClick', ...p });
  });
  v.addEventListener('click', (e) => sendInput({ kind: 'click', ...norm(e) }));
  v.addEventListener('dblclick', (e) => sendInput({ kind: 'doubleClick', ...norm(e) }));
  v.addEventListener('contextmenu', (e) => e.preventDefault());
  v.addEventListener('wheel', (e) => {
    e.preventDefault(); sendInput({ kind: 'scroll', dx: -e.deltaX, dy: -e.deltaY });
  }, { passive: false });

  const KEYMAP = { Enter: 'return', Backspace: 'backspace', Escape: 'esc', Tab: 'tab',
    ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right', ' ': 'space' };
  window.addEventListener('keydown', (e) => {
    if ($('session').hidden) return;
    const mapped = KEYMAP[e.key];
    if (mapped || e.metaKey || e.ctrlKey || e.altKey) {
      e.preventDefault();
      sendInput({ kind: 'key', keyName: mapped || e.key.toLowerCase(),
        command: e.metaKey, option: e.altKey, controlKey: e.ctrlKey, shift: e.shiftKey });
    } else if (e.key.length === 1) {
      e.preventDefault(); sendInput({ kind: 'text', text: e.key });
    }
  });
}

$('hangup').addEventListener('click', () => {
  if (ws && sessionId) ws.send(JSON.stringify({ type: 'hangup', sessionId }));
  teardown('Verbindung beendet');
});

function teardown(msg) {
  if (pc) { pc.close(); pc = null; }
  if (channel) channel = null;
  $('screen').srcObject = null;
  sessionId = null;
  show('connect');
  status(msg);
}

wireInput();
show('login');
