import test from 'node:test';
import assert from 'node:assert/strict';
import { DocumentBridge, createDocumentRemote, BYTE_CHUNK } from './bridge.mjs';

function harness(handle = () => {}) {
  const sent = [];
  const channel = { onmessage: null, postMessage(raw) {
    const frame = JSON.parse(raw);
    assert.equal(typeof frame.id, 'string', 'native policy requires an id on every message');
    assert.ok(!sent.some(previous => previous.id === frame.id), 'request IDs are unique');
    sent.push(frame); handle(frame, reply);
  } };
  const reply = frame => channel.onmessage?.({ data: JSON.stringify(frame) });
  const bridge = new DocumentBridge(channel);
  return { bridge, sent, reply };
}
const success = value => ({ ok: true, value });

test('byte leases are reconstructed in capped chunks and always released', async () => {
  const original = new Uint8Array(BYTE_CHUNK + 19).map((_, i) => i % 251);
  const h = harness((frame, reply) => {
    if (frame.kind === 'call') reply({ id: frame.id, result: success({ data: { encoding: 'android-byte-lease', id: 'lease', length: original.length }, version: 'one' }) });
    if (frame.kind === 'bytes') reply({ id: frame.id, result: success({ offset: frame.offset, data: Buffer.from(original.subarray(frame.offset, frame.offset + frame.length)).toString('base64'), eof: frame.offset + frame.length === original.length }) });
  });
  const result = await h.bridge.call('workspaceFiles', 'readBytes', { path: 'picture.png', options: {} });
  assert.deepEqual(result.value.data, original);
  assert.deepEqual(h.sent.filter(frame => frame.kind === 'bytes').map(frame => frame.length), [BYTE_CHUNK, 19]);
  assert.equal(h.sent.at(-1).kind, 'release');
  h.bridge.close();
});

test('empty and malformed leases release without returning corrupt bytes', async () => {
  for (const length of [0, 2]) {
    const h = harness((frame, reply) => {
      if (frame.kind === 'call') reply({ id: frame.id, result: success({ data: { encoding: 'android-byte-lease', id: 'lease', length } }) });
      if (frame.kind === 'bytes') reply({ id: frame.id, result: success({ offset: 99, data: 'YQ==', eof: true }) });
    });
    const result = h.bridge.call('workspaceFiles', 'readBytes', { path: 'file', options: {} });
    if (length) await assert.rejects(result, /Invalid document byte chunk/);
    else assert.equal((await result).value.data.byteLength, 0);
    assert.equal(h.sent.filter(frame => frame.kind === 'release').length, 1);
    h.bridge.close();
  }
});

test('abort cancels a pending chunk and releases its byte lease', async () => {
  const controller = new AbortController();
  const h = harness((frame, reply) => {
    if (frame.kind === 'call') reply({ id: frame.id, result: success({ data: { encoding: 'android-byte-lease', id: 'lease', length: 10 } }) });
    if (frame.kind === 'bytes') queueMicrotask(() => controller.abort());
  });
  await assert.rejects(h.bridge.call('workspaceFiles', 'readBytes', { path: 'file' }, controller.signal), { name: 'AbortError' });
  const chunk = h.sent.find(frame => frame.kind === 'bytes');
  assert.ok(h.sent.some(frame => frame.kind === 'cancel' && frame.requestId === chunk.id));
  assert.ok(h.sent.some(frame => frame.kind === 'release' && frame.leaseId === 'lease'));
  h.bridge.close();
});

test('stream event can precede receipt; ACK follows consumption and unsubscribe stops late delivery', async () => {
  const h = harness((frame, reply) => {
    if (frame.kind === 'subscribe') {
      reply({ id: frame.id, event: { kind: 'ready' }, sequence: 1, generation: 8 });
      reply({ id: frame.id, result: success({ subscribed: true }) });
      reply({ id: frame.id, event: { kind: 'change', change: { absolutePath: '/file', version: 'two' } }, sequence: 2, generation: 8 });
    }
  });
  const iterator = h.bridge.changes('file')[Symbol.asyncIterator]();
  assert.deepEqual((await iterator.next()).value, { kind: 'ready' });
  assert.equal(h.sent.filter(frame => frame.kind === 'ack').length, 0);
  assert.equal((await iterator.next()).value.kind, 'change');
  assert.deepEqual(h.sent.filter(frame => frame.kind === 'ack').map(({ sequence, generation }) => ({ sequence, generation })), [{ sequence: 1, generation: 8 }]);
  await iterator.return();
  assert.equal(h.sent.at(-1).kind, 'unsubscribe');
  h.bridge.close();
});

test('dispose rejects calls and closes a waiting stream without retaining listeners', async () => {
  const h = harness();
  const request = h.bridge.ready();
  const iterator = h.bridge.changes('file')[Symbol.asyncIterator]();
  const next = iterator.next();
  h.bridge.close();
  await assert.rejects(request, { name: 'AbortError' });
  assert.equal((await next).done, true);
  assert.ok(h.sent.some(frame => frame.kind === 'cancel'));
  assert.ok(h.sent.some(frame => frame.kind === 'unsubscribe'));
});

test('facade maps original positional contracts and refuses cross-session calls', async () => {
  const calls = [];
  const remote = createDocumentRemote({ call: (...args) => { calls.push(args); return Promise.resolve(success({})); }, changes: (...args) => args }, 'session-one', options => options);
  const signal = new AbortController().signal;
  await remote.workspaceFiles.read('session-one', 'hello.txt', { offset: 2 }, signal);
  await remote.workspaceFiles.readBytes('session-one', 'photo.png', { baseFile: 'index.html' }, signal);
  await remote.officeToPdf.render('session-one', 'report.docx', 'foreground', signal);
  await remote.officeToPdf.generation(signal);
  assert.deepEqual(calls.map(args => args.slice(0, 3)), [
    ['workspaceFiles', 'read', { path: 'hello.txt', range: { offset: 2 } }],
    ['workspaceFiles', 'readBytes', { path: 'photo.png', options: { baseFile: 'index.html' } }],
    ['officeToPdf', 'render', { path: 'report.docx', priority: 'foreground' }], ['officeToPdf', 'generation', {}],
  ]);
  assert.throws(() => remote.workspaceFiles.stat('other-session', 'secret.txt', signal), /session mismatch/);
  const h = harness();
  await assert.rejects(h.bridge.call('shell', 'execute', {}), /outside the document bridge/);
  h.bridge.close();
});

test('external links use independent control IDs and reject non-Web or credential-bearing URLs', () => {
  const h = harness();
  h.bridge.openExternalLink('https://example.invalid/guide?q=preview#part');
  h.bridge.openExternalLink('http://example.invalid/readme');
  assert.deepEqual(h.sent.map(({ kind, url }) => ({ kind, url })), [
    { kind: 'external', url: 'https://example.invalid/guide?q=preview#part' },
    { kind: 'external', url: 'http://example.invalid/readme' },
  ]);
  for (const url of ['file:///private/secret', 'javascript:alert(1)', 'intent://example', '/relative',
    'https://user:password@example.invalid/', 'https://@/', null]) {
    assert.throws(() => h.bridge.openExternalLink(url));
  }
  assert.equal(h.sent.length, 2, 'rejected links never reach native launch');
  h.bridge.close();
  assert.equal(h.sent.length, 2, 'fire-and-forget external replies do not retain pending calls');
  assert.throws(() => h.bridge.openExternalLink('https://example.invalid/'), { name: 'AbortError' });
});

test('document routing waits for native acceptance and cancels when its reader closes', async () => {
  const h = harness();
  const target = { sessionId: 'bound', path: 'src/code.ts', line: 23, replace: false };
  const opened = h.bridge.openDocument(target);
  assert.deepEqual(h.sent[0], { id: h.sent[0].id, kind: 'navigate', ...target });
  h.reply({ id: h.sent[0].id, result: { opened: true } });
  assert.deepEqual(await opened, { opened: true });
  const failed = h.bridge.openDocument(target);
  h.reply({ id: h.sent.at(-1).id, error: { code: 'document/inactive', message: 'closed' } });
  await assert.rejects(failed, { code: 'document/inactive' });
  const pending = h.bridge.openDocument(target);
  h.bridge.close();
  await assert.rejects(pending, { name: 'AbortError' });
  assert.equal(h.sent.at(-1).kind, 'cancel');
});
