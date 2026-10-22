import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:dsh_android/configuration_edits.dart';
import 'package:dsh_android/models.dart';
import 'package:dsh_android/models_data.dart';
import 'package:dsh_android/models_editor.dart';
import 'package:dsh_android/models_provider.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/text_document_page.dart';
import 'package:dsh_android/ui.dart';

Json section(String ns, Json value, {int revision = 4, Json? schema}) => {
  'ns': ns,
  'revision': revision,
  'value': cloneConfiguration(value),
  'user': cloneConfiguration(value),
  'base': <String, dynamic>{},
  'schema': schema ?? {},
  'secrets': [],
};
Json profileSchema() => {
  'type': 'object',
  'dict': {
    'providers': {
      'type': 'dict',
      'inner': {
        'type': 'object',
        'dict': {
          'baseURL': {'type': 'string'},
          'apiKeyEnv': {'type': 'string'},
          'models': {
            'type': 'array',
            'inner': {
              'type': 'object',
              'dict': {
                'input': {
                  'type': 'array',
                  'inner': {'type': 'string'},
                },
              },
            },
          },
          'api': {
            'type': 'union',
            'list': [
              {'type': 'const', 'value': 'openai-completions'},
              {'type': 'const', 'value': 'anthropic-messages'},
            ],
          },
        },
      },
    },
  },
};
Json providerEntry({String id = 'acme', String ns = 'llm-pi-ai'}) => {
  'provider': id,
  'displayName': 'Acme',
  'settingsNs': ns,
  'settingsPath': ['providers', id],
  'active': true,
  'declared': true,
};
Json catalog() => {
  'default': {
    'provider': 'acme',
    'model': 'one',
    'reasoningEffort': 'old-level',
  },
  'groups': [
    {
      'id': 'acme',
      'name': 'Acme',
      'models': [
        {'id': 'one', 'name': 'Model One'},
        {
          'id': 'two',
          'name': 'Model Two',
          'reasoning': {
            'efforts': [
              {'id': 'provider-exact-high', 'name': '高强度'},
            ],
          },
        },
      ],
    },
  ],
  'failures': [],
  'routableProviders': ['acme'],
};

class ModelsRuntime extends RuntimeController {
  ModelsRuntime(this.descriptors) {
    phase = 'ready';
  }
  List<Json> descriptors;
  final calls = <Json>[];
  bool failCredential = false, conflict = false;
  bool failCatalog = false, failSettings = false;
  Completer<Json>? pendingCatalog;
  bool configured = false;
  @override
  Future<void> refreshForms() async {}
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add({'method': method, 'params': cloneConfiguration(params)});
    switch (method) {
      case 'settings.describe':
        if (failSettings) throw StateError('private settings failure');
        return descriptors.map(cloneConfiguration).toList();
      case 'settings.mutate':
        if (conflict) {
          throw PlatformException(
            code: 'SETTINGS_CONFLICT',
            message: 'changed remotely',
          );
        }
        final old = descriptors.firstWhere((row) => row['ns'] == params['ns']);
        if (old['revision'] != params['revision']) {
          throw StateError('Wrong revision');
        }
        final value = cloneConfiguration(old['value'] as Json);
        for (final op in params['ops'] as List) {
          applyConfigurationEdit(value, op as Json);
        }
        final next = {
          ...old,
          'value': value,
          'user': cloneConfiguration(value),
          'revision': (old['revision'] as int) + 1,
        };
        descriptors = [
          for (final row in descriptors) row['ns'] == params['ns'] ? next : row,
        ];
        return descriptors.map(cloneConfiguration).toList();
      case 'credentials.describe':
        return {
          'configured': configured,
          'writable': true,
          'source': 'keystore',
        };
      case 'credentials.set':
        if (failCredential) {
          throw PlatformException(code: 'store', message: 'write failed');
        }
        configured = true;
        return {'configured': true};
      case 'credentials.unset':
        configured = false;
        return {'configured': false};
      case 'api.call':
        switch (params['method']) {
          case 'listProviders':
            return [
              {'id': 'acme', 'name': 'Acme'},
            ];
          case 'listConfigurableProviders':
            return [providerEntry()];
          case 'modelCatalog':
            final pending = pendingCatalog;
            if (pending != null) {
              pendingCatalog = null;
              return pending.future;
            }
            if (failCatalog) throw StateError('private catalog failure');
            return catalog();
          case 'discoverModels':
            return [
              {
                'id': 'found',
                'name': 'Found',
                'inputModalities': ['text', 'image'],
              },
            ];
        }
    }
    throw StateError('Unexpected method $method $params');
  }

  void recover() {
    phase = 'ready';
    notifyListeners();
  }
}

final captureKey = GlobalKey();

Future<void> mount(
  WidgetTester tester,
  Widget page, {
  Brightness brightness = Brightness.light,
  double width = 800,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, width < 500 ? 900 : 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: RepaintBoundary(key: captureKey, child: child!),
      ),
      home: page,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['POCKET_CAPTURE_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final image =
        await (captureKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> tap(WidgetTester tester, String text) async {
  final target = find.text(text).evaluate().isEmpty
      ? find.byTooltip(text)
      : find.text(text);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> editValue(WidgetTester tester, String label, String value) async {
  await tap(tester, label);
  expect(find.byType(TextDocumentPage), findsOneWidget);
  await tester.enterText(find.byType(TextField), value);
  await tap(tester, '完成编辑');
}

Future<void> editSecret(WidgetTester tester, String label, String value) async {
  await tap(tester, label);
  final input = tester.widget<TextField>(find.byType(TextField));
  expect(input.obscureText, isTrue);
  expect(input.enableIMEPersonalizedLearning, isFalse);
  expect(
    input.enableInteractiveSelection,
    isTrue,
  ); // Keep credential paste available.
  await tester.enterText(find.byType(TextField), value);
  await tap(tester, '完成编辑');
  expect(find.byType(TextField), findsNothing);
  expect(find.text(value), findsNothing);
}

Future<void> expectSecretDraft(
  WidgetTester tester,
  String label,
  String expected,
) async {
  await tap(tester, label);
  final input = tester.widget<TextField>(find.byType(TextField));
  expect(input.obscureText, isTrue);
  expect(input.controller!.text, expected);
  await tap(tester, '完成编辑');
}

List<Json> mutations(ModelsRuntime runtime) =>
    runtime.calls.where((row) => row['method'] == 'settings.mutate').toList();

void main() {
  setUpAll(() async {
    final path = Platform.environment['POCKET_CAPTURE_FONT'];
    if (path != null) {
      await (FontLoader('Roboto')..addFont(
            Future.value(ByteData.sublistView(await File(path).readAsBytes())),
          ))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.8]) {
      testWidgets(
        'compact model settings ${brightness.name} $scale use summary rows',
        (tester) async {
          final descriptor = section('llm-pi-ai', {
            'providers': {
              'acme': {
                'displayName': '示例服务商',
                'baseURL': 'https://models.example.test/v1',
                'api': 'openai-completions',
                'models': [],
              },
            },
          }, schema: profileSchema());
          final runtime = ModelsRuntime([descriptor]);
          addTearDown(runtime.dispose);
          await mount(
            tester,
            ProviderSettingsPage(
              runtime: runtime,
              provider: ModelProvider(providerEntry(), descriptor),
            ),
            brightness: brightness,
            width: 420,
            scale: scale,
          );
          expect(find.byType(TextField), findsNothing);
          expect(tester.takeException(), isNull);
          await capture(tester, 'models-provider-${brightness.name}-$scale');
          await mount(
            tester,
            DefaultModelPage(
              runtime: runtime,
              snapshot: ModelsSnapshot([], [
                section('agent-default-model', {
                  'provider': 'acme',
                  'model': 'one',
                }),
              ], catalog()),
            ),
            brightness: brightness,
            width: 420,
            scale: scale,
          );
          expect(find.byTooltip('保存默认模型'), findsOneWidget);
          expect(find.byType(TextField), findsNothing);
          final selected = find.ancestor(
            of: find.text('Model One'),
            matching: find.byType(PocketTile),
          );
          expect(
            find.descendant(
              of: selected,
              matching: find.byIcon(Icons.check_rounded),
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await capture(tester, 'models-default-${brightness.name}-$scale');
          await mount(
            tester,
            const ModelEntryPage(
              initial: {
                'id': 'sample-model',
                'name': '示例模型',
                'contextWindow': 256000,
                'maxTokens': 8192,
                'input': ['text', 'image'],
              },
              reasoningLevels: ['high'],
              supportsInput: true,
            ),
            brightness: brightness,
            width: 420,
            scale: scale,
          );
          expect(find.byType(TextField), findsNothing);
          expect(tester.takeException(), isNull);
          await capture(tester, 'models-entry-${brightness.name}-$scale');
          await tap(tester, '模型 ID');
          expect(find.byType(TextField), findsOneWidget);
          expect(tester.takeException(), isNull);
          await capture(tester, 'models-value-${brightness.name}-$scale');
        },
      );
    }
  }

  test('managed reference follows Web convention and capacities preserve exact integral intent', () {
    expect(modelCredentialReference('minimax-cn'), 'MINIMAX_CN_API_KEY');
    expect(modelCapacity('2.3M'), 2300000);
    expect(modelCapacity('256K'), 256000);
    expect(modelCapacity(''), isNull);
    expect(() => modelCapacity('0'), throwsFormatException);
    expect(() => modelCapacity('1.3'), throwsFormatException);
  });

  test('provider removal is restricted to user-only non-root profiles', () {
    final descriptor = section('llm-pi-ai', {
      'providers': {
        'acme': {'apiKeyEnv': 'SHARED'},
      },
    });
    final row = ModelProvider(providerEntry(), descriptor);
    expect(row.credentialRef, 'SHARED');
    expect(row.removable, isTrue);
    descriptor['base'] = {
      'providers': {'acme': {}},
    };
    expect(row.removable, isFalse);
  });

  test(
    'custom provider validates route collision and protocol from owner schema',
    () {
      final choices = modelStringChoices(
        section('llm-pi-ai', {}, schema: profileSchema()),
        ['providers', 'new', 'api'],
      );
      expect(choices, ['openai-completions', 'anthropic-messages']);
      expect(
        () => validateCustomProvider(
          'acme',
          'https://a.test/v1',
          choices.first,
          choices,
          [
            {'id': 'model'},
          ],
          {'acme'},
        ),
        throwsFormatException,
      );
      expect(
        () => validateCustomProvider(
          '2-invalid',
          'https://a.test',
          choices.first,
          choices,
          [
            {'id': 'model'},
          ],
          {},
        ),
        throwsFormatException,
      );
      expect(
        () => validateCustomProvider(
          'valid',
          'file:///tmp',
          choices.first,
          choices,
          [
            {'id': 'model'},
          ],
          {},
        ),
        throwsFormatException,
      );
      expect(
        () => validateModelRows([
          {'id': ' one '},
          {'id': 'one'},
        ]),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'directory is sourced from live services and opens native provider page',
    (tester) async {
      final runtime = ModelsRuntime([
        section('llm-pi-ai', {
          'providers': {
            'acme': {'baseURL': 'https://a.test', 'models': []},
          },
        }, schema: profileSchema()),
        section('agent-default-model', {'provider': 'acme', 'model': 'one'}),
      ]);
      addTearDown(runtime.dispose);
      await mount(tester, ModelsPage(runtime: runtime));
      expect(find.text('添加自定义服务商'), findsOneWidget);
      await tap(tester, 'Acme');
      expect(find.text('完整服务商配置'), findsOneWidget);
      expect(
        runtime.calls
            .where((c) => c['method'] == 'api.call')
            .map((c) => c['params']['method']),
        containsAll([
          'listProviders',
          'listConfigurableProviders',
          'modelCatalog',
        ]),
      );
    },
  );

  testWidgets(
    'catalog outage retains current provider settings but blocks model selection until retry',
    (tester) async {
      final runtime = ModelsRuntime([
        section('llm-pi-ai', {
          'providers': {
            'acme': {'baseURL': 'https://a.test', 'models': []},
          },
        }, schema: profileSchema()),
        section('agent-default-model', {
          'provider': 'acme',
          'model': 'saved-choice',
        }),
      ])..failCatalog = true;
      addTearDown(runtime.dispose);
      await mount(tester, ModelsPage(runtime: runtime));
      expect(runtime.models.snapshot?.catalogFresh, isFalse);
      expect(runtime.models.fresh, isTrue);
      expect(find.text('saved-choice'), findsOneWidget);
      expect(find.textContaining('实时模型目录尚未恢复'), findsOneWidget);
      expect(find.text('Acme'), findsOneWidget);
      await tap(tester, 'saved-choice');
      expect(find.text('保存默认模型'), findsNothing);
      await tap(tester, 'Acme');
      expect(find.text('完整服务商配置'), findsOneWidget);
      await tap(tester, '返回');
      runtime.failCatalog = false;
      await runtime.models.refresh();
      await tester.pumpAndSettle();
      expect(runtime.models.snapshot?.catalogFresh, isTrue);
      expect(find.textContaining('实时模型目录尚未恢复'), findsNothing);
      expect(find.text('one'), findsOneWidget);
    },
  );

  testWidgets('failed settings read retries without exposing its exception', (
    tester,
  ) async {
    final runtime = ModelsRuntime([
      section('agent-default-model', {'provider': 'acme', 'model': 'one'}),
    ])..failSettings = true;
    addTearDown(runtime.dispose);
    await mount(tester, ModelsPage(runtime: runtime));
    expect(runtime.models.snapshot, isNull);
    expect(find.text('模型目录暂不可用'), findsOneWidget);
    expect(find.textContaining('稍后会自动重试'), findsOneWidget);
    expect(find.textContaining('private settings failure'), findsNothing);
    runtime.failSettings = false;
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(runtime.models.fresh, isTrue);
    expect(find.text('one'), findsOneWidget);
  });

  testWidgets('old catalog reply cannot replace the recovered connection', (
    tester,
  ) async {
    final old = Completer<Json>();
    final runtime = ModelsRuntime([
      section('agent-default-model', {'provider': 'acme', 'model': 'one'}),
    ])..pendingCatalog = old;
    addTearDown(runtime.dispose);
    await mount(tester, ModelsPage(runtime: runtime));
    expect(runtime.models.loading, isTrue);
    runtime.fail(StateError('connection lost'));
    await tester.pump();
    expect(runtime.models.fresh, isFalse);
    runtime.recover();
    await tester.pumpAndSettle();
    expect(runtime.models.snapshot?.catalogFresh, isTrue);
    expect(find.text('one'), findsOneWidget);
    old.complete({
      'default': {'provider': 'obsolete', 'model': 'obsolete-model'},
      'groups': <Json>[],
      'failures': <Json>[],
    });
    await tester.pump();
    expect(runtime.models.snapshot?.catalog['default']['model'], 'one');
    expect(find.text('obsolete-model'), findsNothing);
  });

  testWidgets(
    'default model saves original reasoning id and removes previous effort on model change',
    (tester) async {
      final descriptor = section('agent-default-model', {
        'provider': 'acme',
        'model': 'one',
        'reasoningEffort': 'old-level',
      });
      final runtime = ModelsRuntime([descriptor]);
      addTearDown(runtime.dispose);
      await mount(
        tester,
        DefaultModelPage(
          runtime: runtime,
          snapshot: ModelsSnapshot([], [descriptor], catalog()),
        ),
      );
      await tap(tester, 'Model Two');
      await tap(tester, '高强度');
      await tap(tester, '保存默认模型');
      final params = mutations(runtime).single['params'] as Json;
      expect(params['revision'], 4);
      expect(params['ops'], [
        {
          'op': 'set',
          'path': ['model'],
          'value': 'two',
        },
        {
          'op': 'set',
          'path': ['reasoningEffort'],
          'value': 'provider-exact-high',
        },
      ]);
    },
  );

  testWidgets(
    'same-field default conflict preserves selection and requires explicit merge decision',
    (tester) async {
      final descriptor = section('agent-default-model', {
        'provider': 'acme',
        'model': 'one',
      });
      final remote = section('agent-default-model', {
        'provider': 'acme',
        'model': 'remote-model',
      }, revision: 5);
      final runtime = ModelsRuntime([remote])..conflict = true;
      addTearDown(runtime.dispose);
      await mount(
        tester,
        DefaultModelPage(
          runtime: runtime,
          snapshot: ModelsSnapshot([], [descriptor], catalog()),
        ),
      );
      await tap(tester, 'Model Two');
      await tap(tester, '保存默认模型');
      expect(find.textContaining('我的编辑："two"'), findsOneWidget);
      expect(find.textContaining('最新内容："remote-model"'), findsOneWidget);
      await tap(tester, '保留我的编辑');
      await tap(tester, '合并并继续检查');
      expect(mutations(runtime), hasLength(1));
      runtime.conflict = false;
      await tap(tester, '保存默认模型');
      expect(mutations(runtime).last['params']['revision'], 5);
    },
  );

  testWidgets(
    'credential binding commits once and a failed key write retains input for retry',
    (tester) async {
      final descriptor = section('llm-pi-ai', {
        'providers': {
          'acme': {'baseURL': 'https://a.test'},
        },
      }, schema: profileSchema());
      final runtime = ModelsRuntime([descriptor])..failCredential = true;
      addTearDown(runtime.dispose);
      await mount(
        tester,
        ModelCredentialPage(
          runtime: runtime,
          provider: ModelProvider(providerEntry(), descriptor),
        ),
      );
      await editSecret(tester, '新的 API Key', 'test-key-value');
      expect(
        runtime.calls.where((c) => c['method'] == 'credentials.set'),
        isEmpty,
      );
      await tap(tester, '保存 API Key');
      expect(find.textContaining('凭据引用已绑定'), findsOneWidget);
      await expectSecretDraft(tester, '新的 API Key', 'test-key-value');
      expect(mutations(runtime), hasLength(1));
      expect(mutations(runtime).single['params']['ops'], [
        {
          'op': 'set',
          'path': ['providers', 'acme', 'apiKeyEnv'],
          'value': 'ACME_API_KEY',
        },
      ]);
      runtime.failCredential = false;
      await tap(tester, '保存 API Key');
      expect(mutations(runtime), hasLength(1));
      await expectSecretDraft(tester, '新的 API Key', '');
      expect(
        runtime.calls.where((c) => c['method'] == 'credentials.set'),
        hasLength(2),
      );
    },
  );

  testWidgets(
    'credential revocation requires explicit review and keeps shared reference identity',
    (tester) async {
      final descriptor = section('llm-pi-ai', {
        'providers': {
          'acme': {'apiKeyEnv': 'SHARED_KEY'},
        },
      });
      final runtime = ModelsRuntime([descriptor])..configured = true;
      addTearDown(runtime.dispose);
      await mount(
        tester,
        ModelCredentialPage(
          runtime: runtime,
          provider: ModelProvider(providerEntry(), descriptor),
        ),
      );
      await tap(tester, '撤销保存的 API Key');
      expect(
        runtime.calls.where((c) => c['method'] == 'credentials.unset'),
        isEmpty,
      );
      await tap(tester, '确认撤销');
      expect(
        runtime.calls.singleWhere(
          (c) => c['method'] == 'credentials.unset',
        )['params'],
        {'ref': 'SHARED_KEY'},
      );
    },
  );

  testWidgets(
    'credential binding conflict keeps the key and requires review of the changed reference',
    (tester) async {
      final descriptor = section('llm-pi-ai', {
        'providers': {
          'acme': {'baseURL': 'https://a.test'},
        },
      }, schema: profileSchema());
      final remote = section(
        'llm-pi-ai',
        {
          'providers': {
            'acme': {'baseURL': 'https://a.test', 'apiKeyEnv': 'REMOTE_KEY'},
          },
        },
        revision: 5,
        schema: profileSchema(),
      );
      final runtime = ModelsRuntime([remote])..conflict = true;
      addTearDown(runtime.dispose);
      await mount(
        tester,
        ModelCredentialPage(
          runtime: runtime,
          provider: ModelProvider(providerEntry(), descriptor),
        ),
      );
      await editSecret(tester, '新的 API Key', 'retained-key');
      await tap(tester, '保存 API Key');
      expect(
        runtime.calls.where((c) => c['method'] == 'credentials.set'),
        isEmpty,
      );
      expect(find.textContaining('最新配置：REMOTE_KEY'), findsOneWidget);
      await expectSecretDraft(tester, '新的 API Key', 'retained-key');
      await tap(tester, '采用最新引用，保留密钥输入');
      runtime.conflict = false;
      await tap(tester, '保存 API Key');
      expect(
        runtime.calls.singleWhere(
          (c) => c['method'] == 'credentials.set',
        )['params'],
        {'ref': 'REMOTE_KEY', 'value': 'retained-key'},
      );
      expect(mutations(runtime), hasLength(1));
    },
  );

  testWidgets(
    'existing provider edits write only the changed leaf and preserve opaque fields',
    (tester) async {
      final descriptor = section('llm-pi-ai', {
        'providers': {
          'acme': {
            'baseURL': 'https://old.test',
            'apiKeyEnv': 'SHARED',
            'headers': {'x-provider-feature': 'keep'},
            'models': [],
          },
        },
      }, schema: profileSchema());
      final runtime = ModelsRuntime([descriptor]);
      addTearDown(runtime.dispose);
      await mount(
        tester,
        ProviderSettingsPage(
          runtime: runtime,
          provider: ModelProvider(providerEntry(), descriptor),
        ),
      );
      expect(find.byType(TextField), findsNothing);
      await editValue(tester, '接口地址', 'https://new.test/v1');
      expect(mutations(runtime), isEmpty);
      expect(find.text('https://new.test/v1'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tap(tester, '保存配置');
      expect(mutations(runtime).single['params']['ops'], [
        {
          'op': 'set',
          'path': ['providers', 'acme', 'baseURL'],
          'value': 'https://new.test/v1',
        },
      ]);
      expect(
        runtime.descriptors.single['value']['providers']['acme']['headers'],
        {'x-provider-feature': 'keep'},
      );
    },
  );

  testWidgets(
    'custom provider creation uses the owner revision and leaves blank-key authentication untouched',
    (tester) async {
      final descriptor = section('llm-pi-ai', {
        'providers': {},
      }, schema: profileSchema());
      final runtime = ModelsRuntime([descriptor]);
      addTearDown(runtime.dispose);
      await mount(tester, ModelsPage(runtime: runtime));
      await tap(tester, '添加自定义服务商');
      await editValue(tester, '服务商 ID', 'new-route');
      await editValue(tester, '接口地址', 'https://gateway.test/v1');
      await tap(tester, 'openai-completions');
      await tap(tester, '模型列表');
      await tap(tester, '手动添加模型');
      await editValue(tester, '模型 ID', 'new-model');
      await tap(tester, '应用模型');
      await tap(tester, '应用到当前草稿');
      await tap(tester, '创建服务商');
      expect(mutations(runtime).single['params'], {
        'ns': 'llm-pi-ai',
        'revision': 4,
        'ops': [
          {
            'op': 'set',
            'path': ['providers', 'new-route'],
            'value': {
              'baseURL': 'https://gateway.test/v1',
              'api': 'openai-completions',
              'models': [
                {'id': 'new-model'},
              ],
            },
          },
        ],
      });
      expect(
        runtime.calls.where((c) => c['method'] == 'credentials.set'),
        isEmpty,
      );
    },
  );

  testWidgets(
    'model discovery uses draft connection without persisting probe key or auto-adopting results',
    (tester) async {
      final runtime = ModelsRuntime([]);
      addTearDown(runtime.dispose);
      await mount(
        tester,
        ModelListPage(
          runtime: runtime,
          settingsNs: 'llm-pi-ai',
          initial: [],
          endpoint: 'https://draft.test/v1',
          protocol: 'openai-completions',
          reasoningLevels: [],
          supportsInput: true,
        ),
      );
      await editSecret(tester, '仅本次发现使用的 API Key', 'probe-key');
      expect(runtime.calls, isEmpty);
      await tap(tester, '发现模型');
      expect(find.text('尚未添加模型。'), findsOneWidget);
      expect(runtime.calls.single['params'], {
        'namespace': 'llm',
        'method': 'discoverModels',
        'args': {
          'settingsNs': 'llm-pi-ai',
          'request': {
            'baseURL': 'https://draft.test/v1',
            'api': 'openai-completions',
            'apiKey': 'probe-key',
          },
        },
      });
      await tap(tester, 'Found');
      expect(find.text('已添加'), findsOneWidget);
      expect(runtime.calls, hasLength(1));
    },
  );

  testWidgets(
    'editing a model preserves hidden adapter fields and parses capacity',
    (tester) async {
      Json? result;
      await mount(
        tester,
        Builder(
          builder: (context) => PocketScaffold(
            title: const Text('Test'),
            body: PocketButton(
              child: const Text('Open'),
              onPressed: () async {
                result = await Navigator.push<Json>(
                  context,
                  PocketRoute(
                    builder: (_) => const ModelEntryPage(
                      initial: {
                        'id': 'original',
                        'compat': {'opaque': 'preserved'},
                        'futureField': 42,
                      },
                      reasoningLevels: [],
                      supportsInput: true,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tap(tester, 'Open');
      expect(find.byType(TextField), findsNothing);
      await tap(tester, '模型 ID');
      await tester.enterText(find.byType(TextField), 'unaccepted-id');
      await tap(tester, '返回');
      await tap(tester, '继续编辑');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'unaccepted-id',
      );
      await tap(tester, '返回');
      await tap(tester, '放弃编辑并返回');
      expect(find.text('original'), findsOneWidget);
      await editValue(tester, '上下文容量', '2.3M');
      await tap(tester, '应用模型');
      expect(result, {
        'id': 'original',
        'compat': {'opaque': 'preserved'},
        'futureField': 42,
        'contextWindow': 2300000,
      });
    },
  );

  testWidgets(
    'back navigation keeps a failed credential draft until explicitly discarded',
    (tester) async {
      final descriptor = section('llm-pi-ai', {
        'providers': {
          'acme': {'apiKeyEnv': 'ACME_API_KEY'},
        },
      });
      final runtime = ModelsRuntime([descriptor])..failCredential = true;
      addTearDown(runtime.dispose);
      await mount(
        tester,
        Builder(
          builder: (context) => PocketScaffold(
            title: const Text('Test'),
            body: PocketButton(
              child: const Text('Open'),
              onPressed: () => Navigator.push(
                context,
                PocketRoute<void>(
                  builder: (_) => ModelCredentialPage(
                    runtime: runtime,
                    provider: ModelProvider(providerEntry(), descriptor),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tap(tester, 'Open');
      await editSecret(tester, '新的 API Key', 'do-not-drop-me');
      await tap(tester, '保存 API Key');
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('保留当前编辑？'), findsOneWidget);
      await tap(tester, '继续编辑');
      await expectSecretDraft(tester, '新的 API Key', 'do-not-drop-me');
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tap(tester, '放弃编辑并返回');
      expect(find.text('Open'), findsOneWidget);
      expect(
        runtime.calls.where((call) => call['method'] == 'credentials.set'),
        hasLength(1),
      );
    },
  );
}
