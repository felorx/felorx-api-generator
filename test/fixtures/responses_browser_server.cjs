// Local-only browser acceptance harness. Usage: node <file> <generated-sdk-root>
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const root = path.resolve(process.argv[2]);
const ts = require(path.join(root, 'node_modules/typescript'));
const modules = new Map(['responses_stream', 'responses_http'].map(name => [
  '/' + name, ts.transpileModule(fs.readFileSync(path.join(root, name + '.ts'), 'utf8'),
    { compilerOptions: { module: ts.ModuleKind.ES2020, target: ts.ScriptTarget.ES2020 } }).outputText,
]));
modules.set('/axios', fs.readFileSync(path.join(root, 'node_modules/axios/dist/esm/axios.js'), 'utf8'));
const state = { requests: [], closed: 0, redirected: 0 };
const html = `<!doctype html><meta charset="utf-8"><title>Felorx Responses browser acceptance</title>
<h1>Responses browser acceptance</h1><pre id="result">Running...</pre>
<script type="importmap">{"imports":{"axios":"/axios"}}</script>
<script type="module">
import { streamResponses, FelorxResponseHTTPError } from '/responses_http';
const result = document.getElementById('result');
const check = (value, message) => { if (!value) throw new Error(message); };
const state = () => fetch('/state').then(response => response.json());
const waitFor = async predicate => {
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) { if (await predicate()) return; await new Promise(resolve => setTimeout(resolve, 10)); }
  throw new Error('Timed out waiting for network state');
};
try {
  const body = { model: 'fixture', input: '你好', stream: false, extension: { keep: true } };
  const options = { endpoint: location.origin + '/responses', bearerToken: 'browser-fixture-token', provider: 'fixture' };
  const events = [];
  await streamResponses(options, body, async event => { await new Promise(resolve => setTimeout(resolve, 5)); events.push(event); });
  check(events.length === 2 && events[0].data.delta === '你好😀', 'UTF-8 events');
  check(events[1].type === 'response.completed' && body.stream === false, 'terminal and immutable request');
  await waitFor(async () => (await state()).closed === 1);
  let observed = await state();
  check(observed.requests[0].authorization === 'Bearer browser-fixture-token', 'Bearer header');
  check(observed.requests[0].provider === 'fixture' && observed.requests[0].body.stream === true, 'provider and stream flag');
  check(observed.requests[0].body.extension.keep === true, 'extension preserved');
  const abort = new AbortController();
  const pending = streamResponses({ ...options, endpoint: location.origin + '/wait', signal: abort.signal }, body, () => {});
  const outcome = pending.then(() => 'unexpected success', error => error.name);
  await waitFor(async () => (await state()).requests.some(request => request.url === '/wait'));
  abort.abort();
  check(await outcome === 'AbortError', 'cancel blocked read');
  await waitFor(async () => (await state()).closed === 2);
  let quota;
  try { await streamResponses({ ...options, endpoint: location.origin + '/quota' }, body, () => {}); } catch (error) { quota = error; }
  check(quota instanceof FelorxResponseHTTPError && quota.statusCode === 429 && quota.body.error.code === 'insufficient_quota', 'HTTP error');
  let redirectFailed = false;
  try { await streamResponses({ ...options, endpoint: location.origin + '/redirect' }, body, () => {}); } catch (_) { redirectFailed = true; }
  check(redirectFailed && (await state()).redirected === 0, 'redirect not followed');
  result.textContent = 'PASS: UTF-8 SSE, terminal release without EOF, backpressure callback, immutable extensions, bearer/provider, blocked-read cancellation, HTTP quota error, no redirect';
  document.documentElement.dataset.result = 'passed';
} catch (error) {
  result.textContent = 'FAIL: ' + error.stack;
  document.documentElement.dataset.result = 'failed';
}
</script>`;
const server = http.createServer(async (req, res) => {
  if (modules.has(req.url)) { res.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8' }); res.end(modules.get(req.url)); return; }
  if (req.url === '/') { res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); res.end(html); return; }
  if (req.url === '/state') { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(state)); return; }
  let body = '';
  for await (const chunk of req) body += chunk;
  state.requests.push({ url: req.url, authorization: req.headers.authorization, provider: req.headers['x-felorx-ai-provider'], body: body ? JSON.parse(body) : null });
  if (req.url === '/redirect') { res.writeHead(307, { location: '/target' }); res.end(); return; }
  if (req.url === '/target') { state.redirected++; res.end(); return; }
  if (req.url === '/quota') { res.writeHead(429, { 'content-type': 'application/json' }); res.end('{"error":{"code":"insufficient_quota"}}'); return; }
  if (!['/responses', '/wait'].includes(req.url)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8' });
  res.on('close', () => state.closed++);
  res.flushHeaders();
  if (req.url === '/responses') {
    for (const byte of Buffer.from('data: {"type":"response.output_text.delta","delta":"你好😀"}\n\ndata: {"type":"response.completed"}\n\n')) res.write(Buffer.from([byte]));
  }
});
server.listen(0, '127.0.0.1', () => console.log('Browser acceptance: http://127.0.0.1:' + server.address().port));
