# Manual isolated script run

The Settings > Manual isolated script page is a user-initiated developer tool. It does not register a PTC or workflow tool with the model. The native `isolatedManual.prepare` MethodChannel entry sends a distinct Binder message to `AgentService`; ordinary Node/runtime JSON-RPC cannot construct an approval.

## Selection and approval

- Choose an existing session. File access additionally requires a registered workspace whose directory equals the session directory and sits under the App-private runtime workspace. The selected grant names one existing regular file relative to that workspace. Symlink ancestors, directory grants, arbitrary external paths, and unregistered workspace identities are refused.
- File access defaults off. A selected file defaults to read only; edit is a separate explicit choice. The network field accepts one normalized exact `https://host` without a path or port, and defaults off. The native network broker rejects local or IP-like destinations.
- `AgentService` fetches the current catalog itself at preparation and rechecks the selected session, workspace membership, directory, and file identity immediately before admission. A changed selection cancels the approved plan and records a durable cancellation before guest execution. This recheck cannot make a later catalog change atomic with execution; the native file broker still confines every file operation. The scope, program, input, session, workspace and deadline are bound to a fresh run ID. A granted run enters the existing native approval inbox and Android confirmation dialog. A denied scope can run without a capability approval.
- Approval is one use. Expiry, denial, lost IPC, or a process restart cannot replay the script or silently broaden its scope.

## Results

The UI polls `isolatedManual.status`. Only a durable `COMPLETED` terminal receipt exposes `outputJson`. Other terminal states remain explicit. An admitted run without a terminal receipt is **unconfirmed**, including after process death; the App does not retry it. Cancellation joins the native controller and the final state must still be read. The most recent run ID is stored locally so its durable receipt can be checked after reopening the page.

## Current boundary

The page is a manual developer entry point with one exact file and one exact HTTPS host per run. General model-visible PTC/workflow execution, directory capability grants, arbitrary SAF/external workspaces, and automatic resumption are not provided by this entry point.
