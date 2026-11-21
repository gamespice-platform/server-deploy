// Which engine does embed.html run, and does the game reach "playing" on it, in four ways of being served.
//
//   node tools/browser_threads_check.mjs --serve web/build [--game gamemann/game-hungario] [--only a,b] [--secs 300]
//   gpu.sh cdp-run --serve 8097 --port 9222 -- node tools/browser_threads_check.mjs --serve web/build --host-port 8097   (real GPU)
//
//   top-coi      embed.html opened top-level with COOP/COEP        -> engine "threads", solo game started
//   top-plain    embed.html opened top-level WITHOUT those headers  -> engine "single" (the fallback), solo game started
//   framed-coi   the site's shape: an isolated parent page frames embed.html (other origin, tmc-loader's sandbox and allow
//                attributes)                                        -> engine "threads", solo game started
//   framed-noallow  the same parent but the iframe lacks allow="cross-origin-isolated" -> "single", started (a missing attribute
//                degrades, it does not blank the canvas)
// Every request that failed or answered >= 400 is listed (COEP blocks show as ERR_BLOCKED_BY_RESPONSE), per mode.
// "started" = the shell's "solo game started" line. Script load errors are counted per mode and printed: an old content version
// can carry some against a newer shell, but the count must be equal in every mode (it is content skew, not the engine).
// The server is local_shell_server.mjs (proxies /content to --content). The framed parent is localhost:<port> and the
// game 127.0.0.1:<port> (one port, so one tunnel), which are different origins.
import { serveShell } from './local_shell_server.mjs';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';

const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && i + 1 < argv.length ? argv[i + 1] : d; };
const dir = opt('serve', 'web/build');
const game = opt('game', 'gamemann/game-hungario');
const gameVersion = opt('version', '');
const basePort = +opt('host-port', '8097');
const upstream = opt('content', 'https://content.gamespice.net');
const secs = +opt('secs', '300');
const only = opt('only', 'top-coi,top-plain,framed-coi,framed-noallow').split(',');
const outDir = opt('out', path.join(os.tmpdir(), 'browser_threads_check'));
fs.mkdirSync(outDir, { recursive: true });

const require = createRequire(import.meta.url);
let pw;
for (const t of [process.env.PLAYWRIGHT_CORE, 'playwright-core', path.join(os.homedir(), 'pw/node_modules/playwright-core'),
  '/home/gamedev/pw/node_modules/playwright-core', '/home/christian/stack/website-city/node_modules/playwright-core'].filter(Boolean)) {
  try { pw = require(t); break; } catch { /* next */ }
}
if (!pw) { console.error('playwright-core not found; set PLAYWRIGHT_CORE'); process.exit(2); }
const { chromium } = pw;

const buildId = '20261121-0000';
const cdp = process.env.GPU_CDP_URL ? await chromium.connectOverCDP(process.env.GPU_CDP_URL) : null;
const results = [];

// The attributes tmc-loader.js puts on the frame.
const parentPage = (gameUrl, allow) => `<!doctype html><body style="margin:0"><iframe id="g" src="${gameUrl}" style="width:100vw;height:100vh;border:0"
  sandbox="allow-scripts allow-same-origin allow-pointer-lock allow-downloads allow-modals"
  allow="${allow}" allowfullscreen></iframe></body>`;

async function run(mode, port) {
  const framed = mode.startsWith('framed');
  const q = `?solo=${game}${gameVersion ? '&solo-version=' + gameVersion : ''}`;
  const gameUrl = `http://127.0.0.1:${port}/godot/${buildId}/embed.html${q}`;
  const allow = 'autoplay; gamepad; fullscreen; ' + (mode === 'framed-noallow' ? '' : 'cross-origin-isolated; ') + 'microphone';
  const game_srv = await serveShell({ dir, port, buildId, upstream, givenUrl: `http://x/${q}`, coi: mode !== 'top-plain',
    parentHtml: framed ? parentPage(gameUrl, allow) : '' });
  const pageUrl = framed ? `http://localhost:${port}/` : game_srv.url;
  const ctx = cdp ? await cdp.newContext({ viewport: { width: 1280, height: 720 } })
    : await chromium.launch({ headless: true, args: ['--use-angle=gl', '--enable-gpu', '--ignore-gpu-blocklist',
      '--use-gl=swiftshader', '--enable-unsafe-swiftshader'] }).then(b => b.newContext({ viewport: { width: 1280, height: 720 } }));
  const page = await ctx.newPage();
  const t0 = Date.now();
  const lines = [], bad = [];
  const log = s => lines.push(`${((Date.now() - t0) / 1000).toFixed(1)} ${s}`);
  page.on('console', m => log(`[${m.type()}] ${m.text()}`));
  page.on('pageerror', e => log(`[pageerror] ${e.message}`));
  page.on('requestfailed', r => bad.push(`${r.failure()?.errorText} ${r.url()}`));
  page.on('response', r => { if (r.status() >= 400) bad.push(`HTTP ${r.status()} ${r.url()}`); });
  await page.goto(pageUrl);
  const text = () => lines.join('\n');
  const deadline = Date.now() + secs * 1000;
  while (Date.now() < deadline) {
    await page.waitForTimeout(2000);
    if (/solo game started|This did not load|Could not start/.test(text())) break;
  }
  await page.waitForTimeout(8000);
  const frame = framed ? page.frames().find(f => f !== page.mainFrame()) : page.mainFrame();
  const info = await frame.evaluate(() => ({ engine: window.__TMC_ENGINE__, natives: window.__TMC_NATIVES__,
    coi: self.crossOriginIsolated, sab: typeof SharedArrayBuffer, canvasW: document.querySelector('canvas')?.width,
    overlayHidden: document.getElementById('status')?.className })).catch(e => ({ err: String(e) }));
  const shot = path.join(outDir, `${mode}.png`);
  await page.screenshot({ path: shot });
  const png = fs.statSync(shot).size;
  fs.writeFileSync(path.join(outDir, `${mode}.log`), text());
  const choice = lines.find(l => l.includes('tmc engine:')) || '(no "tmc engine:" line)';
  const started = /solo game started/.test(text());
  const scriptErrs = (text().match(/Failed to load script/g) || []).length;
  const want = mode.endsWith('coi') ? 'threads' : 'single';
  const pass = started && info.engine === want && !/This did not load/.test(text());
  results.push({ mode, pass, want, info, started, png, choice, bad, scriptErrs });
  await ctx.close();
  game_srv.srv.close();
}

for (const m of only) await run(m, basePort);
if (cdp) await cdp.close();
console.log('\nmode            want     got      coi    started  png-bytes  verdict');
for (const r of results) {
  console.log(`${r.mode.padEnd(15)} ${r.want.padEnd(8)} ${String(r.info.engine).padEnd(8)} ${String(r.info.coi).padEnd(6)} ${String(r.started).padEnd(8)} ${String(r.png).padEnd(10)} ${r.pass ? 'PASS' : 'FAIL'}`);
  console.log(`   ${r.choice} script-load-errors=${r.scriptErrs}`);
  for (const b of [...new Set(r.bad)].slice(0, 20)) console.log(`   blocked/failed: ${b}`);
}
process.exit(results.every(r => r.pass) ? 0 : 1);
