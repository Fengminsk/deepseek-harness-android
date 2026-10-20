import 'dart:convert';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/tool_activity.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'tool_activity_fixture.dart';

Widget host(ToolActivity activity) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  home: PocketScaffold(
    title: const Text('会话'),
    body: PocketList(
      children: [
        ToolActivityCard(
          key: ValueKey('session-a-${activity.identity}'),
          activity: activity,
        ),
      ],
    ),
  ),
);

Future<void> tapVisible(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await Scrollable.ensureVisible(tester.element(target), alignment: .5);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('open card remains open when its real result arrives', (
    tester,
  ) async {
    final events = <Json>[callEvent(1)];
    final projection = ToolActivityProjection()..reconcile(events);
    await tester.pumpWidget(host(projection.byAnchorSeq[1]!));
    expect(find.text('命令'), findsNothing);
    await tester.tap(find.text('android_shell'));
    await tester.pumpAndSettle();
    expect(find.text('命令'), findsOneWidget);
    expect(find.textContaining('尚未收到工具结果'), findsOneWidget);
    events.add(
      resultEvent(
        2,
        text: jsonEncode({
          'stdout': 'from the device',
          'stderr': '',
          'exitCode': 0,
          'timedOut': false,
        }),
      ),
    );
    projection.reconcile(events);
    await tester.pumpWidget(host(projection.byAnchorSeq[1]!));
    await tester.pumpAndSettle();
    expect(find.text('命令'), findsOneWidget);
    expect(find.text('from the device'), findsOneWidget);
    expect(find.textContaining('尚未收到工具结果'), findsNothing);
    await tester.tap(find.text('android_shell'));
    await tester.pumpAndSettle();
    expect(find.text('命令'), findsNothing);
  });

  testWidgets('expanded child receives its later result in the same card', (
    tester,
  ) async {
    final events = <Json>[callEvent(1, name: 'ptc'), dispatchEvent(2)];
    final projection = ToolActivityProjection()..reconcile(events);
    await tester.pumpWidget(host(projection.byAnchorSeq[1]!));
    await tester.tap(find.text('ptc'));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('read'));
    expect(find.text('路径'), findsOneWidget);
    events.add(dispatchEvent(3, end: true, text: 'updated child output'));
    projection.reconcile(events);
    await tester.pumpWidget(host(projection.byAnchorSeq[1]!));
    await tester.pumpAndSettle();
    expect(find.text('路径'), findsOneWidget);
    expect(find.text('updated child output'), findsOneWidget);
    expect(find.textContaining('已返回结果'), findsOneWidget);
  });

  testWidgets('unknown tool retains raw arguments and result lazily', (
    tester,
  ) async {
    final projection = ToolActivityProjection()
      ..reconcile([
        callEvent(
          1,
          name: 'custom_tool',
          args: {'future': 'keep raw argument'},
        ),
        resultEvent(
          2,
          text: 'keep raw output',
          meta: {
            'privateShape': [1, 2],
          },
        ),
      ]);
    await tester.pumpWidget(host(projection.byAnchorSeq[1]!));
    expect(find.text('完整原始详情'), findsNothing);
    await tester.tap(find.text('custom_tool'));
    await tester.pumpAndSettle();
    expect(find.text('完整原始详情'), findsOneWidget);
    expect(find.textContaining('keep raw argument'), findsNothing);
    await tapVisible(tester, find.text('完整原始详情'));
    expect(find.textContaining('keep raw argument'), findsOneWidget);
    expect(find.textContaining('keep raw output'), findsOneWidget);
    expect(find.textContaining('privateShape'), findsOneWidget);
  });

  testWidgets('failed and result-only cards state missing facts explicitly', (
    tester,
  ) async {
    final projection = ToolActivityProjection()
      ..reconcile([
        resultEvent(
          1,
          isError: true,
          error: {
            'name': 'Rejected',
            'code': 'denied',
            'reason': 'User rejected this tool',
          },
        ),
      ]);
    await tester.pumpWidget(host(projection.byAnchorSeq[1]!));
    expect(find.textContaining('调用失败'), findsOneWidget);
    await tester.tap(find.text('工具调用（名称未记录）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('缺少调用开始记录'), findsOneWidget);
    expect(find.textContaining('User rejected this tool'), findsOneWidget);
    expect(find.textContaining('尚未收到工具结果'), findsNothing);
  });
}
