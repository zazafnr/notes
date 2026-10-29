'use strict';
// Spielt den Steuer-Server mit nachgebautem `axe`/`xcrun` durch (läuft auch unter Linux):
// Anmeldung, Bild-Stream, Live-Touch über den HID-Broker, Tippen, Tasten, Drehen-Koordinaten.

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const WebSocket = require('../server/node_modules/ws');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'simtest-'));
const logFile = path.join(dir, 'mock.log');
fs.writeFileSync(logFile, '');
const token = crypto.randomBytes(24).toString('base64url');
const PORT = 18787;
const config = {
  session: 'test',
  authHash: crypto.createHash('sha256').update(token).digest('hex'),
  simDir: dir,
  devices: [
    { role: 'iphone', udid: 'AAAA-1111', name: 'PC-iPhone', model: 'iPhone 18 Pro', runtimeName: 'iOS 27.0', scale: 3, pixelWidth: 1206, pixelHeight: 2622 },
    { role: 'ipad', udid: 'BBBB-2222', name: 'PC-iPad', model: 'iPad Pro 13-inch (M5)', runtimeName: 'iOS 27.0', scale: 2, pixelWidth: 2064, pixelHeight: 2752 },
  ],
  app: { path: '/tmp/FreeNotes.app', bundle: 'de.freenotes.app', name: 'FreeNotes' },
  deadline: Date.now() + 600_000,
};
fs.writeFileSync(path.join(dir, 'session.json'), JSON.stringify(config));

const env = {
  ...process.env,
  PATH: `${path.join(__dirname, 'mock-bin')}:${process.env.PATH}`,
  MOCK_LOG: logFile,
  SIM_CONFIG: path.join(dir, 'session.json'),
  PORT: String(PORT),
  SIMHELPER: path.join(__dirname, 'mock-bin', 'simhelper'),
};
const server = spawn(process.execPath, [path.join(__dirname, '..', 'server', 'server.js')], { env, stdio: ['ignore', 'pipe', 'pipe'] });
let serverOut = '';
server.stdout.on('data', (d) => { serverOut += d; });
server.stderr.on('data', (d) => { serverOut += d; });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const base = `http://127.0.0.1:${PORT}`;
const auth = { authorization: `Bearer ${token}` };

function mockLog() {
  return fs.readFileSync(logFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
}

async function waitFor(fn, what, ms = 8000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const v = await fn();
    if (v) return v;
    await sleep(50);
  }
  throw new Error(`Zeitüberschreitung: ${what}\n${serverOut}`);
}

async function main() {
  await waitFor(async () => (await fetch(`${base}/healthz`).catch(() => null))?.ok, 'Server startet');

  // Ohne Schlüssel kein Zugriff
  assert.equal((await fetch(`${base}/api/info`)).status, 401);
  assert.equal((await fetch(`${base}/api/info`, { headers: { authorization: 'Bearer falsch' } })).status, 401);
  const info = await (await fetch(`${base}/api/info`, { headers: auth })).json();
  assert.equal(info.devices.length, 2);
  assert.equal(info.devices[0].pointWidth, 402);
  assert.equal(info.devices[0].pointHeight, 874);

  // WebSocket ohne Schlüssel wird abgelehnt
  await assert.rejects(new Promise((resolve, reject) => {
    const bad = new WebSocket(`ws://127.0.0.1:${PORT}/ws/iphone`);
    bad.on('open', resolve);
    bad.on('error', reject);
  }));

  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws/iphone?token=${token}`);
  const frames = [];
  const messages = [];
  ws.on('message', (data, isBinary) => {
    if (isBinary) frames.push(data);
    else messages.push(JSON.parse(data.toString()));
  });
  await new Promise((r) => ws.on('open', r));
  await waitFor(() => messages.find((m) => m.t === 'meta'), 'Meta-Nachricht');
  await waitFor(() => frames.length >= 1, 'erstes Bild');
  assert.equal(frames[0][0], 0xff);
  assert.equal(frames[0][1], 0xd8);
  await waitFor(() => messages.find((m) => m.t === 'meta' && m.device.frame), 'Bildgröße');
  const meta = messages.filter((m) => m.t === 'meta').pop();
  assert.deepEqual(meta.device.frame, { w: 40, h: 80 });
  // Gleiches Bild wird nicht doppelt geschickt
  await sleep(400);
  assert.equal(frames.length, 1, 'unveränderte Bilder werden ausgelassen');

  // Live-Touch: down, zwei Bewegungen, up → beim Broker als down, down, down, up
  const send = (m) => ws.send(JSON.stringify(m));
  send({ t: 'touch', p: 'down', x: 0.5, y: 0.5 });
  send({ t: 'touch', p: 'move', x: 0.55, y: 0.6 });
  send({ t: 'touch', p: 'move', x: 0.6, y: 0.7 });
  send({ t: 'touch', p: 'up', x: 0.6, y: 0.7 });
  const touches = await waitFor(() => {
    const prims = mockLog().filter((e) => e.cmd === 'hid' && e.udid === 'AAAA-1111').flatMap((e) => e.primitives);
    return prims.length >= 4 ? prims : null;
  }, 'Touch beim HID-Broker');
  assert.deepEqual(touches.map((p) => p.kind), ['down', 'down', 'down', 'up']);
  assert.equal(touches[0].x, 201);
  assert.equal(touches[0].y, 437);
  assert.ok(Math.abs(touches[3].x - 241.2) < 0.01);

  // Bewegung ohne vorheriges down wird ignoriert
  send({ t: 'touch', p: 'move', x: 0.1, y: 0.1 });

  // Tippen: ASCII direkt, Umlaute über Zwischenablage + Cmd+V
  send({ t: 'text', s: 'Hallo ' });
  send({ t: 'text', s: 'Welt' });
  await waitFor(() => mockLog().find((e) => e.cmd === 'axe' && e.args[0] === 'type'), 'Tippen');
  const typed = mockLog().filter((e) => e.cmd === 'axe' && e.args[0] === 'type');
  assert.equal(typed.length, 1, 'Text wird gebündelt');
  assert.equal(typed[0].input, 'Hallo Welt');
  send({ t: 'text', s: 'Grüße' });
  await waitFor(() => mockLog().find((e) => e.cmd === 'axe' && e.args[0] === 'key-combo'), 'Einfügen');
  assert.equal(mockLog().find((e) => e.cmd === 'xcrun' && e.args[1] === 'pbcopy').input, 'Grüße');
  const combo = mockLog().find((e) => e.cmd === 'axe' && e.args[0] === 'key-combo');
  assert.deepEqual(combo.args.slice(0, 5), ['key-combo', '--modifiers', '227', '--key', '25']);

  // Tasten
  send({ t: 'key', k: 'Enter', mods: {} });
  send({ t: 'key', k: 'a', mods: { ctrl: true } });
  send({ t: 'button', b: 'home' });
  send({ t: 'button', b: 'lock', long: true });
  await waitFor(() => mockLog().filter((e) => e.cmd === 'axe' && e.args[0] === 'button').length >= 2, 'Tasten');
  const log = mockLog();
  const order = log.filter((e) => e.cmd === 'axe' && ['type', 'key', 'key-combo', 'button'].includes(e.args[0])).map((e) => e.args[0] + (e.args[0] === 'key' ? e.args[1] : ''));
  assert.deepEqual(order, ['type', 'key-combo', 'key40', 'key-combo', 'button', 'button'], 'Reihenfolge bleibt erhalten');
  assert.ok(log.find((e) => e.cmd === 'axe' && e.args[0] === 'key' && e.args[1] === '40'), 'Enter = 40');
  assert.ok(log.find((e) => e.cmd === 'axe' && e.args[0] === 'key-combo' && e.args[2] === '227' && e.args[4] === '4'), 'Strg+A = Cmd+A');
  assert.ok(log.find((e) => e.cmd === 'axe' && e.args[0] === 'button' && e.args[1] === 'home'));
  assert.ok(log.find((e) => e.cmd === 'axe' && e.args[0] === 'button' && e.args[1] === 'lock' && e.args.includes('--duration')));

  // App-Umschalter = Wischen vom unteren Rand mit Halten
  send({ t: 'button', b: 'app-switcher' });
  await waitFor(() => mockLog().filter((e) => e.cmd === 'hid').some((e) => e.primitives.some((p) => p.kind === 'delay' && p.duration >= 0.5)), 'App-Umschalter');

  // Mausrad
  send({ t: 'wheel', x: 0.5, y: 0.5, dx: 0, dy: 0.2 });
  await waitFor(() => mockLog().filter((e) => e.cmd === 'hid').some((e) => {
    const last = e.primitives[e.primitives.length - 1];
    return last.kind === 'up' && Math.abs(last.y - 874 * 0.3) < 0.01;
  }), 'Mausrad wischt nach oben');

  // Ping
  send({ t: 'ping', id: 7 });
  await waitFor(() => messages.find((m) => m.t === 'pong' && m.id === 7), 'Pong');

  // HTTP-Befehle
  const post = (p, body) => fetch(`${base}${p}`, { method: 'POST', headers: { ...auth, 'content-type': 'application/json' }, body: JSON.stringify(body) });
  assert.equal((await post('/api/dev/iphone/appearance', { mode: 'dark' })).status, 200);
  assert.ok(mockLog().find((e) => e.cmd === 'xcrun' && e.args.join(' ') === 'simctl ui AAAA-1111 appearance dark'));
  assert.equal((await post('/api/dev/alle/appearance', { mode: 'light' })).status, 200);
  assert.ok(mockLog().find((e) => e.cmd === 'xcrun' && e.args.join(' ') === 'simctl ui BBBB-2222 appearance light'));
  assert.equal((await post('/api/dev/iphone/openurl', { url: 'https://apple.com' })).status, 200);
  assert.equal((await post('/api/dev/handy/openurl', { url: 'x' })).status, 404);
  const clip = await (await fetch(`${base}/api/dev/iphone/clipboard`, { headers: auth })).json();
  assert.equal(clip.text, 'vom iPhone kopiert');
  const shot = await fetch(`${base}/api/dev/iphone/screenshot`, { headers: auth });
  assert.equal(shot.headers.get('content-type'), 'image/png');
  const media = await fetch(`${base}/api/dev/iphone/media?name=../../urlaub.jpg`, { method: 'POST', headers: auth, body: fs.readFileSync(path.join(__dirname, 'fixtures', 'portrait.jpg')) });
  assert.equal(media.status, 200);
  const add = mockLog().find((e) => e.cmd === 'xcrun' && e.args[1] === 'addmedia');
  assert.equal(path.basename(add.args[3]), 'urlaub.jpg', 'Dateiname ohne Pfadanteile');

  // Video kommt über simhelper (Minicap), nicht über AXe-Einzelbilder
  assert.ok(mockLog().find((e) => e.cmd === 'simhelper-stream' && e.udid === 'AAAA-1111'), 'simhelper-Video läuft');
  assert.ok(!mockLog().find((e) => e.cmd === 'axe' && e.args[0] === 'stream-video'), 'keine AXe-Einzelbilder nötig');

  // Drehen über simhelper: Ausrichtung als HID-Ereignis, Bild bleibt hochkant → Anzeige wird gedreht
  const rot = await post('/api/dev/iphone/rotate', { dir: 'left' });
  assert.equal(rot.status, 200);
  assert.deepEqual(await rot.json(), { orientation: 'landscapeFlipped' });
  assert.ok(mockLog().find((e) => e.cmd === 'simhelper-hid' && e.command.op === 'orientation' && e.command.value === 'landscapeLeft'));
  await waitFor(() => messages.find((m) => m.t === 'meta' && m.device.orientation === 'landscapeFlipped' && m.device.rotateView === -90), 'Anzeige -90° drehen');
  // Tippen oben links in der gedrehten Anzeige = oben rechts im Hochformat
  send({ t: 'touch', p: 'down', x: 0, y: 0 });
  send({ t: 'touch', p: 'up', x: 0, y: 0 });
  await waitFor(() => mockLog().filter((e) => e.cmd === 'hid').some((e) => e.primitives.some((p) => p.kind === 'up' && p.x === 402 && p.y === 0)), 'Touch im Querformat');
  const back = await post('/api/dev/iphone/rotate', { dir: 'right' });
  assert.deepEqual(await back.json(), { orientation: 'portrait' });

  // Zwei Finger (Alt+Ziehen) und Zoom (Strg+Mausrad)
  send({ t: 'pinch', p: 'down', x: 0.4, y: 0.4 });
  send({ t: 'pinch', p: 'move', x: 0.3, y: 0.3 });
  send({ t: 'pinch', p: 'up', x: 0.3, y: 0.3 });
  send({ t: 'zoom', x: 0.5, y: 0.5, scale: 1.5 });
  send({ t: 'button', b: 'shake' });
  await waitFor(() => mockLog().some((e) => e.cmd === 'simhelper-hid' && e.command.op === 'shake'), 'Schütteln');
  const two = mockLog().filter((e) => e.cmd === 'simhelper-hid' && e.command.op === 'two').map((e) => e.command);
  assert.deepEqual(two.map((c) => c.dir), ['down', 'down', 'up']);
  assert.ok(Math.abs(two[0].x1 - 402 * 0.4) < 0.01 && Math.abs(two[0].x2 - 402 * 0.6) < 0.01, 'zweiter Finger gespiegelt');
  assert.ok(mockLog().some((e) => e.cmd === 'simhelper-hid' && e.command.op === 'pinch' && e.command.scale === 1.5));

  // Drehen-Koordinaten: Querformat-Bild → Touch wird ins Hochformat umgerechnet
  const { Device } = require('../server/device');
  const dev = new Device(config.devices[0], { axe: 'axe', log: () => {} });
  dev.orientation = 'landscapeFlipped'; // »Rotate Left«
  assert.deepEqual(dev.toPhysical(0, 0), { x: 402, y: 0 });
  assert.deepEqual(dev.toPhysical(1, 1), { x: 0, y: 874 });
  dev.orientation = 'landscape';
  assert.deepEqual(dev.toPhysical(0, 0), { x: 0, y: 874 });
  dev.close();

  ws.close();
  await post('/api/shutdown', {});
  await waitFor(() => server.exitCode !== null, 'Server endet');
  console.log('Alle Server-Tests bestanden');
}

main().then(() => {
  fs.rmSync(dir, { recursive: true, force: true });
  process.exit(0);
}, (err) => {
  console.error(err);
  console.error('--- Server-Ausgabe ---\n' + serverOut);
  server.kill();
  process.exit(1);
});
