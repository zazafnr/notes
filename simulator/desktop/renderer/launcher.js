'use strict';
// Startfenster: Einrichtung, Geräte- und Profilauswahl, Fortschritt der Sitzung.

const $ = (sel) => document.querySelector(sel);
// `sim` ist die Brücke aus preload.js (window.sim).
let cfg = null;
let branches = [];
let timerHandle = null;
let editingProfile = null;

const show = (id, on = true) => $(id).classList.toggle('hidden', !on);
function message(el, text, kind = '') {
  el.textContent = text || '';
  el.className = `msg ${kind}`;
}
function fmtTime(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = String(s % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${sec}` : `${m}:${sec}`;
}

document.addEventListener('click', (e) => {
  const link = e.target.closest('[data-link]');
  if (link) {
    e.preventDefault();
    sim.openExternal(link.dataset.link);
  }
});

// ---------- Auswahlfelder ----------

function fillModels() {
  const ios = $('#ios').value;
  for (const role of ['iphone', 'ipad']) {
    const sel = $(`#${role}-model`);
    const current = cfg[`${role}Model`] || 'auto';
    sel.innerHTML = '';
    sel.append(new Option(role === 'iphone' ? 'Automatisch (neuestes Pro)' : 'Automatisch (neuestes iPad Pro 13″)', 'auto'));
    for (const m of window.MODELS[ios][role]) sel.append(new Option(m, m));
    sel.value = [...sel.options].some((o) => o.value === current) ? current : 'auto';
  }
}

function fillProfiles() {
  for (const role of ['iphone', 'ipad']) {
    const sel = $(`#${role}-profile`);
    sel.innerHTML = '';
    sel.append(new Option('Leer – Werkszustand mit Apple-Apps', 'leer'));
    for (const p of cfg.profiles.filter((x) => x.kind === role)) sel.append(new Option(p.name, p.id));
    sel.value = [...sel.options].some((o) => o.value === cfg[`${role}Profile`]) ? cfg[`${role}Profile`] : 'leer';
  }
  const list = $('#profile-list');
  list.innerHTML = '';
  if (!cfg.profiles.length) {
    const empty = document.createElement('div');
    empty.className = 'profile empty';
    empty.textContent = 'Noch kein Profil. Lege z. B. »Mein iPhone« mit deinen Fotos an.';
    list.append(empty);
  }
  for (const p of cfg.profiles) {
    const el = document.createElement('div');
    el.className = 'profile';
    const title = document.createElement('b');
    title.textContent = p.name;
    const sub = document.createElement('span');
    sub.className = 'muted small';
    const bits = [p.model && p.model !== 'auto' ? p.model : (p.kind === 'ipad' ? 'iPad' : 'iPhone'), p.appearance === 'dark' ? 'Dunkel' : 'Hell'];
    if (p.photosDir) bits.push('Fotos');
    if (p.contacts) bits.push('Kontakte');
    if (p.keepAppData) bits.push('App-Daten');
    sub.textContent = bits.join(' · ');
    el.append(title, sub);
    el.addEventListener('click', () => openProfile(p));
    list.append(el);
  }
}

function fillBranches() {
  const sel = $('#app-ref');
  sel.innerHTML = '';
  sel.append(new Option('Keine eigene App – leerer Simulator (nur Apple-Apps)', ''));
  for (const b of branches) sel.append(new Option(b, b));
  const wanted = cfg.appRef ?? '';
  if (wanted && !branches.includes(wanted)) sel.append(new Option(wanted, wanted));
  sel.value = wanted;
}

function updateUsage() {
  const used = cfg.usage[cfg.monthKey] || 0;
  const limit = cfg.monthlyLimit || 200;
  const pct = Math.min(100, (used / limit) * 100);
  const fill = $('#usage-fill');
  fill.style.width = `${pct}%`;
  fill.className = pct >= 100 ? 'over' : pct > 75 ? 'warn' : '';
  $('#usage-text').textContent = `Mac-Minuten diesen Monat (geschätzt): ${Math.round(used)} von ${limit}`;
}

function collectStart() {
  const iphone = $('#use-iphone').checked;
  const ipad = $('#use-ipad').checked;
  return {
    devices: iphone && ipad ? 'beide' : iphone ? 'iphone' : 'ipad',
    ios: $('#ios').value,
    iphoneModel: $('#iphone-model').value,
    ipadModel: $('#ipad-model').value,
    iphoneProfile: $('#iphone-profile').value,
    ipadProfile: $('#ipad-profile').value,
    appRef: $('#app-ref').value,
    minutes: Number($('#minutes').value),
  };
}

// ---------- Ansichten ----------

function showMain() {
  show('#setup', !cfg.hasToken);
  show('#start', cfg.hasToken);
  show('#profiles', cfg.hasToken);
  show('#progress', false);
  show('#running', false);
}

function showProgress() {
  show('#start', false);
  show('#progress', true);
  show('#running', false);
  $('#progress-title').textContent = 'Starte die Sitzung …';
  $('#progress-text').textContent = 'Starte den GitHub-Lauf …';
  $('#progress-steps').innerHTML = '';
  show('#progress-run', false);
  const started = Date.now();
  clearInterval(timerHandle);
  timerHandle = setInterval(() => { $('#progress-timer').textContent = fmtTime(Date.now() - started); }, 1000);
}

function renderSteps(steps) {
  if (!steps?.length) return;
  const ul = $('#progress-steps');
  ul.innerHTML = '';
  const hidden = /^(Set up job|Run actions|Post |Complete job|Start melden|Selbsttest|Ende melden|Sitzung läuft)/;
  for (const s of steps) {
    if (hidden.test(s.name)) continue;
    const li = document.createElement('li');
    li.textContent = s.name;
    li.className = s.status === 'completed' ? (s.conclusion || 'success') : s.status;
    ul.append(li);
  }
}

async function showRunning() {
  const s = await sim.session();
  show('#start', false);
  show('#progress', false);
  show('#running', true);
  clearInterval(timerHandle);
  const info = s.info || {};
  const devs = info.devices || [];
  $('#running-text').textContent = `${devs.map((d) => `${d.model} (${d.runtime})`).join(' und ')}${info.app ? ` · App: ${info.app.name}` : ' · ohne eigene App'}`;
  const box = $('#running-devices');
  box.innerHTML = '';
  for (const d of devs) {
    const b = document.createElement('button');
    b.textContent = d.role === 'iphone' ? 'iPhone-Fenster zeigen' : 'iPad-Fenster zeigen';
    b.addEventListener('click', () => sim.showDevices());
    box.append(b);
  }
  $('#btn-rebuild').disabled = !s.info?.app && !cfg.appRef;
  $('#running-run').onclick = (e) => { e.preventDefault(); if (s.runUrl) sim.openExternal(s.runUrl); };
  const deadline = info.deadline;
  timerHandle = setInterval(() => {
    $('#running-timer').textContent = deadline ? `noch ${fmtTime(deadline - Date.now())}` : '';
  }, 1000);
}

// ---------- Ereignisse aus dem Hauptprozess ----------

sim.on('session:progress', (p) => {
  if (p.phase === 'stopping') {
    $('#running-text').textContent = p.text;
    return;
  }
  if (!$('#progress').classList.contains('hidden')) {
    $('#progress-text').textContent = p.text;
    $('#progress-title').textContent = p.phase === 'queued' ? 'Warte auf einen Mac' : 'Cloud-Mac richtet sich ein';
    renderSteps(p.steps);
    if (p.runUrl) {
      show('#progress-run', true);
      $('#progress-run').onclick = (e) => { e.preventDefault(); sim.openExternal(p.runUrl); };
    }
  }
});
sim.on('session:ready', () => showRunning());
sim.on('session:failed', async ({ text, runUrl }) => {
  clearInterval(timerHandle);
  cfg = await sim.getConfig();
  showMain();
  message($('#start-msg'), text, 'error');
  if (runUrl) {
    const a = document.createElement('a');
    a.href = '#';
    a.textContent = ' Lauf ansehen';
    a.onclick = (e) => { e.preventDefault(); sim.openExternal(runUrl); };
    $('#start-msg').append(a);
  }
  updateUsage();
});
sim.on('session:ended', async ({ text, minutes }) => {
  clearInterval(timerHandle);
  cfg = await sim.getConfig();
  showMain();
  message($('#start-msg'), `${text || 'Sitzung beendet'} (${Math.round(minutes)} Min.)`, 'ok');
  updateUsage();
});

// ---------- Buttons ----------

$('#btn-token').addEventListener('click', async () => {
  const msg = $('#setup-msg');
  message(msg, 'Prüfe …');
  try {
    const res = await sim.setToken($('#token').value, $('#repo').value);
    cfg = res.config;
    message(msg, `Verbunden mit ${res.repo.name}`, 'ok');
    await init();
  } catch (err) {
    message(msg, err.message, 'error');
  }
});

$('#ios').addEventListener('change', fillModels);

$('#btn-start').addEventListener('click', async () => {
  const opts = collectStart();
  if (!$('#use-iphone').checked && !$('#use-ipad').checked) {
    message($('#start-msg'), 'Bitte mindestens ein Gerät wählen.', 'error');
    return;
  }
  const used = cfg.usage[cfg.monthKey] || 0;
  if (used + opts.minutes > (cfg.monthlyLimit || 200) * 1.5
    && !confirm('Die geschätzten Mac-Minuten für diesen Monat sind fast aufgebraucht. Trotzdem starten?')) return;
  message($('#start-msg'), '');
  $('#btn-start').disabled = true;
  showProgress();
  try {
    await sim.start(opts);
    cfg = await sim.getConfig();
  } catch (err) {
    clearInterval(timerHandle);
    showMain();
    message($('#start-msg'), err.message, 'error');
  } finally {
    $('#btn-start').disabled = false;
  }
});

$('#btn-cancel').addEventListener('click', () => sim.stop());
$('#btn-stop').addEventListener('click', () => {
  $('#btn-stop').disabled = true;
  sim.stop().finally(() => { $('#btn-stop').disabled = false; });
});

$('#btn-rebuild').addEventListener('click', async () => {
  const log = $('#build-log');
  show('#build-log', true);
  log.textContent = 'Baue die App neu …\n';
  try {
    const s = await sim.session();
    await sim.api('POST', '/api/rebuild', { ref: cfg.appRef || s.info?.ref || undefined });
    const poll = setInterval(async () => {
      const res = await sim.api('GET', '/api/build-log').catch(() => null);
      if (!res) return;
      log.textContent = res.lines.filter((l) => /error:|warning:|==>|BUILD/.test(l)).join('\n') || 'Baue …';
      log.scrollTop = log.scrollHeight;
      if (res.state !== 'running') {
        clearInterval(poll);
        log.textContent += res.state === 'ok' ? '\n✓ Fertig – App wird auf den Geräten neu gestartet.' : '\n✕ Build fehlgeschlagen.';
      }
    }, 2500);
  } catch (err) {
    log.textContent += err.message;
  }
});

$('#btn-install').addEventListener('click', async () => {
  const files = await sim.pickFiles({
    title: 'Simulator-Build installieren (.zip mit .app)',
    filters: [{ name: 'Simulator-App', extensions: ['zip'] }],
    properties: ['openFile'],
  });
  if (!files.length) return;
  $('#running-text').textContent = 'Lade die App hoch …';
  try {
    const res = await sim.upload('/api/install', files[0]);
    $('#running-text').textContent = `${res.app.name} installiert`;
  } catch (err) {
    $('#running-text').textContent = err.message;
  }
});

// ---------- Profile ----------

function fillProfileModels(kind, value) {
  const sel = $('#profile-form').elements.model;
  sel.innerHTML = '';
  sel.append(new Option('Automatisch', 'auto'));
  const all = new Set([...window.MODELS['27'][kind], ...window.MODELS['26'][kind]]);
  for (const m of all) sel.append(new Option(m, m));
  sel.value = [...sel.options].some((o) => o.value === value) ? value : 'auto';
}

async function updatePhotoCount(dir) {
  $('#photos-count').textContent = dir ? 'Zähle …' : '';
  if (!dir) return;
  const n = await sim.countMedia(dir).catch(() => 0);
  $('#photos-count').textContent = `${n} Fotos/Videos gefunden`;
}

function openProfile(p) {
  editingProfile = p || null;
  const f = $('#profile-form');
  const data = p || { kind: 'iphone', appearance: 'light', language: 'de-DE', locale: 'de_DE', keepAppData: true, maxPhotos: 300 };
  $('#profile-dialog-title').textContent = p ? 'Profil bearbeiten' : 'Neues Profil';
  f.elements.name.value = data.name || '';
  f.elements.kind.value = data.kind;
  fillProfileModels(data.kind, data.model);
  f.elements.appearance.value = data.appearance || 'light';
  f.elements.lang.value = `${data.language || 'de-DE'}|${data.locale || 'de_DE'}`;
  f.elements.photosDir.value = data.photosDir || '';
  f.elements.contacts.value = data.contacts || '';
  f.elements.location.value = data.location ? `${data.location.lat},${data.location.lon}` : '';
  f.elements.maxPhotos.value = data.maxPhotos || 300;
  f.elements.keepAppData.checked = !!data.keepAppData;
  f.elements.cleanStatusBar.checked = !!data.cleanStatusBar;
  show('#profile-delete', !!p);
  updatePhotoCount(data.photosDir);
  $('#profile-dialog').showModal();
}

$('#btn-new-profile').addEventListener('click', () => openProfile(null));
$('#profile-form').elements.kind.addEventListener('change', (e) => fillProfileModels(e.target.value, 'auto'));
$('#pick-photos').addEventListener('click', async () => {
  const dir = await sim.pickFolder();
  if (dir) {
    $('#profile-form').elements.photosDir.value = dir;
    updatePhotoCount(dir);
  }
});
$('#pick-contacts').addEventListener('click', async () => {
  const files = await sim.pickFiles({ filters: [{ name: 'Kontakte', extensions: ['vcf'] }], properties: ['openFile'] });
  if (files[0]) $('#profile-form').elements.contacts.value = files[0];
});
$('#profile-cancel').addEventListener('click', () => $('#profile-dialog').close());
$('#profile-delete').addEventListener('click', async () => {
  if (!editingProfile || !confirm(`Profil »${editingProfile.name}« löschen?`)) return;
  cfg = await sim.deleteProfile(editingProfile.id);
  $('#profile-dialog').close();
  fillProfiles();
});
$('#profile-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target.elements;
  const [language, locale] = f.lang.value.split('|');
  const [lat, lon] = f.location.value ? f.location.value.split(',').map(Number) : [];
  const profile = {
    id: editingProfile?.id || `p${Date.now().toString(36)}`,
    name: f.name.value.trim() || 'Profil',
    kind: f.kind.value,
    model: f.model.value,
    appearance: f.appearance.value,
    language,
    locale,
    photosDir: f.photosDir.value || '',
    contacts: f.contacts.value || '',
    location: f.location.value ? { lat, lon } : null,
    maxPhotos: Number(f.maxPhotos.value) || 300,
    keepAppData: f.keepAppData.checked,
    cleanStatusBar: f.cleanStatusBar.checked,
  };
  cfg = await sim.saveProfile(profile);
  if (!editingProfile) {
    cfg = await sim.setConfig({ [`${profile.kind}Profile`]: profile.id });
  }
  $('#profile-dialog').close();
  fillProfiles();
});

// ---------- Einstellungen ----------

$('#btn-settings').addEventListener('click', () => {
  $('#set-repo').value = cfg.repo;
  $('#set-token').value = '';
  $('#set-toolref').value = cfg.toolRef || '';
  $('#set-limit').value = cfg.monthlyLimit || 200;
  message($('#settings-msg'), '');
  $('#settings-dialog').showModal();
});
$('#settings-cancel').addEventListener('click', () => $('#settings-dialog').close());
$('#settings-save').addEventListener('click', async () => {
  const msg = $('#settings-msg');
  try {
    if ($('#set-token').value.trim() || $('#set-repo').value.trim() !== cfg.repo) {
      if ($('#set-token').value.trim()) {
        const res = await sim.setToken($('#set-token').value, $('#set-repo').value);
        cfg = res.config;
      } else {
        cfg = await sim.setConfig({ repo: $('#set-repo').value.trim() });
      }
    }
    cfg = await sim.setConfig({ toolRef: $('#set-toolref').value.trim(), monthlyLimit: Number($('#set-limit').value) || 200 });
    $('#settings-dialog').close();
    await init();
  } catch (err) {
    message(msg, err.message, 'error');
  }
});

// ---------- Start ----------

async function init() {
  cfg = await sim.getConfig();
  $('#ios').value = String(cfg.ios || '27');
  $('#minutes').value = String(cfg.minutes || 60);
  $('#use-iphone').checked = cfg.devices !== 'ipad';
  $('#use-ipad').checked = cfg.devices !== 'iphone';
  $('#setup-repo').textContent = cfg.repo;
  $('#repo').value = cfg.repo;
  fillModels();
  fillProfiles();
  updateUsage();
  showMain();
  if (cfg.hasToken) {
    fillBranches();
    try {
      branches = await sim.branches();
      fillBranches();
    } catch (err) {
      message($('#start-msg'), err.message, 'error');
    }
    const s = await sim.session();
    if (s && !s.ended && s.url) showRunning();
    else if (s && !s.ended) showProgress();
  }
}

init();
