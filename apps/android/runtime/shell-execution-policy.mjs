/**
 * The App-UID Shell has no OS writable-path or network confinement. Require a
 * real isolated executor by default, including when the environment is unset.
 * The explicit App-UID mode is retained only for migration diagnostics; it is
 * not a sandbox or a user-facing permission preset. This guard cannot confine
 * code already executing inside the App-UID Node host.
 */
export function isLegacyAppUidShellEnabled(processMode = process.env.DSH_ANDROID_SHELL_EXECUTION_MODE) {
  return processMode === 'app-uid-approved'
}

export function requireSupportedShellExecution(mode, processMode = process.env.DSH_ANDROID_SHELL_EXECUTION_MODE ?? 'isolated-required') {
  for (const value of [processMode, mode]) {
    if (value === 'app-uid-approved') continue
    const error = new Error(value === 'isolated-required'
    ? 'Isolated Android Shell is unavailable; the App-UID executor was not started.'
    : 'Unknown Android Shell execution policy; the App-UID executor was not started.')
    error.code = value === 'isolated-required' ? 'SHELL_SANDBOX_UNAVAILABLE' : 'SHELL_POLICY_INVALID'
    throw error
  }
}
