import * as React from 'react';
import * as ReactJSX from 'react/jsx-runtime';
import * as ReactDOM from 'react-dom';
import * as ReactDOMClient from 'react-dom/client';
import * as Cordis from '@deepseek-ai/cordis';
import * as Store from '@deepseek-ai/dsh-client-store';
import * as Slots from '@deepseek-ai/dsh-client-ui-slots';
import * as Primitives from '@deepseek-ai/dsh-client-ui-primitives';
import { ClientModuleSystem } from '../../../packages/client/modules/src/client/system.ts';
import { SidebarRightTabRegistry } from '../../../packages/client/ui-sidebar-right/src/client/tab-registry.ts';
import { RemoteStream } from '../../../packages/api/gateway/src/client/remote-stream.ts';
import { installThemeStyles } from '../../../packages/client/ui-theme/src/client/styles.ts';
import { sessionFileAddress } from '../../../packages/util/workspace-path/src/file-address.ts';
import { DocumentBridge, createDocumentRemote } from './bridge.mjs';
import './shell.css';

const PREVIEW = '@deepseek-ai/dsh-client-ui-sidebar-documentpreview';
const observable = value => ({ getSnapshot: () => value, subscribe: () => () => {} });
const bridge = new DocumentBridge(window.PocketDocument);
const lifetime = new AbortController();
const ctx = new Cordis.Context();
let unmount;
let disposed;
async function close() {
  if (disposed) return disposed;
  lifetime.abort();
  unmount?.();
  bridge.close();
  disposed = ctx.fiber.dispose();
  return disposed;
}
window.addEventListener('pagehide', () => { void close(); }, { once: true });

async function boot() {
  const config = await bridge.ready(lifetime.signal);
  if (!config || typeof config.sessionId !== 'string' || !config.sessionId || typeof config.path !== 'string') throw new Error('Invalid native document configuration');
  document.body.toggleAttribute('data-ds-dark-theme', config.dark === true);
  document.documentElement.style.colorScheme = config.dark ? 'dark' : 'light';
  for (const [name, value] of [['top', config.topInset], ['bottom', config.bottomInset]]) {
    document.documentElement.style.setProperty(`--document-${name}-inset`, `${Number.isFinite(value) ? Math.max(0, value) : 0}px`);
  }
  for (const [name, value] of [['background', config.background], ['foreground', config.foreground]]) {
    if (/^#[a-f\d]{6}$/i.test(value)) document.documentElement.style.setProperty(`--document-${name}`, value);
  }
  window.__DSH_LOCALE__ = { read: async () => ({ languages: [config.locale ?? 'zh-CN'], preference: config.locale?.startsWith('en') ? 'en' : 'zh' }), onChange() {} };
  const target = { mode: 'queue', pendingQueue: [], load(registration) { this.pendingQueue.push(registration); } };
  window.__ModuleLoader__ = target;
  const modules = new ClientModuleSystem({
    manifest: __POCKET_DOCUMENT_MANIFEST__, registrationTarget: target,
    bootstrapModule: { id: '@pocket/document-shell', exports: {} },
    staticModules: { react: React, 'react/jsx-runtime': ReactJSX, 'react-dom': ReactDOM, 'react-dom/client': ReactDOMClient,
      '@deepseek-ai/cordis': Cordis, '@deepseek-ai/dsh-client-store': Store, '@deepseek-ai/dsh-client-ui-slots': Slots,
      '@deepseek-ai/dsh-client-ui-primitives': Primitives },
    loadBundle: async url => {
      // ClientModuleSystem uses the original /?? package URLs for chunk identity;
      // this local transport resolves those URLs onto immutable packaged assets.
      const actual = url.includes('/??') ? url.replace('/??', '/').replace('&rev=', '?rev=') : url;
      const resolved = new URL(actual, location.href);
      if (resolved.origin !== location.origin || !resolved.pathname.startsWith(new URL('./bundles/', location.href).pathname)) throw new Error('Invalid document module URL');
      resolved.search = ''; // AssetLoader serves immutable APK assets, never an HTTP combo endpoint.
      await new Promise((resolve, reject) => {
        const script = document.createElement('script'); script.src = resolved.href;
        script.onload = () => { script.remove(); resolve(); };
        script.onerror = () => { script.remove(); reject(new Error('Document module failed to load')); };
        document.head.append(script);
      });
    },
  });
  const activate = async id => {
    const plugin = await modules.import(id);
    for (const dependency of plugin.inject ?? []) if (ctx.get(dependency) === undefined) throw new Error(`Document dependency missing: ${dependency}`);
    const fiber = ctx.plugin(plugin); await fiber.await();
  };
  await activate('@deepseek-ai/dsh-client-ui-renderer');
  const remote = createDocumentRemote(bridge, config.sessionId, options => new RemoteStream({ generation: observable(1) }, options));
  const services = ctx.plugin({ name: 'android-document-services', apply(owner) {
    installThemeStyles(owner);
    owner.reflect.provide('remote', remote);
    owner.reflect.provide('remote.workspaceFiles', remote.workspaceFiles);
    owner.reflect.provide('remote.officeToPdf', remote.officeToPdf);
    owner.reflect.provide('sidebarRightTabs', new SidebarRightTabRegistry(owner));
    // This read-only surface has no settings host. HTML keeps the original safe
    // static mode; the original Office service reports its unavailable result.
    owner.reflect.provide('configForms', { get: () => undefined, developerTools: { enabled: observable(false) } });
  } });
  await services.await();
  const binding = { key: config.sessionId, ctx: services.ctx, hooks: {}, keyedHooks: {}, props: { sessionId: config.sessionId } };
  const current = observable(binding);
  const absent = observable({ key: undefined, hooks: {}, keyedHooks: {}, props: {} });
  const reference = Object.freeze({ sessionId: config.sessionId });
  ctx.slots.installScope('session', { current, bindingSource: target => {
    if (target === undefined) return absent;
    if (target !== reference) throw new Error('Invalid document SessionProvider target');
    return current;
  }, renderArea: (selected, props) => selected.key === undefined ? props.empty?.() ?? null : props.children });
  await activate('@deepseek-ai/dsh-client-locale');
  await activate('@deepseek-ai/dsh-client-resources');
  await activate('@deepseek-ai/dsh-api-workspace-files');
  const address = sessionFileAddress(config.sessionId, config.path);
  let commands;
  const tabInfo = Object.freeze({ sidebar: { expanded: true, fullscreen: true }, panel: { id: 'document' }, tab: {
    id: 'document', kind: 'text', contentId: address, title: config.path.split('/').at(-1), visible: true,
    navigation: { address, params: Number.isSafeInteger(config.line) && config.line > 0 ? { line: config.line } : undefined, revision: 1 },
    signal: lifetime.signal,
    actions: { bindCommands(value) { commands = value; return () => { if (commands === value) commands = undefined; }; },
      openResource() { throw new Error('Open documents through the native file browser'); }, openTab() { throw new Error('Only documents can open in this surface'); }, close() { void close(); } },
  } });
  const shell = ctx.plugin({ name: 'android-document-shell', inject: ['slots'], apply(owner) {
    owner.slots.register({ name: 'root', children: {
      'sidebar.right.pane.tab': { kind: 'keyed', scope: 'session', inject: { hooks: { tabInfo: () => () => tabInfo } } },
      'sidebar.right.pane.tab.title': { kind: 'keyed', scope: 'session', inject: { hooks: { tabInfo: () => () => tabInfo } } },
    } }, ({ renderSlot, SessionProvider }) => React.createElement(SessionProvider, { session: reference },
      React.createElement(Primitives.MarkdownDelegateProvider, { openExternalLink: url => bridge.openExternalLink(url) },
        renderSlot('sidebar.right.pane.tab', {}, { entryKey: PREVIEW, hookContext: tabInfo }))));
  } });
  await shell.await();
  await activate(PREVIEW);
  lifetime.signal.throwIfAborted();
  unmount = ctx.uiRenderer.mount(document.getElementById('document-root'));
  document.documentElement.dataset.documentReady = 'true';
}

boot().catch(error => {
  if (lifetime.signal.aborted) return;
  const failure = document.createElement('p'); failure.setAttribute('role', 'alert'); failure.className = 'document-failure';
  failure.textContent = `无法打开文档：${error.message}`;
  document.getElementById('document-root').replaceChildren(failure);
  console.error('Document preview initialization failed', error);
  void close();
});
