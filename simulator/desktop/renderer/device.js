'use strict';
// Gerätefenster: zeigt den Bildschirm eines Simulators im Gehäuse und gibt Maus, Mausrad und
// Tastatur als Finger und Tastatur ans Gerät weiter.

const params = new URLSearchParams(location.search);
const role = params.get('role') || 'iphone';
const $ = (sel) => document.querySelector(sel);

// Ohne Electron (Test im Browser): Adresse und Schlüssel aus der URL.
const bridge = window.sim || {
  session: async () => ({ url: params.get('url'), token: params.get('token') }),
  api: async (method, path, body) => {
    const res = await fetch(`${params.get('url')}${path}`, {
      method,
      headers: { authorization: `Bearer ${params.get('token')}`, ...(body ? { 'content-type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `Fehler ${res.status}`);
    return data;
  },
  upload: async () => { throw new Error('Nur in der PC-App'); },
  pickFiles: async () => [],
  screenshot: async () => { throw new Error('Nur in der PC-App'); },
  readClipboard: async () => navigator.clipboard.readText(),
  writeClipboard: async (t) => navigator.clipboard.writeText(t),
  saveAppData: async () => null,
  loadAppData: async () => null,
  showFile: async () => {},
  resizeFor: async () => {},
  pin: async () => {},
  minimize: async () => {},
  close: async () => window.close(),
  focusLauncher: async () => {},
  on: () => {},
};

const canvas = $('#canvas');
const ctx = canvas.getContext('2d');
const screenEl = $('#screen');
const deviceEl = $('#device');
const keysEl = $('#keys');

let session = null;
let device = null;     // Beschreibung vom Server (Punkte, Modell, Ausrichtung)
let ws = null;
let pointerId = null;
let connected = false;
let ended = false;
let retries = 0;
let landscape = false;
let appearance = 'light';
let pinned = false;
let rotateView = 0;    // Grad, um die das Bild für die Anzeige gedreht wird
let pinching = false;
const QUALITIES = [['schnell', 'SD'], ['normal', 'HD'], ['scharf', 'HD+']];

// ---------- Anzeige ----------

function overlay(text, { error = false, hide = false } = {}) {
  const el = $('#overlay');
  el.classList.toggle('gone', hide);
  el.classList.toggle('error', error);
  if (text) $('#overlay-text').textContent = text;
}

function toast(msg, level = '') {
  const el = document.createElement('div');
  el.className = `toast ${level}`;
  el.textContent = msg;
  $('#toasts').append(el);
  setTimeout(() => el.remove(), level === 'error' ? 7000 : 3500);
  while ($('#toasts').children.length > 4) $('#toasts').firstChild.remove();
}

function layout() {
  if (!device) return;
  const shape = window.deviceShape(device.model, role);
  const W = device.pointWidth;
  const H = device.pointHeight;
  const bezel = shape.bezel * W;
  let devW = W + 2 * bezel;
  let devH = H + 2 * bezel;
  if (landscape) [devW, devH] = [devH, devW];
  const stage = $('#stage').getBoundingClientRect();
  const s = Math.min((stage.width * 0.96) / devW, (stage.height * 0.96) / devH);
  const innerR = shape.radius * W * s;
  const css = deviceEl.style;
  css.setProperty('--dev-w', `${devW * s}px`);
  css.setProperty('--dev-h', `${devH * s}px`);
  css.setProperty('--bezel', `${bezel * s}px`);
  css.setProperty('--inner-r', `${innerR}px`);
  css.setProperty('--outer-r', `${innerR + bezel * s}px`);
  css.setProperty('--side', `${Math.max(2, 3 * s)}px`);
  deviceEl.classList.toggle('ipad', role === 'ipad');
  deviceEl.classList.toggle('landscape', landscape);

  const cut = $('#cutout');
  if (!shape.cutout) {
    cut.style.display = 'none';
    return;
  }
  const c = shape.cutout;
  const cw = c.width * s;
  const chh = c.height * s;
  const top = c.top * s;
  cut.style.display = '';
  cut.className = `cutout ${c.type}`;
  cut.style.setProperty('--lens', `${chh * 0.32}px`);
  const o = device.orientation;
  if (o === 'landscapeFlipped' || o === 'landscape') {
    cut.classList.add('vertical');
    Object.assign(cut.style, { width: `${chh}px`, height: `${cw}px`, top: `calc(50% - ${cw / 2}px)`, left: '', right: '' });
    if (o === 'landscapeFlipped') cut.style.left = `${top}px`; else cut.style.right = `${top}px`;
    if (c.type === 'notch') cut.style.borderRadius = o === 'landscapeFlipped' ? '0 22px 22px 0' : '22px 0 0 22px';
  } else {
    Object.assign(cut.style, { width: `${cw}px`, height: `${chh}px`, left: `calc(50% - ${cw / 2}px)`, right: '', borderRadius: '' });
    if (o === 'portraitUpsideDown') { cut.style.top = ''; cut.style.bottom = `${top}px`; } else { cut.style.top = `${top}px`; cut.style.bottom = ''; }
  }
}
window.addEventListener('resize', layout);

function displaySize(w, h) {
  return Math.abs(rotateView) === 90 ? { w: h, h: w } : { w, h };
}

function applyMeta(d) {
  const before = landscape;
  device = d;
  document.title = `${d.model} – ${d.runtime}`;
  rotateView = d.rotateView || 0;
  if (d.frame) {
    const size = displaySize(d.frame.w, d.frame.h);
    landscape = size.w > size.h;
    if (canvas.width !== size.w || canvas.height !== size.h) {
      canvas.width = size.w;
      canvas.height = size.h;
      if (lastFrame) drawFrame(lastFrame);
    }
  }
  const q = QUALITIES.find(([k]) => k === d.quality);
  if (q) $('#btn-quality').textContent = q[1];
  if (before !== landscape) bridge.resizeFor(role, landscape);
  layout();
}

// Bilder entpacken, ohne sich zu stauen: nur das neueste wartende Bild wird gezeichnet.
let decoding = false;
let pendingFrame = null;
let lastFrame = null; // zum Neuzeichnen, wenn sich die Zeichenfläche ändert (Drehen)
async function drawFrame(buf) {
  lastFrame = buf;
  if (decoding) { pendingFrame = buf; return; }
  decoding = true;
  try {
    const bmp = await createImageBitmap(new Blob([buf], { type: 'image/jpeg' }));
    const size = displaySize(bmp.width, bmp.height);
    if (canvas.width !== size.w || canvas.height !== size.h) {
      canvas.width = size.w;
      canvas.height = size.h;
      const nowLandscape = size.w > size.h;
      if (nowLandscape !== landscape) {
        landscape = nowLandscape;
        bridge.resizeFor(role, landscape);
        layout();
      }
    }
    if (rotateView) {
      ctx.save();
      ctx.translate(canvas.width / 2, canvas.height / 2);
      ctx.rotate((rotateView * Math.PI) / 180);
      ctx.drawImage(bmp, -bmp.width / 2, -bmp.height / 2);
      ctx.restore();
    } else {
      ctx.drawImage(bmp, 0, 0);
    }
    bmp.close();
    if (!connected) {
      connected = true;
      overlay('', { hide: true });
    }
  } catch { /* kaputtes Bild auslassen */ }
  decoding = false;
  if (pendingFrame) {
    const next = pendingFrame;
    pendingFrame = null;
    drawFrame(next);
  }
}

// ---------- Verbindung ----------

function send(msg) {
  if (ws && ws.readyState === 1) ws.send(JSON.stringify(msg));
}

async function connect() {
  session = await bridge.session();
  if (!session?.url) {
    overlay('Keine Sitzung', { error: true });
    return;
  }
  const wsUrl = `${session.url.replace(/^http/, 'ws')}/ws/${role}?token=${encodeURIComponent(session.token)}`;
  overlay(retries ? 'Verbindung unterbrochen – verbinde neu …' : 'Verbinde mit dem Cloud-Mac …');
  ws = new WebSocket(wsUrl);
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => { retries = 0; };
  ws.onmessage = (ev) => {
    if (typeof ev.data !== 'string') return drawFrame(ev.data);
    const msg = JSON.parse(ev.data);
    if (msg.t === 'meta') applyMeta(msg.device);
    else if (msg.t === 'toast') toast(msg.msg, msg.level);
    else if (msg.t === 'build') toast(msg.line, msg.state === 'failed' ? 'error' : '');
    else if (msg.t === 'log') appendLog(msg.line);
    else if (msg.t === 'pong') $('#latency').textContent = `${Math.round(performance.now() - msg.id)} ms`;
    else if (msg.t === 'bye') endSession(msg.reason);
  };
  ws.onclose = () => {
    connected = false;
    if (ended) return;
    if (retries++ > 12) {
      overlay('Keine Verbindung zum Cloud-Mac. Läuft die Sitzung noch?', { error: true });
      return;
    }
    overlay('Verbindung unterbrochen – verbinde neu …');
    setTimeout(connect, Math.min(8000, 600 * retries));
  };
}

function endSession(reason) {
  ended = true;
  overlay(`Sitzung beendet${reason ? `: ${reason}` : ''}`, { error: true });
  if (ws) ws.close();
}
bridge.on('device:bye', ({ reason }) => endSession(reason));
bridge.on('device:toast', ({ msg }) => toast(msg));

setInterval(() => send({ t: 'ping', id: performance.now() }), 3000);

// ---------- Maus = Finger ----------

function norm(e) {
  const r = canvas.getBoundingClientRect();
  return { x: (e.clientX - r.left) / r.width, y: (e.clientY - r.top) / r.height };
}

screenEl.addEventListener('contextmenu', (e) => e.preventDefault());
screenEl.addEventListener('pointerdown', (e) => {
  keysEl.focus();
  if (pointerId !== null) return;
  const p = norm(e);
  if (e.button === 2) {
    // Rechtsklick = langes Drücken (Kontextmenüs, Symbole verschieben)
    send({ t: 'touch', p: 'down', ...p });
    setTimeout(() => send({ t: 'touch', p: 'up', ...p }), 850);
    return;
  }
  if (e.button !== 0) return;
  pointerId = e.pointerId;
  screenEl.setPointerCapture(e.pointerId);
  screenEl.classList.add('touching');
  // Alt gedrückt: zwei Finger, gespiegelt um die Mitte (Zoomen und Drehen mit zwei Fingern)
  pinching = e.altKey && device?.features?.pinch;
  send({ t: pinching ? 'pinch' : 'touch', p: 'down', ...p });
});
screenEl.addEventListener('pointermove', (e) => {
  if (e.pointerId !== pointerId) return;
  const events = e.getCoalescedEvents ? e.getCoalescedEvents() : [e];
  for (const ev of events.length ? events : [e]) send({ t: pinching ? 'pinch' : 'touch', p: 'move', ...norm(ev) });
});
function release(e) {
  if (e.pointerId !== pointerId) return;
  pointerId = null;
  screenEl.classList.remove('touching');
  send({ t: pinching ? 'pinch' : 'touch', p: 'up', ...norm(e) });
  pinching = false;
}
screenEl.addEventListener('pointerup', release);
screenEl.addEventListener('pointercancel', release);

// Mausrad = mit dem Finger wischen; kurz sammeln, dann eine Wischbewegung senden.
let wheel = null;
let zoomTimer = null;
let zoomAmount = 0;
screenEl.addEventListener('wheel', (e) => {
  e.preventDefault();
  const r = canvas.getBoundingClientRect();
  // Strg+Mausrad (oder Zwei-Finger-Zoom am Touchpad): Zoom-Geste
  if (e.ctrlKey && device?.features?.pinch) {
    zoomAmount += e.deltaY;
    const at = norm(e);
    clearTimeout(zoomTimer);
    zoomTimer = setTimeout(() => {
      const scale = Math.max(0.4, Math.min(2.5, Math.exp(-zoomAmount / 300)));
      zoomAmount = 0;
      send({ t: 'zoom', ...at, scale });
    }, 120);
    return;
  }
  if (!wheel) {
    wheel = { ...norm(e), dx: 0, dy: 0 };
    setTimeout(() => {
      const w = wheel;
      wheel = null;
      const clamp = (v) => Math.max(-0.45, Math.min(0.45, v));
      send({ t: 'wheel', x: w.x, y: w.y, dx: clamp(w.dx), dy: clamp(w.dy) });
    }, 70);
  }
  const unit = e.deltaMode === 1 ? 32 : 1;
  wheel.dx += (e.deltaX * unit * 1.3) / r.width;
  wheel.dy += (e.deltaY * unit * 1.3) / r.height;
}, { passive: false });

// ---------- Tastatur ----------

const SPECIAL = new Set(['Enter', 'Backspace', 'Tab', 'Escape', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Delete', 'Home', 'End', 'PageUp', 'PageDown']);

keysEl.addEventListener('input', (e) => {
  if (e.isComposing) return;
  const text = keysEl.value;
  keysEl.value = '';
  if (text) send({ t: 'text', s: text });
});
keysEl.addEventListener('compositionend', () => {
  const text = keysEl.value;
  keysEl.value = '';
  if (text) send({ t: 'text', s: text });
});

window.addEventListener('keydown', async (e) => {
  if (e.isComposing || e.target.tagName === 'INPUT') return;
  const altGr = e.getModifierState && e.getModifierState('AltGraph');
  const ctrl = (e.ctrlKey || e.metaKey) && !altGr;
  if (ctrl) {
    const k = e.key.toLowerCase();
    const handled = {
      h: () => act(e.shiftKey ? 'app-switcher' : 'home'),
      l: () => act('lock'),
      s: () => act('screenshot'),
      arrowleft: () => act('rotate-left'),
      arrowright: () => act('rotate-right'),
      v: () => act('paste', { thenPaste: !e.shiftKey }),
      c: () => copyFromDevice(),
    }[k];
    e.preventDefault();
    if (handled) return handled();
    if (k.length === 1 || SPECIAL.has(e.key)) send({ t: 'key', k: e.key.length === 1 ? k : e.key, mods: { ctrl: true, shift: e.shiftKey, alt: e.altKey } });
    return;
  }
  if (SPECIAL.has(e.key)) {
    e.preventDefault();
    send({ t: 'key', k: e.key, mods: { shift: e.shiftKey, alt: e.altKey } });
  }
});
window.addEventListener('focus', () => keysEl.focus());
document.addEventListener('pointerup', () => {
  if (document.activeElement?.tagName !== 'INPUT') keysEl.focus();
});

async function copyFromDevice() {
  send({ t: 'key', k: 'c', mods: { ctrl: true } });
  setTimeout(async () => {
    try {
      const { text } = await bridge.api('GET', `/api/dev/${role}/clipboard`);
      if (text) await bridge.writeClipboard(text);
    } catch { /* nichts kopiert */ }
  }, 450);
}

// ---------- Werkzeugleiste ----------

function menu(anchor, items) {
  const el = $('#menu');
  el.innerHTML = '';
  for (const item of items) {
    if (item.input) {
      const input = document.createElement('input');
      input.placeholder = item.input;
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') { closeMenu(); item.run(input.value); }
        if (e.key === 'Escape') closeMenu();
      });
      el.append(input);
      setTimeout(() => input.focus(), 0);
      continue;
    }
    const b = document.createElement('button');
    b.textContent = item.label;
    b.addEventListener('click', () => { closeMenu(); item.run(); });
    el.append(b);
  }
  const r = anchor.getBoundingClientRect();
  el.classList.remove('hidden');
  el.style.top = `${Math.max(8, Math.min(window.innerHeight - el.offsetHeight - 8, r.top - 6))}px`;
}
function closeMenu() { $('#menu').classList.add('hidden'); keysEl.focus(); }
document.addEventListener('pointerdown', (e) => {
  if (!e.target.closest('#menu') && !e.target.closest('.toolbar')) closeMenu();
});

const post = (path, body) => bridge.api('POST', path, body);
const tryRun = async (fn, okMsg) => {
  try {
    const res = await fn();
    if (okMsg) toast(typeof okMsg === 'function' ? okMsg(res) : okMsg);
  } catch (err) {
    toast(err.message, 'error');
  }
};

async function act(name, opts = {}, anchor) {
  switch (name) {
    case 'home':
    case 'lock':
    case 'siri':
    case 'shake':
    case 'app-switcher':
      return send({ t: 'button', b: name });
    case 'rotate-left':
    case 'rotate-right':
      return tryRun(() => post(`/api/dev/${role}/rotate`, { dir: name === 'rotate-left' ? 'left' : 'right' }));
    case 'appearance':
      appearance = appearance === 'dark' ? 'light' : 'dark';
      return tryRun(() => post(`/api/dev/${role}/appearance`, { mode: appearance }), appearance === 'dark' ? 'Dunkelmodus an' : 'Hellmodus an');
    case 'screenshot':
      return tryRun(async () => {
        const file = await bridge.screenshot(role);
        toast('Bildschirmfoto gespeichert');
        bridge.showFile(file);
      });
    case 'photos': {
      const files = await bridge.pickFiles({
        title: 'Fotos oder Videos zum Gerät hinzufügen',
        filters: [{ name: 'Fotos & Videos', extensions: ['jpg', 'jpeg', 'png', 'heic', 'gif', 'webp', 'mov', 'mp4', 'm4v'] }, { name: 'Kontakte', extensions: ['vcf'] }],
        properties: ['openFile', 'multiSelections'],
      });
      for (let i = 0; i < files.length; i++) {
        toast(`Lade ${i + 1} von ${files.length} hoch …`);
        await tryRun(() => bridge.upload(`/api/dev/${role}/media`, files[i]));
      }
      if (files.length) toast('In der Fotos-App sichtbar');
      return;
    }
    case 'paste':
      return tryRun(async () => {
        const text = await bridge.readClipboard();
        if (!text) return;
        await post(`/api/dev/${role}/clipboard`, { text });
        if (opts.thenPaste) send({ t: 'key', k: 'v', mods: { ctrl: true } });
        else toast('Zwischenablage übertragen – im Gerät »Einsetzen« wählen');
      });
    case 'copy':
      return tryRun(async () => {
        const { text } = await bridge.api('GET', `/api/dev/${role}/clipboard`);
        await bridge.writeClipboard(text || '');
        toast(text ? 'Auf den PC kopiert' : 'Zwischenablage des Geräts ist leer');
      });
    case 'url':
      return menu(anchor, [{ input: 'https://… oder App-Link', run: (v) => v && tryRun(() => post(`/api/dev/${role}/openurl`, { url: /^\w+:/.test(v) ? v : `https://${v}` })) }]);
    case 'rebuild':
      return tryRun(() => post('/api/rebuild', {}), 'Baue die App neu – dauert meist 1–2 Minuten');
    case 'appdata':
      return menu(anchor, [
        { label: 'App-Daten auf dem PC sichern …', run: () => tryRun(() => bridge.saveAppData(role), (f) => (f ? 'Gesichert' : '')) },
        { label: 'App-Daten vom PC einspielen …', run: () => tryRun(() => bridge.loadAppData(role), (r) => (r ? 'Eingespielt, App startet neu' : '')) },
      ]);
    case 'logs': {
      const panel = $('#logs');
      const on = panel.classList.toggle('hidden') === false;
      send({ t: 'logs', on });
      return;
    }
    case 'quality':
      return menu(anchor, QUALITIES.map(([key, label]) => ({
        label: `${label} – ${{ schnell: 'flüssig, wenig Daten', normal: 'ausgewogen', scharf: 'scharf, mehr Daten' }[key]}`,
        run: () => send({ t: 'quality', q: key }),
      })));
    case 'pin':
      pinned = !pinned;
      anchor?.classList.toggle('on', pinned);
      return bridge.pin(pinned);
    case 'launcher':
      return bridge.focusLauncher();
    case 'minimize':
      return bridge.minimize();
    case 'close':
      return bridge.close();
    default:
      return undefined;
  }
}

function appendLog(line) {
  const pre = $('#log-lines');
  pre.textContent += `${line}\n`;
  if (pre.textContent.length > 200_000) pre.textContent = pre.textContent.slice(-150_000);
  pre.scrollTop = pre.scrollHeight;
}

document.querySelectorAll('[data-act]').forEach((b) => b.addEventListener('click', (e) => act(b.dataset.act, {}, e.currentTarget)));
document.querySelectorAll('[data-button]').forEach((b) => b.addEventListener('click', () => send({ t: 'button', b: b.dataset.button })));

// ---------- Start ----------

(async () => {
  try {
    const s = await bridge.session();
    const d = s?.info?.devices?.find((x) => x.role === role);
    if (d) applyMeta(d);
  } catch { /* Meta kommt auch über die Verbindung */ }
  keysEl.focus();
  connect();
})();
