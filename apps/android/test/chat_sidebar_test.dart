import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/account_state.dart';
import 'package:dsh_android/chat_sidebar.dart';
import 'package:dsh_android/flclash/popup.dart';
import 'package:dsh_android/library.dart';
import 'package:dsh_android/session_search.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'library_test.dart' show LibraryRuntime, settle, summary;

class SidebarAccountRuntime extends LibraryRuntime {
  SidebarAccountRuntime() {
    observedAccount.addListener(notifyListeners);
  }
  late final observedAccount = AccountState(
    this,
    {},
    avatarFetch: (_) async => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
    ),
  );
  @override
  AccountState get accountSnapshot => observedAccount;
  @override
  void dispose() {
    observedAccount.removeListener(notifyListeners);
    observedAccount.dispose();
    super.dispose();
  }
}

class SidebarHarness {
  SidebarHarness(this.runtime);
  final LibraryRuntime runtime;
  final scaffold = GlobalKey<ScaffoldState>();
  final selected = <String>[];
  int closes = 0, newChats = 0, tasks = 0, automations = 0;

  Widget host({
    double scale = 1,
    bool reduceMotion = true,
    Size size = const Size(390, 844),
    EdgeInsets safe = EdgeInsets.zero,
    double keyboard = 0,
    TextDirection direction = TextDirection.ltr,
    Brightness brightness = Brightness.light,
    String? fontFamily,
    bool glass = false,
    String currentSessionId = 's2',
  }) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: pocketTheme(brightness).copyWith(
      textTheme: pocketTheme(brightness).textTheme
          .apply(fontFamily: fontFamily),
    ),
    builder: (_, child) => MediaQuery(
      data: MediaQueryData(
        size: size,
        padding: safe,
        viewPadding: safe,
        viewInsets: EdgeInsets.only(bottom: keyboard),
        textScaler: TextScaler.linear(scale),
        disableAnimations: reduceMotion,
      ),
      child: Directionality(
        textDirection: direction,
        child: LiquidGlassScope(
          enabled: glass,
          child: LiquidGlassHost(enabled: glass, child: child!),
        ),
      ),
    ),
    home: Scaffold(
      key: scaffold,
      body: const Text('聊天主页'),
      drawer: ChatSidebar(
        runtime: runtime,
        currentSessionId: currentSessionId,
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
  Size size = const Size(390, 844),
  EdgeInsets safe = EdgeInsets.zero,
  double keyboard = 0,
  TextDirection direction = TextDirection.ltr,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final harness = SidebarHarness(runtime ?? LibraryRuntime());
  addTearDown(harness.runtime.dispose);
  await tester.pumpWidget(
    harness.host(
      scale: scale,
      reduceMotion: reduceMotion,
      size: size,
      safe: safe,
      keyboard: keyboard,
      direction: direction,
    ),
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
  await Scrollable.ensureVisible(tester.element(row), alignment: .5);
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
  testWidgets('floating chrome overlays the full scrolling library viewport', (
    tester,
  ) async {
    final harness = await setup(tester);
    final runtime = harness.runtime;
    expect(find.text('Pocket Harness'), findsOneWidget);
    expect(key('sidebar-search'), findsNothing);
    expect(find.text('新对话'), findsNothing);
    expect(find.byTooltip('新对话'), findsOneWidget);
    expect(find.text('自动化任务'), findsNothing);
    expect(find.text('工作区'), findsOneWidget);
    expect(find.text('已归档任务'), findsNothing);
    expect(find.text('子 Agent 会话'), findsNothing);
    expect(find.text('已同步'), findsNothing);
    expect(runtime.library.synchronized, isTrue);
    expect(runtime.watches, hasLength(2));

    final footer = tester.getRect(key('sidebar-footer'));
    final header = tester.getRect(key('sidebar-header'));
    final viewport = tester.getRect(key('sidebar-scroll'));
    expect(viewport.contains(header.center), isTrue);
    expect(viewport.contains(footer.center), isTrue);
    expect(viewport.top, 0);
    expect(viewport.bottom, 844);
    expect(
      tester.getCenter(key('sidebar-settings')).dx,
      lessThan(tester.getCenter(key('sidebar-account')).dx),
    );
    final settings = tester.getRect(key('sidebar-settings'));
    final newChat = tester.getRect(key('sidebar-new-chat'));
    expect(newChat.left, greaterThan(settings.right));
    expect(newChat.left - settings.right, lessThanOrEqualTo(12));
    expect(newChat.center.dy, closeTo(settings.center.dy, .1));
    expect(newChat.width, closeTo(newChat.height, .1));
    expect(newChat.width, lessThanOrEqualTo(48));
    expect(footer.contains(newChat.center), isTrue);
    expect(find.text('账号'), findsNothing);
    expect(find.byTooltip('账号'), findsOneWidget);
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
    expect(find.text('设置'), findsOneWidget);
    expect(runtime.calls.any((call) => call.$1 == 'session.read'), isFalse);
    await dispose(tester);
  });

  testWidgets(
    'more reveals destinations inline in sequence without a menu route',
    (tester) async {
      final harness = await setup(tester, reduceMotion: false);
      final anchor = tester.getRect(key('sidebar-more'));
      final footer = tester.getRect(key('sidebar-footer'));
      await tester.tap(key('sidebar-more'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final first = tester.widget<SizeTransition>(key('sidebar-more-reveal:0'));
      final last = tester.widget<SizeTransition>(key('sidebar-more-reveal:5'));
      expect(first.sizeFactor.value, greaterThan(0));
      expect(first.sizeFactor.value, lessThan(1));
      expect(last.sizeFactor.value, 0);
      expect(find.byType(CommonPopupMenu), findsNothing);
      expect(tester.getRect(key('sidebar-more')), anchor);
      final blur = tester.widget<ImageFiltered>(
        find
            .descendant(
              of: key('sidebar-more-reveal:0'),
              matching: find.byType(ImageFiltered),
            )
            .first,
      );
      expect(blur.enabled, isTrue);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(key('sidebar-more-files')).top,
        closeTo(anchor.bottom, .1),
      );
      expect(tester.getRect(key('sidebar-footer')), footer);
      expect(harness.closes, 0);
      expect(find.text('我的文件'), findsOneWidget);
      await tester.tap(key('sidebar-more'));
      await tester.pumpAndSettle();
      expect(key('sidebar-more-files'), findsNothing);
      expect(tester.getRect(key('sidebar-more')), anchor);
      await tester.tap(key('sidebar-more'));
      await tester.pumpAndSettle();
      await tester.tap(key('sidebar-more-automations'));
      await tester.pumpAndSettle();
      expect(harness.automations, 1);
      expect(harness.closes, 1);
      await dispose(tester);
    },
  );

  testWidgets('session menu follows the pressed point and stays on screen', (
    tester,
  ) async {
    final harness = await setup(tester);
    final row = key('sidebar-session:s2');
    await Scrollable.ensureVisible(tester.element(row), alignment: .5);
    await tester.pumpAndSettle();
    final bounds = tester.getRect(row);
    final leftPoint = Offset(bounds.left + 24, bounds.center.dy);
    final rightPoint = Offset(bounds.right - 24, bounds.center.dy);

    Future<Rect> openAt(Offset point) async {
      await tester.longPressAt(point);
      await tester.pumpAndSettle();
      final popup = tester.getRect(find.byType(CommonPopupMenu));
      expect(popup.left, greaterThanOrEqualTo(16));
      expect(popup.right, lessThanOrEqualTo(374));
      expect(popup.top, greaterThanOrEqualTo(16));
      expect(popup.bottom, lessThanOrEqualTo(828));
      Navigator.of(tester.element(find.byType(CommonPopupMenu))).pop();
      await tester.pumpAndSettle();
      return popup;
    }

    final left = await openAt(leftPoint);
    final right = await openAt(rightPoint);
    expect(right.left, greaterThan(left.left + 24));
    expect(harness.runtime.sent('sessionPin'), isEmpty);
    expect(harness.selected, isEmpty);
    await dispose(tester);
  });

  testWidgets(
    'account entry observes the shared avatar without a name or watch',
    (tester) async {
      final runtime = SidebarAccountRuntime();
      await setup(tester, runtime: runtime);
      final accountEntry = key('sidebar-account');
      expect(
        find.descendant(of: accountEntry, matching: find.byType(Image)),
        findsNothing,
      );
      runtime.observedAccount
        ..view = {'status': 'credential-stored'}
        ..profile = {
          'status': 'ready',
          'value': {
            'name': 'Test Account',
            'avatarUrl': 'https://example.test/avatar.png',
          },
        }
        ..avatar.setUrl('https://example.test/avatar.png');
      runtime.notifyListeners();
      await tester.pumpAndSettle();
      final image = tester.widget<Image>(
        find.descendant(of: accountEntry, matching: find.byType(Image)),
      );
      expect(
        ((image.image as ResizeImage).imageProvider as MemoryImage).bytes,
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
        ),
      );
      expect(find.text('Test Account'), findsNothing);
      expect(runtime.watches.where((entry) => entry.$1 == 'account'), isEmpty);
      runtime.observedAccount.view = {'status': 'signed-out'};
      runtime.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: accountEntry, matching: find.byType(Image)),
        findsNothing,
      );
      expect(find.byTooltip('账号'), findsOneWidget);
      await dispose(tester);
    },
  );

  testWidgets('long lists continue behind both floating controls', (
    tester,
  ) async {
    final runtime = LibraryRuntime();
    (runtime.catalog['sessions'] as List).addAll([
      for (var index = 0; index < 35; index++)
        summary('long$index', '会话 $index'),
    ]);
    await setup(tester, runtime: runtime);
    final scrollable = find.descendant(
      of: key('sidebar-scroll'),
      matching: find.byType(Scrollable),
    );
    final row = key('sidebar-session:long5');
    await tester.scrollUntilVisible(row, 250, scrollable: scrollable);
    await tester.pumpAndSettle();
    final position = tester.state<ScrollableState>(scrollable).position;
    final header = tester.getRect(key('sidebar-header'));
    position.jumpTo(
      position.pixels + tester.getCenter(row).dy - header.center.dy,
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(row).overlaps(header), isTrue);
    final footer = tester.getRect(key('sidebar-footer'));
    position.jumpTo(
      position.pixels + tester.getCenter(row).dy - footer.center.dy,
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(row).overlaps(footer), isTrue);
    expect(tester.getRect(key('sidebar-header')), header);
    expect(tester.getRect(key('sidebar-footer')), footer);
    expect(tester.takeException(), isNull);
    await dispose(tester);
  });

  testWidgets('narrow RTL layout keeps floating controls above the keyboard', (
    tester,
  ) async {
    await setup(
      tester,
      size: const Size(320, 740),
      scale: 1.6,
      safe: const EdgeInsets.only(top: 30, bottom: 24),
      keyboard: 280,
      direction: TextDirection.rtl,
    );
    final header = tester.getRect(key('sidebar-header'));
    final footer = tester.getRect(key('sidebar-footer'));
    expect(header.top, greaterThanOrEqualTo(30));
    expect(footer.bottom, lessThanOrEqualTo(740 - 280));
    expect(
      tester.getCenter(key('sidebar-settings')).dx,
      greaterThan(tester.getCenter(key('sidebar-account')).dx),
    );
    await tester.tap(key('sidebar-search-toggle'));
    await tester.pumpAndSettle();
    final search = tester.getRect(key('sidebar-search'));
    expect(search.top, greaterThan(header.bottom));
    expect(search.bottom, lessThan(footer.top));
    expect(tester.takeException(), isNull);
    await dispose(tester);
  });

  testWidgets('menu opens below a high press and above a low press', (
    tester,
  ) async {
    final runtime = LibraryRuntime();
    (runtime.catalog['sessions'] as List).addAll([
      for (var index = 0; index < 30; index++)
        summary('edge$index', '会话 $index'),
    ]);
    await setup(
      tester,
      runtime: runtime,
      safe: const EdgeInsets.only(top: 26, bottom: 24),
    );
    final row = key('sidebar-session:edge8');
    final scrollable = find.descendant(
      of: key('sidebar-scroll'),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(row, 250, scrollable: scrollable);
    await tester.pumpAndSettle();
    final position = tester.state<ScrollableState>(scrollable).position;
    final high = tester.getRect(key('sidebar-header')).bottom + 32;
    final low = tester.getRect(key('sidebar-footer')).top - 32;
    for (final target in [high, low]) {
      position.jumpTo(position.pixels + tester.getCenter(row).dy - target);
      await tester.pumpAndSettle();
      final bounds = tester.getRect(row);
      await tester.longPressAt(Offset(bounds.right - 24, target));
      await tester.pumpAndSettle();
      final popup = tester.getRect(find.byType(CommonPopupMenu));
      expect(popup.top, greaterThanOrEqualTo(42));
      expect(popup.bottom, lessThanOrEqualTo(804));
      if (target == high) {
        expect(popup.top, greaterThan(target));
      } else {
        expect(popup.bottom, lessThan(target));
      }
      Navigator.of(tester.element(find.byType(CommonPopupMenu))).pop();
      await tester.pumpAndSettle();
    }
    expect(runtime.sent('sessionPin'), isEmpty);
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
    'content search keeps the query and opens the selected real session',
    (tester) async {
      final runtime = LibraryRuntime();
      runtime.handlers['api.call'] = (params) async {
        expect(params, {
          'namespace': 'session',
          'method': 'search',
          'args': {
            'request': {'query': '正文标记'},
          },
        });
        return {
          'items': [
            {'sessionId': 's1', 'snippet': '包含正文标记的原始回复'},
          ],
          'hasMore': false,
        };
      };
      final harness = await setup(tester, runtime: runtime);
      await tester.tap(key('sidebar-search-toggle'));
      await tester.pumpAndSettle();
      await tester.enterText(key('sidebar-search'), '正文标记');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.byType(SessionSearchPage), findsOneWidget);
      expect(
        tester.widget<TextField>(key('session-search-input')).controller!.text,
        '正文标记',
      );
      await tester.tap(key('session-search-result:s1'));
      await tester.pumpAndSettle();
      expect(harness.selected, ['s1']);
      expect(harness.closes, 1);
      expect(runtime.calls.where((call) => call.$1 == 'session.send'), isEmpty);
      await dispose(tester);
    },
  );

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
    expect(key('sidebar-message'), findsNothing);
    expect(find.text('查看详情'), findsNothing);
    expect(harness.closes, 0);
    expect(
      harness.runtime.calls.any((call) => call.$1 == 'session.cancel'),
      isFalse,
    );
    await dispose(tester);
  });

  testWidgets(
    'archive keeps its row until confirmation, then fades before collapse',
    (tester) async {
      final runtime = LibraryRuntime();
      final receipt = Completer<dynamic>();
      runtime.handlers['library.sessionArchive'] = (_) => receipt.future;
      await setup(tester, runtime: runtime, reduceMotion: false);
      await menu(tester, 's2');
      await tester.tap(
        find.descendant(
          of: find.byType(CommonPopupMenu),
          matching: find.text('归档'),
        ),
      );
      await tester.pumpAndSettle();
      final before = tester.getRect(key('sidebar-session:s2'));
      final neighbor = tester.getRect(key('sidebar-session:s3'));
      expect(key('sidebar-message'), findsNothing);
      expect(runtime.sent('sessionArchive'), hasLength(1));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getRect(key('sidebar-session:s2')), before);
      final refresh = Completer<dynamic>();
      runtime.handlers['library.catalog'] = (_) => refresh.future;
      (runtime.catalog['archivedSessionIds'] as List).add('s2');
      receipt.complete({
        'archivedSessionIds': runtime.catalog['archivedSessionIds'],
      });
      await tester.pump();
      // Flush the receipt continuation, then mount the exit ticker before
      // advancing its clock. The follow-up catalog is deliberately unresolved.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 64));
      final fade = tester.widget<FadeTransition>(
        find
            .descendant(
              of: key('sidebar-presence:s2'),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      expect(fade.opacity.value, greaterThan(0));
      expect(fade.opacity.value, lessThan(1));
      expect(tester.getRect(key('sidebar-session:s2')), before);
      expect(tester.getRect(key('sidebar-session:s3')), neighbor);
      await tester.pump(const Duration(milliseconds: 140));
      expect(
        tester.getRect(key('sidebar-presence:s2')).height,
        lessThan(before.height),
      );
      await tester.pumpAndSettle();
      expect(key('sidebar-session:s2'), findsNothing);
      expect(key('sidebar-message'), findsNothing);
      expect(find.text('查看详情'), findsNothing);
      expect(
        tester.getRect(key('sidebar-session:s3')).top,
        lessThan(neighbor.top),
      );
      expect(runtime.library.loading, isTrue);
      refresh.complete(runtime.catalog);
      await tester.pumpAndSettle();
      expect(key('sidebar-session:s2'), findsNothing);
      await dispose(tester);
    },
  );

  testWidgets('rejected archive retains the session and its failure feedback', (
    tester,
  ) async {
    final runtime = LibraryRuntime();
    runtime.handlers['library.sessionArchive'] = (_) async =>
        throw PlatformException(code: 'session/conflict');
    final harness = await setup(tester, runtime: runtime);
    await menu(tester, 's2');
    await choose(tester, '归档');
    expect(key('sidebar-session:s2'), findsOneWidget);
    expect(runtime.library.archivedSessionIds, isNot(contains('s2')));
    expect(runtime.library.actions['archive:s2']?.state, 'rejected');
    expect(find.textContaining('session/conflict'), findsOneWidget);
    expect(harness.closes, 0);
    await dispose(tester);
  });

  testWidgets(
    'archive completion belongs to its original row after current chat changes',
    (tester) async {
      final runtime = LibraryRuntime();
      final receipt = Completer<dynamic>();
      runtime.handlers['library.sessionArchive'] = (_) => receipt.future;
      final harness = await setup(
        tester,
        runtime: runtime,
        reduceMotion: false,
      );
      await menu(tester, 's2');
      await tester.tap(
        find.descendant(
          of: find.byType(CommonPopupMenu),
          matching: find.text('归档'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        harness.host(reduceMotion: false, currentSessionId: 's3'),
      );
      await tester.pumpAndSettle();
      expect(key('sidebar-session:s2'), findsOneWidget);
      (runtime.catalog['archivedSessionIds'] as List).add('s2');
      receipt.complete({
        'archivedSessionIds': runtime.catalog['archivedSessionIds'],
      });
      await tester.pumpAndSettle();
      expect(key('sidebar-session:s2'), findsNothing);
      expect(key('sidebar-session:s3'), findsOneWidget);
      final selected = tester.widget<Semantics>(
        find
            .descendant(
              of: key('sidebar-session:s3'),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(selected.properties.selected, true);
      expect(harness.closes, 0);
      expect(harness.selected, isEmpty);
      await dispose(tester);
    },
  );

  testWidgets(
    'confirmed archive stays removed through stale reads and permits a later restore',
    (tester) async {
      final runtime = LibraryRuntime();
      runtime.handlers['library.sessionArchive'] = (_) async => {
        'archivedSessionIds': ['a1', 's2'],
      };
      await setup(tester, runtime: runtime);
      await menu(tester, 's2');
      await choose(tester, '归档');
      expect(key('sidebar-session:s2'), findsNothing);
      await runtime.library.refresh();
      await tester.pumpAndSettle();
      expect(key('sidebar-session:s2'), findsNothing);
      (runtime.catalog['archivedSessionIds'] as List).add('s2');
      await runtime.library.refresh();
      await tester.pumpAndSettle();
      expect(key('sidebar-session:s2'), findsNothing);
      (runtime.catalog['archivedSessionIds'] as List).remove('s2');
      await runtime.library.refresh();
      await tester.pumpAndSettle();
      expect(key('sidebar-session:s2'), findsOneWidget);
      expect(key('sidebar-message'), findsNothing);
      await dispose(tester);
    },
  );

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
