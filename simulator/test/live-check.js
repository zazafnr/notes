'use strict';
// Selbsttest auf dem echten Cloud-Mac: läuft nur, wenn die Sitzung mit {"selftest": "<Schlüssel>"}
// gestartet wurde. Prüft Bild, Live-Touch (Einstellungen öffnen), Home-Taste, Tippen und Drehen
// über denselben Weg wie die PC-App und legt Bildschirmfotos in $SIM_DIR/selftest ab.

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const WebSocket = require('../server/node_modules/ws');

const token = process.env.SELFTEST_TOKEN;
const simDir = process.env.SIM_DIR || '/tmp/sim';
const out = path.join(simDir, 'selftest');
fs.mkdirSync(out, { recursive: true });
const base = 'http://127.0.0.1:8787';
const auth = { authorization: `Bearer ${token}` };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = [];

function check(name, ok, detail = '') {
  results.push({ name, ok, detail });
  console.log(`${ok ? '✅' : '❌'} ${name}${detail ? ` – ${detail}` : ''}`);
}

function describeUi(udid) {
  try {
    return JSON.parse(execFileSync('axe', ['describe-ui', '--udid', udid], { encoding: 'utf8', timeout: 30_000 }));
  } catch (err) {
    console.log(`describe-ui: ${err.message}`);
    return [];
  }
}

function findLabel(nodes, regex) {
  for (const n of [].concat(nodes || [])) {
    const label = n.AXLabel || n.label || '';
    if (regex.test(label) && n.frame) return n;
    const hit = findLabel(n.children, regex);
    if (hit) return hit;
  }
  return null;
}

function allLabels(nodes, acc = []) {
  for (const n of [].concat(nodes || [])) {
    if (n.AXLabel) acc.push(n.AXLabel);
    allLabels(n.children, acc);
  }
  return acc;
}

async function connect(role) {
  const ws = new WebSocket(`ws://127.0.0.1:8787/ws/${role}?token=${encodeURIComponent(token)}`);
  const state = { frames: 0, last: null, meta: null, ws, messages: [] };
  ws.on('message', (data, isBinary) => {
    if (isBinary) { state.frames++; state.last = data; return; }
    const msg = JSON.parse(data.toString());
    state.messages.push(msg);
    if (msg.t === 'meta') state.meta = msg.device;
  });
  await new Promise((resolve, reject) => { ws.on('open', resolve); ws.on('error', reject); });
  return state;
}

async function tapAt(state, nx, ny) {
  state.ws.send(JSON.stringify({ t: 'touch', p: 'down', x: nx, y: ny }));
  await sleep(80);
  state.ws.send(JSON.stringify({ t: 'touch', p: 'up', x: nx, y: ny }));
}

async function shot(role, name) {
  const res = await fetch(`${base}/api/dev/${role}/screenshot`, { headers: auth });
  fs.writeFileSync(path.join(out, `${name}.png`), Buffer.from(await res.arrayBuffer()));
}

async function testDevice(dev) {
  const role = dev.role;
  const state = await connect(role);
  const start = Date.now();
  while (state.frames < 1 && Date.now() - start < 30_000) await sleep(100);
  // Bildrate messen, während sich etwas bewegt (Wischen zwischen Home-Seiten)
  const before = state.frames;
  const t0 = Date.now();
  for (let k = 0; k < 4; k++) {
    state.ws.send(JSON.stringify({ t: 'touch', p: 'down', x: 0.8, y: 0.5 }));
    for (let i = 1; i <= 20; i++) {
      await sleep(25);
      state.ws.send(JSON.stringify({ t: 'touch', p: 'move', x: 0.8 - 0.03 * i, y: 0.5 }));
    }
    state.ws.send(JSON.stringify({ t: 'touch', p: 'up', x: 0.2, y: 0.5 }));
    await sleep(400);
  }
  const fps = (state.frames - before) / ((Date.now() - t0) / 1000);
  check(`${role}: Bild kommt an`, state.frames >= 1, `${state.meta?.video}, ${state.frames} Bilder, ${state.last?.length ?? 0} Bytes, ${JSON.stringify(state.meta?.frame)}`);
  check(`${role}: flüssiges Bild (≥ 12 Bilder/s bei Bewegung)`, fps >= 12, `${fps.toFixed(1)} Bilder/s`);
  if (state.last) fs.writeFileSync(path.join(out, `${role}-stream.jpg`), state.last);

  // Home, dann das Einstellungen-Symbol suchen und über den Live-Touch-Weg antippen.
  state.ws.send(JSON.stringify({ t: 'button', b: 'home' }));
  await sleep(2000);
  await shot(role, `${role}-1-home`);
  const W = dev.pointWidth;
  const H = dev.pointHeight;
  const icon = findLabel(describeUi(dev.udid), /^(Einstellungen|Settings)$/);
  check(`${role}: Einstellungen-Symbol gefunden`, !!icon, icon ? JSON.stringify(icon.frame) : '');
  if (icon) {
    const f = icon.frame;
    await tapAt(state, (f.x + f.width / 2) / W, (f.y + f.height / 2) / H);
    await sleep(3000);
    await shot(role, `${role}-2-settings`);
    const labels = allLabels(describeUi(dev.udid));
    const opened = labels.some((l) => /^(Allgemein|General|Bildschirmzeit|Screen Time|Datenschutz.*|Privacy.*|WLAN|Wi-Fi)$/.test(l));
    check(`${role}: Antippen öffnet die Einstellungen`, opened, labels.slice(0, 12).join(' | '));

    // Wischen nach oben (Liste scrollen) über move-Ereignisse
    state.ws.send(JSON.stringify({ t: 'touch', p: 'down', x: 0.5, y: 0.75 }));
    for (let i = 1; i <= 15; i++) {
      await sleep(16);
      state.ws.send(JSON.stringify({ t: 'touch', p: 'move', x: 0.5, y: 0.75 - 0.03 * i }));
    }
    state.ws.send(JSON.stringify({ t: 'touch', p: 'up', x: 0.5, y: 0.3 }));
    await sleep(1500);
    await shot(role, `${role}-3-scrolled`);
    const after = allLabels(describeUi(dev.udid));
    check(`${role}: Wischen scrollt die Liste`, after.join('|') !== labels.join('|'), after.slice(0, 8).join(' | '));
  }

  // Suche öffnen (Wischen von der Mitte nach unten auf dem Home-Bildschirm) und tippen
  state.ws.send(JSON.stringify({ t: 'button', b: 'home' }));
  await sleep(1500);
  state.ws.send(JSON.stringify({ t: 'touch', p: 'down', x: 0.5, y: 0.4 }));
  for (let i = 1; i <= 12; i++) {
    await sleep(16);
    state.ws.send(JSON.stringify({ t: 'touch', p: 'move', x: 0.5, y: 0.4 + 0.02 * i }));
  }
  state.ws.send(JSON.stringify({ t: 'touch', p: 'up', x: 0.5, y: 0.64 }));
  await sleep(1500);
  state.ws.send(JSON.stringify({ t: 'text', s: 'Rechner' }));
  await sleep(2500);
  await shot(role, `${role}-4-search`);
  const searchLabels = allLabels(describeUi(dev.udid));
  check(`${role}: Tippen in der Suche`, searchLabels.some((l) => /Rechner|Calculator/.test(l)), searchLabels.slice(0, 10).join(' | '));
  state.ws.send(JSON.stringify({ t: 'button', b: 'home' }));
  await sleep(1000);

  if (role === 'ipad') {
    const res = await fetch(`${base}/api/dev/${role}/rotate`, { method: 'POST', headers: { ...auth, 'content-type': 'application/json' }, body: JSON.stringify({ dir: 'left' }) });
    const body = await res.json();
    await sleep(3000);
    const landscape = state.meta?.frame && (state.meta.frame.w > state.meta.frame.h || Math.abs(state.meta.rotateView) === 90);
    check(`${role}: Drehen ins Querformat`, res.ok && landscape, `${res.status} ${JSON.stringify(body)} frame=${JSON.stringify(state.meta?.frame)} rotateView=${state.meta?.rotateView}`);
    await shot(role, `${role}-5-rotated`);
    if (res.ok) {
      const icon2 = findLabel(describeUi(dev.udid), /^(Einstellungen|Settings)$/);
      if (icon2) {
        const f = icon2.frame;
        await tapAt(state, (f.x + f.width / 2) / H, (f.y + f.height / 2) / W);
        await sleep(3000);
        await shot(role, `${role}-6-rotated-settings`);
        const labels = allLabels(describeUi(dev.udid));
        check(`${role}: Antippen im Querformat trifft`, labels.some((l) => /^(Allgemein|General|WLAN|Wi-Fi)$/.test(l)), labels.slice(0, 8).join(' | '));
      }
      await fetch(`${base}/api/dev/${role}/rotate`, { method: 'POST', headers: { ...auth, 'content-type': 'application/json' }, body: JSON.stringify({ dir: 'right' }) });
    }
  }

  const apps = await (await fetch(`${base}/api/dev/${role}/apps`, { headers: auth })).json();
  check(`${role}: App-Liste`, Array.isArray(apps.apps), JSON.stringify(apps).slice(0, 200));
  state.ws.close();
}

async function main() {
  const info = await (await fetch(`${base}/api/info`, { headers: auth })).json();
  console.log(JSON.stringify(info, null, 2));
  const url = fs.readFileSync(path.join(simDir, 'url'), 'utf8').trim();
  const host = new URL(url).host;
  let remote = false;
  try {
    const ip = execFileSync('dig', ['+short', '@1.1.1.1', host, 'A'], { encoding: 'utf8' }).split('\n').find((l) => /^[0-9.]+$/.test(l));
    remote = !!ip && execFileSync('curl', ['-fsS', '--max-time', '8', '--resolve', `${host}:443:${ip}`, `${url}/healthz`], { encoding: 'utf8' }).includes('ok');
  } catch { /* nicht erreichbar */ }
  check('Tunnel von außen erreichbar', remote, url);
  for (const dev of info.devices) {
    try {
      await testDevice(dev);
    } catch (err) {
      check(`${dev.role}: Test lief durch`, false, err.stack);
    }
  }
  fs.writeFileSync(path.join(out, 'results.json'), JSON.stringify(results, null, 2));
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} Prüfungen bestanden`);
}

main().catch((err) => { console.error(err); process.exitCode = 1; });
