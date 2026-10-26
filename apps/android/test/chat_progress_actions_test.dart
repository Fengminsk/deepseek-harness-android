import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_progress.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/tool_activity_data.dart';
import 'package:dsh_android/tool_activity_presentation.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_projection_test.dart' as fixture;
import 'tool_activity_fixture.dart' as tools;

Widget _host(Widget child) => MaterialApp(
  theme: pocketTheme(Brightness.dark),
  home: MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: Scaffold(body: child),
  ),
);

ToolActivity _pending(
  String name, {
  Json args = const {},
  String id = 'call-0',
}) {
  final projection = ToolActivityProjection()
    ..reconcile([tools.callEvent(1, id: id, name: name, args: args)]);
  return projection.byAnchorSeq[1]!;
}

void main() {
  test('native file actions use human activity names and precise progress', () {
    for (final (action, name, progress) in [
      ('roots', '查看授权目录', '正在查看授权目录'),
      ('list', '浏览文件', '正在浏览文件'),
      ('read', '读取文件', '正在读取文件'),
      ('read_image', '读取图片', '正在读取文件'),
      ('search', '搜索文件', '正在搜索文件'),
    ]) {
      final activity = _pending('android_files', args: {'action': action});
      expect(toolActivityName(activity), name);
      expect(chatProgressLabel([activity]), progress);
    }
  });

  test('mixed pending work reports only its shared observed activity', () {
    expect(
      chatProgressLabel([
        _pending('web_search'),
        _pending('web_fetch', id: 'fetch'),
      ]),
      '正在搜索',
    );
    expect(
      chatProgressLabel([
        _pending('android_shell'),
        _pending('android_files', args: {'action': 'read'}, id: 'read'),
      ]),
      '正在处理',
    );
    expect(chatProgressLabel(const [], writing: true), '正在回复');
  });

  testWidgets(
    'timeline follows the active PTC child without leaking stale status',
    (tester) async {
      final events = <Json>[
        fixture.input(0, '请读取这张图'),
        fixture.event(1, 'turn/start', {'turn': 1}),
        tools.callEvent(2, id: 'root', name: 'ptc'),
        tools.toolEvent(3, 'tool/ptc-dispatch-start', {
          'rootCallId': 'root',
          'parentCallId': 'root',
          'subCallId': 'image',
          'name': 'android_files',
          'arguments': {
            'action': 'read_image',
            'root': 'grant-1',
            'path': 'a.png',
          },
        }),
      ];
      final projection = ChatProjection();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      Widget view() => _host(
        ChatTimeline(
          sessionId: 'progress-actions',
          projection: projection..reconcile(events),
          controller: scroll,
          events: events,
          running: true,
        ),
      );

      await tester.pumpWidget(view());
      expect(find.text('正在读取文件'), findsOneWidget);
      expect(find.text('正在处理'), findsNothing);

      events.add(
        tools.toolEvent(4, 'tool/ptc-dispatch', {
          'rootCallId': 'root',
          'parentCallId': 'root',
          'subCallId': 'image',
          'name': 'android_files',
          'isError': false,
          'content': [
            {'type': 'text', 'text': 'read complete'},
          ],
        }),
      );
      await tester.pumpWidget(view());
      expect(find.text('正在读取文件'), findsNothing);
      expect(find.text('正在处理'), findsOneWidget);

      events.add(tools.resultEvent(5, id: 'root'));
      await tester.pumpWidget(view());
      expect(find.text('正在处理'), findsNothing);
      expect(find.text('正在思考'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
