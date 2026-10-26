import 'dart:convert';
import 'dart:io';

import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_execution_chain_test.dart' as chain;
import 'chat_projection_test.dart' as fixture;
import 'chat_reading_motion_test.dart' as reading;

void main() {
  final expected =
      (jsonDecode(
            File('test/fixtures/chat_reading.expected.json').readAsStringSync(),
          ) as Json)['completionAnchor']
          as Json;
  for (final reduced in [false, true]) {
    testWidgets(
      'at the top only the missing space is retained and a drag consumes it without a jump (reduced=$reduced)',
      (tester) async {
        final events = <Json>[
          fixture.event(0, 'turn/start', {'turn': 1}),
          chain.reasoning(1),
          fixture.assistant(
            2,
            List.generate(30, (i) => '顶部正文 $i').join('\n\n'),
            step: 20,
          ),
        ];
        final scroll = ScrollController();
        final projection = ChatProjection();
        addTearDown(scroll.dispose);
        Widget view() => reading.host(
          ChatTimeline(
            sessionId: 'top',
            projection: projection..reconcile(events),
            events: events,
            controller: scroll,
            running: events.length == 3,
          ),
          reduced: reduced,
        );
        await tester.pumpWidget(view());
        await tester.pumpAndSettle();
        final marker = find.text('顶部正文 0', findRichText: true);
        final before = tester.getTopLeft(marker).dy;
        expect(scroll.offset, 0);
        events.add(chain.end(3, 'completed'));
        await tester.pumpWidget(view());
        expect(tester.getTopLeft(marker).dy, closeTo(before, .1));
        for (var i = 0; i < 24; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getTopLeft(marker).dy, closeTo(before, .1));
        }
        // The animation has released its anchor; future scrolling remains free.
        scroll.jumpTo(20);
        await tester.pump();
        expect(tester.getTopLeft(marker).dy, closeTo(before - 20, .1));
        scroll.jumpTo(0);
        await tester.pump();
        final gesture = await tester.startGesture(const Offset(400, 450));
        await gesture.moveBy(const Offset(0, -25));
        await tester.pump(const Duration(milliseconds: 16));
        final underFinger = tester.getTopLeft(marker).dy;
        await gesture.moveBy(const Offset(0, -40));
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.getTopLeft(marker).dy,
          closeTo(underFinger + (expected['dragDisplacement'] as num), 1),
        );
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'the next send retires remaining space and lifts the new question',
    (tester) async {
      final events = <Json>[
        fixture.event(0, 'turn/start', {'turn': 1}),
        chain.reasoning(1),
        fixture.assistant(2, '上一轮回复。', step: 20),
      ];
      final projection = ChatProjection();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      int? submittedAfter;
      Widget view() => reading.host(
        ChatTimeline(
          sessionId: 'next-send',
          projection: projection..reconcile(events),
          events: events,
          controller: scroll,
          running: events.last['type'] != 'turn/end',
          submittedAfterSeq: submittedAfter,
        ),
      );
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      final oldReply = find.text('上一轮回复。', findRichText: true);
      final initialY = tester.getTopLeft(oldReply).dy;
      events.add(chain.end(3, 'completed'));
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(oldReply).dy, closeTo(initialY, .1));
      submittedAfter = 3;
      events.addAll([
        fixture.input(4, '下一条问题'),
        fixture.event(5, 'turn/start', {'turn': 2}),
      ]);
      await tester.pumpWidget(view());
      // The active Agent indicator repeats; let the finite reveal settle.
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        tester.getTopLeft(find.text('下一条问题', findRichText: true)).dy,
        lessThan(180),
      );
      scroll.jumpTo(0);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getTopLeft(oldReply).dy, lessThan(initialY - 30));
      expect(tester.takeException(), isNull);
    },
  );
  for (final reduced in [false, true]) {
    for (final paragraph in expected['paragraphs'] as List) {
      testWidgets(
        'completion preserves each painted answer frame and its height (reduced=$reduced, paragraph=$paragraph)',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final events = <Json>[
            fixture.assistant(
              0,
              List.filled(15, '较早消息占位。').join('\n\n'),
              turn: 0,
            ),
            fixture.event(1, 'turn/start', {'turn': 1}),
            for (var i = 2; i < 8; i++) chain.reasoning(i, text: '核对第 $i 项来源。'),
            fixture.assistant(
              8,
              List.generate(35, (i) => '阅读段落 $i：保持正文原来的阅读位置。').join('\n\n'),
              step: 50,
            ),
          ];
          final projection = ChatProjection();
          final scroll = ScrollController();
          addTearDown(scroll.dispose);
          Widget view() => reading.host(
            ChatTimeline(
              sessionId: 'anchor',
              projection: projection..reconcile(events),
              events: events,
              controller: scroll,
              running: events.last['type'] != 'turn/end',
            ),
            reduced: reduced,
          );
          await tester.pumpWidget(view());
          await tester.pumpAndSettle();
          // Bring the authored row into the lazy cache, then choose a point in it.
          scroll.jumpTo(scroll.position.maxScrollExtent);
          await tester.pumpAndSettle();
          final marker = find.text(
            '阅读段落 $paragraph：保持正文原来的阅读位置。',
            findRichText: true,
          );
          scroll.jumpTo(scroll.offset + tester.getTopLeft(marker).dy - 300);
          await tester.pumpAndSettle();
          final answer = find.ancestor(
            of: marker,
            matching: find.byType(PocketMarkdown),
          );
          final before = tester.getTopLeft(marker).dy;
          final height = tester.getSize(answer).height;
          events.add(chain.end(9, 'completed'));
          await tester.pumpWidget(view());
          for (var frame = 0; frame < 24; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              tester.getTopLeft(marker).dy,
              closeTo(before + (expected['frameDisplacement'] as num), .1),
              reason: 'painted frame $frame',
            );
            expect(
              tester.getSize(answer).height,
              height + (expected['heightChange'] as num),
            );
          }
          await tester.pumpAndSettle();
          expect(tester.getTopLeft(marker).dy, closeTo(before, .1));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('a drag during auto-fold takes over the answer position', (
    tester,
  ) async {
    final events = <Json>[
      fixture.assistant(0, List.filled(20, '旧回复').join('\n\n'), turn: 0),
      fixture.event(1, 'turn/start', {'turn': 1}),
      for (var i = 2; i < 7; i++) chain.reasoning(i),
      fixture.assistant(
        7,
        List.generate(40, (i) => '可滚动正文 $i').join('\n\n'),
        step: 40,
      ),
    ];
    final projection = ChatProjection();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    Widget view() => reading.host(
      ChatTimeline(
        sessionId: 'drag',
        projection: projection..reconcile(events),
        events: events,
        controller: scroll,
        running: events.last['type'] != 'turn/end',
      ),
    );
    await tester.pumpWidget(view());
    await tester.pumpAndSettle();
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final marker = find.text('可滚动正文 10', findRichText: true);
    scroll.jumpTo(scroll.offset + tester.getTopLeft(marker).dy - 300);
    await tester.pumpAndSettle();
    events.add(chain.end(8, 'completed'));
    await tester.pumpWidget(view());
    await tester.pump(const Duration(milliseconds: 45));
    final before = tester.getTopLeft(marker).dy;
    final gesture = await tester.startGesture(const Offset(300, 400));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.getTopLeft(marker).dy, lessThan(before - 60));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(marker).dy, lessThan(before - 60));
    expect(tester.takeException(), isNull);
  });

  testWidgets('completion does not stop inertial scrolling', (tester) async {
    final events = <Json>[
      fixture.assistant(0, List.filled(20, '旧回复').join('\n\n'), turn: 0),
      fixture.event(1, 'turn/start', {'turn': 1}),
      chain.reasoning(2),
      fixture.assistant(
        3,
        List.generate(60, (i) => '惯性正文 $i').join('\n\n'),
        step: 40,
      ),
    ];
    final projection = ChatProjection();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    Widget view() => reading.host(
      ChatTimeline(
        sessionId: 'inertia',
        projection: projection..reconcile(events),
        events: events,
        controller: scroll,
        running: events.length == 4,
      ),
    );
    await tester.pumpWidget(view());
    await tester.pumpAndSettle();
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final marker = find.text('惯性正文 10', findRichText: true);
    scroll.jumpTo(scroll.offset + tester.getTopLeft(marker).dy - 300);
    await tester.pumpAndSettle();
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -120),
      800,
    );
    await tester.pump(const Duration(milliseconds: 24));
    expect(scroll.position.isScrollingNotifier.value, true);
    final before = scroll.offset;
    events.add(chain.end(4, 'completed'));
    await tester.pumpWidget(view());
    await tester.pump(const Duration(milliseconds: 60));
    expect(scroll.position.isScrollingNotifier.value, true);
    expect(scroll.offset, greaterThan(before + 5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
