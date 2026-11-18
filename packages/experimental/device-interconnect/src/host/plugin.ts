/**
 * Host half of the Device Interconnect bundle.
 *
 * The plugin lives in the DSH Host process and serves the Settings page's
 * bridge routes, then runs the remote host in one of two modes: the stable
 * supervised child process (default) or, when explicitly enabled in the
 * advanced runner settings, an experimental embedded load inside this Host
 * process. The embedded loader is created here from the plugin context; any
 * import or activation failure rejects and the bridge falls back to the child,
 * so a stock DSH distribution still loads this bundle unchanged.
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
import { createContextEmbeddedLoader } from './embedded.ts'
import { createApiHandler } from './routes.ts'
import { ChildSupervisor } from './supervisor.ts'

/** Plugin name shown in DSH diagnostics. */
export const name = 'device-interconnect'

/**
 * First-run seeds for the persisted configuration. Only `enabled` is normally
 * set in the bundle row; every other absent field falls back to the product
 * defaults, and once `config.json` exists it is the single source of truth.
 */
export type Config = Partial<import('../types.ts').DeviceInterconnectConfig>

/**
 * Register the Settings page bridge and start the supervised children when the
 * persisted configuration has them enabled: the remote host first, then the
 * managed NAT-traversal tunnel once that host is ready.
 * @param ctx - Host context; the web server service is awaited through
 * declaration-aware injection so the bridge routes register once the browser
 * surface exists, while a profile without one still loads this plugin.
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
  const supervisor = new ChildSupervisor({ logger })
  const tunnelSupervisor = new ChildSupervisor({ logger, label: 'frpc 隧道' })
  const bridge = new Bridge({
    dataDir,
    store,
    supervisor,
    tunnelSupervisor,
    embeddedHost: createContextEmbeddedLoader(ctx),
    controlPlane: baseUrl => createControlPlane({ baseUrl }),
    logger,
  })
  // Activation order is not guaranteed: on a cold profile boot the web server
  // may appear after this plugin activates. Declaration-aware injection defers
  // the route registration until the service exists instead of dropping the
  // whole Settings page bridge for the process lifetime.
  ctx.inject(['webServer'], (scope) => {
    scope.effect(
      () => scope.webServer.register({ kind: 'prefix', path: API_PREFIX, handler: createApiHandler(bridge, logger) }),
      'device-interconnect: settings-page bridge routes',
    )
  })
  // The bridge owns both children, so it is registered before the initial
  // start: a plugin unload during activation still stops the tunnel and then
  // the remote host.
  ctx.effect(() => {
    void bridge.initialize()
    return () => bridge.dispose()
  }, 'device-interconnect: child supervisors')
}
