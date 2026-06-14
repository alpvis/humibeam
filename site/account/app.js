// Humibeam-Konto — Anmelden/Registrieren + Dashboard (Sync, Passwort ändern, Sitzungen, Backup, Löschen)
// gegen das Zero-Knowledge-Sync-Backend (/humibeam-sync).
import { deriveKeys, encryptBlob, decryptBlob, randomSaltHex } from './crypto.js';

const SYNC = '/humibeam-sync';
const $ = (id) => document.getElementById(id);

let token = null;        // Bearer-Token (kann über Reload in localStorage liegen)
let encKey = null;       // AES-Schlüssel — NUR im Speicher
let currentEmail = null;
let currentPlain = null; // entschlüsselter Blob-JSON-String (für Backup + Re-Encrypt)
let currentDevice = 'Web';

const auth = (extra = {}) => ({ authorization: 'Bearer ' + token, ...extra });

// ---------- Passwort-Stärke ----------
function strength(pw) {
  if (!pw) return { score: 0, label: '', color: 'var(--line)' };
  let s = 0;
  if (pw.length >= 8) s++;
  if (pw.length >= 12) s++;
  if (/[a-z]/.test(pw) && /[A-Z]/.test(pw)) s++;
  if (/\d/.test(pw)) s++;
  if (/[^A-Za-z0-9]/.test(pw)) s++;
  s = Math.min(4, s);
  const labels = ['sehr schwach', 'schwach', 'okay', 'gut', 'stark'];
  const colors = ['#ff6b6b', '#fbbf24', '#fbbf24', '#34d399', '#34d399'];
  return { score: s, label: labels[s], color: colors[s] };
}
function wireMeter(input, bar, lbl) {
  input.addEventListener('input', () => {
    const r = strength(input.value);
    bar.style.width = (r.score / 4 * 100) + '%';
    bar.style.background = r.color;
    lbl.textContent = input.value ? 'Stärke: ' + r.label : '';
  });
}

// ---------- Tabs ----------
let mode = 'login';
function setMode(m) {
  mode = m;
  const reg = m === 'register';
  $('tabLogin').classList.toggle('active', !reg);
  $('tabRegister').classList.toggle('active', reg);
  $('submit').textContent = reg ? 'Konto anlegen' : 'Anmelden';
  $('pwHint').hidden = !reg;
  $('meterWrap').hidden = !reg;
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
      token = (await res.json()).token; encKey = keys.encKey;
    } else {
      status('Melde an…');
      const keys = await deriveForEmail(email, password);
      const loginRes = await fetch(`${SYNC}/login`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, authKey: keys.authKeyHex }),
      });
      if (!loginRes.ok) throw new Error('Anmeldung fehlgeschlagen — E-Mail oder Passwort falsch');
      token = (await loginRes.json()).token; encKey = keys.encKey;
    }
    currentEmail = email;
    try { localStorage.setItem('humibeam_token', token); localStorage.setItem('humibeam_email', email); } catch {}
    await openDashboard();
  } catch (err) { status(err.message, 'err'); }
  finally { busy(false); }
});

async function deriveForEmail(email, password) {
  const saltRes = await fetch(`${SYNC}/salt?email=${encodeURIComponent(email)}`);
  if (!saltRes.ok) throw new Error('Konto nicht gefunden');
  const { kdfSalt } = await saltRes.json();
  return deriveKeys(password, kdfSalt);
}

// ---------- Dashboard ----------
async function openDashboard() {
  const meRes = await fetch(`${SYNC}/me`, { headers: auth() });
  if (!meRes.ok) { logout(); return; }
  const me = await meRes.json();
  currentEmail = me.email || currentEmail;
  $('auth').style.display = 'none';
  $('dash').classList.add('on');
  $('whoEmail').textContent = me.email || '—';
  $('kvEmail').textContent = me.email || '—';
  $('kvId').textContent = me.accountId || '—';
  await Promise.all([loadSync(), loadSessions()]);
}

async function loadSync() {
  try {
    const res = await fetch(`${SYNC}/blob`, { headers: auth() });
    if (res.status === 204) {
      $('stSync').textContent = 'Noch nichts'; $('stRev').textContent = '0'; $('stUpdated').textContent = '–';
      $('syncSummary').textContent = 'Noch keine Daten synchronisiert. Melde dich in der Mac-App oder im iPhone-Companion mit diesem Konto an — dann erscheinen deine Profile, Snippets und Einstellungen hier.';
      currentPlain = null; return;
    }
    if (!res.ok) throw new Error('Sync-Daten nicht abrufbar');
    const blob = await res.json();
    $('stSync').textContent = 'Aktiv';
    $('stRev').textContent = String(blob.rev ?? '–');
    $('stUpdated').textContent = blob.updatedAt ? fmtDate(blob.updatedAt) : '–';
    $('kvDevice').textContent = blob.device || '–';
    currentDevice = blob.device || 'Web';
    if (!encKey) {
      $('syncSummary').textContent = 'Daten sind verschlüsselt gespeichert. Für Detail-Anzahlen, Backup und Passwortwechsel bitte erneut anmelden (der Schlüssel bleibt nur während der Sitzung im Speicher).';
      return;
    }
    if (typeof blob.payload === 'string' && blob.payload.length) {
      try { currentPlain = await decryptBlob(blob.payload, encKey); renderCounts(JSON.parse(currentPlain)); }
      catch { currentPlain = null; $('syncSummary').textContent = 'Verschlüsselte Daten vorhanden, konnten in dieser Sitzung aber nicht entschlüsselt werden.'; }
    } else { currentPlain = null; $('syncSummary').textContent = 'Konto angelegt, aber noch keine Inhalte synchronisiert.'; }
  } catch (err) { $('stSync').textContent = 'Fehler'; $('syncSummary').textContent = err.message; }
}

function renderCounts(data) {
  const labels = { hosts: 'Profile', snippets: 'Snippets', bookmarks: 'Lesezeichen' };
  const chips = $('syncChips'); chips.innerHTML = ''; let any = false;
  for (const [key, val] of Object.entries(data || {})) {
    if (Array.isArray(val)) { any = true; addChip(chips, `${val.length} ${labels[key] || key}`); }
  }
  const theme = data.themeID || data.theme || data.selectedThemeID;
  if (theme) { addChip(chips, `Theme: ${theme}`); any = true; }
  $('syncSummary').textContent = any ? 'Diese Inhalte sind über alle deine Geräte synchronisiert:' : 'Konto verbunden — bisher keine zählbaren Inhalte im Sync.';
}
function addChip(parent, text) { const c = document.createElement('span'); c.className = 'chip'; c.textContent = text; parent.appendChild(c); }

// ---------- Aktive Sitzungen ----------
async function loadSessions() {
  try {
    const res = await fetch(`${SYNC}/sessions`, { headers: auth() });
    if (!res.ok) throw new Error('Sitzungen nicht abrufbar');
    const { sessions } = await res.json();
    const box = $('sessions'); box.innerHTML = '';
    if (!sessions.length) { box.innerHTML = '<p class="note">Keine aktiven Sitzungen.</p>'; return; }
    for (const s of sessions) {
      const row = document.createElement('div');
      row.className = 'sess';
      row.innerHTML = `<span>Sitzung <span style="font-family:ui-monospace,monospace">${esc(s.id)}…</span> · seit ${fmtDate(s.createdAt)}</span>` +
        (s.current ? '<span class="badge">diese</span>' : '');
      box.appendChild(row);
    }
  } catch (err) { $('sessions').innerHTML = `<p class="note">${esc(err.message)}</p>`; }
}
$('logoutAll').addEventListener('click', async () => {
  if (!confirm('Alle anderen Sitzungen abmelden?')) return;
  try {
    const res = await fetch(`${SYNC}/logout-all`, { method: 'POST', headers: auth() });
    const { revoked } = await res.json();
    await loadSessions();
    alert(revoked + ' Sitzung(en) abgemeldet.');
  } catch (err) { alert(err.message); }
});

// ---------- Backup ----------
$('exportBtn').addEventListener('click', () => {
  if (!currentPlain) { alert('Keine entschlüsselten Daten verfügbar. Bitte erneut anmelden (Backup braucht den Sitzungs-Schlüssel).'); return; }
  let pretty = currentPlain;
  try { pretty = JSON.stringify(JSON.parse(currentPlain), null, 2); } catch {}
  const blob = new Blob([pretty], { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `humibeam-backup-${(currentEmail || 'konto').replace(/[^a-z0-9]+/gi, '_')}.json`;
  a.click();
  URL.revokeObjectURL(a.href);
});

// ---------- Passwort ändern ----------
wireMeter($('password'), $('meterBar'), $('meterLbl'));
wireMeter($('newPw'), $('newMeterBar'), $('newMeterLbl'));
function pwStatus(msg, kind = '') { const e = $('pwStatus'); e.textContent = msg; e.className = 'status ' + kind; }
$('pwForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const oldPw = $('oldPw').value, newPw = $('newPw').value, newPw2 = $('newPw2').value;
  if (newPw.length < 8) return pwStatus('Neues Passwort braucht mindestens 8 Zeichen', 'err');
  if (newPw !== newPw2) return pwStatus('Die neuen Passwörter stimmen nicht überein', 'err');
  $('pwSubmit').disabled = true;
  try {
    pwStatus('Prüfe & verschlüssle neu…');
    const oldKeys = await deriveForEmail(currentEmail, oldPw);
    const newKdfSalt = randomSaltHex();
    const newKeys = await deriveKeys(newPw, newKdfSalt);
    // Blob mit neuem Schlüssel neu verschlüsseln (falls vorhanden).
    let payload;
    if (currentPlain) payload = await encryptBlob(currentPlain, newKeys.encKey);
    const res = await fetch(`${SYNC}/change-password`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: currentEmail, oldAuthKey: oldKeys.authKeyHex, newKdfSalt, newAuthKey: newKeys.authKeyHex, payload, device: currentDevice }),
    });
    if (res.status === 401) throw new Error('Aktuelles Passwort falsch');
    if (!res.ok) throw new Error('Passwort ändern fehlgeschlagen');
    token = (await res.json()).token; encKey = newKeys.encKey;
    try { localStorage.setItem('humibeam_token', token); } catch {}
    $('pwForm').reset();
    pwStatus('Passwort geändert. Andere Sitzungen wurden abgemeldet.', 'ok');
    await loadSessions();
  } catch (err) { pwStatus(err.message, 'err'); }
  finally { $('pwSubmit').disabled = false; }
});

// ---------- Konto löschen ----------
$('deleteBtn').addEventListener('click', async () => {
  if (!confirm('Konto wirklich UNWIDERRUFLICH löschen? Alle Sync-Daten gehen verloren.')) return;
  const typed = prompt('Zur Bestätigung "LÖSCHEN" eingeben:');
  if (typed !== 'LÖSCHEN') { $('deleteStatus').textContent = 'Abgebrochen.'; return; }
  try {
    const res = await fetch(`${SYNC}/delete`, { method: 'POST', headers: auth() });
    if (!res.ok) throw new Error('Löschen fehlgeschlagen');
    alert('Konto gelöscht.');
    logout();
  } catch (err) { $('deleteStatus').textContent = err.message; $('deleteStatus').className = 'status err'; }
});

// ---------- Abmelden ----------
function logout() {
  if (token) fetch(`${SYNC}/logout`, { method: 'POST', headers: auth() }).catch(() => {});
  token = null; encKey = null; currentPlain = null;
  try { localStorage.removeItem('humibeam_token'); } catch {}
  $('dash').classList.remove('on');
  $('auth').style.display = '';
  $('password').value = '';
  status('Abgemeldet.', 'ok');
}
$('logout').addEventListener('click', logout);

function fmtDate(iso) {
  try { return new Date(iso).toLocaleString('de-DE', { dateStyle: 'medium', timeStyle: 'short' }); } catch { return iso; }
}
function esc(s) { return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }

// ---------- Init ----------
(async function init() {
  setMode('login');
  let saved, savedEmail; try { saved = localStorage.getItem('humibeam_token'); savedEmail = localStorage.getItem('humibeam_email'); } catch {}
  if (saved) { token = saved; currentEmail = savedEmail; await openDashboard(); }
})();
