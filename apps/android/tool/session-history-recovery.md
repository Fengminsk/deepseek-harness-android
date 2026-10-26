# Android Session history recovery

## Source and boundary

The current session's top-bar Session More menu keeps the Turn navigator reachable even when chat opens at the tail.

The Android conversation opens a bounded tail through the original `sessionController.projections` cursor and cold-safe, Turn-aware `sessionController.page` service. The native carrier caps each delivered window at 500 events and 4 MiB and never retains a whole-session event snapshot for the chat. An explicit Earlier Messages action prepends one page at the fixed opening cursor, preserving the displayed rows if the read fails. The complete `turnOutline` projection names all started turns; choosing one reads only its bounded segment and offers further pages within an unusually long turn. Missing or malformed projection values do not become invented turns.

The separate Session trajectory and file-change audit pages explicitly read the complete original `sessionController.inspect` observation through 200-event snapshot pages. Those complete readers report a failure if the temporary 128 MiB retention limit is exceeded instead of silently presenting a partial audit.

## Cold process replacement

An already displayed timeline is not evidence that its final events survived a Node process replacement. After an explicit restart or a reported new process, the App replaces that timeline with the original controller's repaired tail and merges only notifications observed in the current connection generation. A transient Binder disconnect can retain rows from the same process. Notifications delivered during the read stay visible without duplicating history rows. An older-page reply from a replaced generation cannot prepend stale rows. A failed read leaves the previous display in place and can be retried; it does not silently claim that old rows were recovered.

## Verification boundary

`flutter test --no-pub test/chat_history_recovery_test.dart test/chat_turn_navigation_test.dart` covers the bounded opening, older-page failure and connection replacement, overlapping live events, and native Turn selection. `node --test apps/android/tool/session-history-runtime.test.mjs` requires a freshly staged runtime bundle and checks the original projection/page delegation and carrier bounds. These host tests do not establish Android process-death, storage-provider behavior, or scroll anchoring on a device.
