'use strict';
// Öffnet das Gerätefenster im Browser (Playwright) gegen den Steuer-Server mit nachgebautem Mac,
// zieht mit der Maus, tippt und macht Bildschirmfotos der Oberfläche.
// Aufruf: node test/ui-check.js <Ausgabeordner>

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { chromium } = require('playwright');

const outDir = path.resolve(process.argv[2] || 'ui-out');
fs.mkdirSync(outDir, { recursive: true });
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'uitest-'));
const logFile = path.join(dir, 'mock.log');
fs.writeFileSync(logFile, '');
const token = crypto.randomBytes(24).toString('base64url');
const PORT = 18788;

// Größeres Testbild in iPhone-Proportionen
const { execFileSync } = require('node:child_process');
const fixtures = path.join(__dirname, 'fixtures');
execFileSync('python3', ['-c', `
from PIL import Image, ImageDraw
img = Image.new('RGB', (603, 1311), (240, 240, 245))
d = ImageDraw.Draw(img)
for i in range(24):
    x = 40 + (i % 4) * 140; y = 140 + (i // 4) * 160
    d.rounded_rectangle([x, y, x + 104, y + 104], radius=24, fill=(60 + i * 7, 120, 220 - i * 5))
d.rounded_rectangle([200, 1280, 403, 1290], radius=5, fill=(20, 20, 20))
img.save('${path.join(dir, 'screen.jpg')}', quality=80)
`]);
fs.copyFileSync(path.join(fixtures, 'portrait.jpg'), path.join(dir, 'portrait-backup.jpg'));
fs.copyFileSync(path.join(dir, 'screen.jpg'), path.join(fixtures, 'portrait.jpg'));

const config = {
  session: 'ui',
  authHash: crypto.createHash('sha256').update(token).digest('hex'),
  simDir: dir,
  devices: [{ role: 'iphone', udid: 'UI-1', name: 'PC-iPhone', model: 'iPhone 18 Pro', runtimeName: 'iOS 27.0', scale: 3, pixelWidth: 1206, pixelHeight: 2622 }],
  app: null,
};
fs.writeFileSync(path.join(dir, 'session.json'), JSON.stringify(config));
const server = spawn(process.execPath, [path.join(__dirname, '..', 'server', 'server.js')], {
  env: { ...process.env, PATH: `${path.join(__dirname, 'mock-bin')}:${process.env.PATH}`, MOCK_LOG: logFile, SIM_CONFIG: path.join(dir, 'session.json'), PORT: String(PORT) },
  stdio: 'inherit',
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const mockLog = () => fs.readFileSync(logFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));

async function main() {
  await sleep(800);
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 470, height: 860 } });
  page.on('console', (m) => console.log('[browser]', m.text()));
  const url = `file://${path.join(__dirname, '..', 'desktop', 'renderer', 'device.html')}?role=iphone&url=${encodeURIComponent(`http://127.0.0.1:${PORT}`)}&token=${encodeURIComponent(token)}`;
  await page.goto(url);
  await page.waitForFunction(() => document.querySelector('#overlay').classList.contains('gone'), null, { timeout: 10_000 });
  await sleep(300);
  await page.screenshot({ path: path.join(outDir, 'device-iphone.png') });

  // Ziehen: von oben links nach unten rechts
  const box = await page.locator('#canvas').boundingBox();
  await page.mouse.move(box.x + box.width * 0.2, box.y + box.height * 0.3);
  await page.mouse.down();
  for (let i = 1; i <= 10; i++) await page.mouse.move(box.x + box.width * (0.2 + 0.05 * i), box.y + box.height * (0.3 + 0.03 * i));
  await page.mouse.up();
  // Tippen mit Umlaut
  await page.keyboard.type('Hallo Jürgen');
  await page.keyboard.press('Enter');
  await page.keyboard.press('Control+KeyH');
  await page.mouse.wheel(0, 300);
  await sleep(800);

  const log = mockLog();
  const prims = log.filter((e) => e.cmd === 'hid').flatMap((e) => e.primitives);
  const kinds = prims.map((p) => p.kind);
  const first = prims[0];
  console.log('HID:', kinds.join(','));
  console.log('erster Punkt (pt):', first);
  const typed = log.filter((e) => e.cmd === 'axe' && e.args[0] === 'type').map((e) => e.input);
  const pasted = log.filter((e) => e.cmd === 'xcrun' && e.args[1] === 'pbcopy').map((e) => e.input);
  const buttons = log.filter((e) => e.cmd === 'axe' && e.args[0] === 'button').map((e) => e.args[1]);
  const keys = log.filter((e) => e.cmd === 'axe' && e.args[0] === 'key').map((e) => e.args[1]);
  console.log('getippt:', typed, 'eingefügt:', pasted, 'Tasten:', buttons, 'Keys:', keys);

  const ok = kinds[0] === 'down' && kinds.includes('up') && kinds.filter((k) => k === 'down').length >= 8
    && Math.abs(first.x - 402 * 0.2) < 4 && Math.abs(first.y - 874 * 0.3) < 4
    && pasted.join('').includes('Jürgen') && buttons.includes('home') && keys.includes('40');

  // iPad-Ansicht im Querformat zur Kontrolle der Form
  await page.evaluate(() => {
    window.__testMeta = true;
  });
  await page.setViewportSize({ width: 1100, height: 820 });
  await sleep(300);
  await page.screenshot({ path: path.join(outDir, 'device-iphone-wide.png') });

  await browser.close();
  server.kill();
  fs.copyFileSync(path.join(dir, 'portrait-backup.jpg'), path.join(fixtures, 'portrait.jpg'));
  console.log(ok ? 'UI-Test bestanden' : 'UI-Test FEHLGESCHLAGEN');
  process.exit(ok ? 0 : 1);
}

main().catch((err) => {
  console.error(err);
  server.kill();
  fs.copyFileSync(path.join(dir, 'portrait-backup.jpg'), path.join(fixtures, 'portrait.jpg'));
  process.exit(1);
});
