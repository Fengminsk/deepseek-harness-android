# Mobile controls for original DSH tool settings

This change maps the original configuration schema without changing Cordis paths, defaults, or plugin behavior. Android reads the live `settings.describe` descriptor, stages edits, and writes once with `expectedRevision`. Existing merge handling covers a changed revision; uncertain transport receipts remain reviewable instead of triggering an automatic retry.

| Original DSH source | Fields | Android control |
| --- | --- | --- |
| `packages/fs/tool-fs/src/index.ts` | `read`, `readImage`, `write`, `edit` | Native switches in File capabilities |
| Same | `readLimit`, `readMaxLineLength`, `readMaxBytes`, `readStreamMinSize` | Secondary numeric pages under advanced Read limits |
| `packages/fs/tool-fs-search/src/index.ts` | `sampleOverCapGlobResults` | Native switch with over-cap sampling explanation |
| Same | glob, grep, output, and timeout budgets | Secondary numeric pages under advanced Search limits |
| `packages/web/tool-web/src/index.ts` | `search`, `fetch` | Native switches in Web capabilities |
| Same | Search counts, query counts, output, and timeout budgets | Secondary numeric pages under advanced Web limits |
| `packages/interaction/tool-ask-user/src/index.ts` | `mode` | Standard/timed question choice page |
| Same | `timeout` | Indefinite (`-1`), common durations, or a custom positive integer in seconds |

The switches only govern which tools are exposed to the Agent. Android workspace grants and sandbox policy still bound file access; web providers and network permission still bound web calls. `timeout` is used only in the original `timed` mode. Unknown namespaces and future fields continue to appear through schema-driven editing.

Widget tests cover grouping, native boolean and choice controls, custom seconds, versioned writes, and draft preservation across a remote refresh. Device presentation remains for APK acceptance.
