import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_android/chat_message_actions.dart';
import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _host(Widget child) => MaterialApp(
  theme: pocketTheme(Brightness.dark),
  home: Scaffold(body: child),
);

void main() {
  test('clock follows the local calendar day and omits invalid event time', () {
    final now = DateTime(2026, 10, 25, 12);
    int at(int year, int month, int day, int hour, int minute) =>
        DateTime(year, month, day, hour, minute).millisecondsSinceEpoch;
    expect(chatMessageClock(at(2026, 10, 25, 9, 4), now: now), '09:04');
    expect(
      chatMessageClock(at(2026, 10, 24, 23, 59), now: now),
      '10月24日 23:59',
    );
    expect(
      chatMessageClock(at(2025, 12, 31, 8, 7), now: now),
      '2025年12月31日 08:07',
    );
    expect(chatMessageClock(0, now: now), isNull);
    expect(chatMessageClock(null, now: now), isNull);
    expect(chatMessageClock(9000000000000001, now: now), isNull);
  });

  testWidgets(
    'visible user action copies exact authored text and resets check',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      const text = '**literal**\n\nsecond line';
      await tester.pumpWidget(_host(const ChatUserMessageActions(text: text)));
      final copy = find.byTooltip('复制消息');
      expect(copy, findsOneWidget);
      expect(tester.getSize(copy), const Size(44, 44));
      await tester.tap(copy);
      await tester.pump();
      expect(
        calls
            .where((call) => call.method == 'Clipboard.setData')
            .single
            .arguments,
        {'text': text},
      );
      expect(find.byTooltip('已复制消息'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byTooltip('复制消息'), findsOneWidget);
    },
  );

  testWidgets(
    'old clipboard completion cannot mark a replaced message copied',
    (tester) async {
      final pending = <Completer<void>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            final write = Completer<void>();
            pending.add(write);
            await write.future;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final text = ValueNotifier('old');
      addTearDown(text.dispose);
      await tester.pumpWidget(
        _host(
          ValueListenableBuilder<String>(
            valueListenable: text,
            builder: (_, value, _) => ChatUserMessageActions(text: value),
          ),
        ),
      );
      await tester.tap(find.byTooltip('复制消息'));
      await tester.pump();
      expect(pending, hasLength(1));
      text.value = 'new';
      await tester.pump();
      pending.single.complete();
      await tester.pump();
      expect(find.byTooltip('已复制消息'), findsNothing);
      expect(find.byTooltip('复制消息'), findsOneWidget);
    },
  );

  testWidgets('clipboard failure stays inline and permits a retry', (
    tester,
  ) async {
    var attempts = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData' && ++attempts == 1) {
          throw PlatformException(code: 'clipboard-unavailable');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      _host(const ChatUserMessageActions(text: 'retry me')),
    );
    await tester.tap(find.byTooltip('复制消息'));
    await tester.pumpAndSettle();
    expect(find.text('复制失败，请重试'), findsOneWidget);
    await tester.tap(find.byTooltip('复制消息'));
    await tester.pump();
    expect(find.text('复制失败，请重试'), findsNothing);
    expect(find.byTooltip('已复制消息'), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('only human input gets visible message actions', (tester) async {
    final snapshot = jsonDecode(
      File('test/fixtures/chat_user_message_actions.expected.json')
          .readAsStringSync(),
    ) as Json;
    final expected = snapshot['expected'] as Json;
    final projection = ChatProjection()
      ..reconcile((snapshot['events'] as List).cast<Json>());
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      _host(
        ChatTimeline(
          sessionId: 'session',
          projection: projection,
          controller: scroll,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byType(ChatUserMessageActions),
      findsNWidgets(expected['actionRows'] as int),
    );
    expect(find.text(expected['hiddenContext'] as String), findsNothing);
    expect(
      tester
          .widget<ChatUserMessageActions>(find.byType(ChatUserMessageActions))
          .text,
      expected['humanText'],
    );
  });
}
