import assert from 'node:assert/strict'
import { test } from 'node:test'
import { spawn } from 'node:child_process'
import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startRecoveryAdb } from './acceptance-agent-service-recovery-device.mjs'
import { awaitRecoveryClose } from './agent-service-recovery-driver.mjs'
import { parseCommittedHold, parseTaskCompletionPhase,
  requireTaskCompletionInstrumentation, parseTaskCompletionArguments, parseCompletionInstalledPath,
  requireCompletionInstalledHash, runTaskCompletionCrashAcceptance, runTaskCompletionEntry } from './acceptance-task-completion-device.mjs'

const app = 'com.minnnng.dsh_android'
const token = 'a'.repeat(32)
const declaration = `E: instrumentation (line=50)\n` +
  `  A: android:name(0x01010003)="${app}.TaskCompletionCrashInstrumentation"\n` +
  `  A: android:targetPackage(0x01010021)="${app}"\n` +
  `  A: android:targetProcesses(0x01010541)="${app}:agent"\n`
const result = (phase, pid = 345) => `INSTRUMENTATION_RESULT: phase=${phase}\n` +
  `INSTRUMENTATION_RESULT: token=${token}\n` +
  `INSTRUMENTATION_RESULT: processPid=${pid}\n` +
  'INSTRUMENTATION_RESULT: endSeq=41\n' +
  (phase === 'verify'
    ? 'INSTRUMENTATION_RESULT: validNotice=true\n' +
      'INSTRUMENTATION_RESULT: invalidNotices=false\n' +
      'INSTRUMENTATION_RESULT: receiptsCleared=true\n'
    : 'INSTRUMENTATION_RESULT: cleaned=true\n') +
  'INSTRUMENTATION_RESULT: passed=true\nINSTRUMENTATION_CODE: -1\n'

test('requires one completion instrumentation entry in the Agent process', () => {
  assert.doesNotThrow(() => requireTaskCompletionInstrumentation(declaration))
  assert.throws(() => requireTaskCompletionInstrumentation(declaration.replace(':agent', ':main')), /lacks/)
  assert.throws(() => requireTaskCompletionInstrumentation(declaration + declaration), /lacks/)
})

test('accepts only the committed hold from this process and token', () => {
  const held = `INSTRUMENTATION_STATUS: holdReady=true\n` +
    `INSTRUMENTATION_STATUS: token=${token}\n` +
    'INSTRUMENTATION_STATUS: processPid=123\n' +
    'INSTRUMENTATION_STATUS: receiptCommitted=true\n' +
    'INSTRUMENTATION_STATUS_CODE: 1\n'
  assert.equal(parseCommittedHold(held, token), 123)
  assert.equal(parseCommittedHold(held.replace('STATUS_CODE: 1', 'STATUS_CODE: 0'), token), null)
  assert.throws(() => parseCommittedHold(held.replace('receiptCommitted=true', 'receiptCommitted=false'), token),
    /no committed/)
  assert.throws(() => parseCommittedHold(held.replace('processPid=123', 'processPid=0'), token),
    /does not match/)
})

test('requires a fresh Agent process, valid notice and terminal cleanup', () => {
  assert.deepEqual(parseTaskCompletionPhase(result('verify'), 'verify', token, 123), {
    phase: 'verify', processPid: 345, validNotice: true, invalidNotices: false, receiptsCleared: true,
  })
  assert.deepEqual(parseTaskCompletionPhase(result('cleanup', 346), 'cleanup', token), {
    phase: 'cleanup', processPid: 346, cleaned: true,
  })
  assert.throws(() => parseTaskCompletionPhase(result('verify', 123), 'verify', token, 123), /failed/)
  assert.throws(() => parseTaskCompletionPhase(result('verify').replace('validNotice=true',
    'validNotice=false'), 'verify', token, 123), /failed/)
  assert.throws(() => parseTaskCompletionPhase(result('verify').replace('receiptsCleared=true',
    'receiptsCleared=false'), 'verify', token, 123), /failed/)
  assert.throws(() => parseTaskCompletionPhase(result('verify').replace('CODE: -1',
    'CODE: 0'), 'verify', token, 123), /failed/)
  assert.throws(() => parseTaskCompletionPhase(result('verify') +
    'INSTRUMENTATION_CODE: -1\n', 'verify', token, 123), /failed/)
  assert.throws(() => parseTaskCompletionPhase(result('verify').replace('passed=true',
    'passed=false'), 'verify', token, 123), /failed/)
})

const policy = 'PhoneWindowManager\n  KeyguardServiceDelegate\n    showing=true\n    inputRestricted=true\n    occluded=false\n    systemReady=true\n'
const appHash = 'b'.repeat(64), testHash = 'c'.repeat(64)
const options = { serial: 'fixture-device', token, app: { sha256: appHash }, testApk: { sha256: testHash },
  allowExisting: true, installedOnly: true, noWake: true,
  budgets: { command: 100, hold: 100, phase: 100, retirement: 100, close: 1000 } }
const holdText = `INSTRUMENTATION_STATUS: holdReady=true\nINSTRUMENTATION_STATUS: token=${token}\n` +
  'INSTRUMENTATION_STATUS: processPid=123\nINSTRUMENTATION_STATUS: receiptCommitted=true\nINSTRUMENTATION_STATUS_CODE: 1\n'

function fixture(settings = {}) {
  const events = [], owners = []
  let clock = 0, held = null, active = settings.active ?? false, psReads = 0
  const io = { events, owners, now: () => clock,
    delay: async ms => { clock += ms; await new Promise(resolve => setImmediate(resolve)) },
    start(argv, { signal }) {
      signal?.throwIfAborted(); events.push([...argv]); clock++
      const done = Promise.withResolvers()
      const child = { text: '', ended: false, pid: 567, unreferenced: false,
        closed: done.promise, output: () => child.text, transcript: () => child.text,
        finish(code = 0) { if (!child.ended) { child.ended = true; done.resolve({ code, signal: null }) } },
        async result() { const exit = await done.promise; if (exit.code !== 0) throw new Error('private arbitrary command text'); return child.text },
        async stop() { events.push(['stop-client']); if (!settings.neverClose) child.finish(-9) },
        unref() { child.unreferenced = true },
      }
      owners.push(child)
      if (argv[0] === 'devices') child.text = 'List of devices attached\nfixture-device\tdevice\n'
      else if (argv[1] === 'dumpsys' && argv[2] === 'power') child.text = settings.power ?? 'mWakefulness=Asleep\n'
      else if (argv[1] === 'dumpsys' && argv[2] === 'window') child.text = settings.policy ?? policy
      else if (argv[1] === 'ps') {
        psReads++
        child.text = settings.malformedPs ? 'PID NAME\n' : 'PID ARGS\n' +
          (active || (settings.orphan && held) || (settings.startDuringPreflight && psReads === 2)
            ? `123 ${app}:agent\n` : '')
      } else if (argv[1] === 'pm') child.text = `package:/data/app/fixture/${argv.at(-1)}/base.apk\n`
      else if (argv[1] === 'sha256sum') child.text = `${settings.mismatch ? 'd'.repeat(64) : argv[2].includes('.test/') ? testHash : appHash}  ${argv[2]}\n`
      else if (argv[1] === 'am' && argv[2] === 'force-stop') {
        active = false
        if (argv[3] === app && held && !settings.neverClose) {
          if (settings.closeBarrier) settings.closeBarrier.promise.then(() => held.finish(1))
          else held.finish(1)
        }
        if (settings.failForceStop) { child.finish(1); return child }
      } else if (argv[1] === 'am' && argv[2] === 'instrument') {
        const phase = argv[argv.indexOf('phase') + 1]
        if (phase === 'hold') {
          active = true; held = child
          child.text = settings.noReady ? '' : settings.badHold ? holdText.replace('receiptCommitted=true', 'receiptCommitted=false') : holdText
          if (settings.normalHoldReturn) { child.text += 'INSTRUMENTATION_RESULT: passed=true\n'; child.finish() }
          settings.onHold?.()
          return child
        }
        child.text = result(phase, phase === 'verify' ? 345 : 346)
        if (settings.badVerify && phase === 'verify') child.text = child.text.replace('passed=true', 'passed=false') + 'private-tool-content\n'
        if (settings.badCleanup && phase === 'cleanup') child.text = child.text.replace('cleaned=true', 'cleaned=false')
        if (settings.cancelDuringCleanup && phase === 'cleanup') settings.cancelDuringCleanup.abort(new Error('private cancellation'))
      } else assert.fail(`Unexpected argv ${JSON.stringify(argv)}`)
      child.finish()
      return child
    },
  }
  return io
}

const execute = (io, extra = {}) => runTaskCompletionCrashAcceptance(io, { ...options, ...extra })
const cli = ['--apk', 'app.apk', '--test-apk', 'test.apk', '--adb', 'adb.exe', '--serial', 'fixture-device',
  '--allow-existing', '--installed-only', '--no-wake', '--report', 'new-report.json']

test('device mode requires every explicit noninstalling flag and preserves artifact-only preflight', () => {
  assert.equal(parseTaskCompletionArguments(cli).installedOnly, true)
  assert.equal(parseTaskCompletionArguments(['--apk', 'a.apk', '--test-apk', 'b.apk', '--preflight-only']).preflightOnly, true)
  for (const flag of ['--allow-existing', '--installed-only', '--no-wake'])
    assert.throws(() => parseTaskCompletionArguments(cli.filter(value => value !== flag)), /Missing/)
  assert.throws(() => parseTaskCompletionArguments([...cli, '--report', 'other.json']), /Duplicate/)
  assert.throws(() => parseTaskCompletionArguments([...cli, '--install']), /Unknown/)
})

test('installed identity rejects splits, traversal and checksum output for a different path', () => {
  const path = '/data/app/~~safe=/com.minnnng.dsh_android-a==/base.apk'
  assert.equal(parseCompletionInstalledPath(`package:${path}\n`), path)
  assert.throws(() => parseCompletionInstalledPath(`package:${path}\npackage:/data/app/split.apk`), /ambiguous/)
  assert.throws(() => parseCompletionInstalledPath('package:/data/app/../base.apk'), /ambiguous/)
  assert.throws(() => parseCompletionInstalledPath('package:/data/app/x;id/base.apk'), /ambiguous/)
  assert.doesNotThrow(() => requireCompletionInstalledHash(`${appHash}  ${path}\n`, path, appHash))
  assert.throws(() => requireCompletionInstalledHash(`${testHash}  ${path}\n`, path, appHash), /differs/)
  assert.throws(() => requireCompletionInstalledHash(`${appHash}  ${path}.wrong\n`, path, appHash), /differs/)
})

test('installed-only hold is immediately killed and returns only after synthetic cleanup and all client closes', async () => {
  const io = fixture(), report = await execute(io)
  assert.equal(report.result, 'pass'); assert.equal(report.heldPid, 123)
  assert.deepEqual(report.retirement, { hostProcessClosed: true, deviceProcessesGone: true, forceStopConfirmed: true, confirmed: true })
  assert.equal(report.syntheticStateMayRemain, false)
  const holdIndex = io.events.findIndex(argv => argv.includes('hold'))
  assert.deepEqual(io.events[holdIndex + 1], ['shell', 'am', 'force-stop', app])
  assert.deepEqual(io.events.filter(argv => argv.includes('instrument')).map(argv => argv[argv.indexOf('phase') + 1]), ['hold', 'verify', 'cleanup'])
  assert.ok(io.owners.every(child => child.ended))
  assert.ok(!io.events.some(argv => argv.includes('install') || argv.includes('start') || argv.includes('input')))
})

test('unlocked, active, changed-installed and malformed process states refuse before starting instrumentation', async () => {
  for (const settings of [{ power: 'mWakefulness=Awake\n' }, { policy: policy.replace('showing=true', 'showing=false') },
    { active: true }, { mismatch: true }, { malformedPs: true }, { startDuringPreflight: true }]) {
    const io = fixture(settings)
    await assert.rejects(execute(io), error => error.completion.result === 'unknown')
    assert.ok(!io.events.some(argv => argv.includes('instrument') || argv.includes('force-stop')))
    assert.ok(io.owners.every(child => child.ended))
  }
})

test('cancellation in committed hold stops both packages and joins clients without verifying or clearing unknown receipts', async () => {
  const controller = new AbortController(), io = fixture({ onHold: () => controller.abort(new Error('private cancellation')) })
  await assert.rejects(execute(io, { signal: controller.signal }), error => {
    assert.equal(error.completion.result, 'unknown')
    assert.equal(error.completion.syntheticStateMayRemain, true)
    assert.equal(error.retirement.confirmed, true)
    assert.equal(JSON.stringify(error.completion).includes('private'), false)
    return true
  })
  assert.ok(io.events.some(argv => argv.at(-1) === `${app}.test` && argv.includes('force-stop')))
  assert.ok(!io.events.some(argv => argv.includes('verify') || argv.includes('cleanup')))
  assert.ok(io.owners.every(child => child.ended))
})

test('held process close is awaited before any verify invocation', async () => {
  const barrier = Promise.withResolvers(), io = fixture({ closeBarrier: barrier })
  const pending = execute(io)
  while (!io.events.some(argv => argv.includes('force-stop'))) await new Promise(resolve => setImmediate(resolve))
  assert.ok(!io.events.some(argv => argv.includes('verify')))
  barrier.resolve()
  assert.equal((await pending).result, 'pass')
})

test('failed verification, readiness and cleanup preserve failure and never publish arbitrary tool text', async () => {
  for (const settings of [{ badVerify: true }, { badHold: true }, { noReady: true }, { normalHoldReturn: true }, { badCleanup: true }]) {
    const io = fixture(settings)
    await assert.rejects(execute(io), error => {
      assert.equal(error.completion.result, 'unknown'); assert.equal(error.retirement.confirmed, true)
      assert.equal(JSON.stringify(error.completion).includes('private-tool-content'), false)
      return true
    })
    if (settings.badVerify) assert.ok(!io.events.some(argv => argv.includes('cleanup')))
    assert.ok(io.owners.every(child => child.ended))
  }
})

test('cleanup cancellation cannot turn into a pass and still clears only the acknowledged synthetic receipt', async () => {
  const controller = new AbortController(), io = fixture({ cancelDuringCleanup: controller })
  await assert.rejects(execute(io, { signal: controller.signal }), error => {
    assert.equal(error.completion.cleaned.cleaned, true)
    assert.equal(error.retirement.confirmed, true)
    return error.completion.result === 'unknown'
  })
})

test('unclosed owned client, failed force-stop and surviving full-name process never confirm retirement', async () => {
  for (const settings of [{ neverClose: true }, { orphan: true }, { failForceStop: true }]) {
    const io = fixture(settings)
    await assert.rejects(execute(io, settings.neverClose ? { budgets: { ...options.budgets, close: 20 } } : {}), error => {
      assert.equal(error.completion.result, 'unknown'); assert.equal(error.retirement.confirmed, false)
      assert.ok(error.completion.cleanupFailures.length > 0)
      return true
    })
  }
})

test('real bounded client waits for close after spawn error and after explicit cancellation', async () => {
  const failed = startRecoveryAdb('ignored', 'fixture', [], { timeoutMs: 1000,
    launch: () => { const child = new EventEmitter(); child.stdout = new PassThrough(); child.stderr = new PassThrough()
      child.kill = () => true; child.unref = () => {}; queueMicrotask(() => {
        child.emit('error', new Error('spawn failed')); child.emit('close', -2, null)
      }); return child },
  })
  await assert.rejects(failed.result(), /failed/)
  assert.equal((await failed.closed).code, -2)
  const controller = new AbortController()
  const owned = startRecoveryAdb('ignored', 'fixture', [], { timeoutMs: 10000, signal: controller.signal,
    launch: (_binary, _argv, spawnOptions) => spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)'], spawnOptions) })
  controller.abort(new Error('cancel'))
  await assert.rejects(owned.result(), /failed/)
  await awaitRecoveryClose(owned.closed, 5000)
  assert.throws(() => process.kill(owned.pid, 0))
})


test('entry refuses an existing report before artifact or device work and persists a cancelled run token', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'completion-owner-'))
  const path = join(directory, 'report.json'), args = cli.map(value => value === 'new-report.json' ? path : value)
  try {
    await writeFile(path, 'existing evidence')
    await assert.rejects(runTaskCompletionEntry(args), error => error.code === 'EEXIST')
    assert.equal(await readFile(path, 'utf8'), 'existing evidence')
    await rm(path)
    const controller = new AbortController(); controller.abort(new Error('private reason'))
    await assert.rejects(runTaskCompletionEntry(args, { signal: controller.signal }), error => error.completion.result === 'unknown')
    const text = await readFile(path, 'utf8'), report = JSON.parse(text)
    assert.match(report.token, /^[0-9a-f]{32}$/)
    assert.equal(report.retirement.confirmed, false)
    assert.equal(text.includes('private reason'), false)
  } finally { await rm(directory, { recursive: true, force: true }) }
})
