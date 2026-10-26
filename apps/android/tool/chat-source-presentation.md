# Answer source presentation

English | [中文](chat-source-presentation.zh.md)

The original `tool-web` returns structured `web_search` and `web_fetch` metadata as well as model-facing text. Android reads only completed successful metadata from the current answer's Turn. It never infers sources from prose, code blocks, or unrelated tool output.

The answer footer keeps one compact Sources action. Its small domain marks are generated locally from validated result hosts; opening chat does not fetch favicons or send browsing history to a third party. The drawer places URLs explicitly linked in the answer before other observed results, preserving retrieval order within each group. It keeps the original URL visible before opening it and shows an HTTP error status when a recorded fetch returned 400 or above. Search and fetch diagnostics remain in the expandable tool record instead of occupying every source row.

Only HTTP(S) URLs with a host, no embedded credentials, and no raw whitespace or control character become tappable. The existing native external-link path remains responsible for launching them. Closing or replacing an answer retires its source drawer; neither source ordering nor the domain mark changes the stored tool result or the model response.

Host verification: `flutter test --no-pub test/chat_reply_bar_test.dart test/chat_reply_sources_test.dart test/chat_source_presentation_test.dart`. A device screenshot and external-browser launch still require phone acceptance.
