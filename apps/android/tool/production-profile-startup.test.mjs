import test from 'node:test'
import assert from 'node:assert/strict'
import { fork } from 'node:child_process'
import { once } from 'node:events'
import { randomUUID, randomBytes } from 'node:crypto'
import { mkdtemp, mkdir, readFile, writeFile, copyFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'

async function fixture(t, fail) {
  const root = await mkdtemp(resolve('.cache/android/production-startup-host-'))
  const id = randomUUID(), home = join(root, 'native-runtime-acceptance', id)
  const runtime = join(root, 'runtime'), directory = join(root, 'fixture'), appWorkspaceRoot = join(root, 'workspace')
  const workspace = join(appWorkspaceRoot, `.device-acceptance-${id}`)
  const modelKey = randomBytes(32).toString('base64url'), closeToken = randomBytes(32).toString('base64url')
  for (const path of [home, directory, runtime, workspace]) await mkdir(path, { recursive: true })
  for (const name of ['production-profile-bootstrap.mjs', 'production-profile-model.mjs']) {
    await copyFile(new URL(`./device-runtime-acceptance/${name}`, import.meta.url), join(directory, name))
  }
  await writeFile(join(directory, 'configuration.json'), JSON.stringify({ suite: 'production-profile', expectWorkflow: false,
    runtime, workspace, appWorkspaceRoot }))
  await writeFile(join(home, 'production-profile-auth.json'), JSON.stringify({ schema: 1, caseId: id, modelKey, closeToken }))
  await writeFile(join(runtime, 'package.json'), '{"type":"module"}')
  for (const name of ['@deepseek-ai/dsh/lib/bin.js', '@deepseek-ai/dsh/lib/profile-boot.js', '@minnnng/dsh-android-runtime/index.mjs']) {
    const path = join(runtime, 'node_modules', name)
    await mkdir(resolve(path, '..'), { recursive: true })
    await writeFile(path, 'export const diagnosticFixture = true\n')
  }
  await writeFile(join(runtime, 'node_modules/@deepseek-ai/dsh/package.json'), '{"type":"module"}')
  await writeFile(join(runtime, 'bootstrap.mjs'), `
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
for (const name of ['./node_modules/@deepseek-ai/dsh/lib/bin.js', './node_modules/@deepseek-ai/dsh/lib/profile-boot.js', './node_modules/@minnnng/dsh-android-runtime/index.mjs']) await import(name);
const home = process.env.DSH_HOME;
await mkdir(join(home, 'profiles/android'), { recursive: true });
await writeFile(join(home, 'profiles/android/android-package-manager.json'), '{}');
await writeFile(join(home, 'profiles/android/cordis.yml'), '[]');
await new Promise((resolve, reject) => {
 const timeout = setTimeout(() => { clearInterval(poll); reject(new Error('No diagnostic pulse')); }, 15000);
 const poll = setInterval(async () => {
  try { const state = JSON.parse(await readFile(join(home, 'production-profile-node-pulse.json')));
   if (state.pulseCount >= 2) { clearInterval(poll); clearTimeout(timeout); resolve(); }
  } catch (error) { clearInterval(poll); clearTimeout(timeout); reject(error); }
 }, 20);
});
process.send({ ready: true });
await new Promise(resolve => process.once('message', resolve));
${fail === true ? "throw new Error('Controlled module evaluation failure')" : ''}
`)
  await writeFile(join(directory, 'launcher.mjs'), `
import { readFile } from 'node:fs/promises'; import { join } from 'node:path';
if (typeof process.getuid !== 'function') process.getuid = () => 0;
try {
 await import('./production-profile-bootstrap.mjs');
 const home = process.env.DSH_HOME, auth = JSON.parse(await readFile(join(home, 'production-profile-auth.json')));
 const proof = JSON.parse(await readFile(join(home, 'production-profile-proof.json')));
 const response = await fetch('http://127.0.0.1:' + proof.port + '/acceptance/close', { method: 'POST', headers: {
  authorization: 'Bearer ' + auth.closeToken, 'x-dsh-acceptance-case': auth.caseId } });
 if (response.status !== 200) throw new Error('Closure rejected'); await response.text();
} catch { process.exitCode = 1; } finally { process.disconnect(); }
`)
  const child = fork(join(directory, 'launcher.mjs'), { env: { ...process.env, DSH_HOME: home },
    stdio: ['ignore', 'ignore', 'pipe', 'ipc'], windowsHide: true })
  const closed = once(child, 'close')
  child.stderr.resume()
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) child.kill()
    await Promise.race([closed, new Promise((_, reject) => {
      const timer = setTimeout(() => reject(new Error('Owned startup child did not retire')), 10000)
      closed.then(() => clearTimeout(timer), () => clearTimeout(timer))
    })])
  })
  const ready = await Promise.race([once(child, 'message'), closed.then(() => { throw new Error('Startup child exited before ready') }),
    new Promise((_, reject) => { const timer = setTimeout(() => reject(new Error('Startup child readiness deadline')), 20000)
      closed.then(() => clearTimeout(timer), () => clearTimeout(timer)); child.once('message', () => clearTimeout(timer)) })])
  assert.deepEqual(ready[0], { ready: true })
  return { child, closed, home, modelKey, closeToken }
}

for (const fail of [false, true]) test(`startup observation retires after ${fail ? 'failed' : 'successful'} module evaluation`, { timeout: 30000 }, async t => {
  const f = await fixture(t, fail)
  const pulseFile = join(f.home, 'production-profile-node-pulse.json')
  const running = JSON.parse(await readFile(pulseFile))
  assert.equal(running.active, true)
  assert.ok(running.pulseCount >= 2)
  assert.equal(running.modules['profile-module'], 'loaded')
  assert.equal(running.artifacts.profileRoot, true)
  assert.ok(running.cpuUserMicros + running.cpuSystemMicros > 0)
  f.child.send({ release: true })
  const [code, signal] = await f.closed
  assert.equal(signal, null)
  assert.equal(code, fail ? 1 : 0)
  const final = JSON.parse(await readFile(pulseFile))
  assert.equal(final.active, false)
  assert.equal(JSON.parse(await readFile(join(f.home, 'production-profile-proof.json'))).closed, true)
  const events = await readFile(join(f.home, 'production-profile-startup.jsonl'), 'utf8')
  assert.equal(events.includes(fail ? 'bootstrap-failed' : 'production-bootstrap-import-returned'), true)
  for (const secret of [f.modelKey, f.closeToken]) assert.equal((JSON.stringify(final) + events).includes(secret), false)
})

test('snapshot publication failure cannot masquerade as a clean observation shutdown', { timeout: 30000 }, async t => {
  const f = await fixture(t, false)
  await mkdir(join(f.home, 'production-profile-node-pulse.json.tmp'))
  f.child.send({ release: true })
  const [code, signal] = await f.closed
  assert.equal(signal, null)
  assert.equal(code, 1)
  const final = JSON.parse(await readFile(join(f.home, 'production-profile-node-pulse.json')))
  assert.equal(final.active, true)
  assert.equal(JSON.parse(await readFile(join(f.home, 'production-profile-proof.json'))).closed, true)
  assert.match(await readFile(join(f.home, 'production-profile-startup.jsonl'), 'utf8'), /bootstrap-failed/u)
})
