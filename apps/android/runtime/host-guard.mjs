import { isDeepStrictEqual } from 'node:util'
import { join } from 'node:path'
import { createRequire } from 'node:module'
import { realpathSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import {
  bundlePatchPaths, composeEntries, evaluatePluginCompatibility, loadOptionalPatches,
  loadOverlayPatches, readProfileManifest, readProfileVersionExemptions, resolveBundleDir,
} from '@deepseek-ai/dsh-app-boot'

/** Packaged Android composition; user bundles may extend this ordered base. */
export const ANDROID_BUNDLES = Object.freeze([
  '@deepseek-ai/dsh-base',
  '@deepseek-ai/dsh-web-app',
  '@minnnng/dsh-android-runtime',
])

// Config remains editable. These entries own the native carrier, shared state,
// browser authentication, or the static listeners the App must keep disabled.
const HOST_ENTRIES = new Set([
  'android-runtime', 'credentials', 'authorization', 'deepseek-account',
  'web-startup', 'webserver', 'web-runtime', 'connection', 'session-controller',
  'session-persistence-jsonl', 'android-session-persistence', 'settings', 'file-upload',
  'attachment-local', 'android-attachment-store', 'working-directory', 'agent-loop',
  'workspace', 'workspace-controller', 'android-directory-picker', 'android-filesystem',
  'config-editor', 'plugin-manager',
])

function reject(reason, entry) {
  const error = new Error(`Pocket Harness startup refused: ${reason}${entry ? ` (${entry})` : ''}. `
    + 'Restore the Android host configuration in App recovery, then resume.')
  error.code = 'ANDROID_HOST_CONFIGURATION'
  error.entry = entry
  throw error
}

function flatten(entries, parents = []) {
  return entries.flatMap(entry => [
    { entry, parents },
    ...(entry.group && Array.isArray(entry.config)
      ? flatten(entry.config, [...parents, entry]) : []),
  ])
}

function structure(entry) {
  const { config: _config, ...value } = entry
  return value
}

function assertComposition(canonical, effective, moduleIdentity) {
  const original = flatten(canonical), actual = flatten(effective)
  const protectedModules = new Set(original
    .filter(({ entry }) => HOST_ENTRIES.has(entry.id)).map(({ entry }) => moduleIdentity(entry.name)))
  for (const id of HOST_ENTRIES) {
    const expected = original.filter(({ entry }) => entry.id === id)
    if (expected.length !== 1) reject('the packaged host entry is missing or ambiguous', id)
    const found = actual.filter(({ entry }) => entry.id === id)
    if (found.length !== 1) reject('a required host entry is missing or duplicated', id)
    if (!isDeepStrictEqual(structure(found[0].entry), structure(expected[0].entry))
      || !isDeepStrictEqual(found[0].parents.map(structure), expected[0].parents.map(structure))) {
      reject('a user layer changes a required host entry or its owning group', id)
    }
  }
  // A second row under a different ID must not instantiate another listener,
  // credential store, or native carrier beside the protected original.
  for (const name of protectedModules) {
    const expected = original.filter(({ entry }) => moduleIdentity(entry.name) === name).map(({ entry }) => entry.id).sort()
    const found = actual.filter(({ entry }) => moduleIdentity(entry.name) === name).map(({ entry }) => entry.id).sort()
    if (!isDeepStrictEqual(found, expected)) reject('a host module has an additional or substituted entry', name)
  }
  const connection = actual.find(({ entry }) => entry.id === 'connection').entry
  const config = connection.config
  if (config && (typeof config !== 'object' || Array.isArray(config) || Object.hasOwn(config, '__jsExpr'))) {
    reject('browser trust configuration must be readable before plugin activation', 'connection')
  }
  // Connection's original schema defaults an omitted trustedHosts to [].
  if (config?.trustedHosts !== undefined && !isDeepStrictEqual(config.trustedHosts, [])) {
    reject('browser trusted hosts must remain owned by the App listener', 'connection')
  }
}

/**
 * Reject raw profile layers that replace Android host entries before any plugin starts.
 * Uses the original parser, bundle resolution, compatibility and composition
 * functions without evaluating !!js, importing plugins, or writing profile files.
 * This is an assembly check, not a sandbox for executable plugin/config code.
 * @param {{home: string, installAnchor: string}} options Native DSH home and packaged CLI anchor.
 * @returns {void} Returns only when the current profile preserves the packaged host.
 */
export function assertAndroidHostConfiguration({ home, installAnchor }) {
  const directory = join(home, 'profiles', 'android')
  const manifest = readProfileManifest('Pocket Harness', directory)
  const bundles = manifest.dsh?.profile?.bundles
  if (!Array.isArray(bundles) || bundles.some(name => typeof name !== 'string')
    || ANDROID_BUNDLES.some(name => bundles.filter(value => value === name).length !== 1)) {
    reject('the profile must select each required Android bundle exactly once')
  }
  const exemptions = readProfileVersionExemptions(directory)
  const layers = new Map()
  for (const name of bundles) {
    try {
      const packageDir = resolveBundleDir('Pocket Harness', name, installAnchor, directory)
      const metadata = readProfileManifest('Pocket Harness', packageDir)
      const issue = evaluatePluginCompatibility(metadata, exemptions)
      if (issue && !issue.exempted) throw new Error('Incompatible bundle')
      layers.set(name, bundlePatchPaths(packageDir, metadata.dsh?.bundle)
        .flatMap(path => loadOverlayPatches('Pocket Harness', path)))
    } catch (error) {
      if (ANDROID_BUNDLES.includes(name)) {
        const failure = new Error(`Pocket Harness could not read required bundle ${name}`, { cause: error })
        failure.code = 'ANDROID_HOST_CONFIGURATION'
        throw failure
      }
      // The original loader skips unavailable optional bundles; it reports the
      // reason during ordinary boot. Do not normalize the user's manifest here.
    }
  }
  const canonical = composeEntries(ANDROID_BUNDLES.map(name => layers.get(name)))
  const effective = composeEntries([
    ...bundles.flatMap(name => layers.has(name) ? [layers.get(name)] : []),
    loadOptionalPatches('Pocket Harness', join(directory, 'cordis.patch.yml')) ?? [],
    loadOptionalPatches('Pocket Harness', join(home, 'cordis.patch.yml')) ?? [],
  ])
  const resolveModule = createRequire(installAnchor)
  const resolveProfileModule = createRequire(join(directory, 'package.json'))
  const identities = new Map()
  const moduleIdentity = name => {
    if (identities.has(name)) return identities.get(name)
    let identity = name
    try {
      const path = name.startsWith('file:') ? fileURLToPath(name) : resolveModule.resolve(name)
      identity = realpathSync(path)
    } catch (_error) {
      void _error
      try { identity = realpathSync(resolveProfileModule.resolve(name)) } catch (_profileError) {
        void _profileError
        // Unresolved extensions retain their literal identity; normal boot owns
        // their resolution diagnostic. No plugin is imported by this check.
      }
    }
    identities.set(name, identity)
    return identity
  }
  assertComposition(canonical, effective, moduleIdentity)
}
