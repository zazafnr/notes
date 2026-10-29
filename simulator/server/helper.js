'use strict';
// Anbindung an `simhelper` (simulator/runner/simhelper.swift): Video im Minicap-Format und
// Hardware-Ereignisse, die AXe nicht anbietet (Drehen, zwei Finger, Schütteln).

const { spawn } = require('node:child_process');
const fs = require('node:fs');

function available(bin) {
  try {
    fs.accessSync(bin, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// Zerlegt den Minicap-Strom: Kopf (Länge im 2. Byte), danach je Bild 4 Byte Länge (LE) + JPEG.
function minicapParser(onFrame) {
  let buf = Buffer.alloc(0);
  let headerDone = false;
  return (chunk) => {
    buf = buf.length ? Buffer.concat([buf, chunk]) : chunk;
    if (!headerDone) {
      if (buf.length < 2) return;
      const headerSize = buf[1];
      if (buf.length < headerSize) return;
      buf = buf.subarray(headerSize);
      headerDone = true;
    }
    while (buf.length >= 4) {
      const len = buf.readUInt32LE(0);
      if (len > 20_000_000) { buf = Buffer.alloc(0); return; }
      if (buf.length < 4 + len) return;
      onFrame(Buffer.from(buf.subarray(4, 4 + len)));
      buf = buf.subarray(4 + len);
    }
  };
}

class HelperHid {
  constructor(bin, udid, log) {
    this.bin = bin;
    this.udid = udid;
    this.log = log;
    this.proc = null;
    this.ready = null;
    this.waiting = [];
    this.chain = Promise.resolve();
  }

  start() {
    if (this.ready) return this.ready;
    this.ready = new Promise((resolve, reject) => {
      const proc = spawn(this.bin, ['hid', '--udid', this.udid], { stdio: ['pipe', 'pipe', 'pipe'] });
      this.proc = proc;
      let rest = '';
      let isReady = false;
      const timer = setTimeout(() => { if (!isReady) { proc.kill(); reject(new Error('simhelper antwortet nicht')); } }, 30_000);
      proc.stdout.on('data', (d) => {
        const lines = (rest + d.toString()).split('\n');
        rest = lines.pop();
        for (const line of lines) {
          if (!line.trim()) continue;
          let msg;
          try { msg = JSON.parse(line); } catch { continue; }
          if (msg.ready) {
            isReady = true;
            clearTimeout(timer);
            resolve();
            continue;
          }
          const w = this.waiting.shift();
          if (w) (msg.error ? w.reject(new Error(msg.error)) : w.resolve(msg));
        }
      });
      proc.stderr.on('data', (d) => this.log(`simhelper: ${d.toString().trim()}`));
      proc.on('error', (err) => { clearTimeout(timer); reject(err); });
      proc.on('exit', (code) => {
        clearTimeout(timer);
        if (!isReady) reject(new Error(`simhelper beendet (${code})`));
        for (const w of this.waiting.splice(0)) w.reject(new Error('simhelper beendet'));
        this.proc = null;
        this.ready = null;
      });
    });
    return this.ready;
  }

  send(command) {
    const job = this.chain.then(async () => {
      await this.start();
      return new Promise((resolve, reject) => {
        this.waiting.push({ resolve, reject });
        this.proc.stdin.write(JSON.stringify(command) + '\n');
      });
    });
    this.chain = job.catch(() => {});
    return job;
  }

  close() {
    if (this.proc) this.proc.kill();
  }
}

module.exports = { available, minicapParser, HelperHid };
