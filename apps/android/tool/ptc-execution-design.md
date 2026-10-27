# Android PTC execution design and admission gates

English | [中文](ptc-execution-design.zh.md)

## Status and decision

The Android build does **not** execute the original unrestricted Node `run_code` or Node-hosted workflow providers. The separate [reviewed android_ptc entry](model-ptc-readonly.md) and [isolated native workflow entry](tool-native-workflow.md) are source-enabled for the Build 116 candidate; they do not provide direct Node APIs or establish original PTC parity. Scoped r26 workflow device checks passed, while the workflow-enabled production profile and ordinary Build 116 upgrade remain pending. This reference retains the acceptance contract for the original unrestricted providers. Keep `ptc-runtime`, `workflow-ptc`, `tool-workflow`, and `preset-ptc` disabled in the Android profile and keep both staging and runtime guards active until the gates below pass on a normal, non-rooted device.

The original service contract is [`PtcRuntime`](../../../packages/ptc-runtime/ptc-runtime/README.md): resolved program format, timeout, owner lifetime, named asynchronous bindings, bounded logs, lossless JSON result, structured failure and separate sandbox facts. Its shipped Node provider gives the model direct Node filesystem, network and subprocess APIs and launches a separately managed Node worker after `ctx.sandbox.confine()` for `workspace-write` or `read-only`. [`WorkflowExecution`](../../../packages/workflow/workflow-ptc/src/runtime.ts) then executes a JavaScript body with `agent`, `parallel`, `pipeline`, `phase`, `log` and JSON `args`; the workflow adapter uses the **same** PTC worker and owns children, cancellation and disposal. Preserving the surface alone without those effects is not parity.

## Evidence from the current Android build

| Finding | Source | Consequence |
| --- | --- | --- |
| A pinned Android Node 24.22.0 binary and `libnode.so` exist. | [`runtime-lock.json`](runtime-lock.json), [`CMakeLists.txt`](../android/app/src/main/cpp/CMakeLists.txt) | A JS runtime is available, but availability is not confinement. |
| `NativeRuntime.start()` sets `HOME`, `DSH_HOME`, cache and cwd to App-private paths and starts the full DSH bootstrap in the App's `:agent` process. | [`runtime.cpp`](../android/app/src/main/cpp/runtime.cpp), [`NativeRuntime.kt`](../android/app/src/main/kotlin/com/minnnng/dsh_android/NativeRuntime.kt) | It cannot be reused by an isolated UID, which cannot read those paths; putting it in `:agent` would expose credentials to model code. |
| The App declares isolated Services, including an internal V8 JavaScript evaluator separate from the diagnostic echo. | [`AndroidManifest.xml`](../android/app/src/main/AndroidManifest.xml), [`IsolatedScriptService.kt`](../android/app/src/main/kotlin/com/minnnng/dsh_android/IsolatedScriptService.kt), [`PtcScriptEngine.java`](../android/app/src/main/java/com/minnnng/dsh_android/PtcScriptEngine.java) | The reviewed `android_ptc` tool uses the isolated evaluator and original ToolRuntime callbacks; unrestricted Node PTC semantics remain absent. |
| Local sandbox runner selection covers Linux, macOS and Windows, not Android. | [`sandbox-local/src/index.ts`](../../../packages/sandbox/sandbox-local/src/index.ts) | Calling the original Node provider under `workspace-write` must fail closed; selecting `danger-full-access` to make it run is a policy regression. |
| The Android profile explicitly disables PTC and workflow rows. | [`cordis.patch.yml`](../runtime/cordis.patch.yml), [`ptc-workflow-confinement.md`](ptc-workflow-confinement.md) | The original Node providers remain disabled; the App-owned reviewed PTC and native workflow factories are separately source-enabled in the candidate. |

The isolated UID is an important boundary against App-private files, but it is **not** a workspace file policy by itself. It does not manufacture a filesystem path for SAF documents, restrict every world-readable path to a selected workspace, or guarantee that a Node-created descendant dies when the Service is unbound. An isolated JavaScript `vm` context is likewise not an OS confinement boundary.

## Comparison with published approaches

| Approach | Published execution boundary | Consequence here |
| --- | --- | --- |
| Android [`isolatedProcess`](https://developer.android.com/guide/topics/manifest/service-element) and [`bindIsolatedService`](https://developer.android.com/reference/android/content/Context#bindIsolatedService(android.content.Intent,int,java.lang.String,java.util.concurrent.Executor,android.content.ServiceConnection)) | A Service can run under a distinct UID; the App still designs binding and messages. | Suitable as a guest-process boundary, with explicit grants for each workspace file, tool and state transition. |
| [Termux `RUN_COMMAND` Intent](https://github.com/termux/termux-app/wiki/RUN_COMMAND-Intent) | A permitted third-party caller executes commands in Termux's environment. | Optional user-chosen external-terminal integration is possible, but Termux's workspace and authority are not an in-App confinement boundary for model code. |
| [Official OpenAI Programmatic Tool Calling](https://developers.openai.com/api/docs/guides/tools-programmatic-tool-calling) | Each generated program uses a fresh isolated V8 runtime without Node, direct filesystem/network access or subprocesses; effects pass through eligible tools. | Script orchestration plus a capability broker is a viable product shape, but that restricted-tool contract differs from this repository's direct-Node PTC provider. |
| [Official OpenAI Sandbox Agents](https://developers.openai.com/api/docs/guides/agents/sandboxes) and [security guidance](https://developers.openai.com/api/docs/guides/agents-api/environments/security) | The trusted harness owns approvals, audit and recovery apart from execution compute; file, network and credential access are scoped. | Keep account and task state in the trusted App/Host and execute model code only in a constrained guest. A shared Node process is not that separation. |

This is an architecture comparison, not a claim that the App can reuse OpenAI-hosted execution or that Termux or Android Services automatically satisfy the original DSH policy.

## Target architecture

1. **App-side admission.** A PTC adapter accepts only a caller-owned run with a frozen Session ID, workspace revision, policy, program format, binding allowlist, cancellation source and budget. It records the admitted call before starting the guest. Invalid options fail before a run is published. Approvals for wider effects are App-side and one-time, never inferred from a script argument.
2. **Fresh guest process.** Bind a uniquely named `android:isolatedProcess` Service for every run on API 29+, with the API 28 fallback serialized and forcibly retired after the run. The guest receives program bytes through a bounded descriptor or framed Binder transport, not a path to App-private code, credentials, home or workspace. The guest process has no App-private bootstrap and receives no ambient authority. Binder sender UID, run ID and monotonically unique call ID are checked on both sides. A dead or unexpected Binder endpoint fails the run.
3. **Script engine.** The pinned `libnode` includes V8, but an embedded V8 isolate **without Node globals** is a distinct provider: it can implement a broker-only TypeScript/JavaScript subset and workflow hooks, not the original direct `fs`, `net` and `child_process` contract. A full Node provider may be used only after a device-proven kernel file and process confinement mechanism plus a workspace path model are supplied. V8-only code needs a native bridge for execution, Promise microtask pumping, interruption, heap cap, strict JSON materialization and host-call promises. A synchronous `eval` or JavaScriptCore/WebView call with no host bindings is not an implementation of `workflow`.
4. **Capability broker.** The App holds the mapping from opaque grant IDs to user-selected workspace files. The guest may send only `{runId, callId, grantId, action, boundedArgs}`. The App validates lease, approval, action and expected file revision; returns a bounded read/search/edit result; records both request and terminal outcome. It never accepts a guest-selected App-private path or an arbitrary tool name. Workflow `agent()` needs a separate child-agent capability with owner/limit/disposal rules; file grants must not silently authorize it.
5. **Resource and lifecycle accounting.** Bound script bytes, frame bytes, output bytes, heap, pending calls and host-call queue independently. Elapsed deadline starts before bind and includes all callback waits. A synchronous loop must be terminated through V8 interruption or process death; loss of the guest must settle one terminal result and revoke grants. Cancellation stops future callbacks before teardown, disposes accepted child agents and records the stop cause. Successful completion also retires the guest; no persistent environment is claimed until state-owner release and crash recovery are designed.
6. **Provider integration.** A new Android provider reports its actual `language`, execution mode and enforcement facts. If it omits direct Node APIs, it must expose different `executionInstructions` and must not be passed off as the existing Node provider. The original `workflow-ptc` loader currently rejects a non-TypeScript PTC provider, and its VM uses `node:vm`; adapting or replacing that host is a real integration task. The original unrestricted `run_code` and Node-hosted workflow routes remain hidden until their required contracts are implemented and checked; the separately reviewed native workflow entry has the narrower contract described above.

The proposed App callback boundary is `hostCall(runId, callId, grantId, action, boundedArgs) -> boundedResponse`. Each request is correlated, admitted at most once, and has a terminal response even if the guest dies. This interface intentionally contains no filesystem path, `process.env`, network socket or arbitrary shell request.

### Execution policy chosen for Android

Follow the separation in [official OpenAI Docs on Codex sandboxing](https://learn.chatgpt.com/docs/sandboxing) and [agent approvals](https://learn.chatgpt.com/docs/agent-approvals-security): an approval decision does not widen the sandbox by itself. A run starts with no guest file grant and no guest network grant. The App can then admit an explicit `workspace-write` scope consisting of selected App-owned readable and writable paths. Writes outside that scope, including protected workspace metadata (`.git`, `.agents`, `.codex`, `.aws`), must be rejected at the file operation boundary. Network access is separately denied by default; a reviewed exact HTTPS host can be added through the App's network broker for one bounded run. A child run may only narrow the parent's scope. The guest receives opaque handles, never raw paths, credentials or an ambient socket. A request that cannot be enforced by the selected Android executor returns `sandbox-unavailable` rather than executing in the App UID.

The existing `IsolatedExecutionPolicyOwner`, file broker, network broker and manual script approval implement parts of this contract for App-private exact-file and exact-host selections. The original App-UID Shell, Host web tools and third-party plugins are separate execution surfaces. None inherit these isolated guest grants; each needs its own enforcement or a clear unavailable state. This policy describes the requirements of the original general execution contract, not a claim that the separately reviewed Android entries implement its unrestricted Node behavior.

The implementation should version its wire envelopes and freeze them at admission:

```text
Start {version, runId, ownerId, programFormat, programBytes, programSha256,
       args, grantIds, timeoutMs, maxOutputBytes, maxMessageBytes,
       maxPendingCalls, maxHeapMb}
HostCall {version, runId, callId, grantId, action, boundedArgs}
HostReply {version, runId, callId, result | error}
Terminal {version, runId, completed(value, logs) | failed(kind, detail),
          sandboxFacts, counters}
```

`programBytes` may travel by a one-use read-only descriptor rather than a Binder `Bundle`; the App must hash and size-check what the guest reads. A result frame cannot be treated as success until guest exit, all host calls and child agents have settled, and cleanup has completed. The run state machine is `admitted -> binding -> running -> stopping -> settled`; only the App writes durable `settled`. Every callback checks that its run remains `running`. A late reply, duplicate terminal frame or stale process identity is discarded and audited. Map guest exceptions to `exception`, the elapsed deadline to `timeout`, user cancellation to `abort`, malformed or oversized control to `protocol`, unavailable file policy to `sandbox-unavailable`, guest death or failed cleanup to `worker-exit`, and oversized output to `output-limit`. Keep `sandboxFacts` independent from the failure kind.

The original Node defaults are 120-second elapsed timeout (600-second numeric maximum), 64 MiB combined output, 512 MiB V8 old-generation heap, 128 MiB control message and 128 pending host calls ([`config.ts`](../../../packages/ptc-runtime/ptc-runtime-node/src/config.ts)). Those are not automatically appropriate mobile limits. Any lower Android ceiling must be explicit in the provider descriptor and validated in `resolve()`; it must never silently truncate a program or result and call that parity.

## Acceptance gates before enabling model-visible execution

| Gate | Evidence required |
| --- | --- |
| Native guest | Install the APK on a normal non-rooted Android device, execute a real model-authored script in an isolated UID, and show that the guest UID differs from `:agent`. An Android compile and host unit test are not substitutes. |
| No ambient authority | From the script, attempts to read an App-private marker, out-of-grant workspace file, other SAF URI and direct network/subprocess path fail. Test the actual engine, not a diagnostic echo. |
| Authorized file/tool effects | Granted read, search and revision-checked edit succeed; revoked grant, stale revision, oversized data, malformed UTF-8 and missing file fail with stable errors. All effects are in the durable tool/Session record. |
| Workflow parity | Run `agent`, `parallel`, `pipeline`, `phase` and `log` against real child agents; verify child counts, limits, JSON output, ordinary child failure, infrastructure failure, foreground and background jobs. |
| Termination | Exercise infinite synchronous loop, pending broker call, nested child wait, cancellation, deadline, Binder death, process kill and app restart. Verify one terminal outcome, zero unauthorized late effect and no surviving descendant. |
| Owner and upgrade | Fresh owners do not share state; retained owners (if supported) release on teardown and cannot survive process death; an APK upgrade preserves durable records without replaying side effects. |
| Policy reporting | `read-only` and `workspace-write` are enforced by the actual guest world, or reject as `sandbox-unavailable`; never report full confinement merely from the isolated UID. |

Until those gates are passed, the product reports PTC unavailable while retaining the existing Android file and subagent tools. The legacy App-UID Shell is absent in normal startup and remains an explicit diagnostic path; do not substitute it or an App-UID Node worker for a confined executor, or label the internal pure-JavaScript guest as the original PTC provider.
