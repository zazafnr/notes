'use strict';
// PC-App »iOS-Simulator«: startet über GitHub eine Sitzung auf einem Cloud-Mac und zeigt jedes
// Gerät (iPhone, iPad) in einem eigenen Fenster, das sich wie das Gerät bedienen lässt.

const { app, BrowserWindow, ipcMain, dialog, clipboard, safeStorage, shell, screen, Menu } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const { Readable } = require('node:stream');
const { GitHub, SessionWatcher, newCredentials } = require('./github');

const CONFIG_FILE = () => path.join(app.getPath('userData'), 'config.json');
const PROFILE_DIR = () => path.join(app.getPath('userData'), 'profile');

const DEFAULTS = {
  repo: 'zazafnr/notes',
  toolRef: '',
  ios: '27',
  devices: 'beide',
  iphoneModel: 'auto',
  ipadModel: 'auto',
  appRef: 'claude/chat-ios-notizbuch-ki-yx5ny3',
  minutes: 60,
  iphoneProfile: 'leer',
  ipadProfile: 'leer',
  quality: 'normal',
  monthlyLimit: 200,
  usage: {},
  profiles: [],
};

let config = loadConfig();
let launcher = null;
const deviceWindows = new Map();
let session = null; // { id, token, url, runId, runUrl, ref, startedAt, watcher, info }

// ---------- Einstellungen ----------

function loadConfig() {
  try {
    return { ...DEFAULTS, ...JSON.parse(fs.readFileSync(CONFIG_FILE(), 'utf8')) };
  } catch {
    return { ...DEFAULTS };
  }
}

function saveConfig() {
  fs.mkdirSync(path.dirname(CONFIG_FILE()), { recursive: true });
  fs.writeFileSync(CONFIG_FILE(), JSON.stringify(config, null, 2));
}

function getToken() {
  if (!config.tokenEnc) return '';
  try {
    const buf = Buffer.from(config.tokenEnc, 'base64');
    return safeStorage.isEncryptionAvailable() ? safeStorage.decryptString(buf) : buf.toString('utf8');
  } catch {
    return '';
  }
}

function setToken(token) {
  config.tokenEnc = safeStorage.isEncryptionAvailable()
    ? safeStorage.encryptString(token).toString('base64')
    : Buffer.from(token, 'utf8').toString('base64');
  saveConfig();
}

function publicConfig() {
  const { tokenEnc, ...rest } = config;
  return { ...rest, hasToken: !!tokenEnc, monthKey: monthKey() };
}

function gh() {
  const token = getToken();
  if (!token) throw new Error('Bitte zuerst ein GitHub-Token eintragen.');
  return new GitHub({ token, repo: config.repo, api: process.env.SIM_GITHUB_API || undefined });
}

function monthKey() {
  return new Date().toISOString().slice(0, 7);
}

function addUsage(minutes) {
  const key = monthKey();
  config.usage[key] = Math.round(((config.usage[key] || 0) + minutes) * 10) / 10;
  saveConfig();
}

// ---------- Fenster ----------

function createLauncher() {
  launcher = new BrowserWindow({
    width: 1040,
    height: 760,
    minWidth: 860,
    minHeight: 620,
    title: 'iOS-Simulator',
    backgroundColor: '#f2f2f7',
    icon: path.join(__dirname, 'build', 'icon.png'),
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: false },
  });
  launcher.setMenuBarVisibility(false);
  launcher.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  launcher.on('closed', () => { launcher = null; });
}

function emit(channel, payload) {
  if (launcher && !launcher.isDestroyed()) launcher.webContents.send(channel, payload);
}

// Fenstergröße aus der Bildschirmgröße des Geräts (in Punkten) und dem Platz auf dem PC.
function windowSizeFor(device, landscape) {
  const work = screen.getPrimaryDisplay().workAreaSize;
  const toolbar = 64;
  const bezel = device.role === 'iphone' ? 0.055 : 0.045;
  let w = device.pointWidth * (1 + 2 * bezel);
  let h = device.pointHeight + device.pointWidth * 2 * bezel;
  if (landscape) [w, h] = [h, w];
  const scale = Math.min((work.height * 0.9) / h, (work.width * 0.8 - toolbar) / w, 1.4);
  return { width: Math.round(w * scale + toolbar), height: Math.round(h * scale), toolbar };
}

function openDeviceWindow(device) {
  const existing = deviceWindows.get(device.role);
  if (existing && !existing.isDestroyed()) {
    existing.show();
    existing.focus();
    return;
  }
  const size = windowSizeFor(device, false);
  const win = new BrowserWindow({
    width: size.width,
    height: size.height,
    minWidth: 260,
    minHeight: 300,
    frame: false,
    transparent: true,
    hasShadow: false,
    resizable: true,
    title: device.role === 'iphone' ? 'iPhone' : 'iPad',
    icon: path.join(__dirname, 'build', 'icon.png'),
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: false, backgroundThrottling: false },
  });
  win.setAspectRatio((size.width - size.toolbar) / size.height, { width: size.toolbar, height: 0 });
  win.loadFile(path.join(__dirname, 'renderer', 'device.html'), { query: { role: device.role } });
  win.on('closed', () => deviceWindows.delete(device.role));
  deviceWindows.set(device.role, win);
}

// ---------- Sitzung ----------

async function startSession(opts) {
  if (session && !session.ended) throw new Error('Es läuft schon eine Sitzung.');
  Object.assign(config, opts);
  saveConfig();
  const g = gh();
  const ref = await g.toolRef(config.toolRef);
  const creds = newCredentials();
  const profile = profileById(config.devices === 'ipad' ? config.ipadProfile : config.iphoneProfile);
  const settings = {
    language: profile?.language || 'de-DE',
    locale: profile?.locale || 'de_DE',
    appearance: profile?.appearance || 'light',
  };
  const inputs = {
    session: creds.session,
    auth_hash: creds.authHash,
    devices: config.devices,
    ios: String(config.ios),
    iphone_model: modelFor('iphone'),
    ipad_model: modelFor('ipad'),
    app_ref: config.appRef || '',
    minutes: String(config.minutes),
    settings: JSON.stringify(settings),
  };
  const since = Date.now();
  await g.dispatch(ref, inputs);
  session = { id: creds.session, token: creds.token, ref, startedAt: since, ended: false, phase: 'starting' };
  const watcher = new SessionWatcher(g, { ref, session: creds.session, since });
  session.watcher = watcher;
  watcher.on('progress', (p) => {
    session.runUrl = p.runUrl || session.runUrl;
    emit('session:progress', p);
  });
  watcher.on('ready', (r) => onReady(r).catch((err) => emit('session:failed', { text: `Verbindung ging nicht: ${err.message}`, runUrl: session?.runUrl })));
  watcher.on('failed', (f) => endSession('failed', f));
  watcher.on('ended', (e) => endSession('ended', e));
  watcher.start();
  return { session: creds.session, ref };
}

function modelFor(role) {
  const profile = profileById(role === 'iphone' ? config.iphoneProfile : config.ipadProfile);
  const fromConfig = role === 'iphone' ? config.iphoneModel : config.ipadModel;
  return fromConfig !== 'auto' ? fromConfig : profile?.model || 'auto';
}

function profileById(id) {
  return config.profiles.find((p) => p.id === id) || null;
}

async function onReady({ url, runUrl, runId }) {
  Object.assign(session, { url, runUrl, runId, phase: 'ready', readyAt: Date.now() });
  // Die neue Tunnel-Adresse braucht manchmal ein paar Sekunden, bis sie überall auflöst.
  let info = null;
  for (let attempt = 1; !info; attempt++) {
    try {
      info = await serverApi('GET', '/api/info');
    } catch (err) {
      if (attempt >= 20 || session.ended) throw err;
      emit('session:progress', { phase: 'connecting', text: `Verbinde mit dem Cloud-Mac … (Versuch ${attempt})` });
      await new Promise((r) => setTimeout(r, 3000));
    }
  }
  session.info = info;
  emit('session:ready', { url, runUrl, info });
  for (const device of info.devices) openDeviceWindow(device);
  applyProfiles(info).catch((err) => emit('session:progress', { phase: 'ready', text: `Profil: ${err.message}` }));
}

// Profil aufs Gerät bringen: Erscheinungsbild, Standort, Statusleiste, Fotos, Kontakte, App-Daten.
async function applyProfiles(info) {
  for (const device of info.devices) {
    const profile = profileById(device.role === 'iphone' ? config.iphoneProfile : config.ipadProfile);
    if (!profile) continue;
    const role = device.role;
    const say = (text) => sendToDevice(role, 'device:toast', { msg: text });
    if (profile.appearance) await serverApi('POST', `/api/dev/${role}/appearance`, { mode: profile.appearance });
    if (profile.location) await serverApi('POST', `/api/dev/${role}/location`, profile.location);
    if (profile.cleanStatusBar) await serverApi('POST', `/api/dev/${role}/statusbar`, { clean: true });
    const files = mediaFiles(profile);
    for (let i = 0; i < files.length; i++) {
      say(`Profil »${profile.name}«: Foto ${i + 1} von ${files.length} …`);
      await uploadFile(`/api/dev/${role}/media`, files[i]).catch((err) => say(`${path.basename(files[i])}: ${err.message}`));
    }
    if (profile.contacts && fs.existsSync(profile.contacts)) await uploadFile(`/api/dev/${role}/media`, profile.contacts);
    if (profile.keepAppData && info.app?.bundle) {
      const saved = appDataFile(profile, role, info.app.bundle);
      if (fs.existsSync(saved)) {
        say('Spiele gesicherte App-Daten ein …');
        await uploadFile(`/api/dev/${role}/appdata?bundle=${encodeURIComponent(info.app.bundle)}`, saved);
      }
    }
    say(`Profil »${profile.name}« ist eingerichtet`);
  }
}

const MEDIA = /\.(jpe?g|png|heic|heif|gif|webp|mov|mp4|m4v)$/i;
function mediaFiles(profile) {
  if (!profile.photosDir || !fs.existsSync(profile.photosDir)) return [];
  const out = [];
  const walk = (dir, depth) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory() && depth < 3) walk(full, depth + 1);
      else if (entry.isFile() && MEDIA.test(entry.name)) out.push(full);
      if (out.length >= (profile.maxPhotos || 300)) return;
    }
  };
  walk(profile.photosDir, 0);
  return out.sort();
}

function appDataFile(profile, role, bundle) {
  return path.join(PROFILE_DIR(), profile.id, `${role}-${bundle}.tar.gz`);
}

// Vor dem Beenden die App-Daten sichern, wenn das Profil das will.
async function saveAppData() {
  const info = session?.info;
  if (!info?.app?.bundle) return;
  for (const device of info.devices) {
    const profile = profileById(device.role === 'iphone' ? config.iphoneProfile : config.ipadProfile);
    if (!profile?.keepAppData) continue;
    const file = appDataFile(profile, device.role, info.app.bundle);
    await downloadTo(`/api/dev/${device.role}/appdata?bundle=${encodeURIComponent(info.app.bundle)}`, file).catch(() => {});
  }
}

async function stopSession() {
  if (!session || session.ended) return;
  emit('session:progress', { phase: 'stopping', text: 'Beende die Sitzung …' });
  if (session.url) {
    await saveAppData();
    await serverApi('POST', '/api/shutdown').catch(() => {});
  }
  const runId = session.runId || session.watcher?.runId;
  setTimeout(async () => {
    if (session && !session.ended && runId) {
      await gh().cancel(runId).catch(() => {});
      endSession('ended', { text: 'Sitzung beendet' });
    }
  }, session.url ? 15_000 : 0);
}

function endSession(kind, { text, runUrl } = {}) {
  if (!session || session.ended) return;
  session.ended = true;
  session.watcher?.stop();
  const minutes = (Date.now() - session.startedAt) / 60_000;
  addUsage(minutes);
  for (const win of deviceWindows.values()) if (!win.isDestroyed()) win.webContents.send('device:bye', { reason: text });
  emit(kind === 'failed' ? 'session:failed' : 'session:ended', { text, runUrl: runUrl || session.runUrl, minutes, config: publicConfig() });
}

// ---------- Verbindung zum Mac ----------

async function serverApi(method, apiPath, body) {
  if (!session?.url) throw new Error('Keine Sitzung verbunden');
  const res = await fetch(`${session.url}${apiPath}`, {
    method,
    headers: { authorization: `Bearer ${session.token}`, ...(body ? { 'content-type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(600_000),
  });
  const type = res.headers.get('content-type') || '';
  if (!res.ok) {
    const data = type.includes('json') ? await res.json().catch(() => ({})) : {};
    throw new Error(data.error || `Fehler ${res.status}`);
  }
  if (type.includes('json')) return res.json();
  return Buffer.from(await res.arrayBuffer());
}

async function uploadFile(apiPath, file) {
  const sep = apiPath.includes('?') ? '&' : '?';
  const res = await fetch(`${session.url}${apiPath}${sep}name=${encodeURIComponent(path.basename(file))}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${session.token}`, 'content-length': String(fs.statSync(file).size) },
    body: Readable.toWeb(fs.createReadStream(file)),
    duplex: 'half',
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `Fehler ${res.status}`);
  return data;
}

async function downloadTo(apiPath, file) {
  const res = await fetch(`${session.url}${apiPath}`, { headers: { authorization: `Bearer ${session.token}` } });
  if (!res.ok) throw new Error(`Fehler ${res.status}`);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, Buffer.from(await res.arrayBuffer()));
  return file;
}

function sendToDevice(role, channel, payload) {
  const win = deviceWindows.get(role);
  if (win && !win.isDestroyed()) win.webContents.send(channel, payload);
}

// ---------- IPC ----------

function handle(channel, fn) {
  ipcMain.handle(channel, async (event, ...args) => {
    try {
      return { ok: true, value: await fn(event, ...args) };
    } catch (err) {
      return { ok: false, error: err.message };
    }
  });
}

handle('config:get', () => publicConfig());
handle('config:set', (e, patch) => {
  Object.assign(config, patch);
  saveConfig();
  return publicConfig();
});
handle('token:set', async (e, { token, repo }) => {
  const g = new GitHub({ token: token.trim(), repo: (repo || config.repo).trim(), api: process.env.SIM_GITHUB_API || undefined });
  const repoInfo = await g.check();
  await g.branches();
  config.repo = repoInfo.name;
  setToken(token.trim());
  return { repo: repoInfo, config: publicConfig() };
});
handle('github:branches', () => gh().branches());
handle('session:start', (e, opts) => startSession(opts));
handle('session:stop', () => stopSession());
handle('session:get', () => (session ? {
  id: session.id, url: session.url, token: session.token, info: session.info, phase: session.phase,
  runUrl: session.runUrl, ended: session.ended, startedAt: session.startedAt, readyAt: session.readyAt,
} : null));
handle('session:show-devices', () => session?.info?.devices.forEach(openDeviceWindow));
handle('api', (e, method, apiPath, body) => serverApi(method, apiPath, body));
handle('upload', (e, apiPath, file) => uploadFile(apiPath, file));
handle('profile:save', (e, profile) => {
  const list = config.profiles.filter((p) => p.id !== profile.id);
  list.push(profile);
  config.profiles = list;
  saveConfig();
  return publicConfig();
});
handle('profile:delete', (e, id) => {
  config.profiles = config.profiles.filter((p) => p.id !== id);
  fs.rmSync(path.join(PROFILE_DIR(), id), { recursive: true, force: true });
  saveConfig();
  return publicConfig();
});
handle('profile:count-media', (e, dir) => mediaFiles({ photosDir: dir, maxPhotos: 5000 }).length);
handle('dialog:files', async (e, opts) => {
  const win = BrowserWindow.fromWebContents(e.sender);
  const res = await dialog.showOpenDialog(win, opts);
  return res.canceled ? [] : res.filePaths;
});
handle('dialog:folder', async (e) => {
  const win = BrowserWindow.fromWebContents(e.sender);
  const res = await dialog.showOpenDialog(win, { properties: ['openDirectory'] });
  return res.canceled ? null : res.filePaths[0];
});
handle('screenshot', async (e, role) => {
  const png = await serverApi('GET', `/api/dev/${role}/screenshot`);
  const stamp = new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19);
  const dir = path.join(app.getPath('pictures'), 'iOS-Simulator');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${role}-${stamp}.png`);
  fs.writeFileSync(file, png);
  return file;
});
handle('appdata:save', async (e, role) => {
  const bundle = session?.info?.app?.bundle;
  if (!bundle) throw new Error('In dieser Sitzung ist keine eigene App installiert');
  const win = BrowserWindow.fromWebContents(e.sender);
  const res = await dialog.showSaveDialog(win, { defaultPath: `${bundle}-${role}.tar.gz` });
  if (res.canceled) return null;
  return downloadTo(`/api/dev/${role}/appdata?bundle=${encodeURIComponent(bundle)}`, res.filePath);
});
handle('appdata:load', async (e, role) => {
  const bundle = session?.info?.app?.bundle;
  if (!bundle) throw new Error('In dieser Sitzung ist keine eigene App installiert');
  const win = BrowserWindow.fromWebContents(e.sender);
  const res = await dialog.showOpenDialog(win, { filters: [{ name: 'App-Daten', extensions: ['gz', 'tgz'] }], properties: ['openFile'] });
  if (res.canceled) return null;
  return uploadFile(`/api/dev/${role}/appdata?bundle=${encodeURIComponent(bundle)}`, res.filePaths[0]);
});
handle('clipboard:read', () => clipboard.readText());
handle('clipboard:write', (e, text) => clipboard.writeText(text));
handle('open-external', (e, url) => shell.openExternal(url));
handle('show-file', (e, file) => shell.showItemInFolder(file));
handle('window:resize-for', (e, { role, landscape }) => {
  const win = BrowserWindow.fromWebContents(e.sender);
  const device = session?.info?.devices.find((d) => d.role === role);
  if (!win || !device) return;
  const size = windowSizeFor(device, landscape);
  win.setAspectRatio((size.width - size.toolbar) / size.height, { width: size.toolbar, height: 0 });
  win.setSize(size.width, size.height, true);
});
handle('window:pin', (e, on) => BrowserWindow.fromWebContents(e.sender)?.setAlwaysOnTop(!!on, 'floating'));
handle('window:minimize', (e) => BrowserWindow.fromWebContents(e.sender)?.minimize());
handle('window:close', (e) => BrowserWindow.fromWebContents(e.sender)?.close());
handle('launcher:focus', () => {
  if (!launcher) createLauncher();
  launcher.show();
  launcher.focus();
});

// ---------- Start ----------

app.whenReady().then(() => {
  Menu.setApplicationMenu(null);
  createLauncher();
});

let quitting = false;
app.on('before-quit', async (event) => {
  if (quitting || !session || session.ended) return;
  event.preventDefault();
  quitting = true;
  await Promise.race([stopSession(), new Promise((r) => setTimeout(r, 8000))]);
  if (session?.runId && !session.ended) await gh().cancel(session.runId).catch(() => {});
  app.quit();
});

app.on('window-all-closed', () => app.quit());
