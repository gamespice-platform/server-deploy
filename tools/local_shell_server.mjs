// Serves a local web export (web/build) as /godot/<build>/ with /content proxied to a published origin, for the browser checks
// (browser_solo_overlay_check.mjs, browser_solo_rotate_check.mjs). The proxy matters: a local shell's /content is empty, so a solo game
// that needs an addon overlay (FC: fc-weapons) could not fetch it and refused to start ("This game needs ..., which could not be
// downloaded"), and the CDN sends no CORS header to another origin. Returns the server and the page URL for `givenUrl`'s query.
// `parentHtml` serves that page to Host: localhost:<port> (see below). `coi` sends COOP/COEP on every response, as the site does, so the page is cross-origin isolated and embed.html picks the threaded engine.
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';

export async function serveShell({ dir, port, buildId, upstream, givenUrl, coi = false, parentHtml = '', shellUpstream = '' }) {
  if (!shellUpstream && !fs.existsSync(path.join(dir, 'embed.html'))) throw new Error(`--serve ${dir} has no embed.html`);
  const base = upstream.replace(/\/$/, '');
  const types = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm', '.json': 'application/json', '.png': 'image/png' };
  const prefix = `/godot/${buildId || 'local'}/`;
  const srv = http.createServer((req, res) => {
    if (coi) {
      res.setHeader('cross-origin-opener-policy', 'same-origin');
      res.setHeader('cross-origin-embedder-policy', 'require-corp');
      res.setHeader('cross-origin-resource-policy', 'cross-origin'); // as the game origin sends it, so an isolated parent may frame this page
    }
    const u = new URL(req.url, 'http://x');
    // A page on `localhost:<port>` (this server listens on 127.0.0.1, so it is another origin) is the framing parent, served with
    // the same COOP/COEP: one port, so one tunnel to a GPU box's Chrome carries both origins.
    if (parentHtml && (req.headers.host || '').startsWith('localhost')) {
      res.writeHead(200, { 'content-type': 'text/html', 'cache-control': 'no-store' });
      res.end(parentHtml);
      return;
    }
    if (u.pathname.startsWith('/content/')) {
      const lib = base.startsWith('https:') ? https : http;
      const up = lib.request(base + u.pathname + u.search, {
        method: req.method,
        headers: { 'user-agent': 'local_shell_server/1', ...(req.headers.range ? { range: req.headers.range } : {}) },
      }, r => { const h = { ...r.headers }; delete h['alt-svc']; res.writeHead(r.statusCode, h); r.pipe(res); });
      up.on('error', e => { res.writeHead(502); res.end(String(e)); });
      up.end();
      return;
    }
    if (!u.pathname.startsWith(prefix)) { res.writeHead(404, { 'content-type': 'text/html' }); res.end('<!doctype html>'); return; }
    // `shellUpstream` (an origin that serves /godot/<build>/, e.g. the dev CDN): the shell comes from there instead of `dir`.
    if (shellUpstream) {
      const sb = shellUpstream.replace(/\/$/, '');
      const lib = sb.startsWith('https:') ? https : http;
      const up = lib.request(sb + u.pathname + u.search, { method: req.method, headers: { 'user-agent': 'local_shell_server/1' } },
        r => { const h = { ...r.headers }; delete h['alt-svc']; delete h['content-security-policy']; delete h['x-frame-options']; // the site's frame-ancestors names the site, not this local parent
         res.writeHead(r.statusCode, h); r.pipe(res); });
      up.on('error', e => { res.writeHead(502); res.end(String(e)); });
      up.end();
      return;
    }
    // Resolved first: a relative --serve (`web/build`) never started with its own absolute path, so every file was a 403.
    const p = path.join(path.resolve(dir), decodeURIComponent(u.pathname.slice(prefix.length)));
    if (!p.startsWith(path.resolve(dir))) { res.writeHead(403); res.end(); return; }
    fs.readFile(p, (e, d) => {
      if (e) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'content-type': types[path.extname(p)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
      res.end(d);
    });
  });
  await new Promise(r => srv.listen(port, '127.0.0.1', r));
  return { srv, url: `http://127.0.0.1:${port}${prefix}embed.html${new URL(givenUrl).search}` };
}
