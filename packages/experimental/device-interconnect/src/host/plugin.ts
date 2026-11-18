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
import { DesktopNotifications, type RelayNotification } from './desktop-notifications.ts'
import { createDesktopRelayExecutor, DesktopRelay } from './desktop-relay.ts'
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
  // Plan-B desktop relay: loopback-only HTTP for the remote-host child. A start
  // failure disables the relay and leaves the child host untouched.
  const relay = new DesktopRelay({
    dataDir,
    executor: createDesktopRelayExecutor(ctx),
    logger,
  })
  /**
   * Forward desktop page-line notifications to the remote-host control API.
   * @param notifications - mapped page-line notifications.
   * @returns completion once the control API answered.
   */
  const postRelayNotifications = async (notifications: readonly RelayNotification[]): Promise<void> => {
    const current = store.current()
    if (!current.host.pagesEnabled) throw new Error('本机配对页已关闭，桌面通知中继没有投递端点。')
    const response = await fetch(`http://127.0.0.1:${String(current.host.pagesPort)}/api/notifications/relay`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-dsh-pairing-control': '1' },
      body: JSON.stringify({ notifications }),
      signal: AbortSignal.timeout(3_000),
    })
    if (!response.ok) throw new Error(`桌面通知中继返回 HTTP ${String(response.status)}`)
  }
  const desktopNotifications = new DesktopNotifications({
    ctx,
    post: postRelayNotifications,
    logger,
  })
  const bridge = new Bridge({
    dataDir,
    store,
    supervisor,
    tunnelSupervisor,
    controlPlane: baseUrl => createControlPlane({ baseUrl }),
    relay: () => relay.status(),
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
  // The relay is additive: it starts even while the child is disabled and stops
  // before the bridge releases the children on unload.
  ctx.effect(() => {
    void relay.start()
    desktopNotifications.start()
    return async () => {
      desktopNotifications.stop()
      await relay.stop()
    }
  }, 'device-interconnect: desktop relay')
}
