/** Production-assembly browser checks; no test-runtime, model, phone, or host Web listener. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { resolve, dirname, extname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const requireWeb = createRequire(resolve(repo, 'apps/web/package.json'));
const requireViewer = createRequire(resolve(repo, 'packages/client/ui-sidebar-documentpreview/package.json'));
const { chromium } = requireWeb('playwright');
const output = resolve(repo, '.cache/android/document-preview');
const NATIVE_ORIGIN = 'https://appassets.androidplatform.net';
const MEDIA_PATH = '/workspace/guides/nested/../images/chart one.png';
// Known 2 x 1 RGBA PNG: opaque red, then opaque blue.
const MEDIA_PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAADklEQVR4nGP4z8AAQv8BD/kD/YURmXYAAAAASUVORK5CYII=', 'base64');
const MIME = { '.html': 'text/html', '.js': 'application/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf' };
const ok = value => ({ ok: true, value });
const fail = (code, message) => ({ ok: false, error: { isDSHRemoteError: true, name: 'RemoteError', code, message, details: {} } });

function tinyPdf() {
  const objects = ['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>', '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 160] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>', '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'];
  const stream = 'BT /F1 18 Tf 20 80 Td (PDF preview) Tj ET';
  objects.push(`<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`);
  let text = '%PDF-1.4\n'; const offsets = [0];
  objects.forEach((object, index) => { offsets.push(Buffer.byteLength(text)); text += `${index + 1} 0 obj\n${object}\nendobj\n`; });
  const start = Buffer.byteLength(text);
  text += `xref\n0 6\n0000000000 65535 f \n${offsets.slice(1).map(offset => `${String(offset).padStart(10, '0')} 00000 n \n`).join('')}trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${start}\n%%EOF`;
  return Buffer.from(text);
}

async function checkDocuments(t, mode) {
  const mediaRequests = [];
  const server = createServer(async (request, response) => {
    try {
      const requestUrl = new URL(request.url, 'http://local');
      // Only this exact native media route may carry a query. Keep its original
      // path spelling: the session filesystem resolves authored ../ segments.
      if (requestUrl.pathname === '/document/api/file') {
        if (!['GET', 'HEAD'].includes(request.method)) { response.writeHead(405).end(); return; }
        if (requestUrl.search !== `?path=${encodeURIComponent(MEDIA_PATH)}`) { response.writeHead(400).end(); return; }
        mediaRequests.push({ method: request.method, path: requestUrl.searchParams.get('path') });
        response.writeHead(200, { 'content-type': 'image/png', 'content-length': MEDIA_PNG.length,
          'cache-control': 'private, no-store', 'x-content-type-options': 'nosniff',
          'content-security-policy': "sandbox; default-src 'none'" });
        response.end(request.method === 'HEAD' ? undefined : MEDIA_PNG); return;
      }
      if (requestUrl.search) { response.writeHead(400).end('Native assets reject query strings'); return; }
      const pathname = decodeURIComponent(requestUrl.pathname);
      if (pathname === '/favicon.ico') { response.writeHead(204).end(); return; }
      if (!pathname.startsWith('/document/') || pathname.includes('..')) { response.writeHead(404).end(); return; }
      const file = resolve(output, pathname.slice('/document/'.length));
      response.writeHead(200, { 'content-type': MIME[extname(file)] ?? 'application/octet-stream' }); response.end(await readFile(file));
    } catch { response.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const browser = await chromium.launch({ headless: true, channel: process.env.DOCUMENT_BROWSER_CHANNEL ?? 'msedge' });
  t.after(() => browser.close());
  const localOrigin = `http://127.0.0.1:${server.address().port}`;
  const url = `${NATIVE_ORIGIN}/document/index.html`;
  const reports = [];
  const screenshots = resolve(repo, '.cache/android/document-preview-smoke');
  await mkdir(screenshots, { recursive: true });
  const ExcelJS = requireViewer('exceljs');
  const workbook = new ExcelJS.Workbook();
  const sheet = workbook.addWorksheet('Original workbook');
  sheet.addRows([['Item', 'Amount', 'Notes'], ['Project A', 42, 'Original Excel renderer'], ['Project B', 17, 'Mobile viewport']]);
  sheet.getRow(1).font = { bold: true };
  sheet.columns.forEach(column => { column.width = 20; });
  const workbookBytes = Buffer.from(await workbook.xlsx.writeBuffer());

  async function open(path, bytes, line) {
    const page = await browser.newPage({ viewport: { width: 412, height: 820 }, deviceScaleFactor: 1 });
    // Emulate AssetLoader at its real HTTPS origin without contacting that host.
    // The only network response source is the isolated fixture server above.
    await page.route('**/*', async route => {
      const target = new URL(route.request().url());
      if (target.protocol === 'blob:' || target.protocol === 'data:') return route.continue();
      if (target.origin !== NATIVE_ORIGIN || !target.pathname.startsWith('/document/')) return route.abort();
      await route.fulfill({ response: await route.fetch({ url: `${localOrigin}${target.pathname}${target.search}` }) });
    });
    const errors = []; const frames = []; const workers = []; const requests = []; const leases = new Map(); let revision = 1; let content = bytes;
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', event => { if (event.type() === 'error') errors.push(event.text()); });
    page.on('worker', worker => workers.push(worker.url()));
    page.on('request', request => requests.push(request.url()));
    await page.exposeBinding('__documentDispatch', async (_source, raw) => {
      const message = JSON.parse(raw); assert.equal(typeof message.id, 'string', 'every native control frame has an id'); frames.push(message);
      const reply = payload => page.evaluate(value => window.PocketDocument.onmessage?.({ data: JSON.stringify(value) }), { id: message.id, ...payload });
      const metadata = () => ({ absolutePath: `/workspace/${path}`, version: `${revision}`, bytes: content.length });
      if (message.kind === 'ready') return reply({ result: { sessionId: 'document-session', path, line, locale: 'en', dark: path.endsWith('.pdf'), topInset: 72, bottomInset: 20, background: path.endsWith('.pdf') ? '#151515' : '#ffffff', foreground: path.endsWith('.pdf') ? '#ffffff' : '#151515' } });
      if (message.kind === 'navigate') {
        assert.equal(message.sessionId, 'document-session');
        return message.path === 'denied.md'
          ? reply({ error: { code: 'document/inactive', message: 'Document page is no longer current' } })
          : reply({ result: { opened: true } });
      }
      if (message.kind === 'call') {
        assert.ok(!('sessionId' in message.args));
        if (message.namespace === 'officeToPdf') return reply({ result: fail('gateway/service-unavailable', 'Office conversion is not available') });
        if (message.method === 'stat') return reply({ result: ok(metadata()) });
        if (message.method === 'read') {
          const offset = message.args.range?.offset ?? 1; const lines = content.toString('utf8').split('\n');
          const selected = lines.slice(offset - 1, offset + 199);
          return reply({ result: ok({ ...metadata(), text: selected.join('\n'), offset, lines: selected.length, eof: offset + selected.length > lines.length }) });
        }
        if (message.method === 'readBytes') {
          const range = message.args.options?.range; const offset = range?.offset ?? 0;
          const data = content.subarray(offset, range?.length === undefined ? undefined : offset + range.length);
          const id = `lease-${message.id}`; leases.set(id, data);
          return reply({ result: ok({ ...metadata(), offset, eof: offset + data.length >= content.length, data: { encoding: 'android-byte-lease', id, length: data.length } }) });
        }
      }
      if (message.kind === 'bytes') {
        const lease = leases.get(message.leaseId); const data = lease.subarray(message.offset, message.offset + message.length);
        return reply({ result: ok({ offset: message.offset, data: data.toString('base64'), eof: message.offset + data.length >= lease.length }) });
      }
      if (message.kind === 'release') { leases.delete(message.leaseId); return; }
      if (message.kind === 'subscribe') {
        // Native may deliver the first event before its subscription receipt.
        await reply({ event: { kind: 'ready' }, sequence: 1, generation: 1 });
        return reply({ result: ok({ subscribed: true }) });
      }
    });
    await page.addInitScript(() => { window.PocketDocument = { onmessage: null, postMessage: frame => { void window.__documentDispatch(frame); } }; });
    await page.goto(url);
    await page.waitForFunction(() => document.documentElement.dataset.documentReady === 'true' || document.querySelector('.document-failure'));
    const failure = await page.locator('.document-failure').allTextContents();
    assert.deepEqual(failure, [], errors.join('\n'));
    return { page, frames, errors, leases, workers, requests, change: async text => {
      content = Buffer.from(text); revision++;
      const stream = frames.find(frame => frame.kind === 'subscribe');
      await page.evaluate(frame => window.PocketDocument.onmessage({ data: JSON.stringify(frame) }), { id: stream.id, event: { kind: 'change', change: { absolutePath: `/workspace/${path}`, version: `${revision}` } }, sequence: 2, generation: 1 });
    } };
  }

  for (const [name, fixture, selector] of [
    ['notes.txt', Buffer.from('Original document text'), '[data-textpreview-line]'],
    ['readme.md', Buffer.from('# Original Markdown\n\n**Strong content** — the original document viewer now runs inside the Android shell.\n\n## Reading and navigation\n\n- Preserve the document renderer\n- Keep the session permission boundary\n- Support file changes and cancellation\n\n```js\nconst document = await read();\n```\n\nThis page uses the real Markdown renderer, including headings, lists and code highlighting.'), '[data-document-markdown] h1'],
    ['guides/nested/illustrated.md', Buffer.from('# Local image\n\n![Session chart](../images/chart%20one.png)'), '[data-document-markdown] img'],
    ['links.md', Buffer.from('# External links\n\n[HTTPS guide](https://example.invalid/guide?q=preview#part)\n\n[HTTP guide](http://example.invalid/readme)\n\n[Local file](./src/example%20one.txt#L240-L242)\n\n[This document](./links.md#L3)\n\n[Denied navigation](denied.md)\n\n[Malformed line](notes.txt#L9-L2)\n\n[Other session](dsh-resource://file/session/other/secret.txt)\n\n' + Array.from({ length: 40 }, (_, i) => `Paragraph ${i}.\n\n`).join('')), '[data-document-markdown] h1'],
    ['source.js', Buffer.from('const original = 42;'), '[data-code-preview]'],
    ['sample.png', Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6+6sAAAAASUVORK5CYII=', 'base64'), '[data-image-preview] img'],
    ['sample.pdf', tinyPdf(), '[data-pdf-preview] canvas'],
    ['table.csv', Buffer.from('Name,Value\nOriginal,42\nSecond,43'), '[data-excel-preview]'],
    ['table.xlsx', workbookBytes, '[data-excel-preview]'],
    ['page.html', Buffer.from('<h1>HTML preview</h1><script>parent.__UNSAFE_HTML__=true</script><img src="https://example.invalid/no-network">'), 'iframe[data-html-preview]'],
    ['letter.docx', Buffer.from('unsupported office fixture'), '[data-textpreview-failed]'],
  ]) {
    if ((mode === 'external') !== (name === 'links.md')) continue;
    const state = await open(name, fixture);
    try {
      await state.page.locator(selector).first().waitFor({ state: 'attached', timeout: 20_000 });
      if (name.endsWith('.txt')) {
        await state.change('Updated through original resource feed');
        await state.page.getByText('Updated through original resource feed', { exact: true }).waitFor();
      }
      if (name.endsWith('.md')) {
        assert.ok((await state.page.locator('[data-document-markdown] h1').boundingBox()).y >= 118,
          'Markdown with fenced code still starts below native title and floating controls');
      }
      if (name === 'links.md') {
        for (const label of ['HTTPS guide', 'HTTP guide']) await state.page.getByRole('link', { name: label, exact: true }).click();
        await state.page.waitForFunction(() => document.querySelector('[data-document-markdown]') !== null);
        assert.deepEqual(state.frames.filter(frame => frame.kind === 'external').map(frame => frame.url), [
          'https://example.invalid/guide?q=preview#part', 'http://example.invalid/readme',
        ], 'original Markdown delegates Web links through the dedicated native message');
        assert.equal(state.page.url(), url, 'preview never navigates to the external destination');
        assert.equal(state.page.context().pages().length, 1, 'delegated links do not open a WebView popup');
        await state.page.getByRole('button', { name: 'This document', exact: true }).click();
        await state.page.waitForFunction(() => document.querySelector('[data-document-markdown]') !== null);
        assert.equal(state.frames.filter(frame => frame.kind === 'call' && frame.method === 'read').length, 1,
          'same-document navigation updates the original tab revision without reloading bytes');
        await state.page.getByRole('button', { name: 'Denied navigation', exact: true }).click();
        await state.page.getByRole('alert').filter({ hasText: 'The document could not open' }).waitFor();
        await state.page.getByRole('alert').click();
        assert.equal(await state.page.getByRole('button', { name: 'Malformed line', exact: true }).count(), 0);
        assert.equal(await state.page.getByRole('button', { name: 'Other session', exact: true }).count(), 0,
          'raw resource URLs retain original Markdown sanitization');
        await state.page.getByRole('button', { name: 'Local file', exact: true }).click();
        const local = state.frames.filter(frame => frame.kind === 'navigate').at(-1);
        assert.deepEqual({ sessionId: local.sessionId, path: local.path, line: local.line, replace: local.replace },
          { sessionId: 'document-session', path: 'src/example one.txt', line: 240, replace: false },
          'original Markdown decoder and fileAddressFor retain workspace-root, decoded name, and range start');
        const before = await state.page.locator('[data-textpreview-body]').evaluate(element => { element.scrollTop = 300; return element.scrollTop; });
        const child = await open(local.path, Buffer.from(Array.from({ length: 300 }, (_, i) => `Source line ${i + 1}`).join('\n')), local.line);
        try {
          await child.page.getByText('Source line 240', { exact: true }).waitFor();
          await child.page.waitForFunction(() => document.querySelector('[data-textpreview-body]')?.scrollTop > 0);
          assert.ok(child.frames.some(frame => frame.kind === 'call' && frame.method === 'read' && frame.args.range.offset > 1),
            'original reader loads further pages to satisfy navigation line');
          assert.deepEqual(child.errors, []);
        } finally { await child.page.close(); }
        await state.page.bringToFront();
        assert.equal(await state.page.locator('[data-textpreview-body]').evaluate(element => element.scrollTop), before,
          'retained source reader keeps its scroll position when native route returns');
      }
      if (name.endsWith('illustrated.md')) {
        await state.page.waitForFunction(() => document.querySelector('[data-document-markdown] img')?.naturalWidth === 2);
        const image = await state.page.locator('[data-document-markdown] img').evaluate(async element => {
          const canvas = document.createElement('canvas'); canvas.width = 2; canvas.height = 1;
          const context = canvas.getContext('2d'); context.drawImage(element, 0, 0);
          const head = await fetch(element.src, { method: 'HEAD' });
          return { src: element.src, width: element.naturalWidth, height: element.naturalHeight,
            pixels: [...context.getImageData(0, 0, 2, 1).data],
            head: { status: head.status, type: head.headers.get('content-type'), bytes: (await head.arrayBuffer()).byteLength } };
        });
        assert.equal(image.src, `${NATIVE_ORIGIN}/document/api/file?path=${encodeURIComponent(MEDIA_PATH)}`,
          'original Markdown resolves relative images beside its host-reported absolute document path');
        assert.deepEqual([image.width, image.height], [2, 1]);
        assert.deepEqual(image.pixels, [255, 0, 0, 255, 0, 0, 255, 255], 'local PNG decodes to known visible pixels');
        assert.deepEqual(image.head, { status: 200, type: 'image/png', bytes: 0 });
      }
      if (name.endsWith('.js')) {
        assert.ok((await state.page.locator('[data-code-preview] [data-code-block-banner]').boundingBox()).y >= 72,
          'original code toolbar remains accessible below native title');
        assert.ok((await state.page.locator('[data-code-preview] pre').boundingBox()).y >= 118,
          'source scroll content starts below floating controls');
      }
      if (name.endsWith('.png')) await state.page.waitForFunction(() => document.querySelector('[data-image-preview] img')?.naturalWidth > 0);
      if (name.endsWith('.pdf')) {
        await state.page.waitForFunction(() => [...document.querySelectorAll('[data-pdf-preview] canvas')].some(canvas => canvas.width > 0 && canvas.height > 0));
        assert.equal(await state.page.evaluate(() => {
          const canvas = document.querySelector('[data-pdf-preview] canvas');
          const pixels = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
          return pixels.some((value, index) => index % 4 !== 3 && value < 128);
        }), true, 'PDF canvas contains rendered text pixels');
        assert.ok(state.workers.some(worker => worker.startsWith('blob:')), 'PDF uses original bundled worker');
      }
      if (name.endsWith('.xlsx') || name.endsWith('.csv')) {
        await state.page.locator('[data-excel-preview] canvas').first().waitFor({ state: 'attached' });
        assert.ok(state.workers.some(worker => worker.startsWith('blob:')), 'Excel uses original parser worker');
      }
      if (name.endsWith('.html')) {
        assert.equal(await state.page.locator('iframe[data-html-preview]').getAttribute('sandbox'), '');
        assert.equal(await state.page.evaluate(() => window.__UNSAFE_HTML__), undefined);
      }
      if (name.endsWith('.docx')) await state.page.getByText(/unavailable|not available/i).first().waitFor();
      assert.equal(state.leases.size, 0, `${name}: no retained byte lease after decode`);
      assert.deepEqual(state.errors, [], `${name}: browser console errors`);
      for (const request of state.requests) {
        if (request.startsWith('blob:') || request.startsWith('data:')) continue;
        const asset = new URL(request);
        assert.equal(asset.origin, new URL(url).origin, 'no external network asset');
        if (asset.pathname === '/document/api/file') {
          assert.equal(name, 'guides/nested/illustrated.md');
          assert.equal(asset.search, `?path=${encodeURIComponent(MEDIA_PATH)}`);
        } else assert.equal(asset.search, '', 'packaged asset requests do not use queries');
        assert.ok(asset.pathname.startsWith('/document/'), 'asset stays within native document prefix');
      }
      if (['readme.md', 'sample.pdf', 'table.xlsx'].includes(name)) {
        await state.page.evaluate(title => {
          const header = document.createElement('div'); header.dataset.nativeHeaderPlaceholder = '';
          header.style.cssText = 'position:fixed;z-index:10000;inset:10px 16px auto;display:flex;align-items:center;justify-content:space-between;pointer-events:none;font:600 16px system-ui;color:inherit';
          const circle = '<span style="display:grid;place-items:center;width:44px;height:44px;border-radius:50%;background:#80808035;backdrop-filter:blur(16px)">‹</span>';
          header.innerHTML = `${circle}<span style="max-width:65%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${title}</span><span style="width:44px"></span>`;
          document.body.append(header);
        }, name);
        await state.page.screenshot({ path: resolve(screenshots, `${name.replace('.', '-')}-412.png`) });
      }
      reports.push(name);
    } catch (error) {
      console.error(name, { errors: state.errors, frames: state.frames, body: (await state.page.locator('body').innerText()).slice(0, 1500) });
      throw error;
    } finally { await state.page.close(); }
  }
  assert.deepEqual(mediaRequests, mode === 'external' ? [] : [{ method: 'GET', path: MEDIA_PATH }, { method: 'HEAD', path: MEDIA_PATH }]);
  console.log(`Original document renderers passed: ${reports.join(', ')}`);
}

test('original document-only client renders supported formats, watches changes, and isolates HTML', { timeout: 120_000 }, t => checkDocuments(t, 'formats'));
test('original Markdown links use native routing, preserve source reading, and honor line navigation', { timeout: 60_000 }, t => checkDocuments(t, 'external'));
