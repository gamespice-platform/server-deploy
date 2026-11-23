// embed.html's two guards, in headless Chromium: who may hand it a sign-in
// (TMC_SITE_ORIGINS -> FRAME_ORIGINS) and which servers it connects to
// (TMC_SERVER_HOSTS -> SERVER_HOSTS).
//
//   node tools/embed_guards_check.mjs
//
// No exported shell needed: the page's guards run before the engine is asked for, and
// the stamps are written by the real stamp_embed_guards, cut out of tools/server.in.
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
const pw = (await import(process.env.PLAYWRIGHT_CORE ?? '/home/christian/stack/website-city/node_modules/playwright-core/index.js')).default;
const { chromium } = pw;

const ROOT = new URL('..', import.meta.url).pathname;
const SERVER_IN = path.join(ROOT, 'tools/server.in');

// Runs stamp_embed_guards on a copy of embed.html; returns [exit code, stamped page].
function stamp(env) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'embed-guards-'));
  fs.copyFileSync(path.join(ROOT, 'web/embed.html'), path.join(dir, 'embed.html'));
  const script = `set -u
die() { printf '%s\\n' "$1" >&2; exit "\${2:-2}"; }
eval "$(sed -n '/^stamp_embed_guards() {/,/^}/p' "$1")"
stamp_embed_guards "$2"`;
  const r = spawnSync('bash', ['-c', script, 'bash', SERVER_IN, dir], {
    env: { PATH: process.env.PATH, ...env }, encoding: 'utf8',
  });
  const html = fs.readFileSync(path.join(dir, 'embed.html'), 'utf8');
  fs.rmSync(dir, { recursive: true });
  return [r.status, html, r.stderr];
}

function listen(handler) {
  return new Promise(res => {
    const s = http.createServer(handler);
    s.listen(0, '127.0.0.1', () => res([s, s.address().port]));
  });
}

let failed = 0;
function check(name, ok, got) {
  if (!ok) failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok ? '' : ` (got ${JSON.stringify(got)})`}`);
}

// ---- the stamp itself
{
  const [rc, html] = stamp({});
  check('no env: both lists stay empty', rc === 0 && html.includes('/*TMC_FRAME_ORIGINS*/[]') && html.includes('/*TMC_SERVER_HOSTS*/[]'), rc);
  const [rc2, html2] = stamp({ TMC_SITE_ORIGINS: 'https://a.example https://b.example:8443', TMC_SERVER_HOSTS: 'Play.Example *.games.example' });
  check('origins stamped', rc2 === 0 && html2.includes('var FRAME_ORIGINS = ["https://a.example","https://b.example:8443"];'), rc2);
  check('hosts stamped, lower case', html2.includes('var SERVER_HOSTS = ["play.example","*.games.example"];'), rc2);
  for (const bad of ['https://a.example/path', 'a.example', 'https://a.example";alert(1)//'])
    check(`TMC_SITE_ORIGINS refuses ${bad}`, stamp({ TMC_SITE_ORIGINS: bad })[0] === 3, bad);
  for (const bad of ['wss://play.example', 'play.example:6064', '*', 'a"b'])
    check(`TMC_SERVER_HOSTS refuses ${bad}`, stamp({ TMC_SERVER_HOSTS: bad })[0] === 3, bad);
}

// ---- in a browser. Two parents on different origins frame the page; one is listed.
const AUTH = { code: 'one-use', site: 'x' };
const parentPage = (src) => `<!doctype html><iframe id="f" src="${src}" width="600" height="400"></iframe>
<script>
window.__ready = 0;
addEventListener('message', function (e) {
  if (e.data && e.data.type === 'tmc.auth.ready') {
    window.__ready++;
    document.getElementById('f').contentWindow.postMessage({ type: 'tmc.auth', auth: ${JSON.stringify(AUTH)} }, '*');
  }
});
</script>`;

let gamePage = '';
const [game, gamePort] = await listen((req, r) => {
  if (!req.url.startsWith('/embed.html')) { r.writeHead(404); return r.end(); }
  r.writeHead(200, { 'Content-Type': 'text/html' });
  r.end(gamePage);
});
const gameUrl = (q = '') => `http://127.0.0.1:${gamePort}/embed.html${q}`;
const parent = (req, r) => {
  r.writeHead(200, { 'Content-Type': 'text/html' });
  r.end(parentPage(gameUrl(new URL(req.url, 'http://x').search)));
};
const [listed, listedPort] = await listen(parent);
const [other, otherPort] = await listen(parent);
const LISTED = `http://127.0.0.1:${listedPort}`;
const OTHER = `http://127.0.0.1:${otherPort}`;

const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM ?? undefined });

async function framed(origin, query = '') {
  const page = await browser.newPage();
  await page.goto(origin + '/' + query);
  const frame = page.frames().find(f => f.url().startsWith(gameUrl()));
  await page.waitForTimeout(400);
  const out = {
    ready: await page.evaluate(() => window.__ready),
    auth: await frame.evaluate(() => window.__TMC_AUTH__),
    parent: await frame.evaluate(() => window.__TMC_PARENT__),
  };
  await page.close();
  return out;
}

async function alone(query) {
  const page = await browser.newPage();
  await page.goto(gameUrl(query));
  const out = {
    server: await page.evaluate(() => window.__TMC_SERVER__),
    message: await page.locator('#message').textContent(),
    detail: await page.locator('#detail').textContent(),
    auth: await page.evaluate(() => window.__TMC_AUTH__),
  };
  await page.close();
  return out;
}

try {
  // Unstamped: any parent signs in, and the ping goes to that parent's origin.
  gamePage = stamp({})[1];
  let got = await framed(OTHER);
  check('unstamped: any parent is heard', got.ready === 1 && got.auth.code === AUTH.code && got.parent.origin === OTHER, got);
  got = await alone('?server=' + encodeURIComponent('wss://anything.example:6064'));
  check('unstamped: any wss host is taken', got.server.address === 'wss://anything.example:6064/' && !got.server.refused, got);
  check('unframed: no sign-in is waited for', JSON.stringify(got.auth) === '{}', got);
  got = await alone('?server=' + encodeURIComponent('wss://user:pw@anything.example'));
  check('an address with credentials is dropped', got.server.address === 'wss://localhost:6064', got);
  got = await alone('?server=' + encodeURIComponent('https://anything.example'));
  check('a non-websocket address is dropped', got.server.address === 'wss://localhost:6064', got);

  // Stamped with one origin: only that parent.
  gamePage = stamp({ TMC_SITE_ORIGINS: LISTED, TMC_SERVER_HOSTS: 'play.example *.games.example' })[1];
  got = await framed(LISTED);
  check('listed parent is heard', got.ready === 1 && got.auth.code === AUTH.code && !got.parent.refused, got);
  got = await framed(OTHER);
  check('unlisted parent gets no ping and no sign-in', got.ready === 0 && JSON.stringify(got.auth) === '{}' && got.parent.refused === true, got);

  for (const [addr, ok] of [
    ['wss://play.example:6064', true], ['wss://PLAY.example', true], ['wss://a.games.example', true],
    ['wss://games.example', false], ['wss://evilgames.example', false], ['wss://play.example.evil.test', false],
    ['wss://evil.test', false],
  ]) {
    got = await alone('?server=' + encodeURIComponent(addr));
    check(`host list: ${addr} ${ok ? 'taken' : 'refused'}`,
      ok ? !got.server.refused && got.server.address.startsWith(addr.toLowerCase().slice(0, 12))
         : !!got.server.refused && /does not connect/.test(got.message) && got.detail.includes(got.server.refused), got);
  }
} finally {
  await browser.close();
  game.close(); listed.close(); other.close();
}

console.log(failed ? `\n${failed} FAILED` : '\nall ok');
process.exit(failed ? 1 : 0);
