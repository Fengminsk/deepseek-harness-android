import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink, lstat } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { collectDocumentBundles, inventoryDocumentAssets, prepareDocumentOutput } from './build-document-preview.mjs';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const cache = resolve(repo, '.cache/android');

test('all original renderer chunk hashes and packaged asset inventory are complete', async () => {
  const original = await collectDocumentBundles();
  const manifest = JSON.parse(await readFile(resolve(cache, 'document-preview/asset-manifest.json'), 'utf8'));
  assert.deepEqual(manifest.packages, original);
  const viewer = original.find(pkg => pkg.id.endsWith('ui-sidebar-documentpreview'));
  assert.ok(viewer.files.some(file => file.name === 'client.pdf.js'));
  assert.ok(viewer.files.some(file => file.name === 'client.excel.js'));
  for (const pkg of original) for (const file of pkg.files) {
    const data = await readFile(resolve(cache, 'document-preview/bundles', pkg.id, file.name));
    assert.equal(createHash('sha256').update(data).digest('hex'), file.sha256);
  }
  assert.deepEqual(manifest.assets, await inventoryDocumentAssets(resolve(cache, 'document-preview')));
  assert.ok(manifest.assets.some(file => file.path.endsWith('.woff2')), 'original math fonts are present');
  assert.ok(manifest.assets.some(file => file.path === 'licenses/KaTeX-LICENSE.txt'));
  const pdf = await readFile(resolve(cache, 'document-preview/bundles', viewer.id, 'client.pdf.js'), 'utf8');
  const excel = await readFile(resolve(cache, 'document-preview/bundles', viewer.id, 'client.excel.js'), 'utf8');
  assert.ok(pdf.includes('Apache License'));
  assert.ok(excel.includes('Copyright (c) 2022 Suzhou Ruilisi Technology Co., Ltd'));
});

test('rebuilding removes only the verified output and refuses an escaping or linked output', async t => {
  await mkdir(cache, { recursive: true });
  const fixture = await mkdtemp(resolve(cache, 'preview-output-test-'));
  t.after(() => rm(fixture, { recursive: true, force: true }));
  const nested = resolve(fixture, 'output');
  await mkdir(nested);
  await writeFile(resolve(nested, 'stale.js'), 'old hashed file');
  await prepareDocumentOutput(nested);
  await assert.rejects(lstat(resolve(nested, 'stale.js')), { code: 'ENOENT' });
  await assert.rejects(prepareDocumentOutput(resolve(repo, 'packages')), /must remain/);
  const linked = resolve(fixture, 'linked');
  await symlink(resolve(repo, 'packages'), linked, 'junction');
  await assert.rejects(prepareDocumentOutput(resolve(linked, 'output')), /must not traverse links/);
});
