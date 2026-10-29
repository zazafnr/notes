'use strict';
// USB-HID-Tastencodes für `axe key` / `axe key-combo`. Namen wie KeyboardEvent.key im Browser.

const MOD = { ctrl: 224, shift: 225, alt: 226, cmd: 227 };

const NAMED = {
  Enter: 40, Escape: 41, Backspace: 42, Tab: 43, ' ': 44, Space: 44,
  '-': 45, '=': 46, '[': 47, ']': 48, '\\': 49, ';': 51, "'": 52, '`': 53, ',': 54, '.': 55, '/': 56,
  F1: 58, F2: 59, F3: 60, F4: 61, F5: 62, F6: 63, F7: 64, F8: 65, F9: 66, F10: 67, F11: 68, F12: 69,
  Home: 74, PageUp: 75, Delete: 76, End: 77, PageDown: 78,
  ArrowRight: 79, ArrowLeft: 80, ArrowDown: 81, ArrowUp: 82,
};

function code(name) {
  if (name == null) return null;
  if (Object.prototype.hasOwnProperty.call(NAMED, name)) return NAMED[name];
  if (name.length === 1) {
    const c = name.toLowerCase();
    if (c >= 'a' && c <= 'z') return 4 + c.charCodeAt(0) - 97;
    if (c >= '1' && c <= '9') return 30 + c.charCodeAt(0) - 49;
    if (c === '0') return 39;
  }
  return null;
}

// Strg am PC entspricht Cmd auf dem iPhone/iPad (Kopieren, Einfügen, Alles auswählen …).
function modifiers(mods) {
  const out = [];
  if (mods.ctrl || mods.cmd) out.push(MOD.cmd);
  if (mods.shift) out.push(MOD.shift);
  if (mods.alt) out.push(MOD.alt);
  return out;
}

module.exports = { MOD, code, modifiers };
