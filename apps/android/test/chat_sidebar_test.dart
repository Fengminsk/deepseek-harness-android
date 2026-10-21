import 'dart:async';

import 'package:dsh_android/chat_sidebar.dart';
import 'package:dsh_android/flclash/popup.dart';
import 'package:dsh_android/library.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'library_test.dart' show LibraryRuntime, settle, summary;

class SidebarHarness {
  SidebarHarness(this.runtime);
  final LibraryRuntime runtime;
  final scaffold = GlobalKey<ScaffoldState>();
  final selected = <String>[];
  int closes = 0, newChats = 0, tasks = 0, automations = 0;

  Widget host({double scale = 1, bool reduceMotion = true}) => MaterialApp(
    theme: pocketTheme(Brightness.light),
    builder: (_, child) => MediaQuery(
      data: MediaQueryData(
        size: const Size(390, 844),
        textScaler: TextScaler.linear(scale),
        disableAnimations: reduceMotion,
      ),
      child: child!,
    ),
    home: Scaffold(
      key: scaffold,
      body: const Text('聊天主页'),
      drawer: ChatSidebar(
        runtime: runtime,
        currentSessionId: 's2',
        onClose: () {
          closes++;
          scaffold.currentState!.closeDrawer();
        },
        onNewChat: () => newChats++,
        onSelectSession: selected.add,
        onOpenTasks: () => tasks++,
        onOpenAutomations: () => automations++,
      ),
    ),
  );

  Future<void> open(WidgetTester tester) async {
    scaffold.currentState!.openDrawer();
    await settle(tester);
  }
}

Finder key(String value) => find.byKey(ValueKey(value));

Future<SidebarHarness> setup(
  WidgetTester tester, {
  LibraryRuntime? runtime,
  double scale = 1,
  bool reduceMotion = true,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final harness = SidebarHarness(runtime ?? LibraryRuntime());
  addTearDown(harness.runtime.dispose);
  await tester.pumpWidget(
    harness.host(scale: scale, reduceMotion: reduceMotion),
  );
  await harness.open(tester);
  return harness;
}

Future<void> menu(WidgetTester tester, String id) async {
  final row = key('sidebar-session:$id');
  await tester.scrollUntilVisible(
    row,
    200,
    scrollable: find.descendant(
      of: key('sidebar-scroll'),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.longPress(row);
  await tester.pumpAndSettle();
  expect(find.byType(CommonPopupMenu), findsOneWidget);
}

Future<void> choose(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byType(CommonPopupMenu),
      matching: find.text(label),
    ),
  );
  await settle(tester);
}

Future<void> dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('compact destinations and fixed footer retain library groups', (
    tester,
  ) async {
    final harness = await setup(tester);
    final runtime = harness.runtime;
    expect(find.text('Pocket Harness'), findsOneWidget);
    expect(key('sidebar-search'), findsNothing);
    expect(find.text('新对话'), findsOneWidget);
    expect(find.text('自动化任务'), findsNothing);
    expect(find.text('工作区'), findsOneWidget);
    expect(find.text('已归档任务'), findsNothing);
    expect(find.text('子 Agent 会话'), findsNothing);
    expect(find.text('已同步'), findsNothing);
    expect(runtime.library.synchronized, isTrue);
    expect(runtime.watches, hasLength(2));

    final footer = tester.getRect(key('sidebar-footer'));
    final reads = runtime.reads;
    for (var i = 0; i < 10; i++) {
      runtime.notifyListeners();
      await tester.pump();
    }
    expect(runtime.reads, reads);
    expect(runtime.watches, hasLength(2));
    await tester.drag(key('sidebar-scroll'), const Offset(0, -450));
    await tester.pumpAndSettle();
    expect(tester.getRect(key('sidebar-footer')), footer);
    expect(find.byTooltip('设置'), findsOneWidget);
    expect(runtime.calls.any((call) => call.$1 == 'session.read'), isFalse);
    await dispose(tester);
  });

  testWidgets('search appears on demand and closing it restores all sessions', (
    tester,
  ) async {
    await setup(tester);
    await tester.tap(key('sidebar-search-toggle'));
    await tester.pumpAndSettle();
    await tester.enterText(key('sidebar-search'), '第二');
    await tester.pumpAndSettle();
    expect(key('sidebar-session:s2'), findsOneWidget);
    expect(key('sidebar-session:s1'), findsNothing);
    expect(key('sidebar-workspace:w1'), findsNothing);
    await tester.tap(key('sidebar-search-toggle'));
    await tester.pumpAndSettle();
    expect(key('sidebar-search'), findsNothing);
    expect(key('sidebar-workspace:w1'), findsOneWidget);
    await dispose(tester);
  });

  testWidgets(
    'session selection closes only the drawer and emits its real id',
    (tester) async {
      final harness = await setup(tester);
      await tester.scrollUntilVisible(
        key('sidebar-session:s2'),
        250,
        scrollable: find.descendant(
          of: key('sidebar-scroll'),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(key('sidebar-session:s2'));
      await tester.pumpAndSettle();
      expect(harness.selected, ['s2']);
      expect(harness.closes, 1);
      expect(find.text('聊天主页'), findsOneWidget);
      expect(harness.runtime.sent('sessionPin'), isEmpty);
      expect(harness.runtime.sent('sessionArchive'), isEmpty);
      await harness.open(tester);
      await tester.tap(key('sidebar-new-chat'));
      await tester.pumpAndSettle();
      expect(harness.newChats, 1);
      expect(harness.closes, 2);
      await dispose(tester);
    },
  );

  testWidgets(
    'long press opens FlClash menu, haptics and dismissal do not mutate',
    (tester) async {
      var haptics = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') haptics++;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final harness = await setup(tester, reduceMotion: false);
      await menu(tester, 's1');
      for (final label in ['取消置顶', '重命名', '归档', '查看详情', '导出']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(haptics, greaterThan(0));
      expect(harness.selected, isEmpty);
      final navigator = Navigator.of(
        tester.element(find.byType(CommonPopupMenu)),
      );
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.byType(CommonPopupMenu), findsNothing);
      expect(harness.runtime.sent('sessionPin'), isEmpty);
      expect(harness.runtime.sent('sessionArchive'), isEmpty);
      expect(harness.closes, 0);
      await dispose(tester);
    },
  );

  testWidgets('pin uses the original mutation and confirms in the sidebar', (
    tester,
  ) async {
    final harness = await setup(tester);
    await menu(tester, 's2');
    await choose(tester, '置顶');
    expect(harness.runtime.sent('sessionPin').single.$2, {
      'sessionId': 's2',
      'pinned': true,
    });
    expect(harness.runtime.library.pinnedSessionIds, contains('s2'));
    expect(harness.closes, 0);
    await tester.scrollUntilVisible(
      key('sidebar-message'),
      -250,
      scrollable: find.descendant(
        of: key('sidebar-scroll'),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('已置顶对话。'), findsOneWidget);
    await dispose(tester);
  });

  testWidgets('rename goes straight to the original draft preserving editor', (
    tester,
  ) async {
    final harness = await setup(tester);
    await menu(tester, 's1');
    await choose(tester, '重命名');
    expect(find.byType(LibraryRenamePage), findsOneWidget);
    expect(find.byType(LibrarySessionPage), findsNothing);
    expect(
      tester.widget<TextField>(key('library-title')).controller!.text,
      '原始标题',
    );
    expect(harness.closes, 1);
    expect(harness.runtime.sent('sessionRename'), isEmpty);
    await dispose(tester);
  });

  testWidgets('idle archive confirms without requesting task cancellation', (
    tester,
  ) async {
    final harness = await setup(tester);
    await menu(tester, 's2');
    await choose(tester, '归档');
    expect(harness.runtime.sent('sessionArchive').single.$2, {
      'sessionId': 's2',
      'archived': true,
      'stopActivity': false,
    });
    expect(harness.runtime.library.archivedSessionIds, contains('s2'));
    expect(key('sidebar-session:s2'), findsNothing);
    expect(harness.closes, 0);
    expect(
      harness.runtime.calls.any((call) => call.$1 == 'session.cancel'),
      isFalse,
    );
    await dispose(tester);
  });

  testWidgets(
    'active archive opens original confirmation and never auto stops',
    (tester) async {
      final runtime = LibraryRuntime();
      runtime.handlers['library.sessionArchive'] = (_) async =>
          throw PlatformException(
            code: 'workspace/session-active',
            details: {
              'activity': [
                {
                  'kind': 'job',
                  'items': ['job1'],
                },
              ],
            },
          );
      final harness = await setup(tester, runtime: runtime);
      await menu(tester, 's2');
      await choose(tester, '归档');
      expect(find.byType(LibrarySessionPage), findsOneWidget);
      expect(runtime.sent('sessionArchive'), hasLength(1));
      expect(runtime.sent('sessionArchive').single.$2['stopActivity'], false);
      expect(runtime.library.actions['archive:s2']?.state, 'needs-stop');
      expect(harness.closes, 1);
      expect(runtime.calls.any((call) => call.$1 == 'session.cancel'), isFalse);
      await dispose(tester);
    },
  );

  testWidgets(
    'unknown receipt survives drawer reopening and is never replayed',
    (tester) async {
      final runtime = LibraryRuntime();
      runtime.handlers['library.sessionPin'] = (_) async =>
          throw TimeoutException('reply lost');
      final harness = await setup(tester, runtime: runtime);
      await menu(tester, 's2');
      await choose(tester, '置顶');
      expect(runtime.library.actions['pin:s2']?.state, 'unconfirmed');
      harness.scaffold.currentState!.closeDrawer();
      await tester.pumpAndSettle();
      await harness.open(tester);
      await menu(tester, 's2');
      final popup = tester.widget<CommonPopupMenu>(
        find.byType(CommonPopupMenu),
      );
      expect(
        popup.items.firstWhere((item) => item.label == '置顶').onPressed,
        isNull,
      );
      expect(runtime.sent('sessionPin'), hasLength(1));
      Navigator.of(tester.element(find.byType(CommonPopupMenu))).pop();
      await tester.pumpAndSettle();
      await dispose(tester);
    },
  );

  testWidgets(
    'unsynced recent snapshot stays readable without invented writes',
    (tester) async {
      final runtime = LibraryRuntime()
        ..sessions = [
          {
            'header': {'id': 'fallback'},
            'title': '缓存中的对话',
          },
        ];
      runtime.handlers['library.catalog'] = (_) async =>
          throw StateError('offline');
      await setup(tester, runtime: runtime);
      expect(find.text('缓存中的对话'), findsOneWidget);
      expect(runtime.library.synchronized, isFalse);
      await menu(tester, 'fallback');
      final popup = tester.widget<CommonPopupMenu>(
        find.byType(CommonPopupMenu),
      );
      for (final label in ['置顶', '重命名', '归档']) {
        expect(
          popup.items.firstWhere((item) => item.label == label).onPressed,
          isNull,
        );
      }
      expect(
        popup.items.firstWhere((item) => item.label == '导出').onPressed,
        isNotNull,
      );
      expect(runtime.sent('sessionPin'), isEmpty);
      await dispose(tester);
    },
  );

  testWidgets(
    'workspace navigation can select a session after drawer unmounts',
    (tester) async {
      final harness = await setup(tester);
      await tester.tap(key('sidebar-workspace:w1'));
      await tester.pumpAndSettle();
      expect(find.byType(LibraryWorkspacePage), findsOneWidget);
      Navigator.of(tester.element(find.byType(LibraryWorkspacePage))).pop('s2');
      await tester.pumpAndSettle();
      expect(harness.selected, ['s2']);
      expect(harness.closes, 1);
      expect(find.text('聊天主页'), findsOneWidget);
      await dispose(tester);
    },
  );

  testWidgets(
    'large text keeps footer reachable and menu within phone viewport',
    (tester) async {
      final runtime = LibraryRuntime();
      (runtime.catalog['sessions'] as List).add(
        summary('long', '这是较长的会话标题，用来检查大字体下的换行和长按菜单'),
      );
      await setup(tester, runtime: runtime, scale: 2);
      expect(tester.takeException(), isNull);
      final footer = tester.getRect(key('sidebar-footer'));
      expect(footer.bottom, lessThanOrEqualTo(844));
      await menu(tester, 'long');
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byType(CommonPopupMenu)).right,
        lessThanOrEqualTo(390),
      );
      await dispose(tester);
    },
  );
}
