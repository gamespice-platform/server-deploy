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
  const lines = [];
  const t0 = Date.now();
  const log = x => lines.push(`${((Date.now() - t0) / 1000).toFixed(1)} ${x}`);
  page.on('console', m => log(`[${m.type()}] ${m.text()}`));
  page.on('pageerror', e => log(`[pageerror] ${e.message}`));
  await page.goto(`http://localhost:${port}/`);
  const text = () => lines.join('\n');
  const deadline = Date.now() + secs * 1000;
  let ready = false;
  while (Date.now() < deadline) {
    await page.waitForTimeout(1500);
    if (/This did not load|Could not start|could not be downloaded/.test(text())) break;
    const frame = page.frames().find(f => f !== page.mainFrame());
    const canvas = frame ? await frame.evaluate(() => !!document.querySelector('canvas')).catch(() => false) : false;
    if (canvas && /solo game started/.test(text())) { ready = true; break; }
  }
  if (ready) await page.waitForTimeout(3000); // errors that follow the start
  const out = { text: text(), ready };
  await page.close();
  await new Promise(r => s.srv.close(r));
  return out;
}

function judge(game, first, second) {
  const bad = [];
  if (!first.ready) bad.push('first launch never reached canvas + "solo game started"');
  for (const [tag, t] of [['first', first.text], ['second', second.text]]) {
    const errs = t.split('\n').filter(l => /\[(error|pageerror)\]/.test(l)
      && !/favicon|Failed to load resource: the server responded with a status of 404 \(\)$/.test(l));
    if (errs.length) bad.push(`${tag} launch: ${errs.length} console error(s), first: ${errs[0].slice(0, 200)}`);
    if (/Could not download the content manifest/.test(t)) bad.push(`${tag} launch: manifest download failed`);
    const f = t.split('\n').find(l => /\bfailed[=: ]+([1-9]\d*)/.test(l) && /sync|download|acquir/i.test(l));
    if (f) bad.push(`${tag} launch: sync failed>0: ${f.slice(0, 200)}`);
  }
  if (!second.ready) bad.push('second launch never reached canvas + "solo game started"');
  const dl = second.text.split('\n').filter(l => /cloud\.dl sync starting/.test(l) && !/workshop/i.test(l) && !/fetch[=: ]+0\b/.test(l));
  const need = second.text.split('\n').filter(l => /acquiring content/.test(l) && /need[=: ]+[1-9]/.test(l) && !/workshop/i.test(l));
  if (dl.length || need.length) bad.push(`second launch downloaded objects (${dl.length + need.length} lines): ${(dl[0] || need[0]).slice(0, 200)}`);
  return bad;
}

const results = [];
const ctx = await cdp.newContext({ viewport: { width: 1280, height: 720 } }); // one profile: its IndexedDB is the cache the second launch reuses
try {
  for (const g of games) {
    let bad;
    try {
      const first = await launch(ctx, g);
      const second = await launch(ctx, g);
      fs.writeFileSync(path.join(outDir, `${g.replace('/', '_')}.log`), `--- first\n${first.text}\n--- second\n${second.text}\n`);
      bad = judge(g, first, second);
    } catch (e) { bad = [`harness error: ${e.message}`]; }
    results.push({ g, bad });
    console.log(`${bad.length ? 'FAIL' : 'PASS'} ${g}`);
    for (const b of bad) console.log(`   ${b}`);
  }
} finally {
  await ctx.close().catch(() => {});
  await cdp.close().catch(() => {});
}
const fails = results.filter(r => r.bad.length);
console.log(`release_smoke: ${results.length - fails.length}/${results.length} games pass (build ${buildId}, logs ${outDir})`);
process.exit(fails.length ? 1 : 0);
