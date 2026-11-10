import 'package:flutter/services.dart';

/// Build the Markdown blockquote a quoted message inserts into the composer.
///
/// One `> ` prefix per line, a bare `>` for blank lines, and no trailing blank
/// lines from the source message. Returns an empty string when [text] has no
/// content to quote.
String quotedMessageMarkdown(String text) {
  final lines = text.split('\n');
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  if (lines.isEmpty) return '';
  return lines
      .map((line) => line.trimRight().isEmpty ? '>' : '> ${line.trimRight()}')
      .join('\n');
}

/// Insert [text] as a Markdown blockquote at the draft's selection.
///
/// The block is separated from surrounding text by one newline on each side;
/// an empty draft receives only the block and a trailing newline so the caret
/// continues on the next line. The selection collapses after the inserted
/// block, matching the composer's normal cursor placement.
TextEditingValue insertMessageQuote(TextEditingValue draft, String text) {
  final block = quotedMessageMarkdown(text);
  if (block.isEmpty) return draft;
  final value = draft.text;
  final selection = draft.selection;
  final start = selection.isValid
      ? selection.start.clamp(0, value.length)
      : value.length;
  final end = selection.isValid
      ? selection.end.clamp(0, value.length)
      : value.length;
  final before = value.substring(0, start);
  final after = value.substring(end);
  final leading = before.isEmpty || before.endsWith('\n') ? '' : '\n';
  final trailing = after.isEmpty
      ? '\n'
      : (after.startsWith('\n') ? '' : '\n');
  final inserted = '$leading$block$trailing';
  return TextEditingValue(
    text: '$before$inserted$after',
    selection: TextSelection.collapsed(offset: before.length + inserted.length),
  );
}
