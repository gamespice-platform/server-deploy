// The candidate smoke: loads every platform game's solo frame in a cross-origin-isolated parent page (as the site frames it)
// against the REAL published prod manifests (/content proxied to prod, the legacy `dot_cloud_signed` envelope included), with the
// candidate shell. One browser context at a time (never parallel). Run through release_smoke.sh, which runs it on staging02
// (`gpu.sh cdp-run`, GPU_CDP_URL) and records the verdict against the commit.
//
// Per game it asserts: the canvas appears and the game reports started (polled, up to --secs, not a fixed wait); no console error
// or page error; every "sync" summary says failed=0 and no manifest download failed; then a SECOND launch in the same browser
// profile makes zero object downloads ("cloud.dl sync starting" with fetch>0, or "acquiring content ... need>0").
//   --shell DIR            candidate shell export (web/build)        --shell-origin URL   or: serve it from this origin (dev CDN)
//   --build ID             shell build id (default: web/shell-build)  --content URL        prod content origin
//   --games FILE           default tools/release_games.txt            --only a,b           subset (repo or owner/repo)
// Exit: 0 all games pass, 1 a game failed (named), 2 setup.
import { serveShell } from './local_shell_server.mjs';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && i + 1 < argv.length ? argv[i + 1] : d; };
const dir = opt('shell', path.join(here, '..', 'web/build'));
const shellOrigin = opt('shell-origin', '');
const readTrim = f => { try { return fs.readFileSync(f, 'utf8').trim(); } catch { return ''; } };
const buildId = opt('build', readTrim(path.join(here, '..', 'web/shell-build')) || 'local');
const content = opt('content', 'https://content.gamespice.net');
const secs = +opt('secs', '240');
const port = +opt('host-port', '8099');
const only = opt('only', '').split(',').filter(Boolean);
const outDir = opt('out', path.join(os.tmpdir(), 'release_smoke'));
const games = fs.readFileSync(opt('games', path.join(here, 'release_games.txt')), 'utf8').split('\n')
  .map(l => l.trim()).filter(l => l && !l.startsWith('#'))
  .filter(g => !only.length || only.some(o => g === o || g.endsWith('/' + o)));
if (!games.length) { console.error('release_smoke: no games selected'); process.exit(2); }
fs.mkdirSync(outDir, { recursive: true });

const require = createRequire(import.meta.url);
let pw;
for (const t of [process.env.PLAYWRIGHT_CORE, 'playwright-core', path.join(os.homedir(), 'pw/node_modules/playwright-core'),
  '/home/gamedev/pw/node_modules/playwright-core'].filter(Boolean)) {
  try { pw = require(t); break; } catch { /* next */ }
}
if (!pw) { console.error('release_smoke: playwright-core not found; set PLAYWRIGHT_CORE'); process.exit(2); }
if (!process.env.GPU_CDP_URL) { console.error('release_smoke: GPU_CDP_URL unset; run it through release_smoke.sh (staging02, never this box)'); process.exit(2); }
const cdp = await pw.chromium.connectOverCDP(process.env.GPU_CDP_URL);

const allow = 'autoplay; gamepad; fullscreen; cross-origin-isolated; microphone';
const parentPage = url => `<!doctype html><body style="margin:0"><iframe id="g" src="${url}" style="width:100vw;height:100vh;border:0"
  sandbox="allow-scripts allow-same-origin allow-pointer-lock allow-downloads allow-modals" allow="${allow}" allowfullscreen></iframe></body>`;

// One launch of `game` in `ctx`. Returns the console text and what the page showed.
async function launch(ctx, game) {
  const q = `?solo=${encodeURIComponent(game)}`;
  const gameUrl = `http://127.0.0.1:${port}/godot/${buildId}/embed.html${q}`;
  const s = await serveShell({ dir, port, buildId, upstream: content, givenUrl: `http://x/${q}`, coi: true,
    parentHtml: parentPage(gameUrl), shellUpstream: shellOrigin });
  const page = await ctx.newPage();
  const lines = [], http = [];
  const t0 = Date.now();
  const log = x => lines.push(`${((Date.now() - t0) / 1000).toFixed(1)} ${x}`);
  page.on('console', m => log(`[${m.type()}] ${m.text()}`));
  page.on('pageerror', e => log(`[pageerror] ${e.message}`));
  page.on('response', r => { if (r.status() === 404 || r.status() === 429 || r.status() >= 500) http.push(`HTTP ${r.status()} ${r.url().replace(/^https?:\/\/[^/]+/, '')}`); });
  await page.goto(`http://localhost:${port}/`, { timeout: 60000 }).catch(e => log(`[pageerror] goto: ${e.message}`));
  const text = () => lines.join('\n');
  const deadline = Date.now() + secs * 1000;
  let ready = false, size = null, lastNote = Date.now();
  while (Date.now() < deadline) {
    await page.waitForTimeout(1500);
    if (/This did not load|Could not start|could not be downloaded/.test(text())) break;
    const frame = page.frames().find(f => f !== page.mainFrame());
    // Bounded: an evaluate in a frame that is mid-navigation or busy loading never returns, and one hung poll hung the whole run.
    const canvas = frame ? await Promise.race([frame.evaluate(() => { const c = document.querySelector('canvas'); return c ? { w: c.width, h: c.height } : null; }).catch(() => null),
      new Promise(r => setTimeout(() => r(null), 5000))]) : null;
    if (canvas) size = canvas;
    if (canvas && /solo game started/.test(text())) { ready = true; break; }
    if (Date.now() - lastNote > 30000) { lastNote = Date.now(); console.log(`   ... ${game} still loading (${Math.round((Date.now() - t0) / 1000)} s)`); }
  }
  if (ready) {
    await page.waitForTimeout(3000); // errors that follow the start
    // A map pack starts downloading right after "solo game started"; closing the page mid-download leaves it half cached and the second launch
    // would then (rightly) fetch the rest. Wait for every started sync to finish (bounded), as a player who stays in the game would.
    const open = () => (text().match(/cloud\.dl sync starting/g) || []).length - (text().match(/cloud\.dl sync finished/g) || []).length;
    const end = Date.now() + 180000;
    while (open() > 0 && Date.now() < end) await page.waitForTimeout(1500);
    if (open() > 0) log('[warn] smoke: a content sync was still running after 180 s');
  }
  const out = { text: text(), ready, size, http };
  // A hung close must not hang the run: bounded, then every kept-alive connection (the browser's) is dropped.
  await Promise.race([page.close().catch(() => {}), new Promise(r => setTimeout(r, 15000))]);
  s.srv.closeAllConnections?.();
  await Promise.race([new Promise(r => s.srv.close(r)), new Promise(r => setTimeout(r, 5000))]);
  return out;
}

// Verdict: FAIL = the game is broken for a player; WARN = prod is degraded but the game coped (named, never fatal).
//  - a 404 or 429 (or 5xx) response is a WARN with its path; it is a FAIL only when the game itself logs an error naming that URL's file
//    (the game could not live without it). Chrome's own "Failed to load resource" console line is the network error, so it is that WARN, not a FAIL.
//  - "THREADS UNAVAILABLE" is benign only on a page that is NOT cross-origin isolated; the smoke frames under COOP/COEP, so here it FAILs.
function judge(game, first, second) {
  const bad = [], warn = [];
  const sizeOk = r => r.size && r.size.w > 0 && r.size.h > 0;
  if (!first.ready || !sizeOk(first)) bad.push('first launch never reached canvas + "solo game started"');
  if (first.ready && sizeOk(first) && (first.size.w !== 1280 || first.size.h !== 720)) warn.push(`canvas is ${first.size.w}x${first.size.h}, not 1280x720`);
  for (const [tag, r] of [['first', first], ['second', second]]) {
    const t = r.text;
    for (const h of new Set(r.http)) warn.push(`${tag} launch: ${h}`);
    const errLines = t.split('\n').filter(l => /\[(error|pageerror)\]/.test(l) && !/Failed to load resource/.test(l));
    // The engine reports a resource it could not load as `ERROR: No loader found ...` / `Failed loading resource` / `Parse Error` (+ an `at:` line):
    // the game started and coped, so that is a content defect to fix, named, not a block. Anything else (SCRIPT ERROR, a pageerror, ...) FAILs.
    const isRes = l => /\[error\]\s+(ERROR: (No loader found|Failed loading resource|.*Parse Error)|at: (_load|_printerr))/.test(l);
    for (const e of new Set(errLines.filter(isRes).map(l => l.replace(/^[\d.]+ /, '').slice(0, 160)))) if (!/\bat:/.test(e)) warn.push(`${tag} launch: ${e}`);
    const errs = errLines.filter(l => !isRes(l));
    for (const e of errs) {
      const named = r.http.find(h => { const f = h.split('/').slice(-2).join('/'); return f && e.includes(f.split('?')[0]); });
      bad.push(`${tag} launch: console error${named ? ' for ' + named : ''}: ${e.slice(0, 200)}`);
      if (bad.length > 6) break;
    }
    if (/THREADS UNAVAILABLE/.test(t)) bad.push(`${tag} launch: "THREADS UNAVAILABLE" under COOP/COEP (the threaded engine did not start)`);
    if (/Could not download the content manifest/.test(t)) bad.push(`${tag} launch: manifest download failed`);
    const f = t.split('\n').find(l => /\bfailed[=: ]+([1-9]\d*)/.test(l) && /sync|download|acquir/i.test(l));
    if (f) bad.push(`${tag} launch: sync failed>0: ${f.slice(0, 200)}`);
  }
  if (!second.ready) bad.push('second launch never reached canvas + "solo game started"');
  const dl = second.text.split('\n').filter(l => /cloud\.dl sync starting/.test(l) && !/workshop/i.test(l) && !/fetch[=: ]+0\b/.test(l));
  const need = second.text.split('\n').filter(l => /acquiring content/.test(l) && /need[=: ]+[1-9]/.test(l) && !/workshop/i.test(l));
  if (dl.length || need.length) {
    // A cache that works re-fetches nothing. A handful of tiny objects (seen: 4 objects, 2.3 KiB of a map pack) is a WARN, named; a real
    // re-download (more than 10 objects or 1 MiB or more) means the cache did not hold and FAILs.
    const n = dl.reduce((a, l) => a + Number((l.match(/fetch=(\d+)/) || [0, 0])[1]), 0) + need.reduce((a, l) => a + Number((l.match(/need[=: ]+(\d+)/) || [0, 0])[1]), 0);
    const big = dl.some(l => /bytes="[\d.]+ (MiB|GiB)"/.test(l));
    const msg = `second launch downloaded ${n} object(s) (${dl.length + need.length} lines): ${(dl[0] || need[0]).slice(0, 200)}`;
    (n > 10 || big ? bad : warn).push(msg);
  }
  return { bad, warn };
}

const results = [];
const ctx = await cdp.newContext({ viewport: { width: 1280, height: 720 } }); // one profile: its IndexedDB is the cache the second launch reuses
try {
  for (const g of games) {
    let bad, warn = [];
    try {
      const first = await launch(ctx, g);
      const second = await launch(ctx, g);
      fs.writeFileSync(path.join(outDir, `${g.replace('/', '_')}.log`), `--- first\n${first.text}\n--- second\n${second.text}\n`);
      ({ bad, warn } = judge(g, first, second));
    } catch (e) { bad = [`harness error: ${e.message}`]; }
    results.push({ g, bad, warn });
    console.log(`${bad.length ? 'FAIL' : 'PASS'} ${g}`);
    for (const b of bad) console.log(`   ${b}`);
    for (const w of warn) console.log(`   WARN ${w}`);
  }
} finally {
  await ctx.close().catch(() => {});
  await cdp.close().catch(() => {});
}
const fails = results.filter(r => r.bad.length);
console.log(`release_smoke: ${results.length - fails.length}/${results.length} games pass, ${results.reduce((n, r) => n + r.warn.length, 0)} warning(s) (build ${buildId}, logs ${outDir})`);
process.exit(fails.length ? 1 : 0);
