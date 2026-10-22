import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_android/chat_changes.dart';
import 'package:dsh_android/session_document.dart';
import 'package:dsh_android/ui.dart';
import 'package:dsh_android/workspace_changes.dart';
import 'package:dsh_android/workspace_diff.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'workspace_changes_fixtures.dart';

Widget changesApp(Widget child, {double scale = 1}) => MaterialApp(
  theme: pocketTheme(Brightness.dark),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: true, textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: child,
);

void main() {
  testWidgets(
    'card waits for real summary and hides disabled, missing and empty records',
    (tester) async {
      final runtime = ChangesRuntime();
      final reply = Completer<dynamic>();
      runtime.handler = (_, _) => reply.future;
      final controller = WorkspaceChangesController(
        runtime: runtime,
        sessionId: 'bound',
      );
      addTearDown(() {
        controller.dispose();
        runtime.dispose();
      });
      await controller.initialize();
      final change = ChatChangesTurn(
        event: changeEvent(9, 'turn/end', 1),
        turn: 1,
        announcementSeq: 8,
      );
      Widget card(bool enabled) => changesApp(
        PocketScaffold(
          title: const Text('会话'),
          body: PocketList(
            children: [
              ChatChangesCard(
                controller: controller,
                change: change,
                enabled: enabled,
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(card(false));
      expect(runtime.reads('workspaceChanges.summary'), isEmpty);
      await tester.pumpWidget(card(true));
      expect(find.text('src/example.dart'), findsNothing);
      expect(find.text('example.dart'), findsNothing);
      reply.complete(accepted(changeSummary()));
      await tester.pumpAndSettle();
      expect(find.text('example.dart'), findsOneWidget);
      expect(find.text('+10'), findsOneWidget);
      await tester.pumpWidget(card(false));
      expect(find.text('example.dart'), findsNothing);
      runtime.handler = (_, _) async => unavailable();
      runtime.reconnect();
      await tester.pumpAndSettle();
      await tester.pumpWidget(card(true));
      await tester.pumpAndSettle();
      expect(find.byType(PocketTile), findsNothing);
      runtime.handler = (_, _) async => accepted(changeSummary(files: []));
      runtime.reconnect();
      await tester.pumpAndSettle();
      expect(find.byType(PocketTile), findsNothing);
    },
  );

  testWidgets(
    'card folds after four rows and reports totals omitted by Host cap',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final runtime = ChangesRuntime()
        ..handler = (_, _) async => accepted(
          changeSummary(
            files: List.generate(5, (i) => changedFile('file-$i.txt')),
            total: 8,
          ),
        );
      final controller = WorkspaceChangesController(
        runtime: runtime,
        sessionId: 'bound',
      );
      addTearDown(() {
        controller.dispose();
        runtime.dispose();
      });
      await controller.initialize();
      await tester.pumpWidget(
        changesApp(
          PocketScaffold(
            title: const Text('会话'),
            body: PocketList(
              children: [
                ChatChangesCard(
                  controller: controller,
                  enabled: true,
                  change: ChatChangesTurn(
                    event: changeEvent(9, 'turn/end', 1),
                    turn: 1,
                    announcementSeq: 8,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('8 个文件已更改'), findsOneWidget);
      expect(find.text('file-4.txt'), findsNothing);
      expect(find.text('显示 5 个文件，共 8 个；行数包含全部改动。'), findsOneWidget);
      await tester.tap(find.text('查看全部 5 个文件'));
      await tester.pumpAndSettle();
      expect(find.text('file-4.txt'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native diff renders source numbering, created/coarse notice and supports wrap',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final raw = textDiff(
        lines: [' 原文', '-old', '+${'中文 very_long_identifier ' * 18}', ' '],
        coarse: true,
      )..['before'] = false;
      final diff = WorkspaceFileDiff.parse(raw)!;
      final vertical = ScrollController(), horizontal = ScrollController();
      addTearDown(vertical.dispose);
      addTearDown(horizontal.dispose);
      Future<void> show(bool wrap) async {
        await tester.pumpWidget(
          changesApp(
            PocketScaffold(
              title: const Text('差异'),
              body: WorkspaceDiffBody(
                state: WorkspaceRead(WorkspaceReadPhase.ready, diff),
                retry: () {},
                wrap: wrap,
                controller: vertical,
                horizontalController: horizontal,
              ),
            ),
            scale: 1.8,
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(true);
      expect(find.text('本轮新建的文件'), findsOneWidget);
      expect(find.text('逐行对比超时，按整个文件替换显示'), findsOneWidget);
      expect(find.text('8'), findsOneWidget);
      expect(find.text('14'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await show(false);
      expect(horizontal.position.maxScrollExtent, greaterThan(100));
      expect(tester.takeException(), isNull);
    },
  );

  for (final entry in <(WorkspaceRead<WorkspaceFileDiff>, String)>[
    (const WorkspaceRead(WorkspaceReadPhase.missing), '这轮改动的内容已不可用'),
    (const WorkspaceRead(WorkspaceReadPhase.error), '无法读取改动'),
    (const WorkspaceRead(WorkspaceReadPhase.waiting), '等待服务连接'),
    (const WorkspaceRead(WorkspaceReadPhase.loading), '正在读取改动…'),
    (
      const WorkspaceRead(
        WorkspaceReadPhase.ready,
        WorkspaceFileDiff(
          kind: WorkspaceDiffKind.binary,
          path: 'a',
          display: 'a',
        ),
      ),
      '二进制文件，无法显示改动',
    ),
    (
      const WorkspaceRead(
        WorkspaceReadPhase.ready,
        WorkspaceFileDiff(
          kind: WorkspaceDiffKind.oversized,
          path: 'a',
          display: 'a',
        ),
      ),
      '文件过大，无法显示改动',
    ),
    (
      const WorkspaceRead(
        WorkspaceReadPhase.ready,
        WorkspaceFileDiff(
          kind: WorkspaceDiffKind.text,
          path: 'a',
          display: 'a',
          after: false,
        ),
      ),
      '本轮删除的文件',
    ),
    (
      const WorkspaceRead(
        WorkspaceReadPhase.ready,
        WorkspaceFileDiff(
          kind: WorkspaceDiffKind.text,
          path: 'a',
          display: 'a',
        ),
      ),
      '两侧内容相同',
    ),
  ]) {
    testWidgets('diff state ${entry.$2}', (tester) async {
      var retried = 0;
      await tester.pumpWidget(
        changesApp(
          PocketScaffold(
            title: const Text('差异'),
            body: WorkspaceDiffBody(state: entry.$1, retry: () => retried++),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(entry.$2), findsOneWidget);
      if (entry.$1.phase == WorkspaceReadPhase.error) {
        await tester.tap(find.text('重试'));
        expect(retried, 1);
      } else {
        expect(find.text('重试'), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'review retries exact snapshot coordinates then selects original index',
    (tester) async {
      final runtime = ChangesRuntime();
      var attempt = 0;
      runtime.handler = (method, args) async {
        if (method == 'workspaceChanges.summary') {
          return accepted(
            changeSummary(
              files: [changedFile('z.dart'), changedFile('a.dart')],
            ),
          );
        }
        if (attempt++ == 0) {
          return {
            'ok': false,
            'error': {'code': 'workspace-changes/read-failed'},
          };
        }
        return accepted(
          textDiff(path: args['index'] == 0 ? 'z.dart' : 'a.dart'),
        );
      };
      final controller = WorkspaceChangesController(
        runtime: runtime,
        sessionId: 'bound',
      );
      addTearDown(() {
        controller.dispose();
        runtime.dispose();
      });
      await controller.initialize();
      await tester.pumpWidget(
        changesApp(WorkspaceDiffPage(controller: controller, seq: 8, turn: 1)),
      );
      await tester.pumpAndSettle();
      expect(find.text('无法读取改动'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('before'), findsOneWidget);
      await tester.tap(find.text('z.dart'));
      await tester.pumpAndSettle();
      expect(find.text('更改的文件'), findsOneWidget);
      await tester.tap(find.text('a.dart'));
      await tester.pumpAndSettle();
      expect(runtime.reads('workspaceChanges.diff').last.$2['index'], 1);
      expect(runtime.reads('workspaceChanges.diff').last.$2['seq'], 8);
      expect(
        runtime.reads('workspaceChanges.diff').last.$2['sessionId'],
        'bound',
      );
      expect(
        runtime.calls.where(
          (call) =>
              call.$1.contains('readBytes') || call.$1.contains('files.read'),
        ),
        isEmpty,
      );
      runtime.handler = (_, _) async => unavailable();
      runtime.reconnect();
      await tester.pumpAndSettle();
      await tester.pump();
      expect(
        controller.enabled,
        isTrue,
        reason:
            '${runtime.calls.map((call) => call.$1).join(', ')} / ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join(' | ')}',
      );
      expect(controller.summary(8).value.phase, WorkspaceReadPhase.missing);
      expect(find.text('这轮改动的内容已不可用'), findsOneWidget);
      expect(find.text('before'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disposing page cancels pending diff and suppresses late reply', (
    tester,
  ) async {
    final runtime = ChangesRuntime();
    final pending = Completer<dynamic>();
    runtime.handler = (method, args) => method == 'workspaceChanges.summary'
        ? Future.value(accepted(changeSummary()))
        : pending.future;
    final controller = WorkspaceChangesController(
      runtime: runtime,
      sessionId: 'bound',
    );
    addTearDown(() {
      controller.dispose();
      runtime.dispose();
    });
    await controller.initialize();
    await tester.pumpWidget(
      changesApp(WorkspaceDiffPage(controller: controller, seq: 8, turn: 1)),
    );
    await tester.pumpAndSettle();
    expect(find.text('正在读取改动…'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(runtime.reads('workspaceChanges.cancel'), hasLength(1));
    pending.complete(accepted(textDiff()));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(controller.diff(8, 0).value.phase, WorkspaceReadPhase.idle);
  });

  testWidgets(
    'Host setting disables an already cached card without local override',
    (tester) async {
      final runtime = ChangesRuntime();
      final controller = WorkspaceChangesController(
        runtime: runtime,
        sessionId: 'bound',
      );
      addTearDown(() {
        controller.dispose();
        runtime.dispose();
      });
      await controller.initialize();
      await tester.pumpWidget(
        changesApp(
          PocketScaffold(
            title: const Text('会话'),
            body: PocketList(
              children: [
                ListenableBuilder(
                  listenable: controller,
                  builder: (_, _) => ChatChangesCard(
                    controller: controller,
                    enabled: controller.enabled,
                    change: ChatChangesTurn(
                      event: changeEvent(9, 'turn/end', 1),
                      turn: 1,
                      announcementSeq: 8,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('example.dart'), findsOneWidget);
      runtime.settingsChanged(false);
      await tester.pumpAndSettle();
      expect(find.text('example.dart'), findsNothing);
      expect(controller.summary(8).value.value, isNotNull);
      runtime.settingsChanged(true);
      await tester.pumpAndSettle();
      expect(find.text('example.dart'), findsOneWidget);
      expect(runtime.reads('workspaceChanges.summary'), hasLength(1));
    },
  );

  testWidgets(
    'retired Session controller invalidates an open detail and rejects later readers',
    (tester) async {
      final runtime = ChangesRuntime();
      final controller = WorkspaceChangesController(
        runtime: runtime,
        sessionId: 'bound',
      );
      addTearDown(runtime.dispose);
      await controller.initialize();
      await tester.pumpWidget(
        changesApp(WorkspaceDiffPage(controller: controller, seq: 8, turn: 1)),
      );
      await tester.pumpAndSettle();
      expect(find.text('before'), findsOneWidget);
      controller.dispose();
      await tester.pumpAndSettle();
      expect(find.text('会话已离开，无法继续读取改动'), findsOneWidget);
      expect(find.text('before'), findsNothing);
      final reads = runtime.reads('workspaceChanges.diff').length;
      await tester.pumpWidget(
        changesApp(
          WorkspaceDiffPage(
            key: const Key('new-reader'),
            controller: controller,
            seq: 8,
            turn: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('会话已离开，无法继续读取改动'), findsOneWidget);
      expect(runtime.reads('workspaceChanges.diff'), hasLength(reads));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('current-file action opens original reader in the same Session', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final runtime = ChangesRuntime();
    final controller = WorkspaceChangesController(
      runtime: runtime,
      sessionId: 'bound',
    );
    addTearDown(() {
      controller.dispose();
      runtime.dispose();
    });
    try {
      await controller.initialize();
      await tester.pumpWidget(
        changesApp(WorkspaceDiffPage(controller: controller, seq: 8, turn: 1)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('差异选项'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开当前文件'));
      await tester.pumpAndSettle();
      final reader = tester.widget<SessionDocumentPage>(
        find.byType(SessionDocumentPage),
      );
      expect(reader.sessionId, 'bound');
      expect(reader.path, 'src/example.dart');
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    '412-wide review keeps floating header and source rows readable',
    (tester) async {
      const capture = bool.fromEnvironment('WORKSPACE_DIFF_CAPTURE');
      tester.view.physicalSize = const Size(412, 892);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (capture) {
        await tester.runAsync(() async {
          for (final entry in {
            'ScreenshotFont': r'C:\Windows\Fonts\msyh.ttc',
            'monospace': r'C:\Windows\Fonts\consola.ttf',
            'MaterialIcons': '../../.cache/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          }.entries) {
            await (FontLoader(entry.key)..addFont(
                  File(entry.value).readAsBytes().then(ByteData.sublistView),
                ))
                .load();
          }
        });
      }
      final runtime = ChangesRuntime()
        ..handler = (method, args) async => accepted(
          method == 'workspaceChanges.summary'
              ? changeSummary(
                  files: [
                    changedFile('src/settings.dart', added: 3, deleted: 2),
                    changedFile('test/settings_test.dart'),
                  ],
                )
              : textDiff(
                  path: 'src/settings.dart',
                  oldLines: 5,
                  newLines: 6,
                  lines: [
                    ' final options = Settings(',
                    '-  enabled: false,',
                    '+  enabled: true,',
                    '+  persistSession: true,',
                    ' );',
                    ' ',
                    '-await store.clear();',
                    '+await store.save(options);',
                  ],
                ),
        );
      final controller = WorkspaceChangesController(
        runtime: runtime,
        sessionId: 'bound',
      );
      addTearDown(() {
        controller.dispose();
        runtime.dispose();
      });
      await controller.initialize();
      final paint = GlobalKey();
      final base = pocketTheme(Brightness.dark);
      await tester.pumpWidget(
        RepaintBoundary(
          key: paint,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: capture
                ? base.copyWith(
                    textTheme: base.textTheme.apply(
                      fontFamily: 'ScreenshotFont',
                    ),
                  )
                : base,
            builder: (_, child) => MediaQuery(
              data: const MediaQueryData(
                size: Size(412, 892),
                padding: EdgeInsets.only(top: 28, bottom: 24),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: WorkspaceDiffPage(controller: controller, seq: 8, turn: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('src/settings.dart'), findsOneWidget);
      expect(find.text('  persistSession: true,'), findsOneWidget);
      expect(tester.getRect(find.byType(ListView).first).top, 0);
      expect(tester.getRect(find.text('第 1 轮改动')).top, greaterThan(28));
      expect(tester.takeException(), isNull);
      if (capture) {
        await tester.runAsync(() async {
          final boundary =
              paint.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final picture = await boundary.toImage(pixelRatio: 2);
          try {
            final png = await picture.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File('../../.cache/android/workspace-diff-412.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(png!.buffer.asUint8List());
          } finally {
            picture.dispose();
          }
        });
      }
    },
  );
}
