// 远程会话的待办卡片：收起摘要计数、展开清单、状态图标与截断。
//
// 纯 widget 测试：卡片按传入的 todos / expanded 渲染，展开状态由测试里的
// StatefulBuilder 扮演页面持有，因此不连接任何数据源。

import 'package:dsh_android/remote_session_insights.dart';
import 'package:dsh_android/remote_todo_card.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

RemoteTodoItem _todo(String content, RemoteTodoStatus status) =>
    RemoteTodoItem(content: content, status: status);

/// 把卡片放进 App 主题与可控宽度里；[textScale] 模拟放大字体。
Widget _host({
  required List<RemoteTodoItem>? todos,
  required bool expanded,
  VoidCallback? onToggle,
  double width = 360,
  double textScale = 1,
}) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: width,
              child: RemoteTodoCard(
                todos: todos,
                expanded: expanded,
                onToggle: onToggle ?? () {},
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

/// 由测试持有展开状态的状态化宿主，模拟页面的 setState。
class _StatefulHost extends StatefulWidget {
  const _StatefulHost({required this.todos, required this.onToggle});

  final List<RemoteTodoItem> todos;
  final void Function() onToggle;

  @override
  State<_StatefulHost> createState() => _StatefulHostState();
}

class _StatefulHostState extends State<_StatefulHost> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: 360,
          child: RemoteTodoCard(
            todos: widget.todos,
            expanded: expanded,
            onToggle: () {
              widget.onToggle();
              setState(() => expanded = !expanded);
            },
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('没有待办投影或清单为空时不渲染卡片', (tester) async {
    await tester.pumpWidget(_host(todos: null, expanded: false));
    expect(find.byKey(RemoteTodoCard.toggleKey), findsNothing);
    expect(find.text('任务'), findsNothing);

    await tester.pumpWidget(
      _host(todos: const <RemoteTodoItem>[], expanded: false),
    );
    expect(find.byKey(RemoteTodoCard.toggleKey), findsNothing);
    expect(find.text('任务'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('收起态显示分状态计数，零计数的状态不写', (tester) async {
    await tester.pumpWidget(
      _host(
        todos: <RemoteTodoItem>[
          _todo('检查构建', RemoteTodoStatus.inProgress),
          _todo('跑测试', RemoteTodoStatus.completed),
          _todo('收尾', RemoteTodoStatus.completed),
          _todo('发布', RemoteTodoStatus.pending),
        ],
        expanded: false,
      ),
    );

    expect(find.text('任务'), findsOneWidget);
    expect(find.text('已完成 2 · 进行中 1 · 待处理 1'), findsOneWidget);
    expect(find.byKey(RemoteTodoCard.listKey), findsNothing);

    // 只有一种状态时只写这一段。
    await tester.pumpWidget(
      _host(
        todos: <RemoteTodoItem>[
          _todo('a', RemoteTodoStatus.completed),
          _todo('b', RemoteTodoStatus.completed),
        ],
        expanded: false,
      ),
    );
    expect(find.text('已完成 2'), findsOneWidget);
    expect(find.textContaining('进行中'), findsNothing);
    expect(find.textContaining('待处理'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点按摘要行由页面切换展开，展开后列出全部待办', (tester) async {
    var toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: _StatefulHost(
          todos: <RemoteTodoItem>[
            _todo('检查构建', RemoteTodoStatus.inProgress),
            _todo('跑测试', RemoteTodoStatus.pending),
          ],
          onToggle: () => toggles++,
        ),
      ),
    );

    expect(find.byKey(RemoteTodoCard.listKey), findsNothing);
    await tester.tap(find.byKey(RemoteTodoCard.toggleKey));
    await tester.pump();
    expect(toggles, 1);
    expect(find.byKey(RemoteTodoCard.listKey), findsOneWidget);
    expect(find.text('检查构建'), findsOneWidget);
    expect(find.text('跑测试'), findsOneWidget);

    await tester.tap(find.byKey(RemoteTodoCard.toggleKey));
    await tester.pump();
    expect(toggles, 2);
    expect(find.byKey(RemoteTodoCard.listKey), findsNothing);
    expect(find.text('检查构建'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('展开态按状态显示图标，已完成条目划掉', (tester) async {
    await tester.pumpWidget(
      _host(
        todos: <RemoteTodoItem>[
          _todo('待处理事项', RemoteTodoStatus.pending),
          _todo('进行中事项', RemoteTodoStatus.inProgress),
          _todo('已完成事项', RemoteTodoStatus.completed),
        ],
        expanded: true,
      ),
    );

    expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsOneWidget);
    expect(find.byIcon(Icons.timelapse_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);

    final completed = tester.widget<Text>(find.text('已完成事项'));
    expect(completed.style?.decoration, TextDecoration.lineThrough);
    final inProgress = tester.widget<Text>(find.text('进行中事项'));
    expect(inProgress.style?.decoration, isNot(TextDecoration.lineThrough));
    final pending = tester.widget<Text>(find.text('待处理事项'));
    expect(pending.style?.decoration, isNot(TextDecoration.lineThrough));
    expect(tester.takeException(), isNull);
  });

  testWidgets('长文本最多两行并省略，放大字体也不溢出', (tester) async {
    final long =
        '把很长的待办内容写到足以换行，再继续写到超过两行以便验证省略号确实生效。'
            '后半段继续补充细节，确保这条待办在窄屏上无论如何都放不下一行。' *
        2;
    await tester.pumpWidget(
      _host(
        todos: <RemoteTodoItem>[_todo(long, RemoteTodoStatus.inProgress)],
        expanded: true,
        width: 320,
        textScale: 1.6,
      ),
    );

    final text = tester.widget<Text>(find.text(long));
    expect(text.maxLines, 2);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  testWidgets('待办很多时清单区限高，卡片不会把输入区挤出屏幕', (tester) async {
    await tester.pumpWidget(
      _host(
        todos: <RemoteTodoItem>[
          for (var index = 0; index < 30; index++)
            _todo('第 $index 项待办', RemoteTodoStatus.pending),
        ],
        expanded: true,
      ),
    );

    // 600 是测试默认视口高度；清单区最多占 28%，加上摘要行仍在卡片内。
    final height = tester.getSize(find.byType(RemoteTodoCard)).height;
    expect(height, lessThanOrEqualTo(600 * .28 + 80));
    expect(find.byKey(RemoteTodoCard.listKey), findsOneWidget);

    // 清单在自己的滚动区里滚动，不把整页顶上去。
    await tester.drag(
      find.descendant(
        of: find.byType(RemoteTodoCard),
        matching: find.byType(SingleChildScrollView),
      ),
      const Offset(0, -200),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
