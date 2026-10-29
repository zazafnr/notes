'use strict';

const { spawn } = require('node:child_process');

// Führt ein Programm aus und sammelt die Ausgabe. Wirft bei Fehlern, außer mit allowFail.
function run(cmd, args, { input, timeout = 60_000, allowFail = false, cwd, env } = {}) {
  return new Promise((resolve, reject) => {
    const proc = spawn(cmd, args, { cwd, env: env ? { ...process.env, ...env } : process.env });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => proc.kill('SIGKILL'), timeout);
    proc.stdout.on('data', (d) => { stdout += d; });
    proc.stderr.on('data', (d) => { stderr += d; });
    proc.on('error', (err) => {
      clearTimeout(timer);
      if (allowFail) resolve({ code: -1, stdout, stderr: err.message });
      else reject(err);
    });
    proc.on('close', (code) => {
      clearTimeout(timer);
      const result = { code, stdout, stderr };
      if (code !== 0 && !allowFail) {
        const err = new Error(`${cmd} ${args.slice(0, 3).join(' ')} … fehlgeschlagen (${code}): ${stderr.trim().slice(-400)}`);
        err.result = result;
        reject(err);
      } else {
        resolve(result);
      }
    });
    if (input != null) proc.stdin.end(input);
    else proc.stdin.end();
  });
}

// Breite und Höhe aus dem SOF-Abschnitt eines JPEG lesen.
function jpegSize(buf) {
  if (buf.length < 4 || buf[0] !== 0xff || buf[1] !== 0xd8) return null;
  let i = 2;
  while (i + 9 < buf.length) {
    if (buf[i] !== 0xff) { i++; continue; }
    const marker = buf[i + 1];
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { i += 2; continue; }
    const len = buf.readUInt16BE(i + 2);
    const isSof = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
    if (isSof) return { h: buf.readUInt16BE(i + 5), w: buf.readUInt16BE(i + 7) };
    i += 2 + len;
  }
  return null;
}

module.exports = { run, jpegSize };
