/**
 * Host half of the Device Interconnect bundle.
 *
 * The plugin lives in the DSH Host process and does one of two things: it
 * serves the Settings page's bridge routes, and it supervises a separate
 * remote-host child process. The remote host itself is never imported here —
 * it is reached only through its loopback pairing-control HTTP API, so this
 * bundle stays loadable by a stock DSH distribution.
 * @module @deepseek-ai/dsh-device-interconnect/host/plugin
 */

import { join } from 'node:path'
import type { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-host-webserver'
import { API_PREFIX } from '../api.ts'
import { Bridge } from './bridge.ts'
import {
  CONFIG_FILE_NAME, ConfigStore, dataDirectory, defaultConfig, normalizeConfig, processInferenceEnvironment,
} from './config.ts'
import { createControlPlane } from './control-plane.ts'
import { createApiHandler } from './routes.ts'
import { HostSupervisor } from './supervisor.ts'

/** Plugin name shown in DSH diagnostics. */
export const name = 'device-interconnect'

/**
 * First-run seeds for the persisted configuration. Only `enabled` is normally
 * set in the bundle row; every other absent field falls back to the product
 * defaults, and once `config.json` exists it is the single source of truth.
 */
export type Config = Partial<import('../types.ts').DeviceInterconnectConfig>

/**
 * Register the Settings page bridge and start the supervised remote host when
 * the persisted configuration has it enabled.
 * @param ctx - Host context; the web server service is read optionally so a
 * profile without a browser surface still loads this plugin.
 * @param config - first-run seed from the bundle row.
 * @returns completion once the registration and the initial start were attempted.
 */
export async function apply(ctx: Context, config: Config = {}): Promise<void> {
  const logger = ctx.logger('device-interconnect')
  const inference = processInferenceEnvironment()
  const fallback = defaultConfig(inference)
  const seed = normalizeConfig(config, fallback)
  if (!seed.ok) throw new Error(`device-interconnect: invalid bundle configuration: ${seed.problems.join('; ')}`)
  const dataDir = dataDirectory(inference.env)
  const store = new ConfigStore({ file: join(dataDir, CONFIG_FILE_NAME), fallback: seed.config, logger })
  const supervisor = new HostSupervisor({ logger })
  const bridge = new Bridge({
    dataDir,
    store,
    supervisor,
    controlPlane: baseUrl => createControlPlane({ baseUrl }),
    logger,
  })
  const webServer = ctx.get('webServer')
  if (webServer === undefined) {
    logger.warn('device-interconnect: the web server service is unavailable, so the Settings page bridge was not registered')
  } else {
    ctx.effect(
      () => webServer.register({ kind: 'prefix', path: API_PREFIX, handler: createApiHandler(bridge, logger) }),
      'device-interconnect: settings-page bridge routes',
    )
  }
  // The supervisor owns the child, so it is registered before the initial
  // start: a plugin unload during activation still stops the process.
  ctx.effect(() => {
    void bridge.initialize()
    return () => bridge.dispose()
  }, 'device-interconnect: remote-host supervisor')
}
