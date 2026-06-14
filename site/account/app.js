// Humibeam-Konto — Anmelden/Registrieren gegen das Zero-Knowledge-Sync-Backend (/humibeam-sync)
// und ein kleines Konto-Dashboard (Sync-Status, Geräte, Konto-Infos).
import { deriveKeys, decryptBlob, randomSaltHex } from './crypto.js';

const SYNC = '/humibeam-sync';
const $ = (id) => document.getElementById(id);

let token = null;     // Bearer-Token (kann über Reload in localStorage liegen)
let encKey = null;    // AES-Schlüssel — NUR im Speicher, nie persistiert

// ---------- Tabs: Anmelden / Registrieren ----------
let mode = 'login';
function setMode(m) {
  mode = m;
  const reg = m === 'register';
  $('tabLogin').classList.toggle('active', !reg);
  $('tabRegister').classList.toggle('active', reg);
  $('submit').textContent = reg ? 'Konto anlegen' : 'Anmelden';
  $('pwHint').hidden = !reg;
  $('password').autocomplete = reg ? 'new-password' : 'current-password';
  status('');
}
$('tabLogin').addEventListener('click', () => setMode('login'));
$('tabRegister').addEventListener('click', () => setMode('register'));

function status(msg, kind = '') { const e = $('status'); e.textContent = msg; e.className = 'status ' + kind; }
function busy(on) { $('submit').disabled = on; }

// ---------- Anmelden / Registrieren ----------
$('authForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const email = $('email').value.trim().toLowerCase();
  const password = $('password').value;
  busy(true);
  try {
    if (mode === 'register') {
      if (password.length < 8) throw new Error('Passwort braucht mindestens 8 Zeichen');
      status('Lege Konto an…');
      const kdfSalt = randomSaltHex();
      const keys = await deriveKeys(password, kdfSalt);
      const res = await fetch(`${SYNC}/register`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, kdfSalt, authKey: keys.authKeyHex }),
      });
      if (res.status === 409) throw new Error('Konto existiert schon — bitte anmelden');
      if (!res.ok) throw new Error('Registrierung fehlgeschlagen');
      token = (await res.json()).token;
      encKey = keys.encKey;
    } else {
      status('Melde an…');
      const saltRes = await fetch(`${SYNC}/salt?email=${encodeURIComponent(email)}`);
      if (!saltRes.ok) throw new Error('Konto nicht gefunden');
      const { kdfSalt } = await saltRes.json();
      const keys = await deriveKeys(password, kdfSalt);
      const loginRes = await fetch(`${SYNC}/login`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, authKey: keys.authKeyHex }),
      });
      if (!loginRes.ok) throw new Error('Anmeldung fehlgeschlagen — E-Mail oder Passwort falsch');
      token = (await loginRes.json()).token;
      encKey = keys.encKey;
    }
    try { localStorage.setItem('humibeam_token', token); } catch {}
    await openDashboard();
  } catch (err) {
    status(err.message, 'err');
  } finally { busy(false); }
});

// ---------- Dashboard ----------
async function openDashboard() {
  // Konto-Identität prüfen
  const meRes = await fetch(`${SYNC}/me`, { headers: { authorization: 'Bearer ' + token } });
  if (!meRes.ok) { logout(); return; }
  const me = await meRes.json();

  $('auth').style.display = 'none';
  $('dash').classList.add('on');
  $('whoEmail').textContent = me.email || '—';
  $('kvEmail').textContent = me.email || '—';
  $('kvId').textContent = me.accountId || '—';

  await loadSync();
}

async function loadSync() {
  try {
    const res = await fetch(`${SYNC}/blob`, { headers: { authorization: 'Bearer ' + token } });
    if (res.status === 204) {
      $('stSync').textContent = 'Noch nichts';
      $('stRev').textContent = '0';
      $('stUpdated').textContent = '–';
      $('syncSummary').textContent = 'Noch keine Daten synchronisiert. Sobald du dich in der Mac-App oder im iPhone-Companion mit diesem Konto anmeldest, erscheinen deine Profile, Snippets und Einstellungen hier.';
      return;
    }
    if (!res.ok) throw new Error('Sync-Daten nicht abrufbar');
    const blob = await res.json();
    $('stSync').textContent = 'Aktiv';
    $('stRev').textContent = String(blob.rev ?? '–');
    $('stUpdated').textContent = blob.updatedAt ? fmtDate(blob.updatedAt) : '–';
    $('kvDevice').textContent = blob.device || '–';

    if (!encKey) {
      $('syncSummary').textContent = 'Deine Daten sind verschlüsselt gespeichert. Für die Detail-Anzahlen bitte erneut anmelden (der Entschlüsselungs-Schlüssel bleibt nur während der Sitzung im Speicher).';
      return;
    }
    if (typeof blob.payload === 'string' && blob.payload.length) {
      try {
        const json = await decryptBlob(blob.payload, encKey);
        renderCounts(JSON.parse(json));
      } catch {
        $('syncSummary').textContent = 'Verschlüsselte Daten vorhanden, konnten in dieser Sitzung aber nicht entschlüsselt werden.';
      }
    } else {
      $('syncSummary').textContent = 'Konto angelegt, aber noch keine Inhalte synchronisiert.';
    }
  } catch (err) {
    $('stSync').textContent = 'Fehler';
    $('syncSummary').textContent = err.message;
  }
}

// Zeigt nur Anzahlen, keine Klartext-Inhalte.
function renderCounts(data) {
  const labels = { hosts: 'Profile', snippets: 'Snippets', bookmarks: 'Lesezeichen' };
  const chips = $('syncChips');
  chips.innerHTML = '';
  let any = false;
  for (const [key, val] of Object.entries(data || {})) {
    if (Array.isArray(val)) {
      any = true;
      const name = labels[key] || key;
      const chip = document.createElement('span');
      chip.className = 'chip';
      chip.textContent = `${val.length} ${name}`;
      chips.appendChild(chip);
    }
  }
  // Darstellung (Theme/Schrift) als zusätzlicher Hinweis, falls vorhanden.
  const theme = data.themeID || data.theme || data.selectedThemeID;
  if (theme) {
    const chip = document.createElement('span');
    chip.className = 'chip';
    chip.textContent = `Theme: ${theme}`;
    chips.appendChild(chip);
    any = true;
  }
  $('syncSummary').textContent = any
    ? 'Diese Inhalte sind über alle deine Geräte synchronisiert:'
    : 'Konto verbunden — bisher keine zählbaren Inhalte im Sync.';
}

function fmtDate(iso) {
  try { return new Date(iso).toLocaleString('de-DE', { dateStyle: 'medium', timeStyle: 'short' }); }
  catch { return iso; }
}

// ---------- Abmelden ----------
function logout() {
  if (token) {
    fetch(`${SYNC}/logout`, { method: 'POST', headers: { authorization: 'Bearer ' + token } }).catch(() => {});
  }
  token = null; encKey = null;
  try { localStorage.removeItem('humibeam_token'); } catch {}
  $('dash').classList.remove('on');
  $('auth').style.display = '';
  $('password').value = '';
  status('Abgemeldet.', 'ok');
}
$('logout').addEventListener('click', logout);

// ---------- Beim Laden: bestehende Sitzung fortsetzen? ----------
(async function init() {
  setMode('login');
  let saved; try { saved = localStorage.getItem('humibeam_token'); } catch {}
  if (saved) {
    token = saved;            // encKey fehlt nach Reload → Meta sichtbar, Detail-Anzahlen nach Re-Login
    await openDashboard();
  }
})();
