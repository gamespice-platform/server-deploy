// A content host that misbehaves on purpose, for examples/download_watch_check.gd (no network, nothing to install):
//   GET /ok/<n>       n bytes, at once
//   GET /throttle/<k> answers 429 with Retry-After: 1 the first k times it is asked, then 64 KiB
//   GET /slow/<n>     n bytes, 16 KiB every 100 ms
//   GET /stall/<n>    a 200 that promises n bytes, sends 32 KiB and then goes quiet (holds the socket open)
// Prints `listening <port>` once up; `--port 0` (the default) picks a free one. Exits when stdin closes.
import http from 'node:http';

const portAt = process.argv.indexOf('--port');
const port = portAt < 0 ? 0 : Number(process.argv[portAt + 1] || 0);
const seen = new Map();
const chunk = Buffer.alloc(16 * 1024, 0x61);

const srv = http.createServer((req, res) => {
  const [, kind, arg] = new URL(req.url, 'http://x').pathname.split('/');
  const n = Number(arg) || 0;
  if (kind === 'ok') { res.writeHead(200, { 'content-length': n }); res.end(Buffer.alloc(n, 0x61)); return; }
  if (kind === 'throttle') {
    const c = (seen.get(req.url) || 0) + 1;
    seen.set(req.url, c);
    if (c <= n) { res.writeHead(429, { 'retry-after': '1' }); res.end('slow down'); return; }
    res.writeHead(200, { 'content-length': 65536 }); res.end(Buffer.alloc(65536, 0x61)); return;
  }
  if (kind === 'slow' || kind === 'stall') {
    res.writeHead(200, { 'content-length': n });
    let sent = 0;
    const limit = kind === 'stall' ? 32 * 1024 : n;
    const t = setInterval(() => {
      if (sent >= limit) { clearInterval(t); if (kind === 'slow') res.end(); return; }
      const b = chunk.subarray(0, Math.min(chunk.length, limit - sent));
      res.write(b); sent += b.length;
    }, 100);
    req.on('close', () => clearInterval(t));
    return;
  }
  res.writeHead(404); res.end();
});
srv.listen(port, '127.0.0.1', () => console.log(`listening ${srv.address().port}`));
process.stdin.on('end', () => process.exit(0));
process.stdin.resume();
