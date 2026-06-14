// Humibeam Betreiber-Admin — ruft /humibeam-sync/admin/stats mit dem Admin-Token ab
// und zeigt eine reine Metadaten-Übersicht (kein Klartext, keine Geheimnisse).
const SYNC = '/humibeam-sync';
const $ = (id) => document.getElementById(id);

let adminToken = null;
let lastData = null;

function gateStatus(msg, kind = '') { const e = $('gateStatus'); e.textContent = msg; e.className = 'status ' + kind; }

async function fetchStats() {
  const res = await fetch(`${SYNC}/admin/stats`, { headers: { 'x-admin-token': adminToken } });
  if (res.status === 401) throw new Error('Admin-Token ungültig');
  if (res.status === 503) throw new Error('Admin-Endpoint am Server nicht konfiguriert (adminToken fehlt)');
  if (!res.ok) throw new Error('Fehler ' + res.status);
  return res.json();
}

$('gateForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  adminToken = $('adminToken').value.trim();
  gateStatus('Prüfe…');
  try {
    lastData = await fetchStats();
    try { sessionStorage.setItem('humibeam_admin', adminToken); } catch {}
    $('gate').style.display = 'none';
    $('dash').classList.add('on');
    render(lastData);
  } catch (err) { gateStatus(err.message, 'err'); }
});

$('refresh').addEventListener('click', async () => {
  try { lastData = await fetchStats(); render(lastData); }
  catch (err) { alert(err.message); }
});

$('lock').addEventListener('click', () => {
  adminToken = null; lastData = null;
  try { sessionStorage.removeItem('humibeam_admin'); } catch {}
  $('dash').classList.remove('on');
  $('gate').style.display = '';
  $('adminToken').value = '';
  gateStatus('Gesperrt.', 'ok');
});

$('filter').addEventListener('input', () => { if (lastData) renderRows(lastData.accounts); });

function render(data) {
  const s = data.summary || {};
  $('cAccounts').textContent = s.accounts ?? '–';
  $('cSync').textContent = s.withSync ?? '–';
  $('cTokens').textContent = s.activeTokens ?? '–';
  $('cTime').textContent = s.serverTime ? fmt(s.serverTime) : '–';
  renderRows(data.accounts || []);
}

function renderRows(accounts) {
  const q = $('filter').value.trim().toLowerCase();
  const list = q ? accounts.filter((a) => (a.email || '').toLowerCase().includes(q)) : accounts;
  const rows = $('rows');
  rows.innerHTML = '';
  for (const a of list) {
    const tr = document.createElement('tr');
    const sync = a.sync;
    tr.innerHTML =
      `<td>${esc(a.email)}</td>` +
      `<td>${a.createdAt ? fmt(a.createdAt) : '–'}</td>` +
      `<td class="${sync ? 'dot-on' : 'dot-off'}">${sync ? '● aktiv' : '○ keine'}</td>` +
      `<td>${sync ? sync.rev : '–'}</td>` +
      `<td>${sync && sync.device ? esc(sync.device) : '–'}</td>` +
      `<td>${sync ? kb(sync.bytes) : '–'}</td>` +
      `<td>${sync && sync.updatedAt ? fmt(sync.updatedAt) : '–'}</td>` +
      `<td class="mono">${esc(a.id || '')}</td>`;
    rows.appendChild(tr);
  }
  $('rowInfo').textContent = `${list.length} von ${accounts.length} Konten`;
}

function fmt(iso) {
  try { return new Date(iso).toLocaleString('de-DE', { dateStyle: 'short', timeStyle: 'short' }); }
  catch { return iso; }
}
function kb(bytes) { return bytes ? (bytes < 1024 ? bytes + ' B' : (bytes / 1024).toFixed(1) + ' KB') : '0'; }
function esc(s) { return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }

// Bestehende Sitzung fortsetzen (nur sessionStorage → endet mit dem Tab).
(async function init() {
  let saved; try { saved = sessionStorage.getItem('humibeam_admin'); } catch {}
  if (saved) {
    adminToken = saved;
    try {
      lastData = await fetchStats();
      $('gate').style.display = 'none';
      $('dash').classList.add('on');
      render(lastData);
    } catch { adminToken = null; }
  }
})();
