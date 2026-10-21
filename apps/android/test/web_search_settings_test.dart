import 'package:dsh_android/configuration_editor.dart';
import 'package:dsh_android/ui.dart';
import 'package:dsh_android/web_search_settings.dart';
import 'package:dsh_android/web_search_settings_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/settings_layout_capture.dart';
import 'support/web_search_runtime.dart';

final capture = SettingsLayoutCapture();

Future<void> openPage(
  WidgetTester tester,
  WebSearchTestRuntime runtime, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool nested = false,
}) async {
  tester.view.physicalSize = const Size(420, 960);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  await tester.runAsync(loadSettingsCaptureFonts);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(brightness),
      builder: (context, child) => capture.wrap(context, child, scale: scale),
      home: nested
          ? Builder(
              builder: (context) => PocketScaffold(
                title: const Text('测试入口'),
                body: PocketButton(
                  onPressed: () => Navigator.push<void>(
                    context,
                    PocketRoute(
                      builder: (_) => WebSearchSettingsPage(runtime: runtime),
                    ),
                  ),
                  child: const Text('打开搜索'),
                ),
              ),
            )
          : WebSearchSettingsPage(runtime: runtime),
    ),
  );
  if (nested) await tester.tap(find.text('打开搜索'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'main page uses compact rows and stages field edits before explicit save',
    (tester) async {
      final runtime = WebSearchTestRuntime();
      await openPage(tester, runtime);
      expect(find.byType(TextField), findsNothing);
      expect(
        tester
            .widget<GlassButton>(find.byKey(const ValueKey('web-search-save')))
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.byKey(const ValueKey('web-field:web-search-deepseek:baseURL')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('web-field-input')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('web-field-input')),
        'https://proxy.example/anthropic/v1',
      );
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(find.text('未保存'), findsOneWidget);
      expect(runtime.writes, isEmpty);
      await tester.tap(find.byTooltip('保存网页搜索设置'));
      await tester.pumpAndSettle();
      expect(
        runtime.values[webSearchNamespace]!['baseURL'],
        'https://proxy.example/anthropic/v1',
      );
      expect(runtime.writes.single.args['ns'], webSearchNamespace);
    },
  );

  testWidgets(
    'mode selection is finite and switches both routes without asking for a key',
    (tester) async {
      final runtime = WebSearchTestRuntime();
      await openPage(tester, runtime);
      await tester.tap(find.byKey(const ValueKey('web-search-mode')));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byKey(const ValueKey('web-mode-api')));
      await tester.pumpAndSettle();
      expect(find.text('每次搜索结果数'), findsOneWidget);
      expect(find.text('向搜索服务发送原始问题'), findsOneWidget);
      expect(runtime.writes, isEmpty);
      await tester.tap(find.byTooltip('保存网页搜索设置'));
      await tester.pumpAndSettle();
      expect(runtime.values[webRoutingNamespace], {
        'searchProvider': 'deepseek-search-api',
        'fetchProvider': 'deepseek-fetch-api',
      });
      expect(
        runtime.writes.any((call) => call.method.startsWith('credentials.')),
        false,
      );
    },
  );

  testWidgets(
    'custom pair remains visible and unchanged until choosing a mode',
    (tester) async {
      final runtime = WebSearchTestRuntime();
      runtime.values[webRoutingNamespace] = {
        'searchProvider': 'my-search',
        'fetchProvider': 'my-fetch',
      };
      await openPage(tester, runtime);
      expect(find.text('自定义组合'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('web-search-mode')));
      await tester.pumpAndSettle();
      expect(find.text('my-search'), findsOneWidget);
      expect(find.text('my-fetch'), findsOneWidget);
      expect(runtime.writes, isEmpty);
    },
  );

  testWidgets('credential input is hidden and not written until page save', (
    tester,
  ) async {
    final runtime = WebSearchTestRuntime();
    await openPage(tester, runtime);
    await tester.tap(find.byKey(const ValueKey('web-key:web-search-deepseek')));
    await tester.pumpAndSettle();
    final keyField = find.byKey(const ValueKey('web-key-input'));
    expect(tester.widget<TextField>(keyField).obscureText, true);
    await tester.enterText(keyField, 'local-test-secret');
    await tester.tap(find.byTooltip('完成编辑'));
    await tester.pumpAndSettle();
    expect(find.text('local-test-secret'), findsNothing);
    expect(find.text('已填写，待保存'), findsOneWidget);
    expect(runtime.writes, isEmpty);
    await tester.tap(find.byTooltip('保存网页搜索设置'));
    await tester.pumpAndSettle();
    expect(runtime.writes.single.args, {
      'ref': 'MESSAGES_KEY',
      'value': 'local-test-secret',
    });
  });

  testWidgets('back navigation explicitly guards a staged mode change', (
    tester,
  ) async {
    final runtime = WebSearchTestRuntime();
    await openPage(tester, runtime, nested: true);
    await tester.tap(find.byKey(const ValueKey('web-search-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('web-mode-api')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('保留当前编辑？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('未保存'), findsOneWidget);
    expect(runtime.writes, isEmpty);
  });

  testWidgets(
    'advanced original configuration remains available only outside staged edits',
    (tester) async {
      final runtime = WebSearchTestRuntime();
      await openPage(tester, runtime);
      await tester.tap(find.text('更多设置'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('web-search-advanced')),
        280,
      );
      await tester.tap(find.byKey(const ValueKey('web-search-advanced')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索与读取方式'));
      await tester.pumpAndSettle();
      expect(find.byType(ConfigPage), findsOneWidget);
      expect(runtime.writes, isEmpty);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('web-search-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('web-mode-api')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('更多设置'));
      await tester.tap(find.text('更多设置'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('web-search-advanced')),
        280,
      );
      expect(find.text('先保存或处理当前草稿与未确认操作'), findsOneWidget);
      final row = tester.widget<PocketRow>(
        find.byKey(const ValueKey('web-search-advanced')),
      );
      expect(row.onTap, isNull);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.8]) {
      testWidgets('search settings and choices ${brightness.name} $scale fit', (
        tester,
      ) async {
        final runtime = WebSearchTestRuntime();
        await openPage(tester, runtime, brightness: brightness, scale: scale);
        expect(tester.takeException(), isNull);
        await capture.save(tester, 'web-search-${brightness.name}-$scale');
        await tester.tap(find.byKey(const ValueKey('web-search-mode')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture.save(
          tester,
          'web-search-choices-${brightness.name}-$scale',
        );
        await tester.tap(find.byKey(const ValueKey('web-mode-api')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture.save(tester, 'web-search-api-${brightness.name}-$scale');
      });
    }
  }
}
