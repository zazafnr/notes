'use strict';
// Steuer-Server auf dem Cloud-Mac: liefert die Bildschirme der Simulatoren an die PC-App und nimmt
// Touch, Tastatur und Befehle entgegen. Läuft hinter einem Cloudflare-Tunnel; jede Anfrage braucht
// den Zugangsschlüssel, dessen SHA-256 die PC-App beim Start der Sitzung mitgegeben hat.

const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { WebSocketServer } = require('ws');
const { Device } = require('./device');
const { run } = require('./util');

const CONFIG_PATH = process.env.SIM_CONFIG || '/tmp/sim/session.json';
const PORT = Number(process.env.PORT || 8787);
const AXE = process.env.AXE_BIN || 'axe';
const IDLE_LIMIT_MS = Number(process.env.IDLE_MINUTES || 15) * 60_000;

const config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
const startedAt = Date.now();
const logLines = [];
function log(msg) {
  const line = `${new Date().toISOString().slice(11, 19)} ${msg}`;
  logLines.push(line);
  if (logLines.length > 500) logLines.shift();
  console.log(line);
}

const devices = new Map(config.devices.map((d) => [d.role, new Device(d, { axe: AXE, log })]));
let app = config.app || null; // { path, bundle, name }
let build = { state: config.buildState || (app ? 'ok' : 'none'), lines: [] };
let lastActivity = Date.now();

try {
  build.lines = fs.readFileSync(path.join(config.simDir, 'build.log'), 'utf8').split('\n').slice(-400);
} catch { /* noch kein Build */ }

// ---------- Hilfen ----------

// Der Zugang hängt am Schlüssel, nicht an der Herkunft; so kann die Oberfläche auch im Browser laufen.
const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, content-type',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
};

function authorized(req, url) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : url.searchParams.get('token') || '';
  if (!token || !config.authHash) return false;
  const hash = crypto.createHash('sha256').update(token).digest();
  const expected = Buffer.from(config.authHash, 'hex');
  return expected.length === hash.length && crypto.timingSafeEqual(hash, expected);
}

function send(res, status, body, type = 'application/json') {
  const data = type === 'application/json' ? JSON.stringify(body) : body;
  res.writeHead(status, { 'content-type': type, 'cache-control': 'no-store', ...CORS });
  res.end(data);
}

async function readJson(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 1_000_000) throw Object.assign(new Error('Anfrage zu groß'), { status: 413 });
    chunks.push(chunk);
  }
  const text = Buffer.concat(chunks).toString('utf8');
  return text ? JSON.parse(text) : {};
}

// Hochgeladene Datei direkt auf die Platte schreiben (Fotos, Apps, Sicherungen können groß sein).
function saveUpload(req, name) {
  const safe = path.basename(name || 'upload.bin').replace(/[^\w.\- ]+/g, '_') || 'upload.bin';
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'upload-'));
  const file = path.join(dir, safe);
  return new Promise((resolve, reject) => {
    const out = fs.createWriteStream(file);
    req.pipe(out);
    out.on('finish', () => resolve({ file, dir }));
    out.on('error', reject);
    req.on('error', reject);
  });
}

function targets(role) {
  if (!role || role === 'alle') return [...devices.values()];
  const dev = devices.get(role);
  if (!dev) throw Object.assign(new Error(`Kein Gerät »${role}«`), { status: 404 });
  return [dev];
}

function broadcastAll(obj) {
  for (const dev of devices.values()) dev.broadcast(obj);
}

function info() {
  return {
    session: config.session,
    devices: [...devices.values()].map((d) => d.describe()),
    app,
    build: { state: build.state },
    ref: config.ref,
    xcode: config.xcode,
    startedAt,
    deadline: config.deadline,
  };
}

async function findApp(dir) {
  const res = await run('find', [dir, '-maxdepth', '4', '-name', '*.app', '-type', 'd'], { allowFail: true });
  const appPath = res.stdout.split('\n').map((s) => s.trim()).find(Boolean);
  if (!appPath) throw Object.assign(new Error('Keine .app im Upload gefunden (Simulator-Build als ZIP nötig)'), { status: 400 });
  const plist = path.join(appPath, 'Info.plist');
  const bundle = (await run('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleIdentifier', plist])).stdout.trim();
  const name = (await run('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleName', plist], { allowFail: true })).stdout.trim();
  return { path: appPath, bundle, name: name || path.basename(appPath, '.app') };
}

async function installEverywhere(newApp, devs = [...devices.values()]) {
  for (const dev of devs) {
    try {
      await dev.install(newApp.path);
      await dev.launch(newApp.bundle);
      dev.broadcast({ t: 'toast', msg: `${newApp.name} installiert und gestartet` });
    } catch (err) {
      dev.broadcast({ t: 'toast', level: 'error', msg: `Installieren ging nicht: ${err.message}` });
    }
  }
}

// App aus dem Repo neu bauen (z. B. nach einem Push mit Änderungen) und überall installieren.
function rebuild(ref) {
  if (build.state === 'running') throw Object.assign(new Error('Es wird schon gebaut'), { status: 409 });
  if (!config.buildScript || !config.appDir) throw Object.assign(new Error('Diese Sitzung hat kein App-Repo'), { status: 400 });
  build = { state: 'running', lines: [] };
  broadcastAll({ t: 'build', state: 'running', line: `Baue ${ref || config.ref} neu …` });
  const env = { ...process.env, APP_DIR: config.appDir, SIM_DIR: config.simDir, APP_REF: ref || config.ref || '', DEVICES: config.devicesWanted || '' };
  const proc = spawn('bash', [config.buildScript], { env });
  const onData = (d) => {
    for (const line of d.toString().split('\n')) {
      if (!line.trim()) continue;
      build.lines.push(line);
      if (build.lines.length > 2000) build.lines.shift();
      if (/error:|warning:|BUILD|▸|==>/.test(line)) broadcastAll({ t: 'build', state: 'running', line });
    }
  };
  proc.stdout.on('data', onData);
  proc.stderr.on('data', onData);
  proc.on('close', async (code) => {
    if (code !== 0) {
      build.state = 'failed';
      broadcastAll({ t: 'build', state: 'failed', line: 'Build fehlgeschlagen – Details im Build-Protokoll' });
      return;
    }
    try {
      const result = JSON.parse(fs.readFileSync(path.join(config.simDir, 'app.json'), 'utf8'));
      app = result;
      if (ref) config.ref = ref;
      build.state = 'ok';
      broadcastAll({ t: 'build', state: 'ok', line: 'Build fertig, installiere …' });
      await installEverywhere(app);
    } catch (err) {
      build.state = 'failed';
      broadcastAll({ t: 'build', state: 'failed', line: err.message });
    }
  });
}

function shutdown(reason) {
  log(`Sitzung endet: ${reason}`);
  for (const dev of devices.values()) {
    dev.broadcast({ t: 'bye', reason });
    dev.close();
  }
  setTimeout(() => process.exit(0), 500);
}

// ---------- HTTP ----------

const routes = [];
function route(method, pattern, handler) {
  const keys = [];
  const regex = new RegExp('^' + pattern.replace(/:(\w+)/g, (_, k) => { keys.push(k); return '([^/]+)'; }) + '$');
  routes.push({ method, regex, keys, handler });
}

route('GET', '/api/info', async () => info());
route('GET', '/api/log', async () => ({ lines: logLines }));
route('GET', '/api/build-log', async () => ({ state: build.state, lines: build.lines }));
route('POST', '/api/rebuild', async (req) => {
  const body = await readJson(req);
  rebuild(body.ref);
  return { ok: true };
});
route('POST', '/api/shutdown', async () => {
  setTimeout(() => shutdown('von der PC-App beendet'), 100);
  return { ok: true };
});
route('POST', '/api/install', async (req, url) => {
  const { dir } = await saveUpload(req, url.searchParams.get('name'));
  const file = path.join(dir, fs.readdirSync(dir)[0]);
  if (/\.zip$/i.test(file)) await run('ditto', ['-x', '-k', file, dir], { timeout: 180_000 });
  const found = await findApp(dir);
  await installEverywhere(found, targets(url.searchParams.get('device')));
  return { ok: true, app: found };
});

route('GET', '/api/dev/:role/screenshot', async (req, url, p, res) => {
  const png = await targets(p.role)[0].screenshot();
  send(res, 200, png, 'image/png');
});
route('GET', '/api/dev/:role/apps', async (req, url, p) => ({ apps: await targets(p.role)[0].apps() }));
route('GET', '/api/dev/:role/clipboard', async (req, url, p) => ({ text: await targets(p.role)[0].getClipboard() }));
route('POST', '/api/dev/:role/clipboard', async (req, url, p) => {
  const body = await readJson(req);
  await targets(p.role)[0].setClipboard(String(body.text || ''));
  return { ok: true };
});
route('POST', '/api/dev/:role/rotate', async (req, url, p) => {
  const body = await readJson(req);
  return targets(p.role)[0].rotate(body.dir === 'left' ? 'left' : 'right');
});
route('POST', '/api/dev/:role/appearance', async (req, url, p) => {
  const body = await readJson(req);
  for (const d of targets(p.role)) await d.appearance(body.mode);
  return { ok: true };
});
route('POST', '/api/dev/:role/openurl', async (req, url, p) => {
  const body = await readJson(req);
  await targets(p.role)[0].openUrl(String(body.url));
  return { ok: true };
});
route('POST', '/api/dev/:role/location', async (req, url, p) => {
  const body = await readJson(req);
  for (const d of targets(p.role)) await d.location(body.lat, body.lon);
  return { ok: true };
});
route('POST', '/api/dev/:role/statusbar', async (req, url, p) => {
  const body = await readJson(req);
  for (const d of targets(p.role)) await d.statusBar(!!body.clean);
  return { ok: true };
});
route('POST', '/api/dev/:role/language', async (req, url, p) => {
  const body = await readJson(req);
  const lang = String(body.lang || 'de-DE');
  const locale = String(body.locale || 'de_DE');
  for (const d of targets(p.role)) await d.setLanguage(lang, locale);
  return { ok: true };
});
route('POST', '/api/dev/:role/launch', async (req, url, p) => {
  const body = await readJson(req);
  await targets(p.role)[0].launch(String(body.bundle));
  return { ok: true };
});
route('POST', '/api/dev/:role/media', async (req, url, p) => {
  const { file, dir } = await saveUpload(req, url.searchParams.get('name'));
  try {
    for (const d of targets(p.role)) await d.addMedia(file);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  return { ok: true };
});
// App-Daten (z. B. die Hefte in FreeNotes) als .tar.gz sichern …
route('GET', '/api/dev/:role/appdata', async (req, url, p, res) => {
  const bundle = url.searchParams.get('bundle') || app?.bundle;
  const dir = await targets(p.role)[0].appDataDir(bundle);
  res.writeHead(200, { ...CORS, 'content-type': 'application/gzip', 'content-disposition': `attachment; filename="${bundle}.tar.gz"` });
  const tar = spawn('tar', ['czf', '-', '-C', dir, '.']);
  tar.stdout.pipe(res);
});
// … und beim nächsten Mal wieder einspielen.
route('POST', '/api/dev/:role/appdata', async (req, url, p) => {
  const bundle = url.searchParams.get('bundle') || app?.bundle;
  const { file, dir: tmp } = await saveUpload(req, 'appdata.tar.gz');
  try {
    for (const d of targets(p.role)) {
      await run('xcrun', ['simctl', 'terminate', d.udid, bundle], { allowFail: true });
      const dir = await d.appDataDir(bundle);
      await run('tar', ['xzf', file, '-C', dir], { timeout: 180_000 });
      await d.launch(bundle);
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  return { ok: true };
});

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (req.method === 'OPTIONS') { res.writeHead(204, CORS); return res.end(); }
  if (url.pathname === '/healthz') return send(res, 200, { ok: true, session: config.session });
  if (!authorized(req, url)) return send(res, 401, { error: 'Zugangsschlüssel fehlt oder falsch' });
  lastActivity = Date.now();
  for (const r of routes) {
    if (r.method !== req.method) continue;
    const m = r.regex.exec(url.pathname);
    if (!m) continue;
    const params = Object.fromEntries(r.keys.map((k, i) => [k, decodeURIComponent(m[i + 1])]));
    try {
      const result = await r.handler(req, url, params, res);
      if (!res.headersSent && result !== undefined) send(res, 200, result);
    } catch (err) {
      log(`Fehler ${req.method} ${url.pathname}: ${err.message}`);
      if (!res.headersSent) send(res, err.status || 500, { error: err.message });
    }
    return;
  }
  send(res, 404, { error: 'Unbekannter Pfad' });
});

const wss = new WebSocketServer({ noServer: true, perMessageDeflate: false });
server.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url, 'http://localhost');
  const m = /^\/ws\/([^/]+)$/.exec(url.pathname);
  const dev = m && devices.get(decodeURIComponent(m[1]));
  if (!dev || !authorized(req, url)) {
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => {
    lastActivity = Date.now();
    ws.on('message', () => { lastActivity = Date.now(); });
    dev.attach(ws);
    if (build.state === 'failed') dev.sendJson(ws, { t: 'build', state: 'failed', line: 'Die App ließ sich nicht bauen – Details im Build-Protokoll' });
  });
});

// Minuten sparen: ohne verbundene PC-App endet die Sitzung von selbst.
setInterval(() => {
  const connected = [...devices.values()].some((d) => d.clients.size > 0);
  if (connected) lastActivity = Date.now();
  if (Date.now() - lastActivity > IDLE_LIMIT_MS) shutdown('keine Verbindung mehr');
  if (config.deadline && Date.now() > config.deadline) shutdown('Sitzungszeit abgelaufen');
}, 10_000).unref();

process.on('SIGTERM', () => shutdown('Runner beendet'));

server.listen(PORT, '127.0.0.1', () => log(`Steuer-Server bereit auf Port ${PORT} (${devices.size} Gerät(e))`));
