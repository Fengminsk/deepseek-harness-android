import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/tool_activity.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_projection_test.dart' as fixture;
import 'tool_activity_fixture.dart' as tool_fixture;

Widget host(Widget body, {double scale = 1, double keyboard = 0}) =>
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(390, 844),
          textScaler: TextScaler.linear(scale),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: PocketScaffold(title: const Text('会话'), body: body),
      ),
    );

void main() {
  test('external links preserve HTTPS and refuse implicit filesystem or active scheme navigation', () {
    expect(
      chatExternalUri('https://example.com/path?q=%E4%B8%AD#part')?.host,
      'example.com',
    );
    for (final value in [
      'javascript:alert(1)',
      'data:text/html,x',
      'file:///data/private',
      'content://documents/1',
      'intent://open',
      '/data/private',
      '//example.com',
      'https://name:password@example.com',
      'https://',
      'https://example.com\nx',
    ]) {
      expect(chatExternalUri(value), isNull, reason: value);
    }
  });

  testWidgets('assistant renders Markdown while human input remains verbatim', (
    tester,
  ) async {
    final projection = ChatProjection()
      ..reconcile([
        fixture.input(0, '**原样输入**'),
        fixture.assistant(1, '# 标题\n\n**加粗** 与 `code`\n\n- 第一项\n- 第二项'),
      ]);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      host(
        ChatTimeline(
          sessionId: 'a',
          projection: projection,
          controller: scroll,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('**原样输入**'), findsOneWidget);
    expect(find.text('标题', findRichText: true), findsWidgets);
    expect(find.textContaining('**加粗**', findRichText: true), findsNothing);
    expect(find.textContaining('加粗', findRichText: true), findsWidgets);
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'context and system prompt start collapsed and retain raw text on demand',
    (tester) async {
      final projection = ChatProjection()
        ..reconcile([
          fixture.system(0, 'full system instructions'),
          fixture.input(
            1,
            'runtime context text',
            source: {'kind': 'runtime-context'},
          ),
          fixture.input(2, 'human question'),
        ]);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        host(
          ChatTimeline(
            sessionId: 'a',
            projection: projection,
            controller: scroll,
          ),
        ),
      );
      expect(find.text('full system instructions'), findsNothing);
      expect(find.text('runtime context text'), findsNothing);
      expect(find.text('human question'), findsOneWidget);
      await tester.tap(find.text('上下文 · runtime-context'));
      await tester.pumpAndSettle();
      expect(find.text('runtime context text'), findsOneWidget);
      expect(find.text('full system instructions'), findsNothing);
    },
  );

  testWidgets(
    'same-step live output disappears at settlement; identical next-step text remains',
    (tester) async {
      final projection = ChatProjection()
        ..reconcile([fixture.assistant(0, 'identical reply')]);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      Widget view(int step) => host(
        ChatTimeline(
          sessionId: 'a',
          projection: projection,
          controller: scroll,
          live: ChatLiveMessage(
            identity: 'request-$step',
            turn: 1,
            step: step,
            content: const [
              {'type': 'text', 'text': 'identical reply'},
            ],
          ),
        ),
      );
      await tester.pumpWidget(view(1));
      expect(find.byType(MarkdownBody), findsOneWidget);
      await tester.pumpWidget(view(2));
      expect(find.byType(MarkdownBody), findsNWidgets(2));
    },
  );

  testWidgets(
    'disconnected stream retains its text as unconfirmed without declaring the Agent stopped',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final projection = ChatProjection()..reconcile([]);
      Widget view({required bool unconfirmed, required bool interrupted}) =>
          host(
            ChatTimeline(
              sessionId: 'a',
              projection: projection,
              controller: scroll,
              live: ChatLiveMessage(
                identity: 'original-attempt',
                turn: 1,
                step: 1,
                content: const [
                  {'type': 'text', 'text': '保留已收到的部分回复'},
                ],
                unconfirmed: unconfirmed,
                interrupted: interrupted,
              ),
            ),
          );
      await tester.pumpWidget(view(unconfirmed: true, interrupted: false));
      expect(find.text('回复状态待确认'), findsOneWidget);
      expect(find.text('回复已中断'), findsNothing);
      expect(find.text('保留已收到的部分回复', findRichText: true), findsWidgets);
      await tester.pumpWidget(view(unconfirmed: true, interrupted: true));
      expect(find.text('回复状态待确认'), findsOneWidget);
      expect(find.text('回复已中断'), findsNothing);
      await tester.pumpWidget(view(unconfirmed: false, interrupted: true));
      expect(find.text('回复状态待确认'), findsNothing);
      expect(find.text('回复已中断'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'malformed durable attempt reports its decoding failure and retains raw inspection',
    (tester) async {
      final projection = ChatProjection()
        ..reconcile([
          {
            ...fixture.event(0, 'assistant/attempt', {
              'turn': 1,
              'step': 1,
              'stream': [
                {'type': 'unsupported-fixture-record'},
              ],
            }),
            'assistantContentError': 'Compact stream record is invalid.',
          },
        ]);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        host(
          ChatTimeline(
            sessionId: 'a',
            projection: projection,
            controller: scroll,
          ),
        ),
      );
      expect(find.text('模型回复记录无法解析'), findsOneWidget);
      await tester.tap(find.text('模型回复记录无法解析'));
      await tester.pumpAndSettle();
      expect(find.text('Compact stream record is invalid.'), findsOneWidget);
      expect(find.textContaining('unsupported-fixture-record'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'markdown links use supplied opener and failures remain visible',
    (tester) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        host(
          PocketList(
            children: [
              PocketMarkdown(
                data: '[打开链接](https://example.com)',
                onOpenLink: (uri) async {
                  opened.add(uri);
                  throw StateError('platform failure');
                },
              ),
            ],
          ),
        ),
      );
      await tester.tap(find.text('打开链接', findRichText: true).last);
      await tester.pumpAndSettle();
      expect(opened.single.toString(), 'https://example.com');
      expect(find.text('链接打开失败，请重试。'), findsOneWidget);
    },
  );

  testWidgets(
    'Markdown images never trigger implicit local or network image reads',
    (tester) async {
      await tester.pumpWidget(
        host(
          const PocketList(
            children: [
              PocketMarkdown(
                data: '![本地](file:///data/user/0/private.txt)\n\n![远程](https://example.com/pixel.png)',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.text('本地'), findsOneWidget);
      expect(find.text('远程'), findsOneWidget);
      await tester.tap(find.text('本地'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不能直接打开'), findsOneWidget);
    },
  );

  testWidgets(
    'durable file and image blocks pass the unchanged attachment reference to the opener',
    (tester) async {
      final file = <String, dynamic>{
        'attachmentId': 'a' * 64,
        'name': 'note.txt',
        'bytes': 4,
      };
      final image = <String, dynamic>{
        'attachmentId': 'b' * 64,
        'name': 'sample.png',
        'bytes': 100,
        'mediaType': 'image/png',
        'width': 1,
        'height': 1,
      };
      final opened = <Json>[];
      await tester.pumpWidget(
        host(
          PocketList(
            children: [
              ChatContent(
                storageId: 'session:message',
                content: [
                  {'type': 'file', 'attachment': file},
                  {'type': 'image', 'attachment': image},
                ],
                onOpenAttachment: (ref) async => opened.add(ref),
              ),
            ],
          ),
        ),
      );
      await tester.tap(find.text('note.txt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('sample.png'));
      await tester.pumpAndSettle();
      expect(opened, [file, image]);
      expect(identical(opened[0], file), isTrue);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'assistant tool-call blocks use one correlated expandable tool result card',
    (tester) async {
      final events = <Json>[
        fixture.event(0, 'assistant/message', {
          'turn': 1,
          'step': 1,
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'Checking files.'},
              {
                'type': 'tool-call',
                'callId': 'call-0',
                'name': 'android_shell',
                'arguments': '{"command":"pwd"}',
              },
            ],
          },
        }, surface: 'append'),
        tool_fixture.callEvent(1),
        tool_fixture.resultEvent(
          2,
          text: '{"stdout":"from device","stderr":"","exitCode":0,"timedOut":false}',
        ),
      ];
      final projection = ChatProjection()..reconcile(events);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        host(
          ChatTimeline(
            sessionId: 'a',
            projection: projection,
            controller: scroll,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ToolActivityCard), findsOneWidget);
      expect(find.text('android_shell'), findsOneWidget);
      expect(find.text('from device'), findsNothing);
      await tester.tap(find.text('android_shell'));
      await tester.pumpAndSettle();
      expect(find.text('from device'), findsOneWidget);
      expect(find.textContaining('内容详情'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long history creates only visible rows and restores folded details after eviction',
    (tester) async {
      final events = <Json>[
        fixture.input(0, 'context retained', source: {'kind': 'plugin'}),
        ...List.generate(
          1500,
          (index) => fixture.assistant(index + 1, 'reply $index\n\nMore text.'),
        ),
      ];
      final projection = ChatProjection()..reconcile(events);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        host(
          ChatTimeline(
            sessionId: 'a',
            projection: projection,
            controller: scroll,
          ),
        ),
      );
      expect(find.byType(ChatMessage).evaluate().length, lessThan(30));
      await tester.tap(find.text('上下文 · plugin'));
      await tester.pumpAndSettle();
      expect(find.text('context retained'), findsOneWidget);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('context retained'), findsNothing);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('context retained'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large text with keyboard, table and long code stays inside scroll viewport',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final projection = ChatProjection()
        ..reconcile([
          fixture.assistant(
            0,
            '# 长标题\n\n| 列一 | 列二 |\n| --- | --- |\n| 值一 | 值二 |\n\n'
            '```shell\n${'abcdefghij' * 30}\n```\n\n- [x] 已完成\n- [ ] 待处理',
          ),
        ]);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        host(
          ChatTimeline(
            sessionId: 'a',
            projection: projection,
            controller: scroll,
          ),
          scale: 2,
          keyboard: 320,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(scroll.position.maxScrollExtent, greaterThan(0));
    },
  );
}
