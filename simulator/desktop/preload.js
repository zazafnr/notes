'use strict';
// Brücke zwischen Oberfläche und Hauptprozess (GitHub, Dateien, Verbindung zum Mac).

const { contextBridge, ipcRenderer } = require('electron');

async function call(channel, ...args) {
  const res = await ipcRenderer.invoke(channel, ...args);
  if (!res.ok) throw new Error(res.error);
  return res.value;
}

const listeners = ['session:progress', 'session:ready', 'session:failed', 'session:ended', 'device:bye', 'device:toast'];

contextBridge.exposeInMainWorld('sim', {
  getConfig: () => call('config:get'),
  setConfig: (patch) => call('config:set', patch),
  setToken: (token, repo) => call('token:set', { token, repo }),
  branches: () => call('github:branches'),
  start: (opts) => call('session:start', opts),
  stop: () => call('session:stop'),
  session: () => call('session:get'),
  showDevices: () => call('session:show-devices'),
  api: (method, path, body) => call('api', method, path, body),
  upload: (path, file) => call('upload', path, file),
  saveProfile: (p) => call('profile:save', p),
  deleteProfile: (id) => call('profile:delete', id),
  countMedia: (dir) => call('profile:count-media', dir),
  pickFiles: (opts) => call('dialog:files', opts),
  pickFolder: () => call('dialog:folder'),
  screenshot: (role) => call('screenshot', role),
  saveAppData: (role) => call('appdata:save', role),
  loadAppData: (role) => call('appdata:load', role),
  readClipboard: () => call('clipboard:read'),
  writeClipboard: (text) => call('clipboard:write', text),
  openExternal: (url) => call('open-external', url),
  showFile: (file) => call('show-file', file),
  resizeFor: (role, landscape) => call('window:resize-for', { role, landscape }),
  pin: (on) => call('window:pin', on),
  minimize: () => call('window:minimize'),
  close: () => call('window:close'),
  focusLauncher: () => call('launcher:focus'),
  on: (channel, fn) => {
    if (!listeners.includes(channel)) throw new Error(`Unbekanntes Ereignis ${channel}`);
    ipcRenderer.on(channel, (_e, payload) => fn(payload));
  },
});
