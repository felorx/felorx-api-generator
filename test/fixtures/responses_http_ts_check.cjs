const assert = require('node:assert/strict');
const http = require('node:http');
const axios = require('axios').default;
const { streamResponses, FelorxResponseHTTPError } = require('./dist/responses_http.js');
const ResponsesStreamApi = require('node:fs').existsSync(require('node:path').join(__dirname, 'dist/responses_client.js'))
  ? require('./dist/responses_client.js').ResponsesStreamApi : undefined;
const { Configuration } = require('./dist/configuration.js');
const { operationServerMap } = require('./dist/base.js');

(async () => {
  let requests = [], redirected = 0, closed = 0;
  const closedPaths = [];
  const server = http.createServer(async (req, res) => {
    let input = '';
    for await (const chunk of req) input += chunk;
    requests.push({ url: req.url, headers: req.headers, input });
    if (req.url === '/redirect') { res.writeHead(307, { location: '/target' }); res.end(); return; }
    if (req.url === '/target') { redirected++; res.end(); return; }
    if (req.url === '/quota') { res.writeHead(429, { 'content-type': 'application/json' }); res.end('{"error":{"code":"insufficient_quota","message":"private server detail"}}'); return; }
    if (req.url === '/large') { res.writeHead(503); res.write('x'.repeat(65537)); return; }
    if (req.url === '/mime') { res.writeHead(200, { 'content-type': 'application/json' }); res.end('{}'); return; }
    res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8' });
    res.on('close', () => { closed++; closedPaths.push(req.headers['x-test-adapter'] + ':' + req.url); });
    if (req.url === '/wait') { res.flushHeaders(); return; }
    const text = 'data: {"type":"response.output_text.delta","delta":"你好😀"}\n\ndata: {"type":"response.completed"}\n\n';
    for (const byte of Buffer.from(text)) res.write(Buffer.from([byte]));
    // Deliberately leave the socket open after the terminal event.
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    for (const adapter of ['fetch', 'http']) {
      const options = { endpoint: base + '/api/ai/v1/responses', bearerToken: 'fixture-only-token', provider: 'fixture', adapter,
        headers: { authorization: 'wrong', 'X-Custom': 'custom', 'X-Test-Adapter': adapter },
        client: axios.create({ auth: { username: 'wrong', password: 'wrong' }, params: { forbidden: true } }) };
      const body = { model: 'fixture-model', input: 'hello', stream: false, extension: { nested: true } };
      const original = JSON.stringify(body);
      const events = [];
      await streamResponses(options, body, async event => events.push(event));
      assert.equal(JSON.stringify(body), original);
      assert.equal(options.headers.authorization, 'wrong');
      assert.deepEqual(events.map(event => event.type), ['response.output_text.delta', 'response.completed']);
      assert.equal(events[0].data.delta, '你好😀');
      const request = requests.at(-1);
      assert.equal(request.url, '/api/ai/v1/responses');
      assert.equal(request.headers.authorization, 'Bearer fixture-only-token');
      assert.equal(request.headers['x-felorx-ai-provider'], 'fixture');
      assert.equal(request.headers['x-custom'], 'custom');
      assert.equal(request.headers.accept, 'text/event-stream');
      assert.deepEqual(JSON.parse(request.input), { ...body, stream: true });

      await assert.rejects(streamResponses({ ...options, endpoint: base + '/quota' }, body, () => {}), error => {
        assert.ok(error instanceof FelorxResponseHTTPError);
        assert.equal(error.statusCode, 429);
        assert.equal(error.body.error.code, 'insufficient_quota');
        assert.doesNotMatch(String(error), /private server detail|fixture-only-token/);
        assert.equal(error.config, undefined);
        return true;
      });
      await assert.rejects(streamResponses({ ...options, endpoint: base + '/large' }, body, () => {}), error => {
        assert.equal(error.statusCode, 503); assert.equal(error.body, undefined); return true;
      });
      await assert.rejects(streamResponses({ ...options, endpoint: base + '/redirect' }, body, () => {}));
      assert.equal(redirected, 0);
      await assert.rejects(streamResponses({ ...options, endpoint: base + '/mime' }, body, () => {}), /SSE stream/);
      const abort = new AbortController();
      const pending = streamResponses({ ...options, endpoint: base + '/wait', signal: abort.signal }, body, () => {});
      const rejected = assert.rejects(pending, { name: 'AbortError' });
      const requestDeadline = Date.now() + 1500;
      while (requests.at(-1).url !== '/wait' && Date.now() < requestDeadline) await new Promise(resolve => setTimeout(resolve, 5));
      assert.equal(requests.at(-1).url, '/wait');
      abort.abort();
      await rejected;
      const before = requests.length;
      await assert.rejects(streamResponses({ ...options, signal: abort.signal }, body, () => {}), { name: 'AbortError' });
      await assert.rejects(streamResponses({ ...options, endpoint: base + '/?bad=1' }, body, () => {}), /endpoint/);
      await assert.rejects(streamResponses({ ...options, bearerToken: 'bad\r\nvalue' }, body, () => {}), /bearer/);
      await assert.rejects(streamResponses(options, { toJSON: () => ({ stream: false }) }, () => {}), /JSON request/);
      await assert.rejects(streamResponses(options, { input: 'x'.repeat(8 * 1024 * 1024) }, () => {}), /exceeds limit/);
      assert.equal(requests.length, before);
    }
    const deadline = Date.now() + 1500;
    while (closed < 4 && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
    assert.ok(closed >= 4, `Expected four released SSE responses, got ${closedPaths}`);
    let clientRequests = 0;
    for (const legacy of ResponsesStreamApi ? [false, true] : []) {
      const operation = legacy ? 'createResponseLegacy' : 'createResponse';
      const path = legacy ? '/api/ai/openai/responses' : '/api/ai/v1/responses';
      for (const baseKind of ['configuration', 'operation', 'axios']) {
        for (const authKind of ['string', 'promise', 'callback', 'header']) {
          const token = 'configured-fixture-token';
          let resolutions = 0;
          const configuration = new Configuration({
            accessToken: authKind === 'header' ? undefined : authKind === 'string' ? token : authKind === 'promise' ? Promise.resolve(token) : async () => { resolutions++; return token; },
            basePath: baseKind === 'configuration' ? base + '/configured' : undefined,
            serverIndex: 1,
            baseOptions: { timeout: 1111, headers: { 'X-Config': 'yes', ...(authKind === 'header' ? { authorization: `Bearer ${token}` } : {}) } },
          });
          operationServerMap[`ResponsesApi.${operation}`] = [{ url: 'http://invalid.invalid' }, { url: base + '/operation' }];
          const client = axios.create({ baseURL: baseKind === 'axios' ? base + '/axios' : undefined, headers: { 'X-Client': 'yes' } });
          client.interceptors.request.use(config => { clientRequests++; assert.equal(config.timeout, 2222); return config; });
          const api = new ResponsesStreamApi(configuration, 'http://invalid.invalid', client);
          const body = { model: 'fixture-model', input: 'hello', extension: { retained: true } };
          const events = [];
          const method = legacy ? 'createResponseLegacyRawStream' : 'createResponseRawStream';
          await api[method]({ body, xFelorxAiProvider: 'provider' }, event => events.push(event),
            { adapter: 'http', timeout: 2222, method: 'DELETE', headers: { 'X-Request': 'yes' } });
          const request = requests.at(-1);
          assert.equal(request.url, '/' + (baseKind === 'configuration' ? 'configured' : baseKind) + path);
          assert.equal(request.headers.authorization, `Bearer ${token}`);
          assert.equal(request.headers['x-felorx-ai-provider'], 'provider');
          assert.equal(request.headers['x-config'], 'yes');
          assert.equal(request.headers['x-client'], 'yes');
          assert.equal(request.headers['x-request'], 'yes');
          assert.equal(JSON.parse(request.input).extension.retained, true);
          assert.equal(body.stream, undefined);
          assert.equal(events.length, 2);
          assert.equal(resolutions, authKind === 'callback' ? 1 : 0);
        }
      }
      delete operationServerMap[`ResponsesApi.${operation}`];
    }
    assert.equal(clientRequests, ResponsesStreamApi ? 24 : 0);
    if (!ResponsesStreamApi) console.log('Minimal schema: generated Responses class adapter is not applicable');
    console.log('Axios fetch/http Responses network checks passed');
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
