/**
 * HTTP bridge paths shared by the Host plugin and its browser page. The page
 * and the Host disagreeing on one path is a broken feature, so both import the
 * same constants.
 * @module @deepseek-ai/dsh-device-interconnect/api
 */

/** Every bridge route lives under this prefix. */
export const API_PREFIX = '/device-interconnect/api'

/** `GET` current runtime snapshot. */
export const STATE_ROUTE = `${API_PREFIX}/state`

/** `POST` switch the supervised remote host on or off. */
export const ENABLED_ROUTE = `${API_PREFIX}/enabled`

/** `POST` validate and persist a complete configuration. */
export const CONFIG_ROUTE = `${API_PREFIX}/config`

/** `POST` reopen the long-term pairing window. */
export const PAIR_ROUTE = `${API_PREFIX}/pair`

/** `POST` start or stop the managed NAT-traversal tunnel. */
export const TUNNEL_ROUTE = `${API_PREFIX}/tunnel`

/** `POST` revoke one paired device. */
export const REVOKE_ROUTE = `${API_PREFIX}/devices/revoke`

/** `GET` the child's log tail. */
export const LOGS_ROUTE = `${API_PREFIX}/logs`

/** `GET` the tunnel child's log tail. */
export const TUNNEL_LOGS_ROUTE = `${API_PREFIX}/tunnel/logs`

/** `GET` the proxied QR SVG of the open pairing window. */
export const QR_ROUTE = `${API_PREFIX}/qr.svg`

/**
 * Header every same-origin page write carries. A cross-site form post cannot
 * set it, and a cross-site fetch that sets it needs a CORS preflight this Host
 * never approves.
 */
export const BRIDGE_HEADER = 'x-dsh-device-interconnect'

/** Value of {@link BRIDGE_HEADER} the bridge accepts. */
export const BRIDGE_HEADER_VALUE = '1'
