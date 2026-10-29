'use strict';
// Spricht direkt mit dem HID-Broker von AXe (`axe hid-broker`), damit Finger-Bewegungen live
// ankommen: Ein Broker-Prozess pro Simulator hält die Touch-Sitzung offen, jede Anfrage ist eine
// kurze Unix-Socket-Verbindung (Handshake-Zeile, Anfrage-Zeile, Antwort-Zeile).
// Eine Bewegung ist ein weiteres »down« an der neuen Stelle, genau wie AXe' eigenes `drag`.

const net = require('node:net');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, execFileSync } = require('node:child_process');

const KEEPALIVE_MS = 20_000; // Broker beendet sich nach 60 s ohne Anfrage
const IO_TIMEOUT_MS = 5_000;

function fnv1a64(text) {
  let hash = 0xcbf29ce484222325n;
  for (const byte of Buffer.from(text, 'utf8')) {
    hash ^= BigInt(byte);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return hash.toString(16);
}

function realpath(p) {
  try { return fs.realpathSync(p); } catch { return p.replace(/\/+$/, ''); }
}

// NSTemporaryDirectory() kommt auf macOS aus confstr(_CS_DARWIN_USER_TEMP_DIR), nicht aus $TMPDIR.
function tempRoots() {
  const roots = [];
  try {
    const dir = execFileSync('getconf', ['DARWIN_USER_TEMP_DIR'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    if (dir) roots.push(realpath(dir));
  } catch { /* nur auf macOS vorhanden */ }
  roots.push(realpath(os.tmpdir()));
  return [...new Set(roots)];
}

function developerDir() {
  try {
    return realpath(execFileSync('xcode-select', ['-p'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim());
  } catch {
    return '';
  }
}

function endpointCandidates(udid) {
  const uid = typeof process.getuid === 'function' ? process.getuid() : 0;
  const prefix = `${fnv1a64(udid)}-`;
  const exact = `${prefix}${fnv1a64(developerDir())}-v2.sock`;
  const found = [];
  for (const root of tempRoots()) {
    const dir = path.join(root, `axe-hid-${uid}`);
    found.push(path.join(dir, exact));
    try {
      for (const name of fs.readdirSync(dir)) {
        if (name.startsWith(prefix) && name.endsWith('-v2.sock')) found.push(path.join(dir, name));
      }
    } catch { /* Ordner gibt es erst, wenn ein Broker lief */ }
  }
  return [...new Set(found)];
}

function exchange(socketPath, payload) {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection(socketPath);
    let buffer = '';
    let stage = 'handshake';
    const fail = (err) => { sock.destroy(); reject(err); };
    sock.setTimeout(IO_TIMEOUT_MS, () => fail(new Error('HID-Broker antwortet nicht')));
    sock.on('error', fail);
    sock.on('data', (chunk) => {
      buffer += chunk.toString('utf8');
      let nl;
      while ((nl = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, nl);
        buffer = buffer.slice(nl + 1);
        let msg;
        try { msg = JSON.parse(line); } catch { return fail(new Error('HID-Broker: ungültige Antwort')); }
        if (stage === 'handshake') {
          if (!msg.ready) {
            const err = new Error('HID-Broker nicht bereit');
            err.code = 'NOT_READY';
            return fail(err);
          }
          stage = 'response';
          sock.write(JSON.stringify(payload) + '\n');
        } else {
          stage = 'done';
          sock.end();
          if (msg.error) return reject(new Error(msg.error));
          return resolve();
        }
      }
    });
    sock.on('close', () => {
      if (stage !== 'done') reject(new Error('HID-Broker hat die Verbindung geschlossen'));
    });
  });
}

class HidBroker {
  constructor(udid, { axe = 'axe', log = () => {} } = {}) {
    this.udid = udid;
    this.axe = axe;
    this.log = log;
    this.child = null;
    this.socketPath = null;
    this.pending = [];   // noch nicht gesendete Primitive
    this.busy = false;
    this.waiters = [];
    this.keepalive = setInterval(() => {
      if (!this.busy && this.pending.length === 0) this.send([]).catch(() => {});
    }, KEEPALIVE_MS);
    this.keepalive.unref?.();
  }

  close() {
    clearInterval(this.keepalive);
    if (this.child) this.child.kill();
  }

  // Fügt Primitive an; mehrere Bewegungen, die in der Zwischenzeit kommen, gehen in einer Anfrage.
  send(primitives) {
    return new Promise((resolve, reject) => {
      this.pending.push(...primitives);
      this.waiters.push({ resolve, reject });
      this.pump();
    });
  }

  async pump() {
    if (this.busy) return;
    this.busy = true;
    try {
      while (this.waiters.length) {
        const primitives = this.pending.splice(0);
        const waiters = this.waiters.splice(0);
        try {
          await this.deliver(primitives);
          waiters.forEach((w) => w.resolve());
        } catch (err) {
          waiters.forEach((w) => w.reject(err));
        }
      }
    } finally {
      this.busy = false;
    }
  }

  async deliver(primitives) {
    const payload = { primitives };
    for (let attempt = 0; attempt < 2; attempt++) {
      if (!this.socketPath) await this.start();
      try {
        await exchange(this.socketPath, payload);
        return;
      } catch (err) {
        const gone = err.code === 'ENOENT' || err.code === 'ECONNREFUSED' || err.code === 'NOT_READY';
        if (!gone || attempt === 1) throw err;
        this.log(`HID-Broker neu starten (${err.code})`);
        this.socketPath = null;
      }
    }
  }

  async start() {
    const existing = await this.findLiveSocket();
    if (existing) {
      this.socketPath = existing;
      return;
    }
    if (!this.child || this.child.exitCode !== null) {
      this.child = spawn(this.axe, ['hid-broker', '--udid', this.udid], { stdio: 'ignore' });
      this.child.on('exit', (code) => {
        this.log(`HID-Broker beendet (${code})`);
        this.child = null;
        this.socketPath = null;
      });
      this.child.on('error', (err) => this.log(`HID-Broker startet nicht: ${err.message}`));
    }
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      const live = await this.findLiveSocket();
      if (live) {
        this.socketPath = live;
        return;
      }
      await new Promise((r) => setTimeout(r, 150));
    }
    throw new Error('HID-Broker ließ sich nicht starten');
  }

  async findLiveSocket() {
    for (const candidate of endpointCandidates(this.udid)) {
      if (!fs.existsSync(candidate)) continue;
      try {
        await exchange(candidate, { primitives: [] });
        return candidate;
      } catch { /* veraltet oder nicht bereit */ }
    }
    return null;
  }
}

module.exports = { HidBroker, fnv1a64, endpointCandidates, exchange };
