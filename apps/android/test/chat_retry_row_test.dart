import 'dart:convert';
import 'dart:io';

import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/chat_retry_row.dart';
import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final oracle = jsonDecode(
    File('test/fixtures/chat_retry_countdown.expected.json').readAsStringSync(),
  ) as Json;
  final events = (oracle['events'] as List).cast<Json>();
  final expected = oracle['expected'] as Json;

  test(
    'original retry events retain attempt identity and redact AUTH detail',
    () {
      final projection = ChatProjection()..reconcile(events.take(3).toList());
      final scheduled = projection.entries.single.retry!;
      expect(scheduled.attemptSeq, 2);
      expect(scheduled.turn, 1);
      expect(scheduled.number, 1);
      expect(scheduled.delayMs, 2500);
      expect(scheduled.failure, expected['safeAuthFailure']);
      expect(
        projection.entries.single.text,
        isNot(contains('private credential')),
      );
      expect(chatRetryLabel(scheduled, 3, active: true), expected['scheduled']);
      expect(chatRetrySeconds(2500, 1000), 2);
      expect(chatRetrySeconds(2500, 3000), 1);

      projection.reconcile(events.take(4).toList());
      final started = projection.entries.single.retry!;
      expect(started.attemptSeq, 2);
      expect(started.state, ChatRetryState.started);
      expect(chatRetryLabel(started, 3, active: false), expected['started']);

      projection.reconcile(events.take(5).toList());
      final second = projection.entries.single.retry!;
      expect(second.attemptSeq, 4);
      expect(second.number, 2);
      expect(
        chatRetryLabel(second, 2, active: true),
        expected['secondAttempt'],
      );

      projection.reconcile(events);
      final cancelled = projection.entries.single.retry!;
      expect(cancelled.state, ChatRetryState.cancelled);
      expect(
        chatRetryLabel(cancelled, 2, active: false),
        expected['cancelled'],
      );
    },
  );

  testWidgets(
    'retry countdown stops on turn change and resets for a new attempt',
    (tester) async {
      final projection = ChatProjection()..reconcile(events.take(3).toList());
      var retry = projection.entries.single.retry!;
      var now = DateTime(2026, 10, 21, 12);
      var active = true;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return ChatRetryRow(
                  retry: retry,
                  activeTurn: active,
                  now: () => now,
                );
              },
            ),
          ),
        ),
      );
      expect(find.text(expected['scheduled'] as String), findsOneWidget);
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text(expected['afterOneSecond'] as String), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chat-retry-toggle')));
      await tester.pump();
      expect(find.text('重试延迟：2500 毫秒'), findsOneWidget);
      expect(
        find.textContaining(expected['safeAuthFailure'] as String),
        findsOneWidget,
      );
      expect(find.textContaining('private credential fragment'), findsNothing);

      rebuild(() => active = false);
      await tester.pump();
      expect(find.textContaining('等待模型请求重试'), findsOneWidget);
      now = now.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('正在重试模型请求'), findsNothing);
      projection.reconcile(events.take(5).toList());
      rebuild(() {
        retry = projection.entries.single.retry!;
        active = true;
      });
      await tester.pump();
      expect(find.text(expected['secondAttempt'] as String), findsOneWidget);
      projection.reconcile(events);
      rebuild(() => retry = projection.entries.single.retry!);
      await tester.pump();
      expect(find.text(expected['cancelled'] as String), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an unfinished previous turn never counts down in a new turn', (
    tester,
  ) async {
    final rows = <Json>[...events.take(3)];
    final projection = ChatProjection()..reconcile(rows);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    Widget timeline() => MaterialApp(
      home: Scaffold(
        body: ChatTimeline(
          sessionId: 'retry-session',
          projection: projection,
          controller: scroll,
          events: rows,
          running: true,
        ),
      ),
    );
    await tester.pumpWidget(timeline());
    expect(find.text(expected['scheduled'] as String), findsOneWidget);
    rows.add({
      'seq': 6,
      'type': 'turn/start',
      'data': {'turn': 2},
    });
    projection.reconcile(rows);
    await tester.pumpWidget(timeline());
    expect(find.textContaining('正在重试模型请求'), findsNothing);
    expect(find.textContaining('等待模型请求重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
