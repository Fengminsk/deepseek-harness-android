import assert from 'node:assert/strict'
import test from 'node:test'
import { registerHooks } from 'node:module'
import { isLegacyAppUidShellEnabled, requireSupportedShellExecution } from '../runtime/shell-execution-policy.mjs'

registerHooks({ resolve(specifier, context, nextResolve) {
  if (specifier === '@deepseek-ai/dsh-bash-local') {
    return { url: 'data:text/javascript,export class LocalBashExecutor {}', shortCircuit: true }
  }
  return nextResolve(specifier, context)
} })
const { default: AndroidShell } = await import('../runtime/android-shell.mjs')

test('App-UID Shell policy requires an explicit supported mode', () => {
  assert.doesNotThrow(() => requireSupportedShellExecution('app-uid-approved', 'app-uid-approved'))
  assert.throws(() => requireSupportedShellExecution('isolated-required', 'app-uid-approved'),
    { code: 'SHELL_SANDBOX_UNAVAILABLE' })
  assert.throws(() => requireSupportedShellExecution('app-uid-approved', 'isolated-required'),
    { code: 'SHELL_SANDBOX_UNAVAILABLE' })
  assert.throws(() => requireSupportedShellExecution('app-uid-approved', 'unknown'),
    { code: 'SHELL_POLICY_INVALID' })
})

test('unset mode fails closed and an unknown mode never enables the legacy tool', () => {
  const previous = process.env.DSH_ANDROID_SHELL_EXECUTION_MODE
  delete process.env.DSH_ANDROID_SHELL_EXECUTION_MODE
  try {
    assert.equal(isLegacyAppUidShellEnabled(), false)
    assert.throws(() => requireSupportedShellExecution('app-uid-approved'),
      { code: 'SHELL_SANDBOX_UNAVAILABLE' })
    assert.equal(isLegacyAppUidShellEnabled('unknown'), false)
    assert.throws(() => requireSupportedShellExecution('app-uid-approved', 'unknown'),
      { code: 'SHELL_POLICY_INVALID' })
    assert.equal(isLegacyAppUidShellEnabled('app-uid-approved'), true)
  } finally {
    if (previous === undefined) delete process.env.DSH_ANDROID_SHELL_EXECUTION_MODE
    else process.env.DSH_ANDROID_SHELL_EXECUTION_MODE = previous
  }
})

test('shared Android shell executor does not fall back from required isolation', () => {
  const previous = process.env.DSH_ANDROID_SHELL_EXECUTION_MODE
  process.env.DSH_ANDROID_SHELL_EXECUTION_MODE = 'isolated-required'
  try {
    let launched = false
    const executor = Object.create(AndroidShell.prototype)
    executor.executeArgv = () => { launched = true }
    assert.throws(() => executor.execute({ command: 'printf unsafe' }),
      { code: 'SHELL_SANDBOX_UNAVAILABLE' })
    assert.equal(launched, false)
  } finally {
    if (previous === undefined) delete process.env.DSH_ANDROID_SHELL_EXECUTION_MODE
    else process.env.DSH_ANDROID_SHELL_EXECUTION_MODE = previous
  }
})

test('shared Android shell executor refuses the unset default before starting a child', () => {
  const previous = process.env.DSH_ANDROID_SHELL_EXECUTION_MODE
  delete process.env.DSH_ANDROID_SHELL_EXECUTION_MODE
  try {
    let launched = false
    const executor = Object.create(AndroidShell.prototype)
    executor.executeArgv = () => { launched = true }
    assert.throws(() => executor.execute({ command: 'printf unsafe' }),
      { code: 'SHELL_SANDBOX_UNAVAILABLE' })
    assert.equal(launched, false)
  } finally {
    if (previous === undefined) delete process.env.DSH_ANDROID_SHELL_EXECUTION_MODE
    else process.env.DSH_ANDROID_SHELL_EXECUTION_MODE = previous
  }
})

test('shared Android shell executor preserves explicit legacy App-UID mode', () => {
  const previous = process.env.DSH_ANDROID_SHELL_EXECUTION_MODE
  process.env.DSH_ANDROID_SHELL_EXECUTION_MODE = 'app-uid-approved'
  try {
    const executor = Object.create(AndroidShell.prototype)
    let invocation
    executor.executeArgv = (spec, argv) => { invocation = { spec, argv }; return 'started' }
    const spec = { command: 'printf ready' }
    assert.equal(executor.execute(spec), 'started')
    assert.equal(invocation.spec, spec)
    assert.equal(invocation.argv.at(-1), spec.command)
  } finally {
    if (previous === undefined) delete process.env.DSH_ANDROID_SHELL_EXECUTION_MODE
    else process.env.DSH_ANDROID_SHELL_EXECUTION_MODE = previous
  }
})
