import 'dart:convert';
import 'dart:io';

import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_message_actions.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/chat_reading.dart';
import 'package:dsh_android/chat_execution_chain.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
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
    'context and system prompt leave the reading flow and remain in records',
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
      expect(find.text('上下文 · runtime-context'), findsNothing);
      await tester.pumpWidget(
        host(ChatRecordsPage(entries: projection.entries)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('上下文 · runtime-context'));
      await tester.pumpAndSettle();
      expect(find.text('runtime context text'), findsOneWidget);
      expect(find.text('full system instructions'), findsNothing);
    },
  );

  testWidgets(
    'ordinary command and status use one-line rows while preserving full results',
    (tester) async {
      final projection = ChatProjection()
        ..reconcile([
          fixture.system(0, 'internal system instructions'),
          fixture.input(
            1,
            'runtime-only details',
            source: {'kind': 'runtime-context'},
          ),
          fixture.input(2, 'user request'),
          fixture.event(3, 'command/run', {
            'commandId': 'run-1',
            'name': 'status',
          }),
          fixture.event(4, 'command/done', {
            'commandId': 'run-1',
            'kind': 'success',
            'text': '结果第一行\n指令结果中的第二行',
          }),
          fixture.event(5, 'turn/end', {
            'turn': 1,
            'reason': {'kind': 'max-tokens'},
          }),
        ]);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        host(
          ChatTimeline(
            sessionId: 'status-rows',
            projection: projection,
            controller: scroll,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('user request'), findsOneWidget);
      expect(find.textContaining('internal system instructions'), findsNothing);
      expect(find.textContaining('runtime-only details'), findsNothing);
      expect(find.textContaining('任务状态 · 本轮达到输出长度上限'), findsOneWidget);
      expect(find.text('/status'), findsOneWidget);
      expect(find.textContaining('指令结果中的第二行'), findsNothing);
      expect(find.byType(PocketCard), findsNothing);

      await tester.tap(find.text('/status'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('指令结果中的第二行', findRichText: true),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed status keeps its first reason inline and folds long diagnostics',
    (tester) async {
      await tester.pumpWidget(
        host(
          ChatMessage(
            storageId: 'failed-status',
            entry: ChatEntry(
              key: 'turn-end:1',
              seq: 1,
              kind: ChatEntryKind.notice,
              event: fixture.event(1, 'turn/end', const {}),
              title: '本轮任务未完成',
              text: '服务在任务完成前退出，本轮任务未完成。\n仅在详情里查看的诊断内容。',
              details: '错误栈只在详情里查看。',
              error: true,
            ),
          ),
        ),
      );
      expect(find.byType(PocketCard), findsNothing);
      expect(
        find.textContaining('服务在任务完成前退出', findRichText: true),
        findsWidgets,
      );
      expect(find.textContaining('仅在详情里查看的诊断内容'), findsNothing);
      expect(find.textContaining('错误栈只在详情里查看'), findsNothing);
      await tester.tap(find.textContaining('服务在任务完成前退出'));
      await tester.pumpAndSettle();
      expect(find.textContaining('仅在详情里查看的诊断内容'), findsWidgets);
      expect(find.text('错误栈只在详情里查看。'), findsOneWidget);
      expect(tester.takeException(), isNull);
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
      expect(find.byType(ChatExecutionHeader), findsOneWidget);
      expect(find.text('from device'), findsNothing);
      await tester.tap(find.byType(ChatExecutionHeader));
      await tester.pumpAndSettle();
      expect(find.byType(ChatExecutionStep), findsOneWidget);
      await tester.tap(find.text('pwd'));
      await tester.pumpAndSettle();
      expect(find.text('from device'), findsOneWidget);
      expect(find.textContaining('内容详情'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long press copies complete authored text and offers explicit selection',
    (tester) async {
      final clipboard = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
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
      final projection = ChatProjection()
        ..reconcile([fixture.assistant(0, '**完整回复**\n\n第二段')]);
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
      await tester.longPress(find.byType(ChatMessageActions));
      await tester.pumpAndSettle();
      expect(find.text('选择文本'), findsOneWidget);
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(clipboard, ['**完整回复**\n\n第二段']);
      await tester.longPress(find.byType(ChatMessageActions));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择文本'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        '**完整回复**\n\n第二段',
      );
      expect(tester.takeException(), isNull);
    },
  );

  test('copy excludes hidden reasoning and attachment records', () {
    expect(
      chatMessageText([
        {'type': 'text', 'text': 'visible'},
        {'type': 'reasoning', 'text': 'hidden'},
        {
          'type': 'image',
          'attachment': {'id': 'private'},
        },
        {'type': 'text', 'text': 'second'},
      ]),
      'visible\n\nsecond',
    );
  });

  testWidgets('settled reasoning is a quiet process row outside the answer', (
    tester,
  ) async {
    final snapshot = jsonDecode(
      File('test/fixtures/chat_assistant_process.expected.json')
          .readAsStringSync(),
    ) as Json;
    final expected = snapshot['expected'] as Json;
    final projection = ChatProjection()
      ..reconcile((snapshot['events'] as List).cast<Json>());
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      host(
        ChatTimeline(
          sessionId: 'reasoning',
          projection: projection,
          controller: scroll,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('状态待确认'), findsOneWidget);
    expect(find.text('思考过程'), findsNothing);
    expect(find.text(expected['hiddenReasoning'] as String), findsNothing);
    expect(
      find.textContaining(expected['answer'] as String, findRichText: true),
      findsWidgets,
    );
    expect(
      find.ancestor(
        of: find.text(expected['processTitle'] as String),
        matching: find.byType(ChatMessageActions),
      ),
      findsNothing,
    );
    await tester.tap(find.byType(ChatExecutionHeader));
    await tester.pumpAndSettle();
    expect(find.text(expected['processTitle'] as String), findsOneWidget);
    expect(
      find.textContaining(
        expected['hiddenReasoning'] as String,
        findRichText: true,
      ),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('live reasoning remains separate as reply text arrives', (
    tester,
  ) async {
    final projection = ChatProjection()..reconcile([]);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    Widget timeline(List<dynamic> content) => host(
      ChatTimeline(
        sessionId: 'live-reasoning',
        projection: projection,
        controller: scroll,
        running: true,
        live: ChatLiveMessage(
          identity: 'live-1',
          content: content,
          turn: 1,
          step: 1,
        ),
      ),
    );
    await tester.pumpWidget(
      timeline(const [
        {'type': 'reasoning', 'text': 'private live detail'},
      ]),
    );
    expect(find.text('正在思考'), findsOneWidget);
    expect(find.text('private live detail'), findsOneWidget);
    await tester.pumpWidget(
      timeline(const [
        {'type': 'reasoning', 'text': 'private live detail'},
        {'type': 'text', 'text': 'Visible reply'},
      ]),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('已思考'), findsOneWidget);
    expect(find.text('private live detail'), findsOneWidget);
    expect(
      find.textContaining('Visible reply', findRichText: true),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'message popup closes when its conversation changes or source disappears',
    (tester) async {
      final projection = ChatProjection()
        ..reconcile([fixture.assistant(0, 'copy this message')]);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      Widget view(String session) => host(
        ChatTimeline(
          sessionId: session,
          projection: projection,
          controller: scroll,
        ),
      );
      await tester.pumpWidget(view('a'));
      await tester.longPress(find.byType(ChatMessageActions));
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsOneWidget);
      await tester.pumpWidget(view('b'));
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsNothing);
      await tester.longPress(find.byType(ChatMessageActions));
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsOneWidget);
      projection.reconcile([]);
      await tester.pumpWidget(view('b'));
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tool details follow updates after grouping evicts the row, then close on session switch',
    (tester) async {
      final events = <Json>[tool_fixture.callEvent(0, id: 'first')];
      final projection = ChatProjection()..reconcile(events);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      Widget view(String session) => host(
        ChatTimeline(
          sessionId: session,
          projection: projection,
          controller: scroll,
        ),
      );
      await tester.pumpWidget(view('a'));
      await tester.tap(find.byType(ChatExecutionHeader));
      await tester.pumpAndSettle();
      await tester.tap(find.text('pwd'));
      await tester.pumpAndSettle();
      // Folding removes the lazy step while the route's timeline-owned source
      // continues to deliver results for the original call.
      tester
          .widget<ChatExecutionHeader>(
            find.byType(ChatExecutionHeader, skipOffstage: false),
          )
          .onToggle();
      await tester.pumpAndSettle();
      events.add(tool_fixture.callEvent(1, id: 'second'));
      projection.reconcile(events);
      await tester.pumpWidget(view('a'));
      await tester.pumpAndSettle();
      events.add(
        tool_fixture.resultEvent(
          2,
          id: 'first',
          text: '{"stdout":"late device output","exitCode":0}',
        ),
      );
      projection.reconcile(events);
      await tester.pumpWidget(view('a'));
      await tester.pumpAndSettle();
      expect(find.text('late device output'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(view('b'));
      await tester.pumpAndSettle();
      expect(find.text('late device output'), findsNothing);
      expect(find.byType(ChatExecutionHeader), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large expanded tool groups keep lazy rows and preserve folding',
    (tester) async {
      final projection = ChatProjection()
        ..reconcile(
          List.generate(
            1500,
            (index) => tool_fixture.callEvent(index, id: 'call-$index'),
          ),
        );
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
      expect(find.byType(ChatExecutionStep), findsNothing);
      await tester.tap(find.byType(ChatExecutionHeader));
      await tester.pumpAndSettle();
      expect(
        find.byType(ChatExecutionStep).evaluate().length,
        inInclusiveRange(1, 30),
      );
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.byType(ChatExecutionStep).evaluate().length, lessThan(30));
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ChatExecutionHeader));
      await tester.pumpAndSettle();
      expect(find.byType(ChatExecutionStep), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long history stays lazy and internal context never reappears after recycling',
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
      expect(find.text('上下文 · plugin'), findsNothing);
      expect(find.text('context retained'), findsNothing);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('context retained'), findsNothing);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('context retained'), findsNothing);
      expect(find.byType(ChatMessage).evaluate().length, lessThan(30));
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
  testWidgets('PocketMarkdown 对齐 DSH 手机排版 token', (tester) async {
    await tester.pumpWidget(
      host(
        const PocketMarkdown(
          data:
              '# 一级\n\n## 二级\n\n### 三级\n\n#### 四级\n\n正文段落。\n\n- 列表项\n\n> 引用\n\n`inline`\n\n```\ncode\n```',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    final style = body.styleSheet!;
    expect(style.p!.fontSize, 14);
    expect(style.p!.height, closeTo(24 / 14, .001));
    expect(style.blockSpacing, 16);
    expect(style.listIndent, 18);
    expect(style.listBulletPadding, const EdgeInsets.only(right: 6));
    expect(style.h1!.fontSize, 21);
    expect(style.h1!.height, closeTo(30 / 21, .001));
    expect(style.h1!.fontWeight, FontWeight.w700);
    expect(style.h2!.fontSize, 19);
    expect(style.h3!.fontSize, 18);
    expect(style.h4!.fontSize, 14);
    expect(style.h4!.fontWeight, FontWeight.w600);
    expect(style.h1Padding?.top, 16);
    expect(style.h4Padding, EdgeInsets.zero);
    expect(style.code!.fontFamily, 'monospace');
    expect(style.code!.fontSize, closeTo(14 * .875, .001));
    expect(style.codeblockPadding, const EdgeInsets.all(16));
    expect(
      (style.codeblockDecoration! as BoxDecoration).borderRadius,
      BorderRadius.circular(12),
    );
    final quote = style.blockquoteDecoration! as BoxDecoration;
    expect(quote.color, isNull);
    final quoteBorder = quote.border! as Border;
    expect(quoteBorder.left.width, 2);
    expect(style.blockquotePadding, const EdgeInsets.fromLTRB(14, 0, 0, 0));
    expect(style.tableCellsPadding, const EdgeInsets.symmetric(horizontal: 16, vertical: 10));
    expect(style.tableHead!.fontWeight, FontWeight.w600);
    expect(style.a!.fontWeight, FontWeight.w500);
    expect(chatMessageGutter, 16);
    expect(chatUserBubbleMaxWidthFactor, .82);
    final aux = chatAuxiliaryTextStyle(
      tester.element(find.byType(MarkdownBody)),
    );
    expect(aux.fontSize, 13);
    expect(aux.height, closeTo(18 / 13, .001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏代码块按 DSH 自动换行，不出现横向滚动', (tester) async {
    final longLine = 'https://example.com/${'a' * 240}';
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(320, 640)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: PocketMarkdown(data: '```\n$longLine\n```'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('https://example.com/'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MarkdownBody),
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
      reason: '代码块必须 pre-wrap/break，不提供横向滚动',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽表格在窄屏走横向滚动且不溢出', (tester) async {
    const table =
        '| 列一 | 列二 | 列三 | 列四 | 列五 |\n'
        '| --- | --- | --- | --- | --- |\n'
        '| 很长的单元格内容一 | 很长的内容二 | 很长的内容三 | 很长的内容四 | 很长的内容五 |';
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(320, 640)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: PocketMarkdown(data: table),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('很长的单元格内容一'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
