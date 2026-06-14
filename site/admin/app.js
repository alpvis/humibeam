// Humibeam Betreiber-Admin — Statistik, Wachstums-Chart, CSV-Export, Konto löschen, Auto-Refresh.
const SYNC = '/humibeam-sync';
const $ = (id) => document.getElementById(id);

let adminToken = null;
let lastData = null;
let autoTimer = null;

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

$('refresh').addEventListener('click', refresh);
async function refresh() {
  try { lastData = await fetchStats(); render(lastData); }
  catch (err) { alert(err.message); }
}

$('lock').addEventListener('click', () => {
  adminToken = null; lastData = null; setAuto(false);
  try { sessionStorage.removeItem('humibeam_admin'); } catch {}
  $('dash').classList.remove('on');
  $('gate').style.display = '';
  $('adminToken').value = '';
  gateStatus('Gesperrt.', 'ok');
});

$('autoRefresh').addEventListener('change', (e) => setAuto(e.target.checked));
function setAuto(on) {
  if (autoTimer) { clearInterval(autoTimer); autoTimer = null; }
  if (on) autoTimer = setInterval(refresh, 30000);
  $('autoRefresh').checked = on;
}

$('filter').addEventListener('input', () => { if (lastData) renderRows(lastData.accounts); });

$('csv').addEventListener('click', () => {
  if (!lastData) return;
  const head = ['email', 'createdAt', 'sync', 'rev', 'device', 'bytes', 'updatedAt', 'id'];
  const lines = [head.join(',')];
  for (const a of lastData.accounts) {
    const s = a.sync;
    lines.push([a.email, a.createdAt || '', s ? 'yes' : 'no', s ? s.rev : '', s && s.device ? s.device : '',
      s ? s.bytes : '', s && s.updatedAt ? s.updatedAt : '', a.id || ''].map(csvCell).join(','));
  }
  const blob = new Blob([lines.join('\n')], { type: 'text/csv' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob); a.download = 'humibeam-konten.csv'; a.click();
  URL.revokeObjectURL(a.href);
});
function csvCell(v) { v = String(v); return /[",\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v; }

function render(data) {
  const s = data.summary || {};
  $('cAccounts').textContent = s.accounts ?? '–';
  $('cSync').textContent = s.withSync ?? '–';
  $('cTokens').textContent = s.activeTokens ?? '–';
  $('cTime').textContent = s.serverTime ? fmt(s.serverTime) : '–';
  renderChart(data.accounts || [], s.serverTime);
  renderRows(data.accounts || []);
}

// Balken: neue Konten pro Tag, letzte 14 Tage.
function renderChart(accounts, serverTimeIso) {
  const days = 14;
  const end = serverTimeIso ? new Date(serverTimeIso) : new Date();
  const buckets = [];
  for (let i = days - 1; i >= 0; i--) {
    const d = new Date(end); d.setDate(d.getDate() - i);
    buckets.push({ key: d.toISOString().slice(0, 10), label: ('0' + d.getDate()).slice(-2) + '.' + ('0' + (d.getMonth() + 1)).slice(-2), n: 0 });
  }
  const idx = {}; buckets.forEach((b, i) => idx[b.key] = i);
  for (const a of accounts) {
    if (!a.createdAt) continue;
    const k = String(a.createdAt).slice(0, 10);
    if (k in idx) buckets[idx[k]].n++;
  }
  const max = Math.max(1, ...buckets.map((b) => b.n));
  const box = $('bars'); box.innerHTML = '';
  for (const b of buckets) {
    const col = document.createElement('div'); col.className = 'col';
    col.innerHTML = `<span class="num">${b.n || ''}</span>` +
      `<div class="bar" style="height:${(b.n / max * 100).toFixed(1)}%"></div>` +
      `<span class="lbl">${b.label}</span>`;
    box.appendChild(col);
  }
}

function renderRows(accounts) {
  const q = $('filter').value.trim().toLowerCase();
  const list = q ? accounts.filter((a) => (a.email || '').toLowerCase().includes(q)) : accounts;
  const rows = $('rows'); rows.innerHTML = '';
  for (const a of list) {
    const tr = document.createElement('tr');
    const s = a.sync;
    tr.innerHTML =
      `<td>${esc(a.email)}</td>` +
      `<td>${a.createdAt ? fmt(a.createdAt) : '–'}</td>` +
      `<td class="${s ? 'dot-on' : 'dot-off'}">${s ? '● aktiv' : '○ keine'}</td>` +
      `<td>${s ? s.rev : '–'}</td>` +
      `<td>${s && s.device ? esc(s.device) : '–'}</td>` +
      `<td>${s ? kb(s.bytes) : '–'}</td>` +
      `<td>${s && s.updatedAt ? fmt(s.updatedAt) : '–'}</td>` +
      `<td class="mono">${esc(a.id || '')}</td>` +
      `<td><button class="btn del xs" data-email="${esc(a.email)}">Löschen</button></td>`;
    rows.appendChild(tr);
  }
  rows.querySelectorAll('button.del').forEach((b) => b.addEventListener('click', () => deleteAccount(b.getAttribute('data-email'))));
  $('rowInfo').textContent = `${list.length} von ${accounts.length} Konten`;
}

async function deleteAccount(email) {
  if (!confirm(`Konto "${email}" wirklich löschen? Unwiderruflich.`)) return;
  try {
    const res = await fetch(`${SYNC}/admin/account?email=${encodeURIComponent(email)}`, {
      method: 'DELETE', headers: { 'x-admin-token': adminToken },
    });
    if (!res.ok) throw new Error('Löschen fehlgeschlagen (' + res.status + ')');
    await refresh();
  } catch (err) { alert(err.message); }
}

function fmt(iso) { try { return new Date(iso).toLocaleString('de-DE', { dateStyle: 'short', timeStyle: 'short' }); } catch { return iso; } }
function kb(bytes) { return bytes ? (bytes < 1024 ? bytes + ' B' : (bytes / 1024).toFixed(1) + ' KB') : '0'; }
function esc(s) { return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }

(async function init() {
  let saved; try { saved = sessionStorage.getItem('humibeam_admin'); } catch {}
  if (saved) {
    adminToken = saved;
    try { lastData = await fetchStats(); $('gate').style.display = 'none'; $('dash').classList.add('on'); render(lastData); }
    catch { adminToken = null; }
  }
})();
