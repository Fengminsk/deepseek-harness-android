import 'dart:async';

import 'package:dsh_android/chat_turn_navigation.dart';
import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_projection_test.dart' as fixture;

class _Runtime extends RuntimeController {
  final calls = <(String, Json)>[];
  Future<Json> Function(Json params)? historyPage;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method, params));
    switch (method) {
      case 'session.turnOutline':
        return {
          'asOfSeq': 24,
          'turns': [
            {'turn': 1, 'seq': 0, 'prompt': '第一轮问题', 'response': '第一轮答复'},
            {'turn': 2, 'seq': 20, 'prompt': '第二轮问题', 'response': ''},
          ],
        };
      case 'session.readWindow':
        if (historyPage case final read?) return read(params);
        if (params['beforeSeq'] == 20) {
          return {
            'events': [
              fixture.event(0, 'turn/start', {'turn': 1}),
              fixture.input(1, '第一轮问题'),
              fixture.assistant(2, '第一轮答复'),
              fixture.event(3, 'turn/end', {
                'turn': 1,
                'reason': {'kind': 'completed'},
              }),
              for (var seq = 4; seq < 20; seq++)
                fixture.event(seq, 'session/title', {'title': 'old'}),
            ],
            'firstSeq': 0,
            'throughSeq': 24,
            'hasMore': false,
          };
        }
        return {
          'events': [
            fixture.event(20, 'turn/start', {'turn': 2}),
            fixture.input(21, '第二轮问题'),
            fixture.assistant(22, '第二轮答复', turn: 2),
            fixture.event(23, 'turn/end', {
              'turn': 2,
              'reason': {'kind': 'completed'},
            }),
          ],
          'firstSeq': 20,
          'throughSeq': 24,
          'hasMore': true,
        };
      case 'settings.describe':
        return <Json>[];
      default:
        throw StateError('Unexpected $method');
    }
  }
}

void main() {
  test('outline rejects invalid order and degrades decorative previews', () {
    expect(
      SessionTurnMark.parse([
        {'turn': 2, 'seq': 10, 'prompt': 12, 'response': null},
      ]).single.prompt,
      '',
    );
    expect(
      SessionTurnMark.parse([
        {'turn': 2, 'seq': 10, 'prompt': 'a', 'response': ''},
        {'turn': 1, 'seq': 20, 'prompt': 'b', 'response': ''},
      ]),
      isEmpty,
    );
    expect(
      SessionTurnMark.parse([
        {'turn': 2, 'seq': 10, 'prompt': 'a', 'response': ''},
        {'turn': 3, 'seq': 10, 'prompt': 'b', 'response': ''},
      ]),
      isEmpty,
    );
    expect(
      SessionTurnMark.fromLoadedWindow([
        fixture.event(10, 'turn/start', {'turn': 3}),
        fixture.event(11, 'tool/call', {'turn': 3}),
        fixture.event(20, 'turn/start', {'turn': 4}),
      ]).map((mark) => (mark.turn, mark.seq)),
      [(3, 10), (4, 20)],
    );
  });

  testWidgets(
    'turn picker reads original outline and opens selected bounded turn',
    (tester) async {
      final runtime = _Runtime()..phase = 'ready';
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: ChatTurnNavigatorPage(runtime: runtime, sessionId: 's'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第一轮问题'), findsOneWidget);
      expect(find.text('第二轮问题'), findsOneWidget);
      await tester.tap(find.text('第二轮问题'));
      await tester.pumpAndSettle();
      expect(find.text('第 2 轮'), findsOneWidget);
      expect(find.text('第二轮答复', findRichText: true), findsWidgets);
      final read = runtime.calls.singleWhere(
        (call) => call.$1 == 'session.readWindow',
      );
      expect(read.$2, {'sessionId': 's', 'throughSeq': 24, 'beforeSeq': 25});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'chat earlier button prepends one page and keeps the same loaded timeline',
    (tester) async {
      final runtime = _Runtime()..phase = 'ready';
      addTearDown(runtime.dispose);
      final events = <Json>[
        fixture.event(20, 'turn/start', {'turn': 2}),
        fixture.input(21, '第二轮问题'),
        fixture.assistant(22, '第二轮答复', turn: 2),
        fixture.event(23, 'turn/end', {
          'turn': 2,
          'reason': {'kind': 'completed'},
        }),
      ];
      runtime.timelines['s'] = events;
      runtime.historyWindows['s'] = SessionHistoryWindow(
        throughSeq: 24,
        firstSeq: 20,
        hasMore: true,
        generation: runtime.connectionGeneration,
      );
      final projection = ChatProjection()..reconcile(events);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: Scaffold(
            body: ChatTimeline(
              sessionId: 's',
              projection: projection,
              controller: scroll,
              events: events,
              runtime: runtime,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('更早消息'));
      await tester.pumpAndSettle();
      expect(identical(runtime.timelines['s'], events), isTrue);
      expect(events.first['seq'], 0);
      expect(events.length, 24);
      expect(runtime.historyWindows['s']!.hasMore, isFalse);
      expect(
        projection.entries.any(
          (entry) => entry.kind == ChatEntryKind.user && entry.seq == 1,
        ),
        isTrue,
      );
      expect(find.text('第二轮答复', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'prepending history keeps the viewed row still while new replies arrive',
    (tester) async {
      final runtime = _Runtime()..phase = 'ready';
      addTearDown(runtime.dispose);
      final pending = Completer<Json>();
      final events = <Json>[
        for (var seq = 100; seq <= 130; seq++)
          fixture.assistant(seq, 'Visible row $seq', step: seq + 1),
      ];
      runtime.timelines['s'] = events;
      runtime.historyWindows['s'] = SessionHistoryWindow(
        throughSeq: 130,
        firstSeq: 100,
        hasMore: true,
        generation: runtime.connectionGeneration,
      );
      final projection = ChatProjection()..reconcile(events);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      Widget host() => MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: Scaffold(
          body: ChatTimeline(
            sessionId: 's',
            projection: projection,
            controller: scroll,
            events: events,
            runtime: runtime,
          ),
        ),
      );
      runtime.historyPage = (_) => pending.future;
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      final anchor = find.text('Visible row 100', findRichText: true);
      final beforeY = tester.getTopLeft(anchor.first).dy;
      await tester.tap(find.text('更早消息'));
      await tester.pump();
      events.addAll([
        for (var seq = 131; seq <= 135; seq++)
          fixture.assistant(seq, 'New reply $seq', step: seq + 1),
      ]);
      projection.reconcile(events);
      await tester.pumpWidget(host());
      pending.complete({
        'events': [
          for (var seq = 0; seq < 100; seq++)
            fixture.assistant(
              seq,
              seq % 7 == 0
                  ? 'Older $seq ${List.filled(24, 'variable height').join(' ')}'
                  : 'Older $seq',
              step: seq + 1,
            ),
        ],
        'firstSeq': 0,
        'throughSeq': 130,
        'hasMore': false,
      });
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(anchor.first).dy, closeTo(beforeY, 1));
      expect(find.text('New reply 135', findRichText: true), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
