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

// Only the Android native rename syscall is adapted on the host. The real
// copying/fsync carrier and the original attachment/Session/ZIP owners run.
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === './immutable-file-publisher.mjs') return { url: fixture, shortCircuit: true }
    return nextResolve(specifier, context)
  },
  load(url, context, nextLoad) {
    if (url !== fixture) return nextLoad(url, context)
    return { format: 'module', shortCircuit: true, source: `
      import { createCopiedFilePublisher } from ${JSON.stringify(runtime)};
      import { link, unlink } from 'node:fs/promises';
      import { writeFileSync } from 'node:fs';
      import { sep } from 'node:path';
      const counts = { attachments: 0, sessions: 0, exports: 0 };
      const copy = createCopiedFilePublisher(async (source, target) => {
        await link(source, target);
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
