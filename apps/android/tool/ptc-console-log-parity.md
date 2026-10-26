# PTC console log parity slice

[中文](ptc-console-log-parity.zh.md) | English

The original `packages/ptc-runtime/ptc-runtime-node` returns ordered console output with the execution result. Android's restricted `android_ptc` transport previously returned a fixed empty `logs` array even for a successful isolated run. This slice carries success logs through the actual native chain: V8 console capture → JNI result → isolated Binder reply → versioned durable receipt → native bridge → Node receipt projection → `android_ptc` result. The tool text renderer also presents those lines in order before the result. No model-visible registration gate was opened.

The guest captures `console.log`, `info`, `warn`, `error`, and `debug` as ordered text lines. It allows at most 128 entries and 16 KiB of JSON-encoded logs; logs plus returned JSON must fit within 64 KiB. Overflow returns `OUTPUT_TOO_LARGE` without publishing partial data. Failures, cancellation, timeouts, worker death, and uncertain retirement publish no logs or result. Version-one receipts decode to an empty log array, while newly written receipts use version two.

Host evidence: `node apps/android/tool/acceptance-isolated-script-run.mjs` passed, including a real version-one receipt fixture and version-two logged round trip; `node apps/android/tool/acceptance-ptc-script-engine.mjs` passed; four focused Node suites passed 33 tests. Offline `:app:externalNativeBuildDebug :app:compileDebugKotlin :app:compileDebugAndroidTestKotlin` succeeded. The receipt host acceptance initially hit a Windows `AccessDeniedException` during its existing 256-entry atomic-rename stress loop, then passed on a serial rerun. Device instrumentation has been compiled but has not run.

Remaining original DSH parity gaps include Node module access, declared binding namespaces beyond the reviewed callback, persistent REPL behavior, failure-log retention, longer execution budgets, and device evidence for Binder/UID/process-death behavior. The Android product gate remains closed pending device validation and policy review.
