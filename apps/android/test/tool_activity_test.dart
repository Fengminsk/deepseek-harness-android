import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_android/entry_motion.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/tool_activity.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'tool_activity_fixture.dart';

Widget host(
  ToolActivity activity, {
  ValueNotifier<ToolActivity?>? source,
  bool visible = true,
  bool reduceMotion = false,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  String? fontFamily,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: pocketTheme(brightness).copyWith(
    textTheme: pocketTheme(brightness).textTheme.apply(fontFamily: fontFamily),
  ),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduceMotion,
      textScaler: TextScaler.linear(textScale),
    ),
    child: child!,
  ),
  home: PocketScaffold(
    title: const Text('会话'),
    body: PocketList(
      children: [
        if (visible)
          ToolActivityCard(
            key: ValueKey('session-a-${activity.identity}'),
            activity: activity,
            activitySource: source,
          ),
      ],
    ),
  ),
);

Finder get sheet => find.byKey(const Key('tool-details-sheet'));
Finder foreground(Finder finder) => sheet.evaluate().isEmpty
    ? finder
    : find.descendant(of: sheet, matching: finder);
Finder activeText(String text) => foreground(find.text(text));
Finder activeTextContaining(String text) =>
    foreground(find.textContaining(text));
Finder row(ToolActivity activity) =>
    foreground(find.byKey(ValueKey('tool-row:${activity.identity}')));
Finder copy(String title) => find.byKey(ValueKey('tool-copy:$title'));

Future<void> tapVisible(WidgetTester tester, Finder target) async {
  await Scrollable.ensureVisible(tester.element(target), alignment: .5);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> open(WidgetTester tester, ToolActivity activity) async {
  final full = find.byKey(ValueKey('tool-full:${activity.identity}'));
  if (full.evaluate().isEmpty) {
    await tapVisible(tester, row(activity));
  }
  await tapVisible(tester, full);
  expect(sheet, findsOneWidget);
}

Future<void> close(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('tool-details-close')));
  await tester.pumpAndSettle();
  expect(sheet, findsNothing);
}

void main() {
  testWidgets('optional local light and dark tool detail captures', (
    tester,
  ) async {
    final directory = Platform.environment['POCKET_TOOL_CAPTURE_DIR'];
    if (directory == null) return;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final bytes = await File(
        Platform.environment['POCKET_TOOL_CAPTURE_FONT']!,
      ).readAsBytes();
      await (FontLoader(
        'ToolCapture',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      await (FontLoader(
        'monospace',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    final projection = ToolActivityProjection()
      ..reconcile([
        callEvent(
          1,
          args: {
            'command':
                'pwd; printf "BACKGROUND_OK\\n"\n'
                'node --version\n'
                'printf "本地任务执行记录\\n"',
            'workdir': '/data/user/0/app/files/workspace',
          },
        ),
        resultEvent(
          2,
          text: jsonEncode({
            'stdout':
                '/data/user/0/app/files/workspace\nBACKGROUND_OK\n'
                'v24.22.0\n本地任务执行记录\n'
                '${List.generate(40, (i) => '步骤 ${i + 1}：等待后台任务完成').join('\n')}\n',
            'stderr': '',
            'exitCode': 0,
            'timedOut': false,
            'cancelled': false,
          }),
        ),
      ]);
    final activity = projection.byAnchorSeq[1]!;
    for (final brightness in Brightness.values) {
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: host(
            activity,
            brightness: brightness,
            textScale: brightness == Brightness.dark ? 1.3 : 1,
            fontFamily: 'ToolCapture',
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> capture(String suffix) => tester.runAsync(() async {
        final image =
            await (captureKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 2);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await Directory(directory).create(recursive: true);
        await File('$directory/tool-details-${brightness.name}$suffix.png')
            .writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
      await capture('-collapsed');
      await tapVisible(tester, row(activity));
      await capture('-inline');
      await open(tester, activity);
      await capture('');
      final list = tester.widget<ListView>(
        find.byKey(ValueKey('tool-details-body:${activity.identity}')),
      );
      list.controller!.jumpTo(200);
      await tester.pumpAndSettle();
      await capture('-scrolled');
      await close(tester);
    }
  });

  testWidgets(
    'long logs scroll behind the floating header without a clipped viewport',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final command = List.generate(
        40,
        (i) => 'printf "line ${i + 1}\\n"',
      ).join('\n');
      final projection = ToolActivityProjection()
        ..reconcile([
          callEvent(1, args: {'command': command}),
          resultEvent(
            2,
            text: jsonEncode({'stdout': 'complete', 'exitCode': 0}),
          ),
        ]);
      final activity = projection.byAnchorSeq[1]!;
      await tester.pumpWidget(host(activity));
      await open(tester, activity);
      tester
          .widget<DraggableScrollableSheet>(
            find.byType(DraggableScrollableSheet),
          )
          .controller!
          .jumpTo(.96);
      await tester.pumpAndSettle();
      final listFinder = find.byKey(
        ValueKey('tool-details-body:${activity.identity}'),
      );
      final list = tester.widget<ListView>(listFinder);
      final header = find.byKey(const Key('tool-details-header'));
      final title = find.byKey(const Key('tool-details-title'));
      final closeButton = find.byKey(const Key('tool-details-close'));
      final commandText = foreground(
        find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == command,
        ),
      );
      final bounds = tester.getRect(sheet);
      expect(tester.getRect(listFinder), bounds);
      expect(tester.getCenter(title).dx, closeTo(bounds.center.dx, .01));
      final closeBounds = tester.getRect(closeButton);
      final paintedButton = tester.getRect(
        find.descendant(of: closeButton, matching: find.byType(IconButton)),
      );
      expect(paintedButton.width, closeTo(paintedButton.height, .01));
      final headerBounds = tester.getRect(header);
      list.controller!.jumpTo(
        tester.getTopLeft(commandText).dy - headerBounds.center.dy,
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(commandText).overlaps(headerBounds), isTrue);
      expect(tester.getRect(listFinder), bounds);
      expect(tester.getRect(header), headerBounds);
      expect(tester.getRect(closeButton), closeBounds);
      // The scrim and centered title do not steal scrolling from the log below.
      final before = list.controller!.offset;
      await tester.dragFrom(tester.getCenter(title), const Offset(0, -80));
      await tester.pumpAndSettle();
      expect(list.controller!.offset, greaterThan(before));
      expect(tester.getRect(header), headerBounds);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'detail entrance uses route motion and live updates do not replay it',
    (tester) async {
      final events = <Json>[callEvent(1)];
      final projection = ToolActivityProjection()..reconcile(events);
      final activity = projection.byAnchorSeq[1]!;
      final source = ValueNotifier<ToolActivity?>(activity);
      addTearDown(source.dispose);
      await tester.pumpWidget(host(activity, source: source));
      await tester.pumpAndSettle();
      await tapVisible(tester, row(activity));
      await tester.tap(find.byKey(ValueKey('tool-full:${activity.identity}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      final transition = find.ancestor(
        of: sheet,
        matching: find.byType(PocketBlurTransition),
      );
      expect(transition, findsOneWidget);
      expect(
        tester.widget<PocketBlurTransition>(transition).animation.value,
        inExclusiveRange(0, 1),
      );
      await tester.pumpAndSettle();
      events.add(resultEvent(2, text: 'new result after the entrance'));
      projection.reconcile(events);
      source.value = projection.byAnchorSeq[1]!;
      await tester.pump();
      expect(activeText('new result after the entrance'), findsOneWidget);
      expect(
        tester.widget<PocketBlurTransition>(transition).animation.value,
        1,
      );
      await close(tester);
    },
  );

  testWidgets(
    'compact row expands inline and live results preserve its command reader',
    (tester) async {
      final events = <Json>[callEvent(1)];
      final projection = ToolActivityProjection()..reconcile(events);
      final activity = projection.byAnchorSeq[1]!;
      await tester.pumpWidget(host(activity));
      final original = tester.getRect(row(activity));
      expect(original.height, inInclusiveRange(48, 56));
      expect(activeText('命令'), findsNothing);
      await tapVisible(tester, row(activity));
      expect(sheet, findsNothing);
      expect(activeText('命令'), findsOneWidget);
      expect(activeTextContaining('等待执行或授权结果'), findsOneWidget);
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
      expect(activeText('from the device'), findsOneWidget);
      expect(activeTextContaining('等待执行或授权结果'), findsNothing);
      await tapVisible(tester, row(activity));
      expect(tester.getRect(row(activity)), original);
      expect(activeText('命令'), findsNothing);
    },
  );

  testWidgets(
    'PTC child stays reachable and updates while its details are selected',
    (tester) async {
      final events = <Json>[callEvent(1, name: 'ptc'), dispatchEvent(2)];
      final projection = ToolActivityProjection()..reconcile(events);
      var root = projection.byAnchorSeq[1]!;
      await tester.pumpWidget(host(root));
      await open(tester, root);
      await tapVisible(tester, row(root.children.single));
      expect(activeText('路径'), findsOneWidget);
      events.add(dispatchEvent(3, end: true, text: 'updated child output'));
      projection.reconcile(events);
      root = projection.byAnchorSeq[1]!;
      await tester.pumpWidget(host(root));
      await tester.pumpAndSettle();
      expect(activeText('updated child output'), findsOneWidget);
      expect(activeText('已返回结果'), findsOneWidget);
      expect(sheet, findsOneWidget);
      await tester.tap(find.byTooltip('返回上级调用'));
      await tester.pumpAndSettle();
      expect(activeText('子调用 · 1'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets(
    'unknown tool exposes recorded text and lazy complete raw events',
    (tester) async {
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
      final activity = projection.byAnchorSeq[1]!;
      await tester.pumpWidget(host(activity));
      expect(activeText('完整原始详情'), findsNothing);
      await open(tester, activity);
      expect(activeText('keep raw output'), findsOneWidget);
      expect(activeTextContaining('keep raw argument'), findsNothing);
      await tapVisible(tester, activeText('完整原始详情'));
      expect(activeTextContaining('keep raw argument'), findsOneWidget);
      expect(activeTextContaining('privateShape'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets('result-only failure keeps missing facts and rejection visible', (
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
    final activity = projection.byAnchorSeq[1]!;
    await tester.pumpWidget(host(activity));
    expect(activeTextContaining('调用失败'), findsOneWidget);
    await open(tester, activity);
    expect(activeTextContaining('缺少调用开始记录'), findsOneWidget);
    expect(activeTextContaining('User rejected this tool'), findsOneWidget);
    expect(activeTextContaining('尚未收到工具结果'), findsNothing);
    await close(tester);
  });

  testWidgets(
    'command and output copy complete recorded values despite visual preview and runtime truncation',
    (tester) async {
      final stdout = '${'long output\n' * 600}TAIL_AFTER_PREVIEW';
      const command = 'printf "two lines\\n"\nprintf next';
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
            text: jsonEncode({
              'stdout': stdout,
              'stderr': 'err',
              'exitCode': 7,
              'truncated': true,
            }),
          ),
        ]);
      final activity = projection.byAnchorSeq[1]!;
      await tester.pumpWidget(host(activity));
      await open(tester, activity);
      await tapVisible(tester, copy('命令'));
      await tapVisible(tester, copy('stdout'));
      expect(copied, [command, stdout]);
      expect(activeTextContaining('TAIL_AFTER_PREVIEW'), findsNothing);
      expect(activeTextContaining('显示前 6000'), findsOneWidget);
      expect(activeTextContaining('运行时已截断输出'), findsOneWidget);
      await tapVisible(tester, activeText('显示完整内容'));
      expect(activeTextContaining('TAIL_AFTER_PREVIEW'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets('copy failure retains output and supports explicit retry', (
    tester,
  ) async {
    var attempts = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData' && attempts++ == 0) {
          throw PlatformException(code: 'clipboard_failed');
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
        callEvent(1),
        resultEvent(
          2,
          text: jsonEncode({'stdout': 'retained output', 'exitCode': 0}),
        ),
      ]);
    final activity = projection.byAnchorSeq[1]!;
    await tester.pumpWidget(host(activity));
    await open(tester, activity);
    await tapVisible(tester, copy('stdout'));
    expect(activeText('复制失败，请重试'), findsOneWidget);
    expect(activeText('retained output'), findsOneWidget);
    await tapVisible(tester, copy('stdout'));
    expect(attempts, 2);
    expect(activeText('已复制'), findsOneWidget);
    await close(tester);
  });

  testWidgets(
    'timeline source updates details after row removal and null closes it',
    (tester) async {
      final events = <Json>[callEvent(1)];
      final projection = ToolActivityProjection()..reconcile(events);
      final first = projection.byAnchorSeq[1]!;
      final source = ValueNotifier<ToolActivity?>(first);
      addTearDown(source.dispose);
      await tester.pumpWidget(host(first, source: source));
      await open(tester, first);
      await tester.pumpWidget(host(first, source: source, visible: false));
      await tester.pumpAndSettle();
      expect(sheet, findsOneWidget);
      events.add(
        resultEvent(
          2,
          text: jsonEncode({'stdout': 'after group collapsed', 'exitCode': 0}),
        ),
      );
      projection.reconcile(events);
      source.value = projection.byAnchorSeq[1]!;
      await tester.pumpAndSettle();
      expect(activeText('after group collapsed'), findsOneWidget);
      source.value = null;
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'removing a row without a timeline source closes its stale details',
    (tester) async {
      final projection = ToolActivityProjection()..reconcile([callEvent(1)]);
      final activity = projection.byAnchorSeq[1]!;
      await tester.pumpWidget(host(activity));
      await open(tester, activity);
      await tester.pumpWidget(host(activity, visible: false));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'drag handle expands then dismisses the panel and outside/back also dismiss',
    (tester) async {
      final projection = ToolActivityProjection()..reconcile([callEvent(1)]);
      final activity = projection.byAnchorSeq[1]!;
      await tester.pumpWidget(host(activity));
      await open(tester, activity);
      final before = tester.getRect(sheet);
      await tester.drag(
        find.byKey(const Key('tool-details-drag-handle')),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(sheet).height, greaterThan(before.height));
      await tester.drag(
        find.byKey(const Key('tool-details-drag-handle')),
        const Offset(0, 600),
      );
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      await open(tester, activity);
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      await open(tester, activity);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      '320 dp large text and reduced motion remain usable in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final projection = ToolActivityProjection()
          ..reconcile([
            callEvent(1, args: {'command': 'echo ${'long-word-' * 20}'}),
          ]);
        final activity = projection.byAnchorSeq[1]!;
        await tester.pumpWidget(
          host(
            activity,
            reduceMotion: true,
            textScale: 1.5,
            brightness: brightness,
          ),
        );
        await open(tester, activity);
        expect(sheet, findsOneWidget);
        expect(tester.getRect(sheet).bottom, closeTo(700, .1));
        expect(tester.getRect(copy('命令')).right, lessThanOrEqualTo(320));
        expect(tester.takeException(), isNull);
        await close(tester);
      },
    );
  }

  testWidgets(
    'late clipboard completion after dismissal cannot mutate another panel',
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
      final projection = ToolActivityProjection()..reconcile([callEvent(1)]);
      final activity = projection.byAnchorSeq[1]!;
      await tester.pumpWidget(host(activity));
      await open(tester, activity);
      await tester.tap(copy('命令'));
      await tester.pump();
      await close(tester);
      completion.complete();
      await tester.pumpAndSettle();
      await open(tester, activity);
      expect(activeText('已复制'), findsNothing);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );
}
