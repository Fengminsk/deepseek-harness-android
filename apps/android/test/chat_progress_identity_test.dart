import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_progress.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_projection_test.dart' as fixture;
import 'tool_activity_fixture.dart' as tool_fixture;

Widget host(Widget child) => MaterialApp(
  theme: pocketTheme(Brightness.dark),
  home: MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: Scaffold(body: child),
  ),
);

void main() {
  testWidgets('progress belongs to the current turn, including context turns', (
    tester,
  ) async {
    final events = <Json>[
      fixture.input(0, 'first request'),
      fixture.event(1, 'turn/start', {'turn': 1}),
      tool_fixture.callEvent(2, id: 'first', turn: 1),
      fixture.event(3, 'turn/end', {
        'turn': 1,
        'reason': {'kind': 'completed'},
      }),
      fixture.input(
        4,
        'background context',
        source: {'kind': 'runtime-context'},
      ),
      fixture.event(5, 'turn/start', {'turn': 2}),
      tool_fixture.callEvent(6, id: 'second', turn: 2),
    ];
    final projection = ChatProjection();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    Widget view() => host(
      ChatTimeline(
        sessionId: 'session',
        projection: projection..reconcile(events),
        events: events,
        controller: scroll,
        running: true,
      ),
    );

    await tester.pumpWidget(view());
    expect(
      tester
          .widget<ChatProgressLine>(find.byType(ChatProgressLine))
          .calls
          .map((call) => call.callId),
      ['second'],
    );

    events.addAll([
      fixture.event(7, 'turn/end', {
        'turn': 2,
        'reason': {'kind': 'completed'},
      }),
      fixture.input(8, 'another request'),
    ]);
    await tester.pumpWidget(view());
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
      tester.widget<ChatProgressLine>(find.byType(ChatProgressLine)).calls,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('live and settled assistant use one stable list identity', (
    tester,
  ) async {
    final events = <Json>[
      fixture.input(0, 'request'),
      fixture.event(1, 'turn/start', {'turn': 1}),
    ];
    final projection = ChatProjection();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    Widget view() => host(
      ChatTimeline(
        sessionId: 'session',
        projection: projection..reconcile(events),
        events: events,
        controller: scroll,
        live: const ChatLiveMessage(
          identity: 'attempt-1',
          turn: 1,
          step: 1,
          content: [
            {'type': 'text', 'text': 'one reply'},
          ],
        ),
      ),
    );
    const identity = ValueKey(('session', 'assistant-step:1:1'));
    await tester.pumpWidget(view());
    expect(find.byKey(identity), findsOneWidget);

    events.add(fixture.assistant(2, 'one reply'));
    await tester.pumpWidget(view());
    expect(find.byKey(identity), findsOneWidget);
    expect(find.text('one reply', findRichText: true), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('frozen interrupted reply replaces its live copy', (
    tester,
  ) async {
    final events = <Json>[
      fixture.input(0, 'request'),
      fixture.event(1, 'turn/start', {'turn': 1}),
      fixture.event(2, 'step/start', {'turn': 1, 'step': 1}),
      {
        ...fixture.event(3, 'assistant/attempt', {'turn': 1, 'step': 1}),
        'assistantContent': [
          {'type': 'text', 'text': 'partial reply'},
        ],
      },
      fixture.event(4, 'turn/end', {
        'turn': 1,
        'reason': {'kind': 'interrupted'},
      }),
    ];
    final projection = ChatProjection()..reconcile(events);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      host(
        ChatTimeline(
          sessionId: 'session',
          projection: projection,
          events: events,
          controller: scroll,
          live: const ChatLiveMessage(
            identity: 'attempt-1',
            turn: 1,
            step: 1,
            content: [
              {'type': 'text', 'text': 'partial reply'},
            ],
            interrupted: true,
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey(('session', 'assistant-step:1:1'))),
      findsOneWidget,
    );
    expect(find.text('partial reply', findRichText: true), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
