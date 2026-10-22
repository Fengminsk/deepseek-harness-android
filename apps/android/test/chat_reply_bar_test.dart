import 'dart:async';

import 'package:dsh_android/chat_feedback.dart';
import 'package:dsh_android/chat_reply_bar.dart';
import 'package:dsh_android/chat_reply_sources.dart';
import 'package:dsh_android/flclash/popup.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_feedback_test.dart' show FeedbackRuntime, item, ok;
import 'chat_reply_sources_test.dart' show sourceActivity;

Widget app(Widget child) => MaterialApp(
  theme: pocketTheme(Brightness.dark),
  home: Scaffold(
    body: Align(alignment: Alignment.bottomRight, child: child),
  ),
);

void main() {
  testWidgets(
    'compact copy/share/more row preserves exact authored text and 44px targets',
    (tester) async {
      final platform = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          platform.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      const text = '原始 **正文**\n\nhttps://example.org/?a=1';
      final shared = <String>[];
      await tester.pumpWidget(
        app(
          ChatReplyBar(
            text: text,
            onShare: (value) async => shared.add(value),
            onOpenSource: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('好的回答'), findsNothing);
      expect(find.text('来源'), findsNothing);
      for (final label in ['复制回答', '分享回答', '更多回答操作']) {
        final button = find.byTooltip(label);
        expect(tester.getSize(button).height, 44);
        expect(tester.getSize(button).width, 44);
      }
      final centers = [
        '复制回答',
        '分享回答',
        '更多回答操作',
      ].map((label) => tester.getCenter(find.byTooltip(label)).dy).toSet();
      expect(centers.length, 1);
      await tester.tap(find.byTooltip('复制回答'));
      await tester.pumpAndSettle();
      expect(
        platform
            .where((call) => call.method == 'Clipboard.setData')
            .single
            .arguments,
        {'text': text},
      );
      await tester.tap(find.byTooltip('分享回答'));
      await tester.pumpAndSettle();
      expect(shared, [text]);
    },
  );

  testWidgets(
    'more follows tap point and contains feedback plus records without extra footer icons',
    (tester) async {
      final runtime = FeedbackRuntime()
        ..respond = ((method, args) async => method == 'list'
            ? ok({
                'items': [item('reply', 'v1')],
              })
            : ok({'absent': true}));
      final controller = ChatFeedbackController(
        runtime: runtime,
        sessionId: 's',
      );
      var inspected = 0;
      await tester.pumpWidget(
        app(
          ChatReplyBar(
            text: 'answer',
            feedbackController: controller,
            messageId: 'reply',
            onInspect: () => inspected++,
            onShare: (_) async {},
            onOpenSource: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(runtime.requests.map((r) => r.$1), ['list']);
      final point = tester.getCenter(find.byTooltip('更多回答操作'));
      await tester.tapAt(point);
      await tester.pumpAndSettle();
      expect(find.text('取消好的回答标记'), findsOneWidget);
      expect(find.text('有问题的回答'), findsOneWidget);
      expect(find.text('会话记录'), findsOneWidget);
      final menu = tester.getRect(find.byType(CommonPopupMenu));
      expect(menu.right, greaterThan(point.dx - 44));
      await tester.tap(find.text('取消好的回答标记'));
      await tester.pumpAndSettle();
      expect(runtime.requests.last.$1, 'delete');
      expect(runtime.requests.last.$2['ifVersion'], 'v1');
      await tester.tap(find.byTooltip('更多回答操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('会话记录'));
      await tester.pumpAndSettle();
      expect(inspected, 1);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      runtime.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'stale more menu is removed when reply changes; no wrong owner action',
    (tester) async {
      var inspected = 0;
      final text = ValueNotifier('first');
      await tester.pumpWidget(
        app(
          ValueListenableBuilder<String>(
            valueListenable: text,
            builder: (_, value, _) => ChatReplyBar(
              text: value,
              onInspect: () => inspected++,
              onShare: (_) async {},
              onOpenSource: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多回答操作'));
      await tester.pumpAndSettle();
      text.value = 'replacement';
      await tester.pumpAndSettle();
      expect(find.byType(CommonPopupMenu), findsNothing);
      expect(inspected, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      text.dispose();
    },
  );

  testWidgets(
    'real sources open a draggable sheet, float content behind header and navigate recorded URL',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final sources = ChatReplySources.fromActivities([
        sourceActivity('search', 'web_search', {
          'sources': List.generate(
            16,
            (i) => {
              'url': 'https://example.org/$i',
              'title': '真实来源 $i',
              'snippet': '已经保存在工具结果中的摘录。',
            },
          ),
          'truncated': false,
        }),
      ]);
      final opened = <Uri>[];
      await tester.pumpWidget(
        app(
          ChatReplyBar(
            text: 'answer',
            sources: sources,
            onShare: (_) async {},
            onOpenSource: (uri) async => opened.add(uri),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('来源'));
      await tester.pumpAndSettle();
      final sheet = tester.getRect(
        find.byKey(const Key('reply-sources-sheet')),
      );
      final body = tester.getRect(find.byKey(const Key('reply-sources-body')));
      expect(body.top, sheet.top);
      await tester.tap(find.text('真实来源 0'));
      await tester.pumpAndSettle();
      expect(opened.single.toString(), 'https://example.org/0');
      await tester.drag(
        find.byKey(const Key('reply-sources-drag-handle')),
        const Offset(0, -150),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const Key('reply-sources-sheet'))).height,
        greaterThan(sheet.height),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭来源'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reply-sources-sheet')), findsNothing);
    },
  );

  testWidgets(
    'late share error cannot alter replacement reply and selection remains accessible',
    (tester) async {
      final pending = Completer<void>();
      final text = ValueNotifier('first');
      await tester.pumpWidget(
        app(
          ValueListenableBuilder<String>(
            valueListenable: text,
            builder: (_, value, _) => ChatReplyBar(
              text: value,
              onShare: (_) => pending.future,
              onOpenSource: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('分享回答'));
      await tester.pump();
      text.value = 'replacement';
      await tester.pumpAndSettle();
      pending.completeError(StateError('late failure'));
      await tester.pumpAndSettle();
      expect(find.text('无法打开分享，请重试。'), findsNothing);
      await tester.tap(find.byTooltip('更多回答操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择文本'));
      await tester.pumpAndSettle();
      expect(find.text('replacement'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      text.dispose();
    },
  );
}
