import assert from 'node:assert/strict';
import { FelorxResponsesSseDecoder, readResponsesStream } from './responses_stream.ts';

const encode = text => new TextEncoder().encode(text);
for (const newline of ['\n', '\r', '\r\n']) {
  const decoder = new FelorxResponsesSseDecoder();
  const text = ['\ufeff: comment', 'event: response.output_text.delta',
    'data: {"type":"response.output_text.delta",',
    'data: "delta":"你好😀","number":9007199254740993}', '',
    'data: {"type":"response.completed"}', '', ''].join(newline);
  const events = [];
  for (const byte of encode(text)) events.push(...decoder.push(new Uint8Array([byte])));
  decoder.finish();
  assert.equal(events.length, 2);
  assert.equal(events[0].data.delta, '你好😀');
  assert.match(events[0].rawData, /9007199254740993/);
  assert.equal(decoder.completed, true);
}
for (const type of ['error', 'response.completed', 'response.failed', 'response.incomplete', 'response.cancelled']) {
  const decoder = new FelorxResponsesSseDecoder();
  const events = [...decoder.push(encode(`data: {"type":"${type}"}\n\nignored trailing data`))];
  assert.equal(events.length, 1);
  decoder.finish();
}
for (const text of ['', 'data: [DONE]\n\n', 'data: []\n\n',
  'data: {}\n\n', 'data: {"type":"response.created"}\n\n',
  'event: response.created\ndata: {"type":"response.completed"}\n\n']) {
  assert.throws(() => { const decoder = new FelorxResponsesSseDecoder(); [...decoder.push(encode(text))]; decoder.finish(); });
}
assert.throws(() => [...new FelorxResponsesSseDecoder().push(new Uint8Array([0xff]))]);
assert.throws(() => { const decoder = new FelorxResponsesSseDecoder(); [...decoder.push(new Uint8Array([0xe4]))]; decoder.finish(); });
assert.throws(() => [...new FelorxResponsesSseDecoder().push(encode(':' + 'x'.repeat(8 * 1024 * 1024)))]);
console.log('Responses TypeScript decoder checks passed');

const frame = type => encode(`data: ${JSON.stringify({ type })}\n\n`);
let cancelled = 0;
const terminalStream = new ReadableStream({
  start(controller) { controller.enqueue(frame('response.completed')); },
  cancel() { cancelled++; },
});
const delivered = [];
await readResponsesStream(terminalStream.getReader(), event => delivered.push(event.type));
assert.deepEqual(delivered, ['response.completed']);
assert.equal(cancelled, 1);
assert.equal(terminalStream.locked, false);

// The source is never read again while the sink is blocked.
let reads = 0, releases = 0, cancels = 0, unblock;
const gate = new Promise(resolve => { unblock = resolve; });
const reader = {
  async read() { reads++; return { done: false, value: frame(reads === 1 ? 'response.created' : 'response.completed') }; },
  async cancel() { cancels++; },
  releaseLock() { releases++; },
};
const consuming = readResponsesStream(reader, async event => { if (event.type === 'response.created') await gate; });
await new Promise(resolve => setImmediate(resolve));
assert.equal(reads, 1);
unblock();
await consuming;
assert.equal(reads, 2);
assert.equal(cancels, 1);
assert.equal(releases, 1);

for (const where of ['before', 'read', 'sink']) {
  const abort = new AbortController();
  let calls = 0, closed = 0;
  const stream = new ReadableStream({
    start(controller) { if (where === 'sink') controller.enqueue(frame('response.created')); },
    cancel() { closed++; },
  });
  if (where === 'before') abort.abort();
  const running = readResponsesStream(stream.getReader(), () => { calls++; return new Promise(() => {}); }, abort.signal);
  const rejected = assert.rejects(running, { name: 'AbortError' });
  await new Promise(resolve => setImmediate(resolve));
  abort.abort();
  await rejected;
  assert.equal(calls, where === 'sink' ? 1 : 0);
  assert.equal(closed, 1);
  assert.equal(stream.locked, false);
}

for (const failSink of [false, true]) {
  let closed = 0;
  const stream = new ReadableStream({
    start(controller) { controller.enqueue(failSink ? frame('response.created') : encode('data: []\n\n')); },
    cancel() { closed++; throw new Error('cleanup must not replace failure'); },
  });
  await assert.rejects(readResponsesStream(stream.getReader(), () => { throw new Error('sink failed'); }),
    failSink ? /sink failed/ : /Invalid Responses event/);
  assert.equal(closed, 1);
  assert.equal(stream.locked, false);
}
console.log('Responses stream consumption and cancellation checks passed');
