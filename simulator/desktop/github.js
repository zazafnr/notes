'use strict';
// Startet und beobachtet eine Simulator-Sitzung über die GitHub-API (ohne Electron, damit testbar).
//
// Ablauf: Workflow »iOS-Simulator« per workflow_dispatch starten → Lauf anhand des Titels finden →
// Commit-Status »ios-sim/<Sitzung>« lesen: pending = Fortschritt, success = bereit (URL im Status),
// error = Start fehlgeschlagen, failure = Sitzung beendet.

const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');

const WORKFLOW = 'ios-simulator.yml';
const API = 'https://api.github.com';

class GitHub {
  constructor({ token, repo, fetchImpl = fetch, api = API }) {
    this.token = token;
    this.repo = repo;
    this.fetch = fetchImpl;
    this.api = api;
  }

  async request(method, path, body) {
    const res = await this.fetch(`${this.api}${path}`, {
      method,
      headers: {
        authorization: `Bearer ${this.token}`,
        accept: 'application/vnd.github+json',
        'x-github-api-version': '2022-11-28',
        ...(body ? { 'content-type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (res.status === 204) return null;
    const text = await res.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = { message: text }; }
    if (!res.ok) {
      const err = new Error(explain(res.status, data?.message || res.statusText, path));
      err.status = res.status;
      throw err;
    }
    return data;
  }

  repoPath(p) { return `/repos/${this.repo}${p}`; }

  async check() {
    const repo = await this.request('GET', this.repoPath(''));
    return { name: repo.full_name, private: repo.private, defaultBranch: repo.default_branch };
  }

  async branches() {
    const out = [];
    for (let page = 1; page <= 5; page++) {
      const list = await this.request('GET', this.repoPath(`/branches?per_page=100&page=${page}`));
      out.push(...list.map((b) => b.name));
      if (list.length < 100) break;
    }
    return out;
  }

  // Branch, auf dem der Simulator-Workflow liegt: bevorzugt der Standard-Branch.
  async toolRef(preferred) {
    const candidates = [preferred, (await this.check()).defaultBranch, 'claude/fervent-noether-7h1twv'].filter(Boolean);
    for (const ref of [...new Set(candidates)]) {
      try {
        await this.request('GET', this.repoPath(`/contents/.github/workflows/${WORKFLOW}?ref=${encodeURIComponent(ref)}`));
        return ref;
      } catch (err) {
        if (err.status !== 404) throw err;
      }
    }
    throw new Error('Der Workflow ».github/workflows/ios-simulator.yml« fehlt im Repo.');
  }

  dispatch(ref, inputs) {
    return this.request('POST', this.repoPath(`/actions/workflows/${WORKFLOW}/dispatches`), { ref, inputs });
  }

  async findRun(ref, session, since) {
    const runs = await this.request('GET', this.repoPath(`/actions/workflows/${WORKFLOW}/runs?event=workflow_dispatch&branch=${encodeURIComponent(ref)}&per_page=20`));
    return (runs.workflow_runs || []).find((r) => r.display_title === `iOS-Simulator ${session}` && Date.parse(r.created_at) >= since - 120_000) || null;
  }

  run(id) { return this.request('GET', this.repoPath(`/actions/runs/${id}`)); }
  jobs(id) { return this.request('GET', this.repoPath(`/actions/runs/${id}/jobs?per_page=10`)); }
  cancel(id) { return this.request('POST', this.repoPath(`/actions/runs/${id}/cancel`)); }

  async sessionStatus(sha, session) {
    const list = await this.request('GET', this.repoPath(`/commits/${sha}/statuses?per_page=100`));
    return (list || []).find((s) => s.context === `ios-sim/${session}`) || null; // neuester zuerst
  }
}

function explain(status, message, path) {
  if (status === 401) return 'GitHub-Token ungültig oder abgelaufen.';
  if (status === 403 && /rate limit/i.test(message)) return 'GitHub-Anfragelimit erreicht, bitte kurz warten.';
  if (status === 403) return `Dem GitHub-Token fehlt eine Berechtigung (${message}). Nötig: Actions (Lesen & Schreiben), Commit statuses (Lesen), Contents (Lesen).`;
  if (status === 404 && path.includes('/dispatches')) return 'Workflow nicht gefunden – liegt ».github/workflows/ios-simulator.yml« auf dem Branch?';
  if (status === 404) return `Nicht gefunden (${path}). Stimmt das Repo und darf das Token es lesen?`;
  if (status === 422) return `GitHub lehnt den Start ab: ${message}`;
  return `GitHub-Fehler ${status}: ${message}`;
}

function newCredentials() {
  const session = crypto.randomBytes(6).toString('hex');
  const token = crypto.randomBytes(32).toString('base64url');
  const authHash = crypto.createHash('sha256').update(token).digest('hex');
  return { session, token, authHash };
}

// Beobachtet eine laufende Sitzung und meldet Fortschritt als Ereignisse:
// 'progress' {phase, text, steps, runUrl}, 'ready' {url}, 'failed' {text}, 'ended' {text}
class SessionWatcher extends EventEmitter {
  constructor(gh, { ref, session, since, interval = 4000, queueWarnMs = 240_000 }) {
    super();
    this.gh = gh;
    this.ref = ref;
    this.session = session;
    this.since = since;
    this.interval = interval;
    this.queueWarnMs = queueWarnMs;
    this.runId = null;
    this.sha = null;
    this.state = 'searching';
    this.stopped = false;
    this.errors = 0;
  }

  start() {
    this.tick();
    return this;
  }

  stop() {
    this.stopped = true;
    clearTimeout(this.timer);
  }

  schedule() {
    if (!this.stopped) this.timer = setTimeout(() => this.tick(), this.interval);
  }

  async tick() {
    try {
      await this.poll();
      this.errors = 0;
    } catch (err) {
      this.errors++;
      this.emit('progress', { phase: this.state, text: `Verbindung zu GitHub gestört: ${err.message}` });
      if (this.errors > 8) {
        this.state = 'failed';
        this.emit('failed', { text: err.message });
        return;
      }
    }
    if (!['failed', 'ended'].includes(this.state)) this.schedule();
  }

  async poll() {
    if (!this.runId) {
      const run = await this.gh.findRun(this.ref, this.session, this.since);
      if (!run) {
        if (Date.now() - this.since > 90_000) {
          this.state = 'failed';
          this.emit('failed', { text: 'Der GitHub-Lauf ist nicht aufgetaucht. Sind GitHub Actions für das Repo aktiviert?' });
        } else {
          this.emit('progress', { phase: 'searching', text: 'Warte auf GitHub …' });
        }
        return;
      }
      this.runId = run.id;
      this.runUrl = run.html_url;
      this.sha = run.head_sha;
    }

    const run = await this.gh.run(this.runId);
    const status = this.sha ? await this.gh.sessionStatus(this.sha, this.session) : null;
    let steps = [];
    if (run.status !== 'queued') {
      const jobs = await this.gh.jobs(this.runId).catch(() => null);
      const job = jobs?.jobs?.find((j) => j.name === 'session') || jobs?.jobs?.[0];
      steps = (job?.steps || []).map((s) => ({ name: s.name, status: s.status, conclusion: s.conclusion }));
    }

    if (status?.state === 'success' && status.target_url && this.state !== 'ready') {
      this.state = 'ready';
      this.emit('ready', { url: status.target_url.replace(/\/+$/, ''), runUrl: this.runUrl, runId: this.runId });
      return;
    }
    if (status?.state === 'failure' || (run.status === 'completed' && this.state === 'ready')) {
      this.state = 'ended';
      this.emit('ended', { text: status?.description || 'Sitzung beendet' });
      return;
    }
    if (status?.state === 'error' || (run.status === 'completed' && this.state !== 'ready')) {
      const failedStep = steps.find((s) => s.conclusion === 'failure');
      const reason = run.conclusion === 'cancelled' ? 'abgebrochen'
        : failedStep ? `Schritt »${failedStep.name}« ist fehlgeschlagen` : (status?.description || run.conclusion || 'unbekannt');
      this.state = 'failed';
      this.emit('failed', { text: `Start fehlgeschlagen: ${reason}`, runUrl: this.runUrl });
      return;
    }
    if (this.state === 'ready') return;

    if (run.status === 'queued') {
      const waited = Date.now() - Date.parse(run.created_at);
      this.state = 'queued';
      this.emit('progress', {
        phase: 'queued',
        text: waited > this.queueWarnMs
          ? 'Warte noch auf einen freien Mac. Bei iOS 27 (Vorschau-Mac) kann das dauern – sonst iOS 26 wählen.'
          : 'Warte auf einen freien Cloud-Mac …',
        steps,
        runUrl: this.runUrl,
      });
      return;
    }
    this.state = 'starting';
    this.emit('progress', { phase: 'starting', text: status?.description || 'Cloud-Mac startet …', steps, runUrl: this.runUrl });
  }
}

module.exports = { GitHub, SessionWatcher, newCredentials, WORKFLOW };
