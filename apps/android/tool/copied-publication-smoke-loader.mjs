import { registerHooks } from 'node:module'
import { writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const runtime = pathToFileURL(resolve(import.meta.dirname,
  '../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/immutable-file-publisher.mjs')).href
const fixture = `${runtime}?copied-publication-fixture`
const report = process.env.POCKET_SMOKE_PUBLICATION_REPORT
if (!report) throw new Error('Copied-publication smoke requires an owned report path')
writeFileSync(report, '{}')

// Adapt Android's native exclusive rename to a host-only exclusive copy.
// The real copying/fsync carrier and original attachment/Session/ZIP owners run;
// atomic rename remains a native/package validation boundary.
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === './immutable-file-publisher.mjs') return { url: fixture, shortCircuit: true }
    return nextResolve(specifier, context)
  },
  load(url, context, nextLoad) {
    if (url !== fixture) return nextLoad(url, context)
    return { format: 'module', shortCircuit: true, source: `
      import { createCopiedFilePublisher } from ${JSON.stringify(runtime)};
      import { chmod, copyFile, unlink } from 'node:fs/promises';
      import { constants } from 'node:fs';
      import { writeFileSync } from 'node:fs';
      import { sep } from 'node:path';
      const counts = { attachments: 0, sessions: 0, exports: 0 };
      const copy = createCopiedFilePublisher(async (source, target) => {
        // Host-only exclusive destination stand-in. Android's native atomic
        // rename is validated by its own native/package checks, not this smoke.
        await copyFile(source, target, constants.COPYFILE_EXCL);
        // Windows copies the source's read-only attribute; clear only the
        // fixture's disposable intermediate name before unlinking it.
        if (process.platform === 'win32') await chmod(source, 0o600);
        await unlink(source);
      });
      export async function publishImmutableFile(source, target) {
        await copy(source, target);
        const path = target.split(sep).join('/');
        if (path.includes('/attachments/')) counts.attachments++;
        else if (path.includes('/sessions/')) counts.sessions++;
        else if (path.endsWith('.zip')) counts.exports++;
        writeFileSync(${JSON.stringify(report)}, JSON.stringify(counts));
      }
    ` }
  },
})
