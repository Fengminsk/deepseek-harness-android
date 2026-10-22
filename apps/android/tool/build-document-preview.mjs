/** Build a document-only client composition; original renderer bundles stay byte-for-byte intact. */
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { readFile, readdir, mkdir, copyFile, writeFile, lstat, realpath, rm } from 'node:fs/promises';
import { resolve, dirname, relative, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const webRequire = createRequire(resolve(repo, 'apps/web/package.json'));
const rendererRequire = createRequire(resolve(repo, 'packages/client/ui-renderer/package.json'));
export const DOCUMENT_PACKAGES = [
  'packages/client/ui-renderer', 'packages/client/resources', 'packages/client/locale',
  'packages/api/workspace-files', 'packages/client/ui-sidebar-documentpreview',
];

export async function collectDocumentBundles(root = repo) {
  const packages = [];
  for (const directory of DOCUMENT_PACKAGES) {
    const source = resolve(root, directory);
    const metadata = JSON.parse(await readFile(resolve(source, 'package.json'), 'utf8'));
    const files = (await readdir(resolve(source, 'lib'))).filter(name => /^client(?:\.[A-Za-z0-9._-]+)?\.js$/.test(name));
    if (!files.includes('client.js')) throw new Error(`Build original client artifacts first: ${metadata.name}`);
    const hashes = [];
    for (const name of files.sort()) hashes.push({ name, sha256: createHash('sha256').update(await readFile(resolve(source, 'lib', name))).digest('hex') });
    packages.push({ id: metadata.name, version: metadata.version, source: directory, files: hashes });
  }
  return packages;
}

/** Refuse linked output/ancestors before recursively replacing the one build directory. */
export async function prepareDocumentOutput(target, root = repo) {
  const cache = resolve(root, '.cache/android');
  const requested = resolve(target);
  if (!requested.startsWith(`${cache}${sep}`)) throw new Error('Document output must remain under .cache/android');
  const rootReal = await realpath(root);
  let current = root;
  for (const segment of relative(root, requested).split(sep)) {
    current = resolve(current, segment);
    let info;
    try { info = await lstat(current); } catch (error) { if (error.code === 'ENOENT') break; throw error; }
    if (info.isSymbolicLink() || !info.isDirectory()) throw new Error(`Document output must not traverse links or files: ${current}`);
    const actual = await realpath(current);
    const within = relative(rootReal, actual);
    if (within === '..' || within.startsWith(`..${sep}`)) throw new Error('Document output resolves outside the repository');
  }
  // rm removes nested links themselves; ancestor and final target are checked above.
  await rm(requested, { recursive: true, force: true });
  await mkdir(requested, { recursive: true });
}

export async function inventoryDocumentAssets(directory) {
  const assets = [];
  async function walk(current) {
    for (const entry of (await readdir(current, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
      const path = resolve(current, entry.name);
      if (entry.isSymbolicLink()) throw new Error('Linked document asset is not distributable');
      if (entry.isDirectory()) await walk(path);
      else if (entry.isFile() && path !== resolve(directory, 'asset-manifest.json')) {
        const bytes = await readFile(path);
        assets.push({ path: relative(directory, path).split(sep).join('/'), sha256: createHash('sha256').update(bytes).digest('hex'), bytes: bytes.length });
      }
    }
  }
  await walk(directory);
  return assets;
}

export async function buildDocumentPreview({ outDir = resolve(repo, '.cache/android/document-preview') } = {}) {
  const packages = await collectDocumentBundles();
  const modules = packages.map(pkg => {
    const rev = pkg.files.find(file => file.name === 'client.js').sha256;
    const url = `./bundles/??${pkg.id}/client.js&rev=${rev}`;
    // These standalone factories depend only on the exact platform singleton seed.
    return { id: pkg.id, url, initialUrl: url, rev, inject: [], external: [] };
  });
  const manifest = { rev: createHash('sha256').update(JSON.stringify(packages)).digest('hex'), modules, plugins: [] };
  const { build } = await import(pathToFileURL(webRequire.resolve('vite')).href);
  const seed = ['react', 'react/jsx-runtime', 'react-dom', 'react-dom/client', '@deepseek-ai/dsh-client-store', '@deepseek-ai/dsh-client-ui-slots', '@deepseek-ai/dsh-client-ui-primitives'];
  const aliases = seed.map(name => ({ find: new RegExp(`^${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`), replacement: webRequire.resolve(name) }));
  aliases.push({ find: /^@deepseek-ai\/cordis$/, replacement: rendererRequire.resolve('@deepseek-ai/cordis') });
  // Never erase an arbitrary caller path. Vite owns only the named cache subtree.
  const target = resolve(outDir);
  await prepareDocumentOutput(target);
  await build({
    configFile: false, root: resolve(repo, 'apps/android/preview'), base: './',
    resolve: { alias: aliases, dedupe: ['react', 'react-dom', '@deepseek-ai/cordis'] },
    define: { __POCKET_DOCUMENT_MANIFEST__: JSON.stringify(manifest), 'process.env.NODE_ENV': JSON.stringify('production') },
    build: { target: 'es2022', outDir: target, emptyOutDir: false, sourcemap: false, reportCompressedSize: false,
      rollupOptions: { output: { assetFileNames: 'assets/[name]-[hash][extname]' } } },
    logLevel: 'warn',
  });
  for (const pkg of packages) {
    const output = resolve(target, 'bundles', pkg.id);
    await mkdir(output, { recursive: true });
    for (const file of pkg.files) await copyFile(resolve(repo, pkg.source, 'lib', file.name), resolve(output, file.name));
  }
  const licenses = resolve(target, 'licenses');
  await mkdir(licenses, { recursive: true });
  await copyFile(resolve(repo, 'LICENSE'), resolve(licenses, 'DSH-LICENSE.txt'));
  // PDF/Excel licenses and embedded worker/font/CMap/WASM assets are inside the
  // unmodified original client chunks. The seed also bundles KaTeX fonts.
  const primitivesRequire = createRequire(resolve(repo, 'packages/client/ui-primitives/package.json'));
  const katexRoot = dirname(primitivesRequire.resolve('katex/package.json'));
  await copyFile(resolve(katexRoot, 'LICENSE'), resolve(licenses, 'KaTeX-LICENSE.txt'));
  const assets = await inventoryDocumentAssets(target);
  await writeFile(resolve(target, 'asset-manifest.json'), JSON.stringify({ format: 1, composition: 'document-only', manifest: manifest.rev, packages, assets }, null, 2) + '\n');
  return { directory: target, packages: packages.map(pkg => pkg.id), manifest: manifest.rev };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  console.log(JSON.stringify(await buildDocumentPreview(), null, 2));
}
