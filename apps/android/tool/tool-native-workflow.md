# Android native workflow registration

English | [中文](tool-native-workflow.zh.md)

`registerAndroidWorkflowTool` registers the original `workflow` parameter, result and presentation contract through `createWorkflowToolDefinition`. The App supplies the executor and a build-owned availability function; its default is closed. No profile value, model argument or user credential can open that gate. The production `index.mjs` integration and device acceptance are separate gates; importing this module alone registers nothing.

Each invocation captures the exact current ToolRuntime definition and registration identity, checks the live parent Agent and its real Session ID, and consumes one App-owned admission ticket. The App issues an ungranted scope with a 120-second deadline, at most eight children and two concurrent children. Children use the parent model route and the confined preset: no files, web tools or shell, with only structured-result submission where requested. The original JavaScript DSL runs through the fixed isolated guest, not in the Node host.

Foreground calls publish only a confirmed completed receipt. `run_in_background: true` is admitted only by the App's explicit background policy and transfers the prepared request to `startBackgroundDsl`, preserving the parent and creating ToolCall IDs in the real jobs registry. The tool-step signal is not retained after handoff. Job cancellation and owner disposal remain the existing cancellation owners; failed or unconfirmed retirement never becomes a completed result or synthetic Session end.

Host checks: `node --import tsx --test apps/android/tool/tool-native-workflow.test.mjs apps/android/tool/tool-workflow-preflight.test.mjs`. These exercise the real ToolRuntime, Agent and jobs registry with the native boundary substituted; they do not prove Android Binder execution. The original package regression is `node node_modules/vitest/vitest.mjs run packages/workflow/tool-workflow/tests/tool-workflow.spec.ts`.

For the remaining device proof, use a test-only composition inside the existing App process with a scripted model adapter and a fresh `android-…` Session, keeping user account settings unchanged. Run the actual ToolRuntime through foreground arithmetic, a real confined child, and a background job followed by `job_kill`; compare persisted Session events, native receipt identities and job outcomes. Only that reviewed composition may explicitly open the registration gate during acceptance. Kotlin-only transport fixtures or host substitutes cannot satisfy this end-to-end evidence requirement.
