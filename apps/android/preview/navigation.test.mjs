import test from 'node:test';
import assert from 'node:assert/strict';
import { SidebarRightTabRegistry } from '../../../packages/client/ui-sidebar-right/src/client/tab-registry.ts';
import { textDefinition } from '../../../packages/client/ui-sidebar-documentpreview/src/client/definition.ts';
import { parseFileLink } from '../../../packages/client/ui-primitives/src/markdown/file-link.ts';
import { sessionFileAddress } from '../../../packages/util/workspace-path/src/file-address.ts';
import { createDocumentNavigation } from './navigation.mjs';

function fixture(open) {
  const tabs = new SidebarRightTabRegistry({ effect: install => install() });
  tabs.register(textDefinition());
  const opened = [], revealed = [], errors = [];
  return { tabs, opened, revealed, errors, navigation: createDocumentNavigation({ sessionId: 'bound', path: 'guides/readme.md', tabs,
    open: async target => { opened.push(target); await open?.(target); }, reveal: line => revealed.push(line), report: error => errors.push(error) }) };
}

test('original Markdown paths and line ranges keep workspace-root semantics and filename escapes', async () => {
  const f = fixture();
  for (const raw of ['./src/example%20one.ts#L12-L19', '../report%23one%3F.md', '/workspace/code.ts#L2']) {
    const { path, ...options } = parseFileLink(raw);
    await f.navigation.openFile(path, options);
  }
  assert.deepEqual(f.opened, [
    { sessionId: 'bound', path: 'src/example one.ts', line: 12, replace: false },
    { sessionId: 'bound', path: '../report#one?.md', replace: false },
    { sessionId: 'bound', path: '/workspace/code.ts', line: 2, replace: false },
  ]);
  assert.deepEqual(f.errors, []);
});

test('same document reveals a new line only after native acceptance; failed navigation retains the reader', async () => {
  const f = fixture();
  await f.navigation.openResource(sessionFileAddress('bound', 'guides/readme.md'), { params: { line: 24 } });
  await f.navigation.openFile('./guides/readme.md');
  assert.deepEqual(f.revealed, [24, undefined]);
  const failure = fixture(() => { throw new Error('native view already closed'); });
  await failure.navigation.openFile('guides/readme.md', { line: 4 });
  assert.deepEqual(failure.revealed, []);
  assert.equal(failure.errors.length, 1);
  const cancelled = fixture(() => { throw new DOMException('closed', 'AbortError'); });
  await cancelled.navigation.openFile('other.md');
  assert.deepEqual(cancelled.errors, []);
  const normalized = [];
  const links = createDocumentNavigation({ sessionId: 'bound', path: './guides/readme.md', tabs: f.tabs,
    open: async target => normalized.push(target.path), reveal: () => {}, report: error => { throw error; } });
  await links.openFile('guides/readme.md');
  assert.deepEqual(normalized, ['./guides/readme.md'], 'equivalent original address stays on the native route');
});

test('original resource registry supports same-Session documents and rejects other scopes and types', async () => {
  const f = fixture();
  await f.navigation.openResource(sessionFileAddress('bound', 'report.pdf'), { replaceTab: true });
  for (const address of [sessionFileAddress('different', 'secret.txt'), 'dsh-resource://file/absolute/etc/passwd',
    'dsh-resource://task/list', 'dsh-resource://file/session/bound/%ZZ']) await f.navigation.openResource(address);
  await f.navigation.openResource(sessionFileAddress('bound', 'code.ts'), { params: { line: 1.2 } });
  f.tabs.register({ id: 'unsupported-special-viewer', kind: 'custom', patterns: ['dsh-resource://file/**'], title: () => 'Special view' });
  await f.navigation.openResource(sessionFileAddress('bound', 'special.ext'));
  f.navigation.openTab('settings');
  assert.deepEqual(f.opened, [{ sessionId: 'bound', path: 'report.pdf', replace: true }]);
  assert.deepEqual(f.errors.map(error => error.code), ['document/session-mismatch', 'document/unsupported-resource',
    'document/unsupported-resource', 'document/unsupported-resource', 'document/invalid-target', 'document/unsupported-resource', 'document/unsupported-resource']);
});
