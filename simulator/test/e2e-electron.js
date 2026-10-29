'use strict';
// Kompletter Ablauf in der echten PC-App (Electron, über Playwright) gegen ein nachgebautes GitHub
// und einen nachgebauten Mac: Token eintragen → Starten → Fortschritt → Gerätefenster mit Bild →
// Finger-Eingabe → Beenden.
// Aufruf (Linux ohne Bildschirm): xvfb-run -a node test/e2e-electron.js <Ausgabeordner>

const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { _electron: electron } = require('playwright');

const outDir = path.resolve(process.argv[2] || 'e2e-out');
fs.mkdirSync(outDir, { recursive: true });
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'e2e-'));
const logFile = path.join(work, 'mock.log');
fs.writeFileSync(logFile, '');
const MAC_PORT = 18790;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let macServer = null;
let session = null; // { id, inputs, polls }

function startMac(authHash) {
  const config = {
    session: session.id,
    authHash,
    simDir: work,
    devices: [
      { role: 'iphone', udid: 'E2E-1', name: 'PC-iPhone', model: 'iPhone 18 Pro', runtimeName: 'iOS 27.0', scale: 3, pixelWidth: 1206, pixelHeight: 2622 },
      { role: 'ipad', udid: 'E2E-2', name: 'PC-iPad', model: 'iPad Pro 13-inch (M5)', runtimeName: 'iOS 27.0', scale: 2, pixelWidth: 2064, pixelHeight: 2752 },
    ],
    app: { path: '/tmp/FreeNotes.app', bundle: 'de.freenotes.app', name: 'FreeNotes' },
    deadline: Date.now() + 3_600_000,
  };
  fs.writeFileSync(path.join(work, 'session.json'), JSON.stringify(config));
  macServer = spawn(process.execPath, [path.join(__dirname, '..', 'server', 'server.js')], {
    env: {
      ...process.env,
      PATH: `${path.join(__dirname, 'mock-bin')}:${process.env.PATH}`,
      MOCK_LOG: logFile,
      SIM_CONFIG: path.join(work, 'session.json'),
      PORT: String(MAC_PORT),
      SIMHELPER: path.join(__dirname, 'mock-bin', 'simhelper'),
    },
    stdio: 'inherit',
  });
}

// Nachgebautes GitHub: nur die Pfade, die die PC-App benutzt.
const gh = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  const json = (status, body) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
  let body = '';
  for await (const chunk of req) body += chunk;
  if (p === '/repos/zazafnr/notes') return json(200, { full_name: 'zazafnr/notes', private: true, default_branch: 'main' });
  if (p === '/repos/zazafnr/notes/branches') return json(200, [{ name: 'main' }, { name: 'claude/chat-ios-notizbuch-ki-yx5ny3' }]);
  if (p.startsWith('/repos/zazafnr/notes/contents/.github/workflows/')) return json(200, {});
  if (p.endsWith('/dispatches')) {
    const { inputs } = JSON.parse(body);
    session = { id: inputs.session, inputs, polls: 0, created: new Date().toISOString() };
    res.writeHead(204);
    return res.end();
  }
  if (p.endsWith('/actions/workflows/ios-simulator.yml/runs')) {
    return json(200, { workflow_runs: session ? [{ id: 99, display_title: `iOS-Simulator ${session.id}`, created_at: session.created, html_url: 'https://github.com/x/runs/99', head_sha: 'abc' }] : [] });
  }
  if (p === '/repos/zazafnr/notes/actions/runs/99') return json(200, { status: session.ended ? 'completed' : 'in_progress', conclusion: session.ended ? 'success' : null, created_at: session.created });
  if (p === '/repos/zazafnr/notes/actions/runs/99/cancel') { session.ended = true; return json(202, {}); }
  if (p.startsWith('/repos/zazafnr/notes/actions/runs/99/jobs')) {
    const n = session.polls;
    const steps = ['Simulatoren anlegen', 'App bauen', 'Auf Simulatoren warten', 'Sitzung öffnen'].map((name, i) => ({
      name, status: i < n ? 'completed' : i === n ? 'in_progress' : 'queued', conclusion: i < n ? 'success' : null,
    }));
    return json(200, { jobs: [{ name: 'session', steps }] });
  }
  if (p === '/repos/zazafnr/notes/commits/abc/statuses') {
    session.polls++;
    if (session.ended) return json(200, [{ context: `ios-sim/${session.id}`, state: 'failure', description: 'Sitzung beendet' }]);
    if (session.polls < 3) return json(200, [{ context: `ios-sim/${session.id}`, state: 'pending', description: session.polls === 1 ? 'Baue die App (FreeNotes)' : 'Starte iPhone/iPad' }]);
    if (!macServer) startMac(session.inputs.auth_hash);
    return json(200, [{ context: `ios-sim/${session.id}`, state: 'success', description: 'bereit', target_url: `http://127.0.0.1:${MAC_PORT}/` }]);
  }
  json(404, { message: `unbekannt ${p}` });
});

async function main() {
  await new Promise((r) => gh.listen(0, '127.0.0.1', r));
  const ghUrl = `http://127.0.0.1:${gh.address().port}`;
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'e2e-home-'));
  const desktop = path.join(__dirname, '..', 'desktop');
  const app = await electron.launch({
    executablePath: path.join(desktop, 'node_modules', 'electron', 'dist', 'electron'),
    args: [desktop, '--no-sandbox', '--disable-gpu'],
    env: { ...process.env, HOME: home, SIM_GITHUB_API: ghUrl },
  });
  const errors = [];
  app.on('window', (w) => {
    w.on('pageerror', (e) => errors.push(`${w.url()}: ${e.message}`));
    w.on('console', (m) => { if (m.type() === 'error') errors.push(`${w.url()}: ${m.text()}`); });
  });
  const win = await app.firstWindow();
  win.on('pageerror', (e) => errors.push(e.message));

  await win.waitForSelector('#setup:not(.hidden)');
  await win.fill('#token', 'github_pat_test');
  await win.click('#btn-token');
  await win.waitForSelector('#start:not(.hidden)');
  await win.waitForFunction(() => document.querySelectorAll('#app-ref option').length > 1);
  await win.screenshot({ path: path.join(outDir, '1-start.png') });

  await win.click('#btn-start');
  await win.waitForSelector('#progress:not(.hidden)');
  await win.waitForFunction(() => document.querySelectorAll('#progress-steps li').length > 0, null, { timeout: 20_000 });
  await win.screenshot({ path: path.join(outDir, '2-progress.png') });

  await win.waitForSelector('#running:not(.hidden)', { timeout: 40_000 });
  // Zwei Gerätefenster gehen auf
  const deadline = Date.now() + 15_000;
  while (app.windows().length < 3 && Date.now() < deadline) await sleep(200);
  const deviceWins = app.windows().filter((w) => w.url().includes('device.html'));
  if (deviceWins.length !== 2) throw new Error(`erwartet 2 Gerätefenster, sind ${deviceWins.length}`);
  await win.screenshot({ path: path.join(outDir, '3-running.png') });

  const phone = deviceWins.find((w) => w.url().includes('role=iphone'));
  await phone.waitForFunction(() => document.querySelector('#overlay').classList.contains('gone'), null, { timeout: 15_000 });
  await phone.screenshot({ path: path.join(outDir, '4-iphone.png') });
  const box = await phone.locator('#canvas').boundingBox();
  await phone.mouse.move(box.x + box.width * 0.5, box.y + box.height * 0.5);
  await phone.mouse.down();
  await phone.mouse.move(box.x + box.width * 0.5, box.y + box.height * 0.3, { steps: 8 });
  await phone.mouse.up();
  await phone.keyboard.type('Hallo');
  await sleep(800);
  const log = fs.readFileSync(logFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const touches = log.filter((e) => e.cmd === 'hid' && e.udid === 'E2E-1').flatMap((e) => e.primitives.map((x) => x.kind));
  const typed = log.filter((e) => e.cmd === 'axe' && e.args[0] === 'type').map((e) => e.input);
  console.log('Touches:', touches.join(','), '| getippt:', typed);
  if (!touches.includes('down') || !touches.includes('up') || !typed.includes('Hallo')) throw new Error('Eingaben kamen nicht an');

  const pad = deviceWins.find((w) => w.url().includes('role=ipad'));
  await pad.waitForFunction(() => document.querySelector('#overlay').classList.contains('gone'), null, { timeout: 15_000 });
  await pad.click('[data-act="rotate-left"]');
  await sleep(800);
  await pad.screenshot({ path: path.join(outDir, '5-ipad-gedreht.png') });

  await win.click('#btn-stop');
  await win.waitForSelector('#start:not(.hidden)', { timeout: 30_000 });
  console.log('Meldung nach Ende:', await win.textContent('#start-msg'));
  await win.screenshot({ path: path.join(outDir, '6-ende.png') });
  await app.close();
  gh.close();
  if (macServer && macServer.exitCode === null) macServer.kill();
  if (errors.length) {
    console.log('Fehler in den Fenstern:', errors);
    process.exit(1);
  }
  console.log('E2E-Test in der PC-App bestanden');
  process.exit(0);
}

main().catch((err) => {
  console.error(err);
  if (macServer) macServer.kill();
  process.exit(1);
});
