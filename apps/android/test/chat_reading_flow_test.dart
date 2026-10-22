import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_progress.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/chat_reply_bar.dart';
import 'package:dsh_android/chat_stream_reveal.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_projection_test.dart' as fixture;
import 'tool_activity_fixture.dart' as tools;

Widget host(Widget child, {bool reduced = true}) => MaterialApp(
  theme: pocketTheme(Brightness.dark),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Scaffold(body: child),
  ),
);

void main() {
  testWidgets(
    'closed reply owns one compact bar with only its own turn sources',
    (tester) async {
      final events = <Json>[
        fixture.input(0, 'first'),
        tools.callEvent(1, name: 'web_search'),
        tools.resultEvent(
          2,
          meta: {
            'sources': [
              {'url': 'https://first.example/a'},
            ],
            'truncated': false,
          },
        ),
        fixture.assistant(3, 'first answer'),
        fixture.event(4, 'turn/end', {
          'turn': 1,
          'reason': {'kind': 'completed'},
        }),
        fixture.input(5, 'second'),
        tools.callEvent(6, id: 'two', name: 'web_search', turn: 2),
        tools.resultEvent(
          7,
          id: 'two',
          turn: 2,
          meta: {
            'sources': [
              {'url': 'https://second.example/b'},
            ],
            'truncated': false,
          },
        ),
        fixture.assistant(8, 'second answer', turn: 2),
      ];
      final projection = ChatProjection();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      Widget view() => host(
        ChatTimeline(
          sessionId: 's',
          projection: projection..reconcile(events),
          events: events,
          controller: scroll,
        ),
      );
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(find.byType(ChatReplyBar), findsOneWidget);
      var bar = tester.widget<ChatReplyBar>(find.byType(ChatReplyBar));
      expect(bar.text, 'first answer');
      expect(bar.sources.entries.map((source) => source.url), [
        'https://first.example/a',
      ]);
      events.add(
        fixture.event(9, 'turn/end', {
          'turn': 2,
          'reason': {'kind': 'completed'},
        }),
      );
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('second answer', findRichText: true),
        200,
      );
      await tester.pumpAndSettle();
      bar = tester.widgetList<ChatReplyBar>(find.byType(ChatReplyBar)).last;
      expect(bar.text, 'second answer');
      expect(bar.sources.entries.map((source) => source.url), [
        'https://second.example/b',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('each completed reply branches at its own inclusive turn end', (
    tester,
  ) async {
    final events = <Json>[
      fixture.input(0, 'first'),
      fixture.assistant(1, 'first answer'),
      fixture.event(2, 'turn/end', {
        'turn': 1,
        'reason': {'kind': 'completed'},
      }),
      fixture.input(3, 'second'),
      fixture.assistant(4, 'second answer', turn: 2),
      fixture.event(5, 'turn/end', {
        'turn': 2,
        'reason': {'kind': 'completed'},
      }),
    ];
    final cuts = <int>[];
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      host(
        ChatTimeline(
          sessionId: 'source',
          projection: ChatProjection()..reconcile(events),
          events: events,
          controller: scroll,
          onBranch: (atSeq) async {
            cuts.add(atSeq);
            return null;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final index in [0, 1]) {
      if (index == 1) {
        await tester.scrollUntilVisible(
          find.text('second answer', findRichText: true),
          200,
        );
        await tester.pumpAndSettle();
      }
      final bar = find.byWidgetPredicate(
        (widget) =>
            widget is ChatReplyBar &&
            widget.text == (index == 0 ? 'first answer' : 'second answer'),
      );
      await tester.tap(
        find.descendant(of: bar, matching: find.byTooltip('更多回答操作')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('在新会话中创建分支'));
      await tester.pumpAndSettle();
    }
    expect(cuts, [2, 5]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'busy indicator hides after settlement and does not count previous user turn',
    (tester) async {
      final events = <Json>[
        fixture.input(0, 'first'),
        tools.callEvent(1, name: 'web_search'),
        tools.resultEvent(
          2,
          meta: {
            'sources': [
              {'url': 'https://first.example/'},
            ],
            'truncated': false,
          },
        ),
        fixture.input(3, 'new request'),
      ];
      final projection = ChatProjection()..reconcile(events);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      Widget view(bool running) => host(
        ChatTimeline(
          sessionId: 's',
          projection: projection,
          events: events,
          controller: scroll,
          running: running,
        ),
      );
      await tester.pumpWidget(view(true));
      await tester.pumpAndSettle();
      expect(find.text('正在思考'), findsOneWidget);
      expect(find.byType(ChatRollingCount), findsNothing);
      await tester.pumpWidget(view(false));
      await tester.pumpAndSettle();
      expect(find.byType(ChatProgressLine), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stream paint reveals only appended glyphs without dimming prior text',
    (tester) async {
      final boundaryKey = GlobalKey();
      Widget view(String text, {bool reduced = false}) => host(
        Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: SizedBox(
              width: 200,
              height: 80,
              child: ColoredBox(
                color: Colors.black,
                child: ChatStreamReveal(
                  revision: text,
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        reduced: reduced,
      );
      Future<Uint8List> pixels() async => (await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();
        return bytes!.buffer.asUint8List();
      }))!;
      int light(Uint8List data, int begin, int end) {
        var sum = 0;
        for (var y = 0; y < 80; y++) {
          for (var x = begin; x < end; x++) {
            sum += data[(y * 200 + x) * 4];
          }
        }
        return sum;
      }

      await tester.pumpWidget(view('old'));
      await tester.pumpAndSettle();
      final original = await pixels();
      await tester.pumpWidget(view('old new'));
      final initial = await pixels();
      await tester.pump(const Duration(milliseconds: 300));
      final finalPixels = await pixels();
      expect(light(initial, 0, 55), light(original, 0, 55));
      expect(light(finalPixels, 85, 180), greaterThan(light(initial, 85, 180)));
      await tester.pumpWidget(view('old new end', reduced: true));
      final reduced = await pixels();
      await tester.pump(const Duration(milliseconds: 300));
      expect(await pixels(), orderedEquals(reduced));
      expect(tester.takeException(), isNull);
    },
  );
}
