import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_projection_test.dart' as fixture;

void main() {
  testWidgets(
    'manual compact presents one concise result and opens its saved summary',
    (tester) async {
      final projection = ChatProjection()
        ..reconcile([
          fixture.event(1, 'command/run', {
            'commandId': 'c',
            'name': 'compact',
          }),
          fixture.event(2, 'compaction/summary', {
            'compactionId': 'txn',
            'sourceCommandId': 'c',
            'summary': [
              {'type': 'text', 'text': 'Saved summary'},
            ],
            'shadowedSeqs': [1, 2, 3],
            'shadowedTokenCount': 60,
          }),
          fixture.event(
            3,
            'user/message',
            {
              'source': {
                'kind': 'compact-checkpoint',
                'compactionId': 'txn',
                'sourceCommandId': 'c',
              },
              'content': [],
            },
            surface: {'op': 'replace', 'startSeq': 0, 'endSeq': 0},
          ),
          fixture.event(4, 'command/done', {
            'commandId': 'c',
            'kind': 'success',
            'sourceEventSeq': 2,
          }),
        ]);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: Scaffold(
            body: ChatMessage(
              entry: projection.entries.single,
              storageId: 'session:command',
              sessionId: 'session',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已压缩 3 条历史记录 · 约 60 tokens'), findsOneWidget);
      expect(find.text('Saved summary'), findsNothing);
      await tester.tap(find.text('压缩上下文'));
      await tester.pumpAndSettle();
      expect(find.text('Saved summary'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed compact shows the durable error without a summary disclosure',
    (tester) async {
      final projection = ChatProjection()
        ..reconcile([
          fixture.event(1, 'command/run', {
            'commandId': 'c',
            'name': 'compact',
          }),
          fixture.event(2, 'command/done', {
            'commandId': 'c',
            'kind': 'error',
            'text': 'Compaction cancelled.',
          }),
        ]);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: Scaffold(
            body: ChatMessage(
              entry: projection.entries.single,
              storageId: 'session:failed',
              sessionId: 'session',
            ),
          ),
        ),
      );
      expect(find.text('Compaction cancelled.'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
