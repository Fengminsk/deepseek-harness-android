import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:dsh_android/account.dart';
import 'package:dsh_android/account_state.dart';
import 'package:dsh_android/configuration_model_destination.dart';
import 'package:dsh_android/models.dart';
import 'package:dsh_android/models_provider.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';

class DestinationRuntime extends RuntimeController {
  DestinationRuntime() {
    phase = 'ready';
  }
  bool failRead = false, serveDefault = true;
  int catalogReads = 0, revision = 1;
  String catalogModel = 'first';

  @override
  Future<AccountState> ensureAccount({String locale = 'zh-CN'}) async =>
      throw const FormatException('Synthetic account initialization failure');

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (failRead) throw StateError('Synthetic directory unavailable');
    if (method == 'settings.describe') {
      return [
        if (serveDefault)
          {
            'ns': 'agent-default-model',
            'revision': revision,
            'value': {'provider': 'deepseek', 'model': catalogModel},
            'user': {'provider': 'deepseek', 'model': catalogModel},
            'base': {},
            'schema': {},
            'secrets': [],
          },
        {
          'ns': 'llm-deepseek',
          'revision': revision,
          'value': {'baseURL': 'https://example.test'},
          'user': {},
          'base': {},
          'schema': {
            'type': 'object',
            'dict': {
              'baseURL': {'type': 'string'},
            },
          },
          'secrets': [],
        },
      ];
    }
    if (method == 'api.call') {
      switch (params['method']) {
        case 'listProviders':
          return [
            {'id': 'deepseek', 'name': '测试提供方'},
          ];
        case 'listConfigurableProviders':
          return [
            {
              'provider': 'deepseek',
              'displayName': '测试提供方',
              'settingsNs': 'llm-deepseek',
              'settingsPath': <String>[],
            },
          ];
        case 'modelCatalog':
          catalogReads++;
          return {
            'default': {'provider': 'deepseek', 'model': catalogModel},
            'groups': [
              {
                'id': 'deepseek',
                'name': '测试提供方',
                'models': [
                  {'id': catalogModel, 'name': '目录模型 $catalogModel'},
                ],
              },
            ],
            'failures': [],
          };
      }
    }
    throw StateError('Unexpected method $method');
  }
}

Future<void> mount(
  WidgetTester tester,
  DestinationRuntime runtime,
  String namespace,
) async {
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: ConfigurationModelDestination(
        runtime: runtime,
        namespace: namespace,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('only model and account namespaces use semantic model destinations', () {
    for (final namespace in [
      'agent-default-model',
      'llm-deepseek',
      'llm-deepseek-account',
      'llm-pi-ai',
    ]) {
      expect(isModelConfigurationNamespace(namespace), isTrue);
    }
    expect(isModelConfigurationNamespace('web'), isFalse);
    expect(isModelConfigurationNamespace('custom-llm-plugin'), isFalse);
  });

  testWidgets('default selection refreshes the directory before opening', (
    tester,
  ) async {
    final runtime = DestinationRuntime();
    await runtime.models.refresh();
    runtime.catalogModel = 'updated';
    runtime.revision = 8;
    await mount(tester, runtime, 'agent-default-model');
    final page = tester.widget<DefaultModelPage>(find.byType(DefaultModelPage));
    expect(page.snapshot.descriptor('agent-default-model')!['revision'], 8);
    expect(runtime.catalogReads, 2);
    expect(find.text('目录模型 updated'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets(
    'failed refresh cannot open a cached model editor and retry uses new data',
    (tester) async {
      final runtime = DestinationRuntime();
      await runtime.models.refresh();
      runtime.failRead = true;
      await mount(tester, runtime, 'agent-default-model');
      expect(runtime.models.snapshot, isNotNull);
      expect(find.byType(DefaultModelPage), findsNothing);
      expect(find.textContaining('本地服务尚未返回完整配置'), findsOneWidget);
      runtime.failRead = false;
      runtime.catalogModel = 'recovered';
      await tester.tap(find.byTooltip('重新读取模型设置'));
      await tester.pumpAndSettle();
      expect(find.byType(DefaultModelPage), findsOneWidget);
      expect(find.text('目录模型 recovered'), findsOneWidget);
    },
  );

  testWidgets(
    'removed default settings show a retryable failure instead of JSON',
    (tester) async {
      final runtime = DestinationRuntime()..serveDefault = false;
      await mount(tester, runtime, 'agent-default-model');
      expect(find.byType(DefaultModelPage), findsNothing);
      expect(find.textContaining('此模型配置已不可用'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    },
  );

  testWidgets('API provider settings use the host directory ownership', (
    tester,
  ) async {
    final runtime = DestinationRuntime();
    await mount(tester, runtime, 'llm-deepseek');
    final page = tester.widget<ProviderSettingsPage>(
      find.byType(ProviderSettingsPage),
    );
    expect(page.provider.id, 'deepseek');
    expect(page.provider.path, isEmpty);
    expect(page.provider.descriptor!['ns'], 'llm-deepseek');
    expect(find.text('API Key'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('account settings stay reachable without a model catalog', (
    tester,
  ) async {
    final runtime = DestinationRuntime()..failRead = true;
    await mount(tester, runtime, 'llm-deepseek-account');
    expect(find.byType(AccountPage), findsOneWidget);
    expect(find.byType(ProviderSettingsPage), findsNothing);
    expect(runtime.catalogReads, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compatible provider namespace opens the model connection directory',
    (tester) async {
      final runtime = DestinationRuntime();
      await mount(tester, runtime, 'llm-pi-ai');
      expect(find.byType(ModelsPage), findsOneWidget);
      expect(find.text('测试提供方'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    },
  );
}
