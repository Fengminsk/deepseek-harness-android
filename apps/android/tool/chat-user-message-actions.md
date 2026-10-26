# Human message actions in Android chat

The original DSH `MessageIconActions` puts a copy icon and a local clock below each human message. Android shows the same compact row beneath a human bubble. Its 44 dp circular copy target writes the authored text blocks exactly, with a short check state on success. A failed clipboard write leaves the action available and shows an inline error. Replacing a row while its write is pending cannot mark the replacement copied.

The clock uses the event timestamp in local time: `HH:mm` today, month and day earlier this year, and year, month, and day for older messages. Events with no valid positive timestamp omit the clock. Runtime context, system prompts, and other nonhuman records have no human action row; they remain available through the separate records view. Attachments are not converted to text by the copy action.

The owner-local `chat_user_message_actions.expected.json` session fixture records human, runtime-context, and assistant messages. Flutter tests cover its human-only action row, local-calendar cuts, clipboard payload and check reset, retry after failure, and a late clipboard completion after a row changes. Device appearance and Android clipboard behavior remain unverified without a phone run.
