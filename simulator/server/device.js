'use strict';
// Ein gestarteter Simulator: Bild-Stream, Eingaben (Touch, Tastatur, Tasten) und Geräte-Befehle.

const { spawn } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { HidBroker } = require('./hid');
const helper = require('./helper');
const { run, jpegSize } = require('./util');
const keys = require('./keys');

// fps/quality/scale für simhelper (echtes Video); AXe macht Einzelbilder und schafft weniger fps.
// Das iPad hat fast doppelt so viele Pixel, deshalb dort kleiner skalieren.
const QUALITY = {
  schnell: { fps: 30, quality: 55, scale: 0.4, scaleIpad: 0.3 },
  normal: { fps: 24, quality: 70, scale: 0.5, scaleIpad: 0.4 },
  scharf: { fps: 15, quality: 82, scale: 0.75, scaleIpad: 0.55 },
};

// Skalierung so wählen, dass die Bildbreite ein Vielfaches von 16 Pixeln ist: dann hat jede Zeile
// der Rohdaten genau Breite × 4 Byte und simhelper kann die Zeilen nicht falsch zuordnen.
function alignedScale(scale, width) {
  const target = Math.max(16, Math.floor((scale * width) / 16) * 16);
  return (target + 0.5) / width;
}

// Reihenfolge im Uhrzeigersinn, Namen wie in AXe (OrientationCoordinateMath).
const CLOCKWISE = ['portrait', 'landscape', 'portraitUpsideDown', 'landscapeFlipped'];
// Ausrichtung für das HID-Ereignis (UIDeviceOrientation: »Landscape Left« = gegen den Uhrzeigersinn)
const ORIENTATION_HID = {
  portrait: 'portrait',
  landscape: 'landscapeRight',
  portraitUpsideDown: 'portraitUpsideDown',
  landscapeFlipped: 'landscapeLeft',
};
// Drehung, mit der ein Bild im Hochformat des Geräts aufrecht angezeigt wird
const VIEW_ROTATION = { portrait: 0, landscape: 90, portraitUpsideDown: 0, landscapeFlipped: -90 };
const ORIENTATION_MENU = {
  portrait: 'Portrait',
  landscape: 'Landscape Right',
  portraitUpsideDown: 'Portrait Upside Down',
  landscapeFlipped: 'Landscape Left',
};

class Device {
  constructor(info, { axe = 'axe', simhelper = process.env.SIMHELPER, log }) {
    this.info = info; // { role, udid, name, model, runtime, scale, pixelWidth, pixelHeight }
    this.role = info.role;
    this.udid = info.udid;
    this.axe = axe;
    this.log = (msg) => log(`[${this.role}] ${msg}`);
    this.pointWidth = info.pixelWidth / info.scale;
    this.pointHeight = info.pixelHeight / info.scale;
    this.orientation = 'portrait';
    this.clients = new Set();
    this.quality = 'normal';
    this.stream = null;
    this.streamFailures = [];
    this.lastFrame = null;
    this.frameSize = null;
    this.hid = new HidBroker(this.udid, { axe, log: this.log });
    this.simhelper = simhelper && helper.available(simhelper) ? simhelper : null;
    this.helperStream = !!this.simhelper;
    this.helperHid = this.simhelper ? new helper.HelperHid(this.simhelper, this.udid, this.log) : null;
    this.pinching = false;
    this.inputChain = Promise.resolve();
    this.touchDown = false;
    this.textBuffer = '';
    this.textTimer = null;
    this.logProc = null;
    this.logClients = new Set();
  }

  describe() {
    return {
      role: this.role,
      udid: this.udid,
      name: this.info.name,
      model: this.info.model,
      runtime: this.info.runtimeName,
      pointWidth: this.pointWidth,
      pointHeight: this.pointHeight,
      orientation: this.orientation,
      quality: this.quality,
      frame: this.frameSize,
      rotateView: this.rotateView(),
      video: this.helperStream ? 'video' : 'einzelbilder',
      features: { rotate: true, pinch: !!this.helperHid, shake: !!this.helperHid },
    };
  }

  // Liefert der Strom Bilder im Hochformat, obwohl das Gerät quer liegt, dreht die PC-App die Anzeige.
  rotateView() {
    if (!this.frameSize) return 0;
    const landscapeFrame = this.frameSize.w > this.frameSize.h;
    const landscapeDevice = this.orientation === 'landscape' || this.orientation === 'landscapeFlipped';
    return landscapeFrame === landscapeDevice ? 0 : VIEW_ROTATION[this.orientation];
  }

  // ---------- Clients ----------

  attach(ws) {
    ws.lastHash = null;
    this.clients.add(ws);
    this.sendJson(ws, { t: 'meta', device: this.describe() });
    if (this.lastFrame) this.sendFrame(ws, this.lastFrame);
    this.ensureStream();
    ws.on('message', (data, isBinary) => {
      if (isBinary) return;
      let msg;
      try { msg = JSON.parse(data.toString('utf8')); } catch { return; }
      if (msg.t === 'ping') return this.sendJson(ws, { t: 'pong', id: msg.id });
      // Eingaben strikt der Reihe nach, sonst überholt z. B. Enter den Text davor.
      this.inputChain = this.inputChain
        .then(() => this.handle(ws, msg))
        .catch((err) => this.sendJson(ws, { t: 'toast', level: 'error', msg: err.message }));
    });
    ws.on('close', () => {
      this.clients.delete(ws);
      this.logClients.delete(ws);
      if (this.touchDown) this.touch('up', this.lastTouch?.x ?? 0.5, this.lastTouch?.y ?? 0.5).catch(() => {});
      if (this.clients.size === 0) this.stopStream();
      if (this.logClients.size === 0) this.stopLogs();
    });
  }

  sendJson(ws, obj) {
    if (ws.readyState === 1) ws.send(JSON.stringify(obj));
  }

  broadcast(obj) {
    for (const ws of this.clients) this.sendJson(ws, obj);
  }

  sendFrame(ws, frame) {
    if (ws.readyState !== 1) return;
    if (ws.bufferedAmount > 1_500_000) return; // langsame Leitung: Bild auslassen statt stauen
    if (ws.lastHash === frame.hash) return;
    ws.lastHash = frame.hash;
    ws.send(frame.data, { binary: true });
  }

  async handle(ws, msg) {
    switch (msg.t) {
      case 'touch': return this.touch(msg.p, msg.x, msg.y);
      case 'wheel': return this.wheel(msg.x, msg.y, msg.dx, msg.dy);
      case 'text': return this.typeText(msg.s);
      case 'key': return this.key(msg.k, msg.mods || {});
      case 'button': return this.button(msg.b, !!msg.long);
      case 'pinch': return this.pinch(msg.p, msg.x, msg.y);
      case 'zoom': return this.zoom(msg.x, msg.y, msg.scale);
      case 'quality': return this.setQuality(msg.q);
      case 'logs': return msg.on ? this.startLogs(ws) : this.logClients.delete(ws);
      case 'ping': return this.sendJson(ws, { t: 'pong', id: msg.id });
      default: return undefined;
    }
  }

  // ---------- Bild ----------

  setQuality(q) {
    if (!QUALITY[q] || q === this.quality) return;
    this.quality = q;
    this.stopStream();
    this.ensureStream();
    this.broadcast({ t: 'meta', device: this.describe() });
  }

  ensureStream() {
    if (this.stream || this.clients.size === 0) return;
    const preset = QUALITY[this.quality];
    const { fps, quality } = preset;
    const scale = this.role === 'ipad' ? preset.scaleIpad : preset.scale;
    let proc;
    let parse;
    const startedAt = Date.now();
    let frames = 0;
    if (this.helperStream) {
      proc = spawn(this.simhelper, ['stream', '--udid', this.udid, '--fps', String(fps),
        '--quality', String(quality / 100), '--scale', alignedScale(scale, this.info.pixelWidth).toFixed(6),
        '--src-width', String(this.info.pixelWidth), '--src-height', String(this.info.pixelHeight)], { stdio: ['ignore', 'pipe', 'pipe'] });
      parse = helper.minicapParser((f) => { frames++; this.onFrame(f); });
    } else {
      // Einzelbilder über AXe: je Bild 4 Byte Länge (BE) + JPEG
      proc = spawn(this.axe, ['stream-video', '--udid', this.udid, '--format', 'raw',
        '--fps', String(Math.min(fps, 15)), '--quality', String(quality), '--scale', String(scale)], { stdio: ['ignore', 'pipe', 'pipe'] });
      let buf = Buffer.alloc(0);
      parse = (chunk) => {
        buf = buf.length ? Buffer.concat([buf, chunk]) : chunk;
        while (buf.length >= 4) {
          const len = buf.readUInt32BE(0);
          if (len > 20_000_000) { buf = Buffer.alloc(0); break; }
          if (buf.length < 4 + len) break;
          frames++;
          this.onFrame(Buffer.from(buf.subarray(4, 4 + len)));
          buf = buf.subarray(4 + len);
        }
      };
    }
    this.stream = proc;
    proc.stdout.on('data', parse);
    if (this.helperStream) {
      // Hängt der Video-Helfer (kein erstes Bild), auf AXe-Einzelbilder umschalten.
      setTimeout(() => {
        if (this.stream === proc && frames === 0) {
          this.log('simhelper liefert kein Bild, nutze AXe-Einzelbilder');
          this.helperStream = false;
          this.stream = null;
          proc.kill('SIGKILL');
          this.broadcast({ t: 'meta', device: this.describe() });
          this.ensureStream();
        }
      }, Number(process.env.HELPER_FIRST_FRAME_MS || 20_000));
    }
    proc.stderr.on('data', (d) => {
      for (const line of d.toString().split('\n')) {
        const text = line.trim();
        if (text && !/Captured \d+ frames|damage callbacks|CoreSimulator:|SimulatorKit:|Loaded All|SimDisplay Class/.test(text)) this.log(`stream: ${text}`);
      }
    });
    proc.on('error', (err) => this.log(`stream startet nicht: ${err.message}`));
    proc.on('exit', (code) => {
      if (this.stream !== proc) return;
      this.stream = null;
      // Liefert simhelper gar keine Bilder, bleibt es bei AXe-Einzelbildern.
      if (this.helperStream && frames === 0 && Date.now() - startedAt < 20_000) {
        this.log('simhelper-Video geht nicht, nutze AXe-Einzelbilder');
        this.helperStream = false;
        this.broadcast({ t: 'meta', device: this.describe() });
      }
      if (this.clients.size === 0) return;
      const now = Date.now();
      this.streamFailures = this.streamFailures.filter((t) => now - t < 30_000);
      this.streamFailures.push(now);
      this.log(`stream beendet (${code}), starte neu`);
      setTimeout(() => this.ensureStream(), this.streamFailures.length > 3 ? 5000 : 500);
    });
  }

  stopStream() {
    if (!this.stream) return;
    const proc = this.stream;
    this.stream = null;
    proc.kill('SIGINT');
  }

  onFrame(data) {
    const size = jpegSize(data);
    const hash = crypto.createHash('md5').update(data).digest('hex');
    this.lastFrame = { data, hash };
    if (size && (!this.frameSize || size.w !== this.frameSize.w || size.h !== this.frameSize.h)) {
      this.frameSize = size;
      this.broadcast({ t: 'meta', device: this.describe() });
    }
    for (const ws of this.clients) this.sendFrame(ws, this.lastFrame);
  }

  // ---------- Koordinaten ----------

  // x/y kommen normiert (0…1) bezogen auf das angezeigte Bild; der HID-Broker will Punkte
  // im Hochformat des Geräts.
  toPhysical(nx, ny) {
    const W = this.pointWidth;
    const H = this.pointHeight;
    const cx = Math.min(1, Math.max(0, nx));
    const cy = Math.min(1, Math.max(0, ny));
    switch (this.orientation) {
      case 'landscape': { // im Uhrzeigersinn gedreht
        const lx = cx * H; const ly = cy * W;
        return { x: ly, y: H - lx };
      }
      case 'landscapeFlipped': { // gegen den Uhrzeigersinn gedreht
        const lx = cx * H; const ly = cy * W;
        return { x: W - ly, y: lx };
      }
      case 'portraitUpsideDown':
        return { x: W - cx * W, y: H - cy * H };
      default:
        return { x: cx * W, y: cy * H };
    }
  }

  // ---------- Eingaben ----------

  async touch(phase, nx, ny) {
    const p = this.toPhysical(nx, ny);
    this.lastTouch = { x: nx, y: ny };
    if (phase === 'down' || phase === 'move') {
      if (phase === 'move' && !this.touchDown) return;
      this.touchDown = true;
      return this.hid.send([{ kind: 'down', x: p.x, y: p.y }]);
    }
    if (phase === 'up') {
      if (!this.touchDown) return;
      this.touchDown = false;
      return this.hid.send([{ kind: 'up', x: p.x, y: p.y }]);
    }
  }

  // Mausrad = kurzes Wischen mit dem Finger an der Mausposition.
  async wheel(nx, ny, dx, dy) {
    if (this.touchDown) return;
    const steps = 6;
    const ex = Math.min(0.98, Math.max(0.02, nx - dx));
    const ey = Math.min(0.98, Math.max(0.02, ny - dy));
    const prims = [];
    for (let i = 0; i <= steps; i++) {
      const f = i / steps;
      const p = this.toPhysical(nx + (ex - nx) * f, ny + (ey - ny) * f);
      prims.push({ kind: 'down', x: p.x, y: p.y });
      prims.push({ kind: 'delay', duration: 0.016 });
    }
    const end = this.toPhysical(ex, ey);
    prims.push({ kind: 'up', x: end.x, y: end.y });
    return this.hid.send(prims);
  }

  // Text sammeln und gebündelt tippen; Umlaute und Emoji über die Zwischenablage einfügen.
  typeText(s) {
    if (!s) return;
    this.textBuffer += s;
    clearTimeout(this.textTimer);
    this.textTimer = setTimeout(() => this.flushText().catch((e) => this.log(`tippen: ${e.message}`)), 60);
  }

  async flushText() {
    const text = this.textBuffer;
    this.textBuffer = '';
    if (!text) return;
    // eslint-disable-next-line no-control-regex
    if (/^[\x20-\x7e]*$/.test(text)) {
      await run(this.axe, ['type', '--stdin', '--udid', this.udid], { input: text });
    } else {
      await run('xcrun', ['simctl', 'pbcopy', this.udid], { input: text });
      await run(this.axe, ['key-combo', '--modifiers', String(keys.MOD.cmd), '--key', String(keys.code('v')), '--udid', this.udid]);
    }
  }

  async key(name, mods) {
    await this.flushText();
    const code = keys.code(name);
    if (code == null) return;
    const modifiers = keys.modifiers(mods);
    if (modifiers.length) {
      await run(this.axe, ['key-combo', '--modifiers', modifiers.join(','), '--key', String(code), '--udid', this.udid]);
    } else {
      await run(this.axe, ['key', String(code), '--udid', this.udid]);
    }
  }

  // Zwei Finger, gespiegelt um die Bildschirmmitte (wie Alt+Ziehen im Simulator auf dem Mac).
  async pinch(phase, nx, ny) {
    if (!this.helperHid) throw new Error('Zwei-Finger-Gesten gehen in dieser Sitzung nicht');
    if (phase === 'move' && !this.pinching) return;
    const f1 = this.toPhysical(nx, ny);
    const f2 = this.toPhysical(1 - nx, 1 - ny);
    this.pinching = phase !== 'up';
    return this.helperHid.send({ op: 'two', dir: phase === 'up' ? 'up' : 'down', x1: f1.x, y1: f1.y, x2: f2.x, y2: f2.y });
  }

  // Strg+Mausrad: Zoom-Geste an der Mausposition
  async zoom(nx, ny, scale) {
    if (!this.helperHid) throw new Error('Zoomen geht in dieser Sitzung nicht');
    const p = this.toPhysical(nx, ny);
    const s = Math.max(0.3, Math.min(3, Number(scale) || 1));
    return this.helperHid.send({ op: 'pinch', x: p.x, y: p.y, scale: s, duration: 0.35, radius: Math.min(this.pointWidth, this.pointHeight) * 0.12 });
  }

  async button(name, long) {
    if (name === 'shake') {
      if (!this.helperHid) throw new Error('Schütteln geht in dieser Sitzung nicht');
      return this.helperHid.send({ op: 'shake' });
    }
    if (name === 'app-switcher') {
      // Wischen vom unteren Rand nach oben und kurz halten, wie auf Face-ID-Geräten.
      const prims = [];
      const start = this.toPhysical(0.5, 0.995);
      prims.push({ kind: 'down', x: start.x, y: start.y });
      for (let i = 1; i <= 12; i++) {
        const p = this.toPhysical(0.5, 0.995 - 0.35 * (i / 12));
        prims.push({ kind: 'delay', duration: 0.02 });
        prims.push({ kind: 'down', x: p.x, y: p.y });
      }
      prims.push({ kind: 'delay', duration: 0.6 });
      const end = this.toPhysical(0.5, 0.645);
      prims.push({ kind: 'up', x: end.x, y: end.y });
      return this.hid.send(prims);
    }
    const allowed = ['home', 'lock', 'side-button', 'siri', 'apple-pay'];
    if (!allowed.includes(name)) throw new Error(`Unbekannte Taste: ${name}`);
    const args = ['button', name, '--udid', this.udid];
    if (long) args.push('--duration', '2.5');
    await run(this.axe, args);
  }

  // ---------- Geräte-Befehle ----------

  async rotate(dir) {
    const i = CLOCKWISE.indexOf(this.orientation);
    const target = dir === 'left' ? CLOCKWISE[(i + 3) % 4] : CLOCKWISE[(i + 1) % 4];
    if (this.helperHid) {
      try {
        await this.helperHid.send({ op: 'orientation', value: ORIENTATION_HID[target] });
        this.orientation = target;
        this.broadcast({ t: 'meta', device: this.describe() });
        return { orientation: target };
      } catch (err) {
        this.log(`Drehen über simhelper: ${err.message}`);
      }
    }
    const menuItem = ORIENTATION_MENU[target];
    const relative = dir === 'left' ? 'Rotate Left' : 'Rotate Right';
    const name = this.info.name.replace(/"/g, '');
    const script = `
      tell application "Simulator" to activate
      delay 0.3
      tell application "System Events"
        tell process "Simulator"
          try
            perform action "AXRaise" of (first window whose name contains "${name}")
          end try
          delay 0.2
          try
            click menu item "${menuItem}" of menu "Orientation" of menu item "Orientation" of menu "Device" of menu bar 1
          on error
            click menu item "${relative}" of menu "Device" of menu bar 1
          end try
        end tell
      end tell`;
    const res = await run('osascript', ['-e', script], { timeout: 15_000, allowFail: true });
    if (res.code !== 0) throw new Error(`Drehen ging nicht: ${res.stderr.trim() || res.code}`);
    this.orientation = target;
    this.broadcast({ t: 'meta', device: this.describe() });
    return { orientation: target };
  }

  appearance(mode) {
    return run('xcrun', ['simctl', 'ui', this.udid, 'appearance', mode === 'dark' ? 'dark' : 'light']);
  }

  openUrl(url) {
    return run('xcrun', ['simctl', 'openurl', this.udid, url]);
  }

  location(lat, lon) {
    return run('xcrun', ['simctl', 'location', this.udid, 'set', `${Number(lat)},${Number(lon)}`]);
  }

  async setClipboard(text) {
    await run('xcrun', ['simctl', 'pbcopy', this.udid], { input: text });
  }

  async getClipboard() {
    const res = await run('xcrun', ['simctl', 'pbpaste', this.udid]);
    return res.stdout;
  }

  addMedia(file) {
    return run('xcrun', ['simctl', 'addmedia', this.udid, file], { timeout: 120_000 });
  }

  async screenshot() {
    const file = path.join(os.tmpdir(), `shot-${this.role}-${Date.now()}.png`);
    await run('xcrun', ['simctl', 'io', this.udid, 'screenshot', '--type=png', file], { timeout: 30_000 });
    const data = fs.readFileSync(file);
    fs.rmSync(file, { force: true });
    return data;
  }

  statusBar(clean) {
    if (!clean) return run('xcrun', ['simctl', 'status_bar', this.udid, 'clear']);
    return run('xcrun', ['simctl', 'status_bar', this.udid, 'override', '--time', '9:41',
      '--batteryState', 'charged', '--batteryLevel', '100', '--wifiBars', '3', '--cellularBars', '4']);
  }

  async apps() {
    const res = await run('/bin/sh', ['-c', `xcrun simctl listapps ${this.udid} | plutil -convert json -o - -`]);
    const all = JSON.parse(res.stdout || '{}');
    return Object.values(all)
      .filter((a) => a.ApplicationType === 'User')
      .map((a) => ({ bundle: a.CFBundleIdentifier, name: a.CFBundleDisplayName || a.CFBundleName, executable: a.CFBundleExecutable }));
  }

  async install(appPath) {
    await run('xcrun', ['simctl', 'install', this.udid, appPath], { timeout: 180_000 });
  }

  async launch(bundle) {
    await run('xcrun', ['simctl', 'terminate', this.udid, bundle], { allowFail: true });
    await run('xcrun', ['simctl', 'launch', this.udid, bundle], { timeout: 60_000 });
  }

  async appDataDir(bundle) {
    const res = await run('xcrun', ['simctl', 'get_app_container', this.udid, bundle, 'data']);
    return res.stdout.trim();
  }

  async setLanguage(lang, locale) {
    const prefs = ['simctl', 'spawn', this.udid, 'defaults', 'write', '-g'];
    await run('xcrun', [...prefs, 'AppleLanguages', '-array', lang]);
    await run('xcrun', [...prefs, 'AppleLocale', '-string', locale]);
    // SpringBoard übernimmt die Sprache erst nach einem Neustart des Geräts.
    this.stopStream();
    await run('xcrun', ['simctl', 'shutdown', this.udid], { allowFail: true, timeout: 60_000 });
    await run('xcrun', ['simctl', 'boot', this.udid], { timeout: 120_000 });
    await run('xcrun', ['simctl', 'bootstatus', this.udid, '-b'], { timeout: 300_000 });
    this.ensureStream();
  }

  // ---------- App-Protokoll ----------

  async startLogs(ws) {
    this.logClients.add(ws);
    if (this.logProc) return;
    const apps = await this.apps().catch(() => []);
    const names = apps.map((a) => a.executable).filter(Boolean);
    const predicate = names.length
      ? names.map((n) => `process == "${n.replace(/"/g, '')}"`).join(' OR ')
      : 'eventType == logEvent AND messageType >= 16';
    const proc = spawn('xcrun', ['simctl', 'spawn', this.udid, 'log', 'stream', '--style', 'compact', '--level', 'debug', '--predicate', predicate], { stdio: ['ignore', 'pipe', 'pipe'] });
    this.logProc = proc;
    let rest = '';
    proc.stdout.on('data', (d) => {
      const lines = (rest + d.toString()).split('\n');
      rest = lines.pop();
      for (const line of lines) {
        if (!line.trim()) continue;
        for (const c of this.logClients) this.sendJson(c, { t: 'log', line });
      }
    });
    proc.on('exit', () => { if (this.logProc === proc) this.logProc = null; });
  }

  stopLogs() {
    if (this.logProc) this.logProc.kill();
    this.logProc = null;
  }

  close() {
    this.stopStream();
    this.stopLogs();
    this.hid.close();
    if (this.helperHid) this.helperHid.close();
  }
}

module.exports = { Device, QUALITY, alignedScale };
