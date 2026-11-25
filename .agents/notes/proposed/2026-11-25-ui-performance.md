# UI performance: where we lose frames, and what their code does differently

## What the upstream study found

FlClash's UI is smooth because prism_ui makes frame cost bounded by construction, not because its widgets are simpler:

| Mechanism | Where | Effect |
| --- | --- | --- |
| One capture host, one atlas per frame | `liquid_glass_capture.dart:394` (`addToScene` → `_capture`) | No per-pane `BackdropFilter`; the surface is never copied per pane |
| Capture keyed by the pictures underneath | `liquid_glass_capture.dart:704-719` | A still scene reuses the atlas; no rasterisation at all |
| `hold` / `steadyFrost` panes | `liquid_glass.dart:1177` | A moving menu or alert keeps one capture instead of one per frame |
| Picture caches with value-equality keys | `liquid_glass.dart:1357`, `:1472` | An equal style or unchanged uniforms re-record nothing |
| Page transition is a render object, not a rebuild | `page_transition.dart:436-499` | Moving a page costs paint only, never build or layout |
| Snapshot the outgoing route, not the incoming one | `page_transition.dart:205-215` | The leaving page stops being drawn in full |
| `LayoutBuilder` only under a repaint+relayout boundary | `scaffold.dart:292-326` (`_BodyBoundary`) | A spinner or dock lens cannot relayout the page |
| Rows measure themselves once, dry layout included | `list_row.dart:504-527`, `measure.dart` | No intrinsics pass per frame |
| Inherited scopes split by aspect | `view_scope.dart`, `inherited.dart` | A width change does not rebuild size readers |
| `TickerMode` off for kept-alive pages | FlClash `home.dart:211-230` | Offscreen tabs stop asking for frames |

Their own post-pin work (not in v0.9.4) reinforces the same direction: skip the glass rim where nothing reaches (`uInner`), pre-snapshot when a drag starts, clip the covered route to its uncovered strip, and tightly constrain table cells so a cell change stops at the cell.

## Where this app loses frames

Ranked by rebuild frequency × work per rebuild, from a read-only audit of `apps/android/lib`:

1. **One live-text frame rebuilt the entire chat page, unthrottled** (`runtime.dart:431`, `main.dart:1528-1547`). The page select tuple included `liveMessages[sessionId]`, a new map per token frame, so header, drawer, timeline and composer rebuilt at the model's emission rate.
2. **Per-event O(n) work on the UI isolate** (`remote_conversation_live_source.dart:954-997`): dedupe scan over the whole event list plus copy-and-sort, and the list is never trimmed in the source.
3. **Glass capture re-walks the layer tree every scene build** (`liquid_glass_capture.dart:391-394`), with a geometry-only keep path; scrolling under a glass composer re-records the text beneath each band.
4. **Streaming reveal walks every paragraph and pushes a `ShaderMaskLayer` per frame** (`chat_stream_reveal.dart:123-232`), and Markdown is re-parsed per flush.
5. **`SessionModelProjection` replays from index 0 on every event** because it compares list identity (`session_model_projection.dart:27-41`).
6. Per-flush list copies, a post-frame scroll "settle" chain up to 32 iterations (`main.dart:1463-1506`), and a full cache copy per flush.
7. Every mounted timeline row rebuilds per flush (`chat_messages.dart:729-754`; `SliverChildBuilderDelegate.shouldRebuild` is always true).
8. The 24 s ambient loop redraws three radial gradients plus 26 circles per frame (`daylight.dart:151-198`) on pages that do not pass `ambientMotion: false`.
9. `ChatProgressLabel` rebuilds a `ShaderMask` with a fresh gradient every frame (`chat_progress.dart:89-139`).
10. `ImageFiltered` blur on every pushed page (`ui.dart:77` → `entry_motion.dart:36-43`) and on newly mounted local rows.

What the app already gets right: the remote page batches live frames (120 ms) and events (180 ms), `_synchronize` short-circuits on an unchanged stamp, `ChatProjection` reconciles by element identity, the transcript is a lazy sliver with a repaint boundary, chat rows carry no glass, and image decode is pixel-budgeted. The local chat page simply never got the same treatment.

## Changed in this pass

`lib/runtime.dart`: live and stream frames now fold into one notification per 90 ms window; any other frame flushes immediately, so status, errors and interactions stay synchronous. State is applied as frames arrive — only the listeners that rebuild the page wait. Covered by `test/runtime_notify_window_test.dart`, and the 69 tests that drive live frames and chat flow still pass.

Consequence: a streaming reply now rebuilds the page at most ~11 times a second instead of once per token, without changing what the transcript shows.

## Next, in order

1. Keep streaming text out of the page-level selection: a per-session `ValueListenable` consumed by the live row, so a token rebuilds one row (the audit's F7 fix builds on this).
2. Append-only live event list with a `seen` set and a bounded source history (F2, F5).
3. Cache the ambient and progress shaders per size instead of allocating per frame (F8, F9); default `ambientMotion: false` while a reply streams.
4. Tail-only reveal and the remote page's plain-text streaming path on the local page (F4).
5. As consumers move to prism_ui, take its structures with them: snapshot the outgoing route, put the body and dock under repaint+relayout boundaries, and give menus and alerts a `hold` rectangle.

Frame measurement already has a harness: `lib/main_perf.dart` with `tool/device-frame-profile.mjs` (profile build, `DSH_FRAME` FrameTiming summaries, 16.667 ms budget). It drives a paired remote host, so it measures the remote page rather than the local chat page; adding a local scenario would price these changes on a device.
