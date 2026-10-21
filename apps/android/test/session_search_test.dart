import 'package:dsh_android/session_search.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/session_search_runtime.dart';
import 'support/settings_layout_capture.dart';

final capture = SettingsLayoutCapture();

Future<void> openSearch(
  WidgetTester tester,
  SessionSearchTestRuntime runtime, {
  String initialQuery = '',
  Brightness brightness = Brightness.light,
  double scale = 1,
  double width = 420,
  ValueChanged<String?>? onSelection,
}) async {
  tester.view.physicalSize = Size(width, 960);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  await tester.runAsync(loadSettingsCaptureFonts);
  Widget page() =>
      SessionSearchPage(runtime: runtime, initialQuery: initialQuery);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(brightness),
      builder: (context, child) => capture.wrap(context, child, scale: scale),
      home: onSelection == null
          ? page()
          : Builder(
              builder: (context) => PocketScaffold(
                title: const Text('测试入口'),
                body: PocketList(
                  children: [
                    PocketButton(
                      onPressed: () async {
                        final result = await Navigator.push<String>(
                          context,
                          PocketRoute<String>(builder: (_) => page()),
                        );
                        onSelection(result);
                      },
                      child: const Text('打开搜索'),
                    ),
                  ],
                ),
              ),
            ),
    ),
  );
  if (onSelection != null) await tester.tap(find.text('打开搜索'));
  await tester.pumpAndSettle();
}

Future<void> submit(WidgetTester tester, String query) async {
  await tester.enterText(
    find.byKey(const ValueKey('session-search-input')),
    query,
  );
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'submitted initial query searches once and subsequent typing remains local',
    (tester) async {
      final runtime = SessionSearchTestRuntime();
      await openSearch(tester, runtime, initialQuery: '之前的关键词');
      expect(find.text('没有找到相关对话'), findsOneWidget);
      expect(runtime.calls.length, 2);
      await tester.enterText(find.byType(TextField), '新的关键词');
      await tester.pumpAndSettle();
      expect(runtime.calls.length, 2);
      await tester.tap(find.byKey(const ValueKey('session-search-submit')));
      await tester.pumpAndSettle();
      expect(find.text('没有找到相关对话'), findsOneWidget);
      expect(runtime.calls.length, 4);
      runtime.changeConnection();
      await tester.pumpAndSettle();
      expect(runtime.calls.length, 4);
    },
  );

  testWidgets('empty initial query does not access the search service', (
    tester,
  ) async {
    final runtime = SessionSearchTestRuntime();
    await openSearch(tester, runtime);
    expect(find.text('从一句话开始查找'), findsOneWidget);
    expect(runtime.calls, isEmpty);
  });

  testWidgets(
    'submit key dismisses keyboard and returns selected catalog session only',
    (tester) async {
      final runtime = SessionSearchTestRuntime()
        ..response = sessionSearchResponse('这里执行过 Shell');
      String? selected;
      await openSearch(
        tester,
        runtime,
        onSelection: (value) => selected = value,
      );
      await submit(tester, 'Shell');
      expect(tester.testTextInput.isVisible, isFalse);
      expect(find.text('手机里的本地助手'), findsOneWidget);
      expect(find.text('这里执行过 Shell'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('session-search-result:first')),
      );
      await tester.pumpAndSettle();
      expect(selected, 'first');
      expect(runtime.calls.length, 2);
      expect(find.text('测试入口'), findsOneWidget);
    },
  );

  testWidgets('unknown match shows its ID and explanation without opening', (
    tester,
  ) async {
    final runtime = SessionSearchTestRuntime()
      ..response = sessionSearchResponse('子 Agent 里面的内容', id: 'child-17');
    await openSearch(tester, runtime);
    await submit(tester, '内容');
    expect(find.text('child-17'), findsOneWidget);
    expect(find.text('会话信息未读取'), findsOneWidget);
    expect(find.text('该会话未在当前会话目录中，暂不能从这里打开'), findsOneWidget);
    final row = tester.widget<PocketTile>(
      find.byKey(const ValueKey('session-search-result:child-17')),
    );
    expect(row.onTap, isNull);
  });

  testWidgets('archived result keeps a visible label and can be selected', (
    tester,
  ) async {
    final runtime = SessionSearchTestRuntime()
      ..response = sessionSearchResponse('归档后仍能查找', id: 'archived');
    String? selected;
    await openSearch(tester, runtime, onSelection: (value) => selected = value);
    await submit(tester, '查找');
    expect(find.text('已归档'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('session-search-result:archived')),
    );
    await tester.pumpAndSettle();
    expect(selected, 'archived');
  });

  testWidgets(
    'more matches asks for narrower query rather than offering pagination',
    (tester) async {
      final runtime = SessionSearchTestRuntime()
        ..response = sessionSearchResponse('匹配内容', more: true);
      await openSearch(tester, runtime);
      await submit(tester, '内容');
      expect(find.text('最多显示 20 个会话。还有更多匹配，请缩小搜索范围。'), findsOneWidget);
      expect(find.text('加载更多'), findsNothing);
      expect(find.text('下一页'), findsNothing);
    },
  );

  testWidgets(
    'new query and reconnection retire rows until an explicit new search',
    (tester) async {
      final runtime = SessionSearchTestRuntime()
        ..response = sessionSearchResponse('旧摘要');
      await openSearch(tester, runtime);
      await submit(tester, '旧');
      runtime.changeConnection();
      await tester.pumpAndSettle();
      expect(find.text('旧摘要'), findsNothing);
      expect(find.text('连接已恢复，请重新搜索'), findsOneWidget);
      expect(runtime.calls.length, 2);
      await tester.tap(find.text('重新搜索'));
      await tester.pumpAndSettle();
      expect(find.text('旧摘要'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '新');
      await tester.pumpAndSettle();
      expect(find.text('旧摘要'), findsNothing);
      expect(runtime.calls.length, 4);
    },
  );

  testWidgets(
    'clear and blank-space taps release or restore input intentionally',
    (tester) async {
      final runtime = SessionSearchTestRuntime();
      await openSearch(tester, runtime);
      await tester.enterText(find.byType(TextField), '草稿');
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tapAt(const Offset(100, 850));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(find.byTooltip('清空搜索'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(tester.testTextInput.isVisible, isTrue);
      expect(runtime.calls, isEmpty);
    },
  );

  testWidgets(
    'invalid long query is visible and disabled, not silently truncated',
    (tester) async {
      final runtime = SessionSearchTestRuntime();
      await openSearch(tester, runtime);
      final query = '😀' * 251;
      await tester.enterText(find.byType(TextField), query);
      await tester.pumpAndSettle();
      expect(find.text('搜索内容过长，请缩短至 500 个字符以内'), findsOneWidget);
      expect(
        tester
            .widget<GlassButton>(
              find.byKey(const ValueKey('session-search-submit')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        query,
      );
      expect(runtime.calls, isEmpty);
    },
  );

  testWidgets(
    'closing the page ignores outstanding search and catalog receipts',
    (tester) async {
      final runtime = SessionSearchTestRuntime()..deferSearch = true;
      String? selected;
      await openSearch(
        tester,
        runtime,
        onSelection: (value) => selected = value,
      );
      await submit(tester, '未完成');
      expect(find.text('正在查找对话'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      runtime.pending.single.complete(sessionSearchResponse('来晚了'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      expect(find.text('来晚了'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'read timeout remains retryable and late response stays invisible',
    (tester) async {
      final runtime = SessionSearchTestRuntime()..deferSearch = true;
      await openSearch(tester, runtime);
      await submit(tester, '查询');
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect(find.text('搜索用时较长，请稍后重试或缩短搜索内容'), findsOneWidget);
      runtime.pending.single.complete(sessionSearchResponse('超时回执'));
      await tester.pumpAndSettle();
      expect(find.text('超时回执'), findsNothing);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.8]) {
      testWidgets('long result layout ${brightness.name} $scale', (
        tester,
      ) async {
        final runtime = SessionSearchTestRuntime()
          ..response = {
            'items': [
              {
                'sessionId': 'first',
                'snippet': '我们讨论过如何在手机上读取授权的文件，执行普通 Shell，并在离开应用后继续后台任务。搜索只读取已有对话内容，不会启动新的模型请求。',
              },
              {'sessionId': 'archived', 'snippet': '尝试在锁屏后等待任务完成，回来查看执行结果。'},
            ],
            'hasMore': true,
          };
        runtime.catalog['sessions'][0]['projections']['values']['title'] =
            '手机本地 Agent 的文件读取与后台任务执行测试记录';
        await openSearch(tester, runtime, brightness: brightness, scale: scale);
        await submit(tester, '后台任务');
        expect(tester.takeException(), isNull);
        await capture.save(tester, 'session-search-${brightness.name}-$scale');
        await tester.ensureVisible(find.text('已归档'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('narrow page and visible keyboard keep search reachable', (
    tester,
  ) async {
    final runtime = SessionSearchTestRuntime();
    await openSearch(tester, runtime, width: 320, scale: 1.8);
    tester.view.viewInsets = const FakeViewPadding(bottom: 340);
    addTearDown(tester.view.resetViewInsets);
    await tester.enterText(find.byType(TextField), '内容');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('session-search-submit')).hitTestable(),
      findsOneWidget,
    );
    await capture.save(tester, 'session-search-keyboard-narrow');
  });
}
