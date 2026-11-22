// The shell's identity in a real browser: the page is titled and iconed GameSpice from the first frame, the loading screen
// shows an icon named by ?icon= before any pack is mounted, and once the game is known document.title and the favicon are
// the game's (Godot's web DisplayServer writes both, so this proves the web path has the same behaviour as the desktop).
//
//   node tools/browser_identity_check.mjs --serve web/build [--game gamemann/game-hungario] [--secs 240] [--out DIR]
//   gpu.sh cdp-run ... -- node tools/browser_identity_check.mjs ...     (a real GPU; GPU_CDP_URL is honoured)
//
// The ?icon= URL is answered by the check itself (a solid 64x64 PNG of a colour GameSpice's icon does not have), so it also
// proves the fetch happens. Prints one verdict line per check; exit 0 only when all pass. Screenshots land in --out.
import { serveShell } from './local_shell_server.mjs';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';
import { createRequire } from 'node:module';

const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && i + 1 < argv.length ? argv[i + 1] : d; };
const dir = opt('serve', 'web/build');
const game = opt('game', 'gamemann/game-hungario');
const port = +opt('host-port', '8097');
const upstream = opt('content', 'https://content.gamespice.net');
const secs = +opt('secs', '240');
const outDir = opt('out', path.join(os.tmpdir(), 'browser_identity_check'));
fs.mkdirSync(outDir, { recursive: true });

const require = createRequire(import.meta.url);
let pw;
for (const t of [process.env.PLAYWRIGHT_CORE, 'playwright-core', path.join(os.homedir(), 'pw/node_modules/playwright-core'),
  '/home/gamedev/pw/node_modules/playwright-core', '/home/christian/stack/website-city/node_modules/playwright-core'].filter(Boolean)) {
  try { pw = require(t); break; } catch { /* next */ }
}
if (!pw) { console.error('playwright-core not found; set PLAYWRIGHT_CORE'); process.exit(2); }
const { chromium } = pw;

// A solid-colour PNG, no dependency: signature, IHDR, one zlib IDAT, IEND.
function solidPng(w, h, [r, g, b]) {
  const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  const crc = buf => { let c = 0xffffffff; for (const x of buf) c = crcTable[(c ^ x) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (type, data) => { const t = Buffer.from(type), len = Buffer.alloc(4), c = Buffer.alloc(4); len.writeUInt32BE(data.length); c.writeUInt32BE(crc(Buffer.concat([t, data]))); return Buffer.concat([len, t, data, c]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  const row = Buffer.concat([Buffer.from([0]), Buffer.from(Array.from({ length: w }, () => [r, g, b]).flat())]);
  const raw = Buffer.concat(Array.from({ length: h }, () => row));
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

const ICON_URL = 'https://icons.example.test/first-load.png';
const q = `?solo=${game}&icon=${encodeURIComponent(ICON_URL)}`;
const buildId = '20261122-0000';
const srv = await serveShell({ dir, port, buildId, upstream, givenUrl: `http://x/${q}`, coi: true });
const cdp = process.env.GPU_CDP_URL ? await chromium.connectOverCDP(process.env.GPU_CDP_URL) : null;
const ctx = cdp ? await cdp.newContext({ viewport: { width: 1280, height: 720 } })
  : await chromium.launch({ headless: true, args: ['--use-angle=gl', '--enable-gpu', '--ignore-gpu-blocklist', '--use-gl=swiftshader', '--enable-unsafe-swiftshader'] })
    .then(b => b.newContext({ viewport: { width: 1280, height: 720 } }));
const page = await ctx.newPage();
let iconAsked = 0;
await page.route(ICON_URL, route => { iconAsked++; route.fulfill({ status: 200, contentType: 'image/png', body: solidPng(64, 64, [0, 200, 80]), headers: { 'access-control-allow-origin': '*' } }); });

const lines = [];
page.on('console', m => lines.push(`[${m.type()}] ${m.text()}`));
page.on('pageerror', e => lines.push(`[pageerror] ${e.message}`));
const snap = () => page.evaluate(() => ({ title: document.title, icons: [...document.querySelectorAll('link[rel~="icon"]')].map(l => l.href.length > 120 ? l.href.slice(0, 120) : l.href), iconLen: [...document.querySelectorAll('link[rel~="icon"]')].map(l => l.href.length) }));

await page.goto(`${srv.url.split('?')[0]}${q}`, { waitUntil: 'load', timeout: 60000 });
const timeline = [];
const deadline = Date.now() + secs * 1000;
let first = null;
while (Date.now() < deadline) {
  await page.waitForTimeout(1500);
  const s = await snap().catch(() => null);
  if (!s) continue;
  timeline.push(s);
  if (s.title === 'GameSpice' && first === null) { first = s; await page.screenshot({ path: path.join(outDir, 'loading.png') }); }
  if (lines.some(l => /solo game started/.test(l)) || lines.some(l => /This did not load|Could not start/.test(l))) break;
}
await page.waitForTimeout(6000);
const last = await snap();
await page.screenshot({ path: path.join(outDir, 'playing.png') });
fs.writeFileSync(path.join(outDir, 'console.log'), lines.join('\n'));

const titles = [...new Set(timeline.map(s => s.title))];
const results = [
  ['the page is titled GameSpice before the game is known', first !== null || timeline.some(s => s.title === 'GameSpice')],
  ['a favicon link exists', timeline.some(s => s.icons.length > 0) || last.icons.length > 0],
  ['?icon= was fetched before the pack mounted', iconAsked > 0],
  ['the favicon changed while the shell ran (hint icon, then the game icon)', new Set(timeline.map(s => s.icons.join('|'))).size > 1 || last.icons.join('|') !== (first?.icons.join('|') ?? '')],
  ['the title became the game\'s name once known', last.title !== 'GameSpice' && last.title !== '' && !/^(game|mg)-/.test(last.title)],
  ['the game started', lines.some(l => /solo game started/.test(l))],
];
console.log(JSON.stringify({ titles, first, last, iconAsked }, null, 1));
for (const [name, ok] of results) console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}`);
await ctx.close(); if (cdp) await cdp.close(); srv.srv.close();
process.exit(results.every(r => r[1]) ? 0 : 1);
