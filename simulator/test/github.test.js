'use strict';
// Prüft den Ablauf der PC-App gegen ein nachgebautes GitHub: starten, Lauf finden, Fortschritt,
// bereit, beendet – und die Fehlerfälle.

const assert = require('node:assert/strict');
const { GitHub, SessionWatcher, newCredentials } = require('../desktop/github');

function fakeGitHub(script) {
  const calls = [];
  const state = { tick: 0, ...script.initial };
  const fetchImpl = async (url, opts = {}) => {
    const path = url.replace('https://api.github.com', '');
    calls.push({ method: opts.method || 'GET', path, body: opts.body && JSON.parse(opts.body) });
    const reply = script.route(path, opts, state);
    if (reply === 204) return new Response(null, { status: 204 });
    if (typeof reply === 'number') return new Response(JSON.stringify({ message: 'nope' }), { status: reply });
    return new Response(JSON.stringify(reply), { status: 200 });
  };
  return { gh: new GitHub({ token: 't', repo: 'zazafnr/notes', fetchImpl }), calls, state };
}

function waitEvent(emitter, names, ms = 3000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`kein Ereignis ${names}`)), ms);
    for (const n of names) emitter.once(n, (p) => { clearTimeout(timer); resolve({ name: n, payload: p }); });
  });
}

async function happyPath() {
  const since = Date.now();
  const { gh, calls } = fakeGitHub({
    initial: { polls: 0 },
    route(path, opts, st) {
      if (path.endsWith('/dispatches')) return 204;
      if (path.includes('/contents/.github/workflows/ios-simulator.yml?ref=main')) return 404;
      if (path.includes('/contents/.github/workflows/ios-simulator.yml')) return {};
      if (path === '/repos/zazafnr/notes') return { full_name: 'zazafnr/notes', private: true, default_branch: 'main' };
      if (path.includes('/actions/workflows/ios-simulator.yml/runs')) {
        st.polls++;
        if (st.polls < 2) return { workflow_runs: [] };
        return { workflow_runs: [{ id: 42, display_title: 'iOS-Simulator abc', created_at: new Date(since).toISOString(), html_url: 'https://github.com/run/42', head_sha: 'sha1' }] };
      }
      if (path === '/repos/zazafnr/notes/actions/runs/42') return { status: 'in_progress', created_at: new Date(since).toISOString() };
      if (path.startsWith('/repos/zazafnr/notes/actions/runs/42/jobs')) return { jobs: [{ name: 'session', steps: [{ name: 'App bauen', status: 'in_progress' }] }] };
      if (path.startsWith('/repos/zazafnr/notes/commits/sha1/statuses')) {
        st.statusPolls = (st.statusPolls || 0) + 1;
        if (st.statusPolls < 2) return [{ context: 'ios-sim/abc', state: 'pending', description: 'Baue die App' }, { context: 'ios-sim/anders', state: 'success', target_url: 'https://falsch' }];
        if (st.statusPolls < 4) return [{ context: 'ios-sim/abc', state: 'success', description: 'bereit', target_url: 'https://x.trycloudflare.com/' }];
        return [{ context: 'ios-sim/abc', state: 'failure', description: 'Sitzung beendet' }];
      }
      throw new Error(`unerwartet: ${path}`);
    },
  });

  const ref = await gh.toolRef('');
  assert.equal(ref, 'claude/fervent-noether-7h1twv', 'nimmt den Branch, auf dem der Workflow liegt');
  await gh.dispatch(ref, { session: 'abc' });
  assert.deepEqual(calls.find((c) => c.path.endsWith('/dispatches')).body, { ref, inputs: { session: 'abc' } });

  const w = new SessionWatcher(gh, { ref, session: 'abc', since, interval: 20 });
  const progress = [];
  w.on('progress', (p) => progress.push(p));
  w.start();
  const ready = await waitEvent(w, ['ready', 'failed']);
  assert.equal(ready.name, 'ready');
  assert.equal(ready.payload.url, 'https://x.trycloudflare.com', 'URL ohne Schrägstrich am Ende');
  assert.ok(progress.some((p) => p.text === 'Baue die App' && p.steps[0].name === 'App bauen'));
  const ended = await waitEvent(w, ['ended', 'failed']);
  assert.equal(ended.name, 'ended');
  w.stop();
}

async function failedStart() {
  const since = Date.now();
  const { gh } = fakeGitHub({
    route(path) {
      if (path.includes('/runs?')) return { workflow_runs: [{ id: 7, display_title: 'iOS-Simulator f', created_at: new Date(since).toISOString(), head_sha: 's' }] };
      if (path === '/repos/zazafnr/notes/actions/runs/7') return { status: 'completed', conclusion: 'failure', created_at: new Date(since).toISOString() };
      if (path.includes('/jobs')) return { jobs: [{ name: 'session', steps: [{ name: 'Simulatoren anlegen', status: 'completed', conclusion: 'failure' }] }] };
      if (path.includes('/statuses')) return [{ context: 'ios-sim/f', state: 'error', description: 'Fehler beim Start' }];
      throw new Error(path);
    },
  });
  const w = new SessionWatcher(gh, { ref: 'main', session: 'f', since, interval: 20 }).start();
  const ev = await waitEvent(w, ['ready', 'failed']);
  assert.equal(ev.name, 'failed');
  assert.match(ev.payload.text, /Simulatoren anlegen/);
}

async function errorsExplained() {
  const { gh } = fakeGitHub({ route: () => 401 });
  await assert.rejects(gh.check(), /Token ungültig/);
  const { gh: gh2 } = fakeGitHub({ route: () => 403 });
  await assert.rejects(gh2.branches(), /Berechtigung/);
}

async function main() {
  const c = newCredentials();
  assert.match(c.session, /^[0-9a-f]{12}$/);
  assert.equal(c.authHash.length, 64);
  await happyPath();
  await failedStart();
  await errorsExplained();
  console.log('Alle GitHub-Ablauf-Tests bestanden');
}

main().catch((err) => { console.error(err); process.exit(1); });
