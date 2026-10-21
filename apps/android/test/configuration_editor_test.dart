import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:dsh_android/configuration_editor.dart';
import 'package:dsh_android/configuration_edits.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/models.dart';
import 'package:dsh_android/models_data.dart';
import 'package:dsh_android/ui.dart';

class SettingsRuntime extends RuntimeController {
  SettingsRuntime(Json initial) : remote = cloneConfiguration(initial) {
    forms = [cloneConfiguration(remote)];
    phase = 'ready';
  }
  Json remote;
  final writes = <Json>[];
  final storedCredentials = <String, String>{};
  bool failReceipt = false;

  Json mutate(Json args, String revisionKey) {
    writes.add(cloneConfiguration(args));
    if (args[revisionKey] != remote['revision']) {
      throw PlatformException(
        code: revisionKey == 'revision'
            ? 'SETTINGS_CONFLICT'
            : 'settings/conflict',
        message: 'changed',
      );
    }
    for (final op in args['ops'] as List) {
      applyConfigurationEdit(remote['value'] as Json, op as Json);
      applyConfigurationEdit(remote['user'] as Json, op);
    }
    remote['revision'] = (remote['revision'] as int) + 1;
    return cloneConfiguration(remote);
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    switch (method) {
      case 'api.call':
        if (params['namespace'] != 'settings') {
          throw StateError('Unexpected namespace');
        }
        if (params['method'] == 'describe') {
          return {
            'writable': true,
            'namespaces': [cloneConfiguration(remote)],
          };
        }
        if (params['method'] == 'mutate') {
          if (failReceipt) {
            writes.add(cloneConfiguration(params['args'] as Json));
            throw PlatformException(code: 'transport/unavailable');
          }
          return mutate(params['args'] as Json, 'expectedRevision');
        }
        throw StateError('Unexpected API method');
      case 'settings.describe':
        return [cloneConfiguration(remote)];
      case 'settings.mutate':
        return [mutate(params, 'revision')];
      case 'credentials.describe':
        return {'configured': storedCredentials.containsKey(params['ref'])};
      case 'credentials.set':
        storedCredentials[params['ref'] as String] = params['value'] as String;
        return {'configured': true};
      default:
        throw StateError('Unexpected method $method');
    }
  }
}

Json fixture() => {
  'ns': 'llm-deepseek',
  'revision': 1,
  'value': {'baseURL': 'https://old.example', 'maxTokens': 1024},
  'user': {'baseURL': 'https://old.example'},
  'secrets': [
    {
      'path': ['apiKey'],
      'set': true,
    },
  ],
  'schema': {
    'uid': 1,
    'refs': {
      '1': {
        'uid': 1,
        'type': 'object',
        'dict': {'baseURL': 2, 'maxTokens': 3, 'apiKey': 4},
      },
      '2': {'uid': 2, 'type': 'string'},
      '3': {
        'uid': 3,
        'type': 'number',
        'meta': {'min': 1, 'step': 1},
      },
      '4': {
        'uid': 4,
        'type': 'string',
        'meta': {'role': 'secret'},
      },
    },
  },
};

Finder field(String name) =>
    find.byKey(ValueKey('configuration-field:${jsonEncode([name])}'));

Future<void> openEditor(WidgetTester tester, SettingsRuntime runtime) async {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: ConfigPage(runtime: runtime, descriptor: runtime.forms.single),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'JSON subpage holds the original revision while remote updates remain reviewable',
    (tester) async {
      final runtime = SettingsRuntime(fixture());
      await openEditor(tester, runtime);
      await tester.tap(find.text('高级 JSON 编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('configuration-json')),
        '{"baseURL":"https://local.example","maxTokens":1024}',
      );
      runtime.remote['revision'] = 2;
      runtime.remote['value']['maxTokens'] = 2048;
      await runtime.refreshForms();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(runtime.writes, isEmpty);
      expect(find.text('版本比较'), findsOneWidget);
      expect(find.textContaining('编辑基于版本 1，当前版本 2'), findsOneWidget);
      expect(
        tester.widget<TextField>(field('baseURL')).controller!.text,
        'https://local.example',
      );
      expect(
        tester.widget<TextField>(field('maxTokens')).controller!.text,
        '1024',
      );
      expect(find.text('请先比较并合并'), findsOneWidget);
    },
  );

  testWidgets(
    'long text edits return to the parent draft without writing or truncating',
    (tester) async {
      final descriptor = fixture();
      final original = List.filled(10, 'prompt line').join('\n');
      descriptor['value']['baseURL'] = original;
      final runtime = SettingsRuntime(descriptor);
      await openEditor(tester, runtime);
      await tester.tap(find.text('编辑服务地址'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      final next = '$original\nnew line';
      await tester.enterText(find.byType(TextField), next);
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(runtime.writes, isEmpty);
      expect(find.text('${next.length} 个字符'), findsOneWidget);
      await tester.tap(find.text('编辑服务地址'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        next,
      );
    },
  );

  testWidgets(
    'JSON protection rejects before leaving the text buffer and normal edits remain staged only',
    (tester) async {
      final runtime = SettingsRuntime(fixture());
      await openEditor(tester, runtime);
      await tester.tap(find.text('高级 JSON 编辑'));
      await tester.pumpAndSettle();
      final text = find.byKey(const Key('configuration-json'));
      const protected =
          '{"baseURL":"https://draft.example","maxTokens":1024,"apiKey":"never-save-this"}';
      await tester.enterText(text, protected);
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(text).controller!.text, protected);
      expect(find.textContaining('输入已保留'), findsWidgets);
      expect(runtime.writes, isEmpty);
      await tester.enterText(
        text,
        '{"baseURL":"https://draft.example","maxTokens":1024}',
      );
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(text, findsNothing);
      expect(runtime.writes, isEmpty);
      expect(
        tester.widget<TextField>(field('baseURL')).controller!.text,
        'https://draft.example',
      );
      await tester.tap(find.text('保存并应用'));
      await tester.pumpAndSettle();
      expect(runtime.writes, hasLength(1));
      expect(runtime.remote['value']['baseURL'], 'https://draft.example');
      expect(runtime.remote['value'].containsKey('apiKey'), isFalse);
    },
  );

  Json structuredFixture() => {
    'ns': 'llm-example',
    'revision': 1,
    'user': {},
    'secrets': [],
    'value': {
      'models': [
        {'id': 'before', 'unknown': true},
      ],
      'other': 'original',
    },
    'schema': {
      'type': 'object',
      'dict': {
        'models': {
          'type': 'array',
          'inner': {
            'type': 'object',
            'dict': {
              'id': {
                'type': 'string',
                'meta': {'required': true},
              },
            },
          },
        },
        'other': {'type': 'string'},
      },
    },
  };

  Future<void> openModelField(WidgetTester tester) async {
    await tester.tap(find.text('编辑模型目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('structure-item:0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('structure-entry:id')));
    await tester.pumpAndSettle();
  }

  Future<void> finishStructure(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('完成编辑'));
      await tester.pumpAndSettle();
    }
  }

  testWidgets(
    'structured arrays stage once and save one atomic field with revision',
    (tester) async {
      final runtime = SettingsRuntime(structuredFixture());
      await openEditor(tester, runtime);
      await openModelField(tester);
      await tester.enterText(find.byKey(const Key('structure-value')), 'after');
      await finishStructure(tester);
      expect(runtime.writes, isEmpty);
      await tester.tap(find.text('保存并应用'));
      await tester.pumpAndSettle();
      expect(runtime.writes.single['expectedRevision'], 1);
      expect(runtime.writes.single['ops'], [
        {
          'op': 'set',
          'path': ['models'],
          'value': [
            {'id': 'after', 'unknown': true},
          ],
        },
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'remote update during structured draft becomes atomic conflict and keeps input',
    (tester) async {
      final runtime = SettingsRuntime(structuredFixture());
      await openEditor(tester, runtime);
      await openModelField(tester);
      await tester.enterText(find.byKey(const Key('structure-value')), 'local');
      runtime.remote['revision'] = 2;
      runtime.remote['value']['models'] = [
        {'id': 'remote'},
      ];
      await runtime.refreshForms();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('structure-value')))
            .controller!
            .text,
        'local',
      );
      await finishStructure(tester);
      expect(find.text('编辑基于版本 1，当前版本 2。'), findsOneWidget);
      expect(find.textContaining('local'), findsWidgets);
      final save = find.ancestor(
        of: find.text('请先比较并合并'),
        matching: find.byType(PocketButton),
      );
      expect(tester.widget<PocketButton>(save).onPressed, isNull);
      expect(runtime.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('discarded child leaves outer configuration unchanged', (
    tester,
  ) async {
    final runtime = SettingsRuntime(structuredFixture());
    await openEditor(tester, runtime);
    await openModelField(tester);
    await tester.enterText(find.byKey(const Key('structure-value')), 'discard');
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃编辑并返回'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('保存并应用'));
    await tester.pumpAndSettle();
    expect(runtime.writes, isEmpty);
    expect(runtime.remote['value']['models'], [
      {'id': 'before', 'unknown': true},
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'secret-bearing array never exposes structured replacement controls',
    (tester) async {
      final data = structuredFixture();
      data['schema']['dict']['models']['inner']['dict']['token'] = {
        'type': 'string',
        'meta': {'role': 'secret'},
      };
      data['secrets'] = [
        {
          'path': ['models', '0', 'token'],
          'set': true,
        },
      ];
      final runtime = SettingsRuntime(data);
      await openEditor(tester, runtime);
      expect(find.text('编辑模型目录'), findsNothing);
      expect(find.textContaining('此结构包含凭据'), findsOneWidget);
      expect(runtime.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('bundled model and Web settings have distinct functional titles', () {
    const expected = {
      'llm-deepseek': 'DeepSeek API 密钥接入',
      'llm-deepseek-account': 'DeepSeek 账号模型接入',
      'subagent-model-selection-settings': '子 Agent 模型选择',
      'ui-settings-account': 'Web 账号界面',
      'ui-theme': 'Web 主题与字体',
      'ui-settings': 'Web 开发者工具',
      'ui-conversation': 'Web 繁忙时发送行为',
      'ui-chat': 'Web 聊天展示',
    };
    for (final entry in expected.entries) {
      expect(configurationNamespaceTitle(entry.key), entry.value);
    }
    final titles = [
      ...expected.keys,
      'session-log-deepseek',
      'agent-default-model',
      'llm-pi-ai',
      'subagent',
      'web',
      'web-search-deepseek',
      'web-deepseek-api',
    ].map(configurationNamespaceTitle).toList();
    expect(titles.toSet(), hasLength(titles.length));
  });

  test(
    'unknown settings retain their exact identity without keyword guesses',
    () {
      for (final namespace in [
        'agent',
        'custom-llm',
        'custom-model',
        'custom-shell',
        'custom-bash',
        'custom-search',
        'custom-web',
        'custom-preset',
        'custom-persona',
        'custom-subagent',
      ]) {
        expect(configurationNamespaceTitle(namespace), namespace);
      }
    },
  );

  testWidgets(
    'native fields save only their changes without writing the hidden key or defaults',
    (tester) async {
      final runtime = SettingsRuntime(fixture());
      await openEditor(tester, runtime);
      expect(find.text('已配置；值已隐藏，请在凭据入口管理。'), findsOneWidget);
      await tester.enterText(field('baseURL'), 'https://new.example');
      await tester.tap(find.text('保存并应用'));
      await tester.pumpAndSettle();
      expect(runtime.writes.single['ops'], [
        {
          'op': 'set',
          'path': ['baseURL'],
          'value': 'https://new.example',
        },
      ]);
      expect(find.text('已保存并应用。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a stale save retains the draft and merges remote changes after an explicit conflict choice',
    (tester) async {
      final runtime = SettingsRuntime(fixture());
      await openEditor(tester, runtime);
      await tester.enterText(field('baseURL'), 'https://mine.example');
      runtime.remote['revision'] = 2;
      runtime.remote['value'] = {
        'baseURL': 'https://remote.example',
        'maxTokens': 2048,
      };
      await tester.tap(find.text('保存并应用'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field('baseURL')).controller!.text,
        'https://mine.example',
      );
      expect(runtime.remote['value']['baseURL'], 'https://remote.example');
      await tester.ensureVisible(find.text('保留我的修改'));
      await tester.tap(find.text('保留我的修改'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('合并到草稿'));
      await tester.tap(find.text('合并到草稿'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field('baseURL')).controller!.text,
        'https://mine.example',
      );
      expect(
        tester.widget<TextField>(field('maxTokens')).controller!.text,
        '2048',
      );
      expect(runtime.writes, isEmpty);
      await tester.tap(find.text('保存并应用'));
      await tester.pumpAndSettle();
      expect(runtime.writes.last['expectedRevision'], 2);
      expect(runtime.remote['value'], {
        'baseURL': 'https://mine.example',
        'maxTokens': 2048,
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('invalid numeric input prevents a write and stays in the field', (
    tester,
  ) async {
    final runtime = SettingsRuntime(fixture());
    await openEditor(tester, runtime);
    await tester.enterText(field('maxTokens'), '-1');
    await tester.pumpAndSettle();
    expect(find.text('不能小于 1。'), findsOneWidget);
    await tester.tap(find.text('保存并应用'));
    await tester.pumpAndSettle();
    expect(runtime.writes, isEmpty);
    expect(tester.widget<TextField>(field('maxTokens')).controller!.text, '-1');
    await tester.ensureVisible(find.text('使用默认值').first);
    await tester.tap(find.text('使用默认值').first);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field('maxTokens')).controller!.text, '-1');
    expect(find.text('不能小于 1。'), findsOneWidget);
    expect(runtime.writes, isEmpty);
    runtime.remote['revision'] = 2;
    runtime.remote['value']['maxTokens'] = 2048;
    await runtime.refreshForms();
    await tester.pumpAndSettle();
    final merge = find.ancestor(
      of: find.text('合并到草稿'),
      matching: find.byType(PocketButton),
    );
    expect(tester.widget<PocketButton>(merge).onPressed, isNull);
    expect(tester.widget<TextField>(field('maxTokens')).controller!.text, '-1');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'invalid field is retained after another field returns to its original value',
    (tester) async {
      final runtime = SettingsRuntime(fixture());
      await openEditor(tester, runtime);
      await tester.enterText(field('maxTokens'), 'not a number');
      await tester.enterText(field('baseURL'), 'temporary');
      await tester.enterText(field('baseURL'), 'https://old.example');
      runtime.remote['revision'] = 2;
      runtime.remote['value']['maxTokens'] = 2048;
      await runtime.refreshForms();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field('maxTokens')).controller!.text,
        'not a number',
      );
      expect(find.text('请输入有效数字。'), findsOneWidget);
      expect(find.text('编辑基于版本 1，当前版本 2。'), findsOneWidget);
      expect(runtime.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'uncertain save exposes the observed configuration before explicit adoption',
    (tester) async {
      final runtime = SettingsRuntime(fixture())..failReceipt = true;
      await openEditor(tester, runtime);
      await tester.enterText(field('baseURL'), 'https://mine.example');
      await tester.tap(find.text('保存并应用'));
      await tester.pumpAndSettle();
      expect(find.text('核对保存结果'), findsOneWidget);
      expect(
        tester.widget<TextField>(field('baseURL')).controller!.text,
        'https://mine.example',
      );
      expect(tester.widget<TextField>(field('baseURL')).enabled, isFalse);
      await tester.tap(find.text('查看当前配置（凭据已隐藏）'));
      await tester.pumpAndSettle();
      expect(find.textContaining('https://old.example'), findsOneWidget);
      expect(find.textContaining('此次保存没有覆盖新版本'), findsNothing);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('继续核对'));
      await tester.tap(find.text('继续核对'));
      await tester.pumpAndSettle();
      expect(runtime.writes, hasLength(1));
      await tester.ensureVisible(find.text('采用当前配置'));
      await tester.tap(find.text('采用当前配置'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field('baseURL')).controller!.text,
        'https://old.example',
      );
      expect(find.text('核对保存结果'), findsNothing);
      expect(runtime.writes, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'invalid raw JSON survives incoming configuration and is guarded on exit',
    (tester) async {
      final runtime = SettingsRuntime(fixture());
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ConfigPage(
                    runtime: runtime,
                    descriptor: runtime.forms.single,
                  ),
                ),
              ),
              child: const Text('open editor'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open editor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高级 JSON 编辑'));
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('configuration-json'));
      await tester.enterText(input, '{ invalid draft');
      runtime.remote['revision'] = 2;
      runtime.remote['value']['baseURL'] = 'new';
      await runtime.refreshForms();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        '{ invalid draft',
      );
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('保留当前编辑？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        '{ invalid draft',
      );
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃编辑并返回'));
      await tester.pumpAndSettle();
      expect(find.text('高级 JSON 编辑'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('open editor'), findsOneWidget);
      expect(runtime.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'default model save uses the revisioned settings owner and reports persistence',
    (tester) async {
      final runtime = SettingsRuntime({
        'ns': 'agent-default-model',
        'revision': 4,
        'value': {'provider': 'deepseek-official', 'model': 'deepseek-flash'},
        'user': {},
        'secrets': [],
      });
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: DefaultModelPage(
            runtime: runtime,
            snapshot: ModelsSnapshot([], runtime.forms, {
              'groups': [
                {
                  'id': 'deepseek-official',
                  'name': 'DeepSeek',
                  'models': [
                    {'id': 'deepseek-flash', 'name': 'Flash'},
                    {'id': 'deepseek-pro', 'name': 'Pro'},
                  ],
                },
              ],
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pro'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存默认模型'));
      await tester.tap(find.text('保存默认模型'));
      await tester.pumpAndSettle();
      expect(runtime.writes.single['revision'], 4);
      expect(runtime.remote['value']['model'], 'deepseek-pro');
      expect(runtime.model, 'deepseek-pro');
      expect(find.text('已保存。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
