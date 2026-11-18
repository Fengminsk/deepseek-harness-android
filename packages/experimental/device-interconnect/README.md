---
description: "Run the PC-side remote host from Settings and pair phones with a long-lived QR code the page keeps available."
kind: "package-bundle"
---

# @deepseek-ai/dsh-device-interconnect

English | [中文](README.zh.md)

## Summary

An opt-in Settings page that supervises the PC-side remote DSH host. It starts and stops the host as a child process, shows its long-lived pairing code, edits listener settings, and lists paired phones with a revoke action. Given only a SakuraFrp access key it can also create or reuse a TCP tunnel through the SakuraFrp API, derive the pairing origin from the provider's public address, and start frpc. The host itself is not part of this bundle: the plugin talks to its loopback pairing-control HTTP API, so a stock DSH install can load this package.

## Table of Contents

- [Use this package](#use-this-package)
- [Understand the implementation](#understand-the-implementation)
- [Further Exploration](#further-exploration)
- [Model Experience](#model-experience)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)
- [Dev Note](#dev-note)

-----

<a id="use-this-package"></a>
## Use this package

### Install and enable the bundle

The manifest declares an installable `dsh.bundle` layer and a browser face. Install the bundle from its local directory with the plugin manager's `install_bundle` action, or install the published package and add it to the profile's `dsh.profile.bundles`. The bundle is `listedByDefault: false`, so it stays out of the shipped profile until the profile names it. The Settings page appears as **Devices**; the remote host stays off until its switch is turned on.

The profile needs the standard Web composition for the page to render, and the remote host needs its own working profile (the launcher's `--profile` argument). The page has no effect on a profile without the Web server service: the plugin loads, logs one warning, and registers no bridge routes.

### Configure the runner

The plugin launches the remote host as `<node> <pnpm.mjs> dsh --profile <profile> --patch <generated overlay> --no-open` in the checkout directory, with `DSH_HOME` and the Node.js directory on `PATH`. The advanced runner section edits these fields:

| Field | Meaning | First-run inference |
| --- | --- | --- |
| `nodePath` | Node.js executable that runs the launcher | `DSH_DEVICE_INTERCONNECT_NODE`, else the `node` under `$DSH_HOME/dsh-runtimes/*/dependencies/`, else the current executable when it is not Electron |
| `pnpmPath` | `pnpm.mjs` the executable runs | `DSH_DEVICE_INTERCONNECT_PNPM`, else the managed runtime's `dependencies/pnpm/bin/pnpm.mjs` |
| `repoDir` | Checkout the child runs from | `DSH_DEVICE_INTERCONNECT_REPO`, else empty |
| `profile` | DSH profile the child launches | `remote-host` |
| `patchPath` | Extra `--patch` applied after the generated overlay | empty |
| `dshHome` | `DSH_HOME` given to the child | empty inherits the DSH host process's value |

An empty or missing path is reported on the page, and the switch does not spawn a broken command. The generated overlay is rewritten on every child start from the listener settings, so the remote host never runs with a stale configuration.

### Listener and pairing settings

The page edits the remote host's `port`, `host`, `publicHost`, `publicOrigin`, UDP discovery switch and port, and the loopback pairing page switch and port. Saving validates the document, writes `$DSH_HOME/device-interconnect/config.json` atomically, and restarts the child when it is running. Long-term pairing stays on by default: the generated overlay requests a 30-day pairing window, and the remote host opens a fresh window after each successful pairing, so the page shows a QR code without a countdown and the next phone can pair without touching the page. **New pairing link** reopens the window on demand.

`publicOrigin` accepts only `wss://host[:port]`, for a TLS-terminating reverse proxy or a domain-based deployment. Leaving it empty derives the origin from `publicHost` or the default-route IPv4 address.

### Manage paired devices

The paired-device card sits at the bottom of the page, lists active phones first and revoked or expired records after, and collapses itself while more than six devices exist (the disclosure header toggles it, and the user's choice wins until the panel closes).

- **Revoke** (active devices only) keeps the record as a revoked tombstone. The phone's connection is closed with `4001 auth-revoked`, the device stops working immediately, and the row stays visible as revoked so the host can still tell a revoked token from an unknown one.
- **Delete** permanently removes the record in any state. Deleting an active device first revokes it — same disconnect and `remote.deviceRevoked` notification — and then removes the row, so the phone must pair again and the record cannot be recovered. Revoked or expired rows are removed directly.

### SakuraFrp TCP tunnel

The page can run a [SakuraFrp](https://www.natfrp.com/) `frpc` child that maps the remote host's TLS port to the internet, so a phone outside the LAN can pair. Only a **TCP tunnel** works: the remote host terminates TLS itself with its fixed CA, so an HTTP or HTTPS tunnel — which terminates TLS at the provider — makes every pinned-certificate connection fail. The tunnel card states that limit and rejects a public address pasted as an `https://` URL.

#### One-click setup (default)

With just the access key the plugin can do the whole setup through the [SakuraFrp API v4](https://api.natfrp.com/docs/) (Bearer auth, only for this computer's DSH remote access — not a public game server):

1. Get the access key from the SakuraFrp panel (**View access key**; different from the account password).
2. Open **NAT traversal (SakuraFrp)** → **SakuraFrp**, keep **Create the tunnel automatically**, paste the access key, and optionally change the tunnel name.
3. **Save and create tunnel** asks for confirmation, then: validates the account (frozen, real-name, and tunnel-quota facts are reported), picks the first node that accepts new tunnels (`flag & 4`, not offline, not BETA, not VIP-only), reuses the saved or same-name TCP tunnel (aligning its local target to `127.0.0.1:<remote host port>`), or creates one; derives `publicAddress = <node-host>:<remote-port>` and `publicOrigin = wss://…`; prepares frpc (a missing executable is downloaded only after that explicit click, then checked with `frpc -V` for the SakuraFrp build); restarts the remote host so pairing links use the new origin; and starts the tunnel.
4. The card shows each step, the account (name, tunnel quota, remaining traffic), node, tunnel id, effective origin, the child state and output. A failed attempt keeps the saved configuration and shows the failed step; **Retry automatic setup** reuses the same tunnel. An `important_warning_for_ai` returned by the API is shown in the card.

The automatic mode consumes one tunnel from the account quota. The access key stays write-only: the page never displays it again.

The one-click setup also guards against duplicates. Only one provision runs at a time, so a repeated click or a second request joins the attempt already in flight instead of creating another tunnel. As soon as the tunnel is known, its id and node are persisted before the remaining steps run: a later failure (public address, frpc, start) keeps that id, so a retry reuses the same tunnel, even after the user renamed it. The next attempt first reuses the saved id, then an existing TCP tunnel with the same name; `reuseExisting: false` is the only way to ask for a new tunnel. Nothing is ever deleted or migrated automatically.

Node selection aims for the nearest reachable node and respects the account's VIP level. The account group level (`user/info` → `group.level`, 0 when absent) caps each node's VIP requirement (`vip <= level`), so an ordinary account never picks a VIP-only node. In automatic mode the plugin measures a plain TCP connect to every usable node's frps port 7000 (1.2 s timeout, at most 32 at a time, no external service), then picks the lowest latency; on a tie ordinary nodes win, then the lower node id. Unreachable nodes rank last; if every probe fails it falls back to the persisted node, else the first usable node in service order, and says so in the step. An explicitly requested node id (`nodeId` in the one-click request) is honored without probing, and the persisted `nodeId` is never treated as a lock, so moving to another city re-picks the nearest node. A reused tunnel stays on its node: when that node is at least 150 ms farther than the nearest usable node (or unreachable), the steps add a non-blocking note suggesting a manual recreate — the plugin neither migrates nor deletes existing tunnels.

#### Manual mode (advanced)

Turn **Create the tunnel automatically** off to manage the tunnel yourself:

1. In the SakuraFrp panel, create a **TCP** tunnel whose local target is `127.0.0.1:<the remote host port>` (default 4777). The panel assigns a node domain and remote port.
2. Fill in the frpc executable path, the tunnel IDs, and the public `<node-domain>:<remote-port>`; the access key is still needed to authenticate frpc.
3. **Save tunnel settings** writes the derived `publicOrigin` into the generated remote-host overlay and restarts a running remote host. **Start tunnel** starts frpc once the remote host reports its listener; **Stop tunnel** leaves the remote host running. When the plugin activates, a configured tunnel starts again after the remote host is ready; disabling the remote host or uninstalling the bundle stops the tunnel first.

Readiness lists missing facts and neither the button nor activation spawns a broken command. The advanced disclosure offers a custom `frpc.ini` (`frpc -c <ini> -n`, replacing the access key and tunnel ids, though the public address is still required for the derived origin), a pinned node id, extra frpc arguments, and the frpc path. Managed frpc runs with `-n --disable_log_color` so it does not self-update and its output stays readable.

### Security model

The remote host's control API binds `127.0.0.1` only, and this plugin's own bridge routes reject any non-loopback `Host` head and any cross-site `Origin`. Every read and write also requires the `x-dsh-device-interconnect: 1` header, which a cross-site page cannot set without a CORS preflight this Host never approves; no CORS header is returned. The one header-free route is the QR image, which an `<img>` element must be able to load and which reveals nothing the page does not already show. All responses are `Cache-Control: no-store`. The accepted local threat is the usual one: another process on the same computer can read the configuration file and the children's logs.

The SakuraFrp access key is write-only over the bridge: state reports only `tokenConfigured: true`, the page never displays it again, and it is not logged. It is still stored in plain text in `$DSH_HOME/device-interconnect/config.json`, so the same local-read threat applies; an empty staged field keeps the stored key, and clearing it requires an explicit `clearToken`/`null` write. One click calls `https://api.natfrp.com/v4` with the access key as a Bearer token to read the account, nodes, and tunnels and to create or edit one tunnel; the key is never put in a URL, a log line, or an error message. A clicked one-click setup may download `frpc` from `https://getfr.sh/d/…` into `<DSH_HOME>/device-interconnect/bin/`, then runs `frpc -V` and requires `sakura` in its output before the binary is ever spawned; nothing is downloaded during plugin activation. When that service is unreachable it falls back to SakuraFrp's versioned Nyatwork CDN mirror and reuses an already installed binary whose `frpc -V` reports `sakura`.

### Uninstall

Remove the bundle in the plugin manager; the plugin stops the tunnel and then the remote host on disposal. `$DSH_HOME/device-interconnect/` (configuration, including the stored access key, and the generated overlay) remains for a later reinstall and can be deleted by hand. Devices paired with the remote host are stored by that host, not by this bundle.

-----

<a id="understand-the-implementation"></a>
## Understand the implementation

### Host plugin and HTTP bridge

`apply` reads the configuration file, builds one `Bridge`, registers one `prefix` route under `/device-interconnect/api` on `ctx.webServer` (read with `ctx.get`, so a profile without a Web server still loads), and registers the disposal of both child supervisors. Routes are loopback-only JSON; each action answers the complete runtime snapshot so the page never has to stitch a second read together:

| Method and path | Body | Effect |
| --- | --- | --- |
| `GET /device-interconnect/api/state` | — | configuration (without the access key), remote-host child state and log tail, tunnel child state, derived origin and readiness, SakuraFrp account/node/tunnel/frpc facts, the last provision steps, control-plane facts, pairing view, devices, runner readiness |
| `POST /device-interconnect/api/enabled` | `{enabled}` | persist the remote-host switch and start or stop that child |
| `POST /device-interconnect/api/tunnel` | `{enabled}` | start or stop the tunnel child without changing the remote-host switch |
| `POST /device-interconnect/api/tunnel/provision` | `{token?, frpcPath?, frpcAutoDownload?, nodeId?, tunnelName?, reuseExisting?}` | validate the access key, select a node, create or reuse the TCP tunnel, prepare frpc, align the origin, and start the tunnel; the snapshot carries the step results |
| `POST /device-interconnect/api/config` | `{config}` | validate the complete document, persist it, restart a running child; `tunnel.token` is write-only (`null` or `clearToken` clears it) |
| `POST /device-interconnect/api/pair` | — | reopen the pairing window through the control plane |
| `POST /device-interconnect/api/devices/revoke` | `{deviceId}` | revoke one paired device |
| `GET /device-interconnect/api/logs` | — | remote-host child output tail |
| `GET /device-interconnect/api/tunnel/logs` | — | tunnel child output tail |
| `GET /device-interconnect/api/qr.svg` | — | proxy of the open window's QR SVG, same-origin for the page's `<img>` |

Failures answer `{error: {code, message}}` with a stable code the page maps onto its dictionary.

### Child supervisors

One `ChildSupervisor` instance owns each child (remote host and frpc): piped stdout and stderr feed a 64 KiB combined tail, `start` is idempotent, `stop` kills the Windows process tree with `taskkill /T /F` (or signals the child elsewhere) and waits for the exit, `restart` applies a new configuration, and disposal stops the child. The bridge enforces the order: the tunnel starts only after the remote host's control plane reports its `listener` up, the tunnel stops first when the host restarts or stops, and a tunnel failure never stops the remote host. `/api/state` reads are cached for one second so several open pages polling at two seconds cannot multiply loopback requests.

### Loopback control-plane client

`createControlPlane` validates every field of the remote host's `/api/state` JSON at that process boundary and calls `/api/pair` and `/api/devices/revoke` with the control header. An unreachable control plane is a snapshot field, not an exception: the page shows the host as not running and says why.

### Browser page

The browser half registers the `settings.section` entry (id `device-interconnect`, order 15, label from its dictionary), its `settings.section.icon` glyph, and the en/zh dictionaries. `DeviceInterconnectController` holds the snapshot store and the polling driver: the mounted page calls `open`, the unmounting page calls `close`, polling pauses while the document is hidden, and every action refreshes the snapshot. The page shows the switch and status, the long-term pairing card, listener settings, paired devices with a confirmation dialog, the collapsible NAT-traversal card (provider, frpc fields, effective origin, tunnel state and output), the collapsible runner fields, and the remote-host output.

-----

<a id="further-exploration"></a>
## Further Exploration

- [Remote host composition](../../../apps/remote-host/cordis.patch.yml) — the PC-side host this bundle supervises.
- [Plugin Manager page](../../client/ui-plugin-manager/README.md) — installing, enabling, and removing bundles.
- [Host Web server](../../host/webserver/README.md) — the route registry the bridge registers on.

-----


## Model Experience

None, as the Settings page supervises separate child processes and adds no model context, tools, or Session events.

#### KV Cache effect

The bundle adds no request content, so it neither grows nor invalidates a cached request prefix. Changing the switches affects only separate child processes; DSH Sessions on this Host are untouched.

### Desktop relay (Plan B, experimental)

When a session is owned by the desktop DSH process, the remote-host child cannot write it. The desktop plugin now starts a loopback-only relay (`127.0.0.1`, random token, descriptor `<DSH_HOME>/device-interconnect/relay.json`) and the child's overlay points at it through `desktopRelayFile`. If the child's own `session.send` fails with a write-handle conflict, the child retries that text-only send through the relay; the desktop process executes it with the already-loaded `typertGateway`/`connection` services and returns the same result shape. Attachments and commands are not relayed in this phase. The desktop plugin also observes desktop task completions and approvals and posts the same page-line notifications to the child's control API (`POST /api/notifications/relay`), so §8 notifications reach the phone without loading any App runtime into the desktop process. Missing services, a stopped desktop relay, a bad token, or a timeout all leave the child's existing behaviour unchanged; nothing is added to the desktop profile or bundle list.

## Known Limitations and Deferred Work

<a id="known-limitations-and-deferred-work"></a>

- **The remote host is not distributed with this bundle** — the plugin launches a checkout that must already contain the remote host bundle and the profile that mounts it. A stock DSH installation can load this page but cannot start a host until such a checkout, or a packaged runtime, is available at the configured paths.
- **The control API is the remote host's loopback page** — pairing-window state, long-term windows, `/api/pair`, `/api/devices/revoke`, and `/qr.svg` are contracts of `apps/remote-host`. A checkout whose pairing page lacks a contract endpoint degrades to the affected action reporting its failure; the rest of the page keeps working.
- **The page has no remote access** — the bridge intentionally refuses non-loopback Host heads, so a DSH instance served on a non-loopback address cannot use this Settings page from another machine. That is the security boundary, not a missing feature.
- **Windows process-tree kill is `taskkill`** — a platform where `taskkill` is unavailable leaves grandchild processes alive after a stop; the supervisor records the timeout rather than reporting a clean stop.
- **Only TCP tunnels preserve the remote host's TLS** — the App pins the remote host's CA, so an HTTP/HTTPS SakuraFrp tunnel (TLS terminated at the provider) cannot work. The tunnel card rejects an `https://` public address and states the limit; there is no automatic fallback to another tunnel type.
- **The SakuraFrp access key is stored in plain text** — the bridge never serves it back and it is not logged, but `$DSH_HOME/device-interconnect/config.json` holds it in cleartext for other local processes to read. Accepted under the same local-read threat as the pairing configuration.
- **frpc is downloaded only on an explicit click** — the one-click setup may fetch the SakuraFrp frpc build from `https://getfr.sh/d/…`, falling back to the versioned Nyatwork CDN mirror when that service is unreachable, and reusing an installed binary that passes `frpc -V`; a mismatch asks for a manual path. Manual mode never downloads.
- **The one-click setup depends on a third-party API** — SakuraFrp API v4, its node flags, and the account's tunnel quota are external contracts. An API or quota change fails the setup with a readable reason, and the saved configuration plus the retry path stay usable.
- **The tunnel-derived origin overrides the manual one** — while a public address is configured, the manual `publicOrigin` field is ignored and the derived `wss://<node-domain>:<port>` is announced. Clearing the public address restores the manual origin on the next save or start.

<a id="dev-note"></a>
### Dev Note

<details>
<summary>Maintainer context — click to expand</summary>

None.

</details>
- **Supervised children restart after unexpected exits** — the bridge restarts the remote host or frpc child with 2s→30s capped exponential backoff (5 attempts) when the configuration is enabled and the user did not stop it; repeated crashes stop auto-restart and surface a `remote-host-restart-exhausted` / `frpc-restart-exhausted` problem with `restartCount` / `nextRetryAt` in the runtime state. A remote host restarted to apply a tunnel origin waits for host readiness before frpc starts again; there is no independent 30s control-plane health probe, so a hung (not exited) child is not restarted.
