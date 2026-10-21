import 'dart:async';

import 'package:dsh_android/appearance.dart';
import 'package:dsh_android/main.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _ReadyRuntime extends RuntimeController {
  _ReadyRuntime() {
    phase = 'ready';
  }

  final openedSessions = <String>[];
  final libraryStreams = <StreamController<Json>>[];

  @override
  Future<void> openSession(String id) async => openedSessions.add(id);

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method != 'library.catalog') {
      throw StateError('Unexpected fixture call $method');
    }
    return {
      'workspaces': <Json>[],
      'sessions': [
        for (final row in sessions)
          {
            'sessionId': row['header']['id'],
            'updatedAt': 1,
            'running': false,
            'blank': false,
            'cwd': '/fixture',
            'projections': {
              'values': {'title': row['title'] ?? row['header']['title']},
            },
          },
      ],
      'archivedSessionIds': <String>[],
      'pinnedSessionIds': <String>[],
      'defaultDirectory': '/fixture',
    };
  }

  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) {
    if ((namespace, method) != ('workspace', 'follow') &&
        (namespace, method) != ('session', 'control')) {
      throw StateError('Unexpected fixture stream $namespace.$method');
    }
    late final StreamController<Json> stream;
    stream = StreamController<Json>(
      onListen: () => scheduleMicrotask(() {
        if (stream.isClosed) return;
        stream.add({
          'type': 'item',
          'value': {'type': 'baseline'},
        });
      }),
    );
    libraryStreams.add(stream);
    return stream.stream;
  }

  Future<void> disposeFixture() async {
    dispose();
    await Future.wait(libraryStreams.map((stream) => stream.close()));
  }
}

class _ConversationRuntime extends _ReadyRuntime {
  @override
  String newSession() {
    final id = super.newSession();
    timelines[id] = List.generate(
      20,
      (index) => _message(index, '历史回复 $index'),
    );
    return id;
  }

  void appendReply(String text) {
    final timeline = timelines.values.first;
    timeline.add(_message(timeline.length, text));
    notifyListeners();
  }
}

class _PendingRuntime extends _ReadyRuntime {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> send(String id, String text) async {
    entered.complete();
    await release.future;
  }
}

Json _message(int seq, String text) => {
  'seq': seq,
  'time': seq * 1000,
  'type': 'assistant/message',
  'surfaceOp': 'append',
  'data': {
    'turn': seq + 1,
    'step': 1,
    'message': {
      'id': 'fixture-assistant-$seq',
      'role': 'assistant',
      'source': {
        'kind': 'model',
        'provider': 'fixture-provider',
        'model': 'fixture-model',
      },
      'content': [
        {'type': 'text', 'text': text},
      ],
    },
    'stream': <Json>[],
  },
};

Widget _host(Widget child, {double scale = 1}) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: true, textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: child,
);

void _phone(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
}

void main() {
  testWidgets(
    'drawer search stays usable with a phone keyboard and enlarged text',
    (tester) async {
      _phone(tester, const Size(360, 800));
      final runtime = _ReadyRuntime();
      addTearDown(runtime.disposeFixture);
      await tester.pumpWidget(_host(ChatPage(runtime: runtime), scale: 1.3));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('打开侧栏'));
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('sidebar-search'));
      expect(search, findsNothing);
      await tester.tap(find.byTooltip('搜索对话'));
      await tester.pumpAndSettle();
      await tester.tap(search);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      await tester.enterText(search, '文件');
      expect(tester.takeException(), isNull);
      expect(tester.getRect(search).bottom, lessThanOrEqualTo(480));
      expect(search.hitTestable(), findsOneWidget);
      expect(find.text('文件'), findsOneWidget);
      expect(find.byTooltip('关闭搜索').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('关闭搜索'));
      await tester.pumpAndSettle();
      expect(search, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('system 200 percent text keeps the theme preview readable', (
    tester,
  ) async {
    _phone(tester, const Size(390, 844));
    final appearance = AppearanceController();
    addTearDown(appearance.dispose);
    await tester.pumpWidget(
      AppearanceScope(
        controller: appearance,
        child: _host(const AppearancePage(), scale: 2),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('按住右上按钮，拖动试试'), findsOneWidget);
  });

  testWidgets(
    'a multiline composer stays above the keyboard and leaves send reachable',
    (tester) async {
      _phone(tester, const Size(360, 800));
      final runtime = _ReadyRuntime();
      addTearDown(runtime.disposeFixture);
      await tester.pumpWidget(_host(ChatPage(runtime: runtime), scale: 1.3));
      await tester.pumpAndSettle();
      final composer = find.widgetWithText(TextField, '交给 Pocket Harness');
      await tester.enterText(composer, '第一行\n第二行\n第三行\n第四行\n第五行\n第六行');
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(composer).bottom, lessThanOrEqualTo(480));
      final send = find.byTooltip('发送');
      expect(send.hitTestable(), findsOneWidget);
      expect(tester.getRect(send).bottom, lessThanOrEqualTo(480));
    },
  );

  testWidgets('new conversations isolate drafts and returning restores them', (
    tester,
  ) async {
    _phone(tester, const Size(390, 844));
    final runtime = _ReadyRuntime();
    addTearDown(runtime.disposeFixture);
    await tester.pumpWidget(_host(ChatPage(runtime: runtime)));
    await tester.pumpAndSettle();
    final originalId = runtime.timelines.keys.single;
    runtime.sessions = [
      {
        'header': {'id': originalId, 'title': '原对话'},
      },
    ];
    final composer = find.widgetWithText(TextField, '交给 Pocket Harness');
    await tester.enterText(composer, '仅属于原对话的未发送草稿');
    await tester.tap(find.byTooltip('新对话'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
    await tester.enterText(composer, '新对话的草稿');
    await tester.tap(find.byTooltip('打开侧栏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('原对话'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(composer).controller!.text, '仅属于原对话的未发送草稿');
    expect(runtime.openedSessions, [originalId]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new replies follow the reader who is already at the bottom', (
    tester,
  ) async {
    _phone(tester, const Size(390, 844));
    final runtime = _ConversationRuntime();
    addTearDown(runtime.disposeFixture);
    await tester.pumpWidget(_host(ChatPage(runtime: runtime)));
    await tester.pumpAndSettle();
    final list = find.byType(ListView);
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)).first,
    );
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    runtime.appendReply('这条新回复应跟随已在底部的阅读位置。');
    await tester.pumpAndSettle();
    expect(
      scrollable.position.maxScrollExtent - scrollable.position.pixels,
      lessThanOrEqualTo(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an old admission cannot clear an identical draft in a new conversation',
    (tester) async {
      _phone(tester, const Size(390, 844));
      final runtime = _PendingRuntime();
      addTearDown(runtime.disposeFixture);
      await tester.pumpWidget(_host(ChatPage(runtime: runtime)));
      await tester.pumpAndSettle();
      final composer = find.widgetWithText(TextField, '交给 Pocket Harness');
      await tester.enterText(composer, '两个对话中相同的文字');
      await tester.tap(find.byTooltip('发送'));
      await runtime.entered.future;
      await tester.tap(find.byTooltip('新对话'));
      await tester.pumpAndSettle();
      await tester.enterText(composer, '两个对话中相同的文字');
      runtime.release.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(composer).controller!.text, '两个对话中相同的文字');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('new replies do not pull a reader away from older messages', (
    tester,
  ) async {
    _phone(tester, const Size(390, 844));
    final runtime = _ConversationRuntime();
    addTearDown(runtime.disposeFixture);
    await tester.pumpWidget(_host(ChatPage(runtime: runtime)));
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    final readingPosition = scrollable.position.pixels;
    expect(
      scrollable.position.maxScrollExtent - readingPosition,
      greaterThan(200),
    );
    runtime.appendReply('读者在查看旧消息时，不应自动跳走。');
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, closeTo(readingPosition, 1));
    expect(tester.takeException(), isNull);
  });
}
