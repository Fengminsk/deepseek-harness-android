import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/tool_activity.dart';
import 'package:dsh_android/tool_activity_details.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'tool_activity_fixture.dart';
import 'tool_activity_test.dart' as shared;

Finder reader(String identity) =>
    find.byKey(ValueKey('inline-scroll:$identity'));
Finder copy(String identity) => find.byKey(ValueKey('inline-copy:$identity'));

ScrollController controller(WidgetTester tester, String identity) => tester
    .widget<SingleChildScrollView>(
      find.descendant(
        of: reader(identity),
        matching: find.byType(SingleChildScrollView),
      ),
    )
    .controller!;

void main() {
  testWidgets(
    'inline shell separates bounded command and complete selectable output',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final command = List.generate(
        35,
        (i) => 'printf "command $i\\n"',
      ).join('\n');
      final output = '${'recorded output\n' * 600}TAIL_AFTER_6000';
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
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
      final projection = ToolActivityProjection()
        ..reconcile([
          callEvent(1, args: {'command': command}),
          resultEvent(
            2,
            text: jsonEncode({'stdout': output, 'stderr': '', 'exitCode': 0}),
          ),
        ]);
      final activity = projection.byAnchorSeq[1]!;
      await tester.pumpWidget(shared.host(activity));
      expect(
        tester.getRect(shared.row(activity)).height,
        inInclusiveRange(48, 56),
      );
      expect(find.textContaining('android_shell'), findsNothing);
      expect(find.byType(ToolBoundedText), findsNothing);
      await shared.tapVisible(tester, shared.row(activity));
      expect(shared.sheet, findsNothing);
      final commandId = '${activity.identity}:command';
      final outputId = '${activity.identity}:stdout';
      expect(tester.getSize(reader(commandId)).height, lessThanOrEqualTo(180));
      expect(tester.getSize(reader(outputId)).height, lessThanOrEqualTo(260));
      expect(
        tester.getTopLeft(reader(commandId)).dy,
        lessThan(tester.getTopLeft(reader(outputId)).dy),
      );
      expect(
        find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == output,
        ),
        findsOneWidget,
      );
      expect(
        controller(tester, outputId).position.maxScrollExtent,
        greaterThan(1000),
      );
      await shared.tapVisible(tester, copy(commandId));
      await shared.tapVisible(tester, copy(outputId));
      expect(copied, [command, output]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late result retains inline command scroll and call expansion', (
    tester,
  ) async {
    final events = <Json>[
      callEvent(1, args: {'command': 'echo command\n' * 70}),
    ];
    final projection = ToolActivityProjection()..reconcile(events);
    var activity = projection.byAnchorSeq[1]!;
    await tester.pumpWidget(shared.host(activity));
    await shared.tapVisible(tester, shared.row(activity));
    final commandId = '${activity.identity}:command';
    final before = controller(tester, commandId);
    before.jumpTo(160);
    await tester.pump();
    events.add(
      resultEvent(
        2,
        text: jsonEncode({'stdout': 'arrived later', 'exitCode': 0}),
      ),
    );
    projection.reconcile(events);
    activity = projection.byAnchorSeq[1]!;
    await tester.pumpWidget(shared.host(activity));
    await tester.pumpAndSettle();
    expect(identical(before, controller(tester, commandId)), isTrue);
    expect(before.offset, 160);
    expect(find.text('arrived later'), findsOneWidget);
    expect(shared.sheet, findsNothing);
  });

  testWidgets(
    'PTC descendants expand in place and keep the actual parent relationship',
    (tester) async {
      final events = <Json>[
        callEvent(1, name: 'ptc'),
        dispatchEvent(2),
        dispatchEvent(3, parent: 'sub-a', child: 'nested'),
      ];
      final projection = ToolActivityProjection()..reconcile(events);
      var activity = projection.byAnchorSeq[1]!;
      final child = activity.children.single;
      final nested = child.children.single;
      await tester.pumpWidget(shared.host(activity));
      await shared.tapVisible(tester, shared.row(activity));
      expect(shared.row(child), findsOneWidget);
      expect(shared.row(nested), findsNothing);
      await shared.tapVisible(tester, shared.row(child));
      expect(shared.row(nested), findsOneWidget);
      expect(reader('${child.identity}:路径'), findsOneWidget);
      await shared.tapVisible(tester, shared.row(nested));
      expect(reader('${nested.identity}:路径'), findsOneWidget);
      expect(shared.sheet, findsNothing);
      events.add(
        dispatchEvent(
          4,
          parent: 'sub-a',
          child: 'nested',
          end: true,
          text: 'nested output',
        ),
      );
      projection.reconcile(events);
      activity = projection.byAnchorSeq[1]!;
      await tester.pumpWidget(shared.host(activity));
      await tester.pumpAndSettle();
      expect(find.text('nested output'), findsOneWidget);
      await shared.tapVisible(tester, shared.row(child));
      expect(shared.row(nested), findsNothing);
      expect(shared.sheet, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('collapsed exit failure and expanded truncation remain visible', (
    tester,
  ) async {
    final projection = ToolActivityProjection()
      ..reconcile([
        callEvent(1, args: {'command': 'cat missing'}),
        resultEvent(
          2,
          text: jsonEncode({
            'stdout': '',
            'stderr': 'No such file',
            'exitCode': 2,
            'truncated': true,
          }),
        ),
      ]);
    final activity = projection.byAnchorSeq[1]!;
    await tester.pumpWidget(shared.host(activity));
    expect(find.text('运行失败 cat missing'), findsOneWidget);
    await shared.tapVisible(tester, shared.row(activity));
    expect(find.text('No such file'), findsOneWidget);
    expect(find.textContaining('退出码 2'), findsOneWidget);
    expect(find.textContaining('运行时已截断输出'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('inline readers fit 320dp at large text in $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final projection = ToolActivityProjection()
        ..reconcile([
          callEvent(1, args: {'command': 'echo ${'unbreakable' * 100}'}),
          resultEvent(
            2,
            text: jsonEncode({'stdout': 'output\n' * 200, 'exitCode': 0}),
          ),
        ]);
      final activity = projection.byAnchorSeq[1]!;
      await tester.pumpWidget(
        shared.host(
          activity,
          reduceMotion: true,
          textScale: 1.8,
          brightness: brightness,
        ),
      );
      await shared.tapVisible(tester, shared.row(activity));
      expect(
        tester.getRect(reader('${activity.identity}:command')).right,
        lessThanOrEqualTo(320),
      );
      expect(
        tester.getRect(reader('${activity.identity}:stdout')).right,
        lessThanOrEqualTo(320),
      );
      expect(tester.getSize(copy('${activity.identity}:command')).width, 36);
      expect(tester.getSize(copy('${activity.identity}:command')).height, 36);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'late inline clipboard completion cannot mark replacement output copied',
    (tester) async {
      final completion = Completer<void>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') await completion.future;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      Widget host(String text) => MaterialApp(
        home: Scaffold(
          body: ToolBoundedText(
            identity: 'copy-owner',
            title: '输出',
            text: text,
          ),
        ),
      );
      await tester.pumpWidget(host('old snapshot'));
      await tester.tap(copy('copy-owner'));
      await tester.pump();
      await tester.pumpWidget(host('new snapshot'));
      completion.complete();
      await tester.pumpAndSettle();
      expect(find.text('已复制'), findsNothing);
      expect(find.text('new snapshot'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
