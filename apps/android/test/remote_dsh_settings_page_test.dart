// 远程设置页：设置节展示、默认模型修改、版本冲突重读与能力门控。
//
// 这里不连宿主、不拨号：页面只认 `RemoteDshSettingsSource` /
// `RemoteDshModelCatalogSource`，替身来自 `support/remote_home_fakes.dart`，因此
// describe/mutate、冲突重读与手动填写都能在没有 PC 的情况下验证。

import 'package:dsh_android/remote_dsh_live_source.dart';
import 'package:dsh_android/remote_dsh_settings_page.dart';
import 'package:dsh_android/remote_transport.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/remote_home_fakes.dart';

/// 挂载设置页并等首次读取完成。
Future<void> _show(
  WidgetTester tester,
  FakeRemoteSettingsSource source, {
  FakeRemoteModelCatalogSource? catalog,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: RemoteDshSettingsPage(source: source, catalogSource: catalog),
    ),
  );
  await tester.pumpAndSettle();
}

/// 打开默认模型弹层并选中 [modelId]（`deepseek-account` 提供方下）。
Future<void> _chooseModel(
  WidgetTester tester,
  String modelId, {
  String? effortLabel,
}) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('remote-settings-change-model')),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(
      ValueKey<String>('remote-settings-model:deepseek-account:$modelId'),
    ),
  );
  await tester.pumpAndSettle();
  if (effortLabel != null) {
    await tester.tap(find.text(effortLabel));
    await tester.pumpAndSettle();
  }
  await tester.tap(
    find.byKey(const ValueKey<String>('remote-settings-model-apply')),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('设置节展示', () {
    testWidgets('置顶显示默认模型路由与设置版本', (tester) async {
      final source = FakeRemoteSettingsSource(
        describes: <RemoteDshSettingsSnapshot>[
          fakeSettingsSnapshot(
            sections: <RemoteDshSettingsSection>[
              fakeDefaultModelSection(revision: 3),
              fakeSettingsSection(
                ns: 'agent-loop',
                title: 'Agent 执行',
                fields: <RemoteDshSettingField>[
                  fakeSettingField(
                    name: 'maxParallelToolCalls',
                    label: '并行工具调用数',
                    value: '4',
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      await _show(tester, source);

      expect(find.text('deepseek-account/deepseek-flash'), findsOneWidget);
      expect(find.textContaining('版本 3'), findsOneWidget);
      expect(find.text('Agent 执行'), findsOneWidget);
      expect(find.text('并行工具调用数'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('remote-settings-change-model')),
        findsOneWidget,
      );
    });

    testWidgets('凭据槽位只显示是否已配置，不显示内容', (tester) async {
      final source = FakeRemoteSettingsSource(
        describes: <RemoteDshSettingsSnapshot>[
          fakeSettingsSnapshot(
            sections: <RemoteDshSettingsSection>[
              fakeSettingsSection(
                ns: 'llm-deepseek',
                title: 'DeepSeek API 密钥接入',
                fields: <RemoteDshSettingField>[
                  fakeSettingField(
                    name: 'apiKey',
                    label: 'API 密钥',
                    value: '已配置（不显示）',
                    kind: RemoteDshSettingFieldKind.secret,
                    configured: true,
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      await _show(tester, source);

      expect(find.text('已配置（不显示）'), findsOneWidget);
      expect(find.textContaining('sk-'), findsNothing, reason: '凭据内容绝不能出现在页面上');
      // 电脑没有提供默认模型这一节时给出明确说明，而不是空白卡片。
      expect(find.text('这台电脑没有提供默认模型设置'), findsOneWidget);
    });

    testWidgets('电脑只接受读取时更换入口置灰', (tester) async {
      final source = FakeRemoteSettingsSource(
        describes: <RemoteDshSettingsSnapshot>[
          fakeSettingsSnapshot(
            writable: false,
            sections: <RemoteDshSettingsSection>[
              fakeDefaultModelSection(revision: 1),
            ],
          ),
        ],
      );
      await _show(tester, source);

      final change = tester.widget<GlassButton>(
        find.byKey(const ValueKey<String>('remote-settings-change-model')),
      );
      expect(change.onPressed, isNull, reason: '只读 profile 不能出现能点但没用的按钮');
      expect(find.textContaining('只接受读取'), findsOneWidget);
    });

    testWidgets('读取失败展示宿主消息，重试后恢复', (tester) async {
      final source = FakeRemoteSettingsSource(
        describes: <RemoteDshSettingsSnapshot>[
          fakeSettingsSnapshot(
            sections: <RemoteDshSettingsSection>[
              fakeDefaultModelSection(revision: 2),
            ],
          ),
        ],
        describeError: PlatformException(
          code: 'gateway/timeout',
          message: '电脑上的 DSH 响应超时，请重试。',
        ),
      );
      await _show(tester, source);

      expect(find.text('读取电脑设置失败'), findsOneWidget);
      expect(find.text('电脑上的 DSH 响应超时，请重试。'), findsOneWidget);

      source.describeError = null;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(find.text('deepseek-account/deepseek-flash'), findsOneWidget);
    });
  });

  group('修改默认模型', () {
    testWidgets('从模型目录选择模型与思考强度并写回修订号', (tester) async {
      final saved = fakeSettingsSnapshot(
        sections: <RemoteDshSettingsSection>[
          fakeDefaultModelSection(
            model: 'deepseek-v4-pro',
            reasoningEffort: 'high',
            revision: 4,
          ),
        ],
      );
      final source = FakeRemoteSettingsSource(
        describes: <RemoteDshSettingsSnapshot>[
          fakeSettingsSnapshot(
            sections: <RemoteDshSettingsSection>[
              fakeDefaultModelSection(revision: 3),
            ],
          ),
        ],
        afterMutation: saved,
      );
      final catalog = FakeRemoteModelCatalogSource(fakeModelCatalog());
      await _show(tester, source, catalog: catalog);

      await _chooseModel(tester, 'deepseek-v4-pro', effortLabel: '高');

      expect(catalog.calls, 1);
      expect(source.mutations, hasLength(1));
      expect(source.mutations.single.revision, 3, reason: '写回必须带读取时的修订号');
      expect(source.mutations.single.route.provider, 'deepseek-account');
      expect(source.mutations.single.route.model, 'deepseek-v4-pro');
      expect(source.mutations.single.route.reasoningEffort, 'high');
      expect(find.text('deepseek-account/deepseek-v4-pro'), findsOneWidget);
      expect(find.textContaining('已应用新的默认模型'), findsWidgets);
    });

    testWidgets('没有变化时不能提交写请求', (tester) async {
      final source = FakeRemoteSettingsSource(
        describes: <RemoteDshSettingsSnapshot>[
          fakeSettingsSnapshot(
            sections: <RemoteDshSettingsSection>[
              fakeDefaultModelSection(revision: 3),
            ],
          ),
        ],
      );
      await _show(
        tester,
        source,
        catalog: FakeRemoteModelCatalogSource(fakeModelCatalog()),
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('remote-settings-change-model')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('remote-settings-model-apply')),
      );
      await tester.pumpAndSettle();

      expect(source.mutations, isEmpty);
      expect(
        find.text('更换默认模型'),
        findsOneWidget,
        reason: '选中项没有变化时应用按钮不可点，弹层保持打开',
      );
    });

    testWidgets('修订号冲突时重读设置并留下可重试提示', (tester) async {
      final stale = fakeSettingsSnapshot(
        sections: <RemoteDshSettingsSection>[
          fakeDefaultModelSection(revision: 3),
        ],
      );
      final latest = fakeSettingsSnapshot(
        sections: <RemoteDshSettingsSection>[
          fakeDefaultModelSection(model: 'deepseek-v4-pro', revision: 4),
        ],
      );
      final source = FakeRemoteSettingsSource(
        describes: <RemoteDshSettingsSnapshot>[stale, latest],
        mutateError: PlatformException(
          code: 'SETTINGS_CONFLICT',
          message: 'settings namespace "agent-default-model" changed since it was read',
        ),
      );
      await _show(
        tester,
        source,
        catalog: FakeRemoteModelCatalogSource(fakeModelCatalog()),
      );

      await _chooseModel(tester, 'deepseek-v4-pro');

      expect(source.mutations, hasLength(1));
      expect(source.describeCalls, 2, reason: '冲突后必须重读最新设置');
      expect(
        find.byKey(const ValueKey<String>('remote-settings-notice')),
        findsOneWidget,
      );
      expect(find.textContaining('设置已在电脑上被修改'), findsOneWidget);
      expect(
        find.text('deepseek-account/deepseek-v4-pro'),
        findsOneWidget,
        reason: '冲突后页面显示电脑上的最新路由',
      );
    });

    testWidgets('模型目录不可用时退回手动填写并写回', (tester) async {
      final saved = fakeSettingsSnapshot(
        sections: <RemoteDshSettingsSection>[
          fakeDefaultModelSection(
            provider: 'custom-provider',
            model: 'custom-model',
            reasoningEffort: 'medium',
            revision: 5,
          ),
        ],
      );
      final source = FakeRemoteSettingsSource(
        describes: <RemoteDshSettingsSnapshot>[
          fakeSettingsSnapshot(
            sections: <RemoteDshSettingsSection>[
              fakeDefaultModelSection(revision: 3),
            ],
          ),
        ],
        afterMutation: saved,
      );
      final catalog = FakeRemoteModelCatalogSource(
        fakeModelCatalog(),
        error: PlatformException(
          code: 'unsupported-method',
          message: '当前连接的电脑不支持「api.call」。',
        ),
      );
      await _show(tester, source, catalog: catalog);

      await tester.tap(
        find.byKey(const ValueKey<String>('remote-settings-change-model')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('当前连接的电脑不支持'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey<String>('remote-settings-provider')),
        'custom-provider',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('remote-settings-model')),
        'custom-model',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('remote-settings-effort')),
        'medium',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('remote-settings-model-apply')),
      );
      await tester.pumpAndSettle();

      expect(source.mutations.single.route.provider, 'custom-provider');
      expect(source.mutations.single.route.model, 'custom-model');
      expect(source.mutations.single.route.reasoningEffort, 'medium');
      expect(find.text('custom-provider/custom-model'), findsOneWidget);
    });
  });

  group('能力门控', () {
    testWidgets('宿主没有声明设置能力时只显示原因且不读取', (tester) async {
      final source = FakeRemoteSettingsSource(
        capability: const RemoteDshCapability.notDeclared(
          '这台电脑没有声明「settings.describe」，暂时无法使用。',
        ),
        describes: const <RemoteDshSettingsSnapshot>[],
      );
      await _show(tester, source);

      expect(find.text('这台电脑不支持远程设置'), findsOneWidget);
      expect(find.textContaining('没有声明'), findsOneWidget);
      expect(source.describeCalls, 0);
    });

    testWidgets('宿主明确不支持写入时同样按能力原因展示', (tester) async {
      final source = FakeRemoteSettingsSource(
        capability: const RemoteDshCapability.unavailable(
          '这台电脑声明不支持「settings.mutate」。',
        ),
        describes: const <RemoteDshSettingsSnapshot>[],
      );
      await _show(tester, source);

      expect(find.text('这台电脑不支持远程设置'), findsOneWidget);
      expect(find.text('这台电脑声明不支持「settings.mutate」。'), findsOneWidget);
    });
  });

  group('解析 settings.describe / 模型目录', () {
    test('解析设置节、默认模型路由与凭据槽位', () {
      final snapshot = parseRemoteDshSettings(<dynamic>[
        <String, dynamic>{
          'ns': 'agent-default-model',
          'revision': 3,
          'schema': <String, dynamic>{
            'type': 'object',
            'dict': <String, dynamic>{
              'provider': <String, dynamic>{'type': 'string'},
              'model': <String, dynamic>{'type': 'string'},
              'reasoningEffort': <String, dynamic>{'type': 'string'},
            },
          },
          'value': <String, dynamic>{
            'provider': 'deepseek-account',
            'model': 'deepseek-v4-pro',
            'reasoningEffort': 'high',
          },
        },
        <String, dynamic>{
          'ns': 'llm-deepseek',
          'revision': 1,
          'schema': <String, dynamic>{
            'type': 'object',
            'dict': <String, dynamic>{
              'apiKey': <String, dynamic>{
                'type': 'string',
                'meta': <String, dynamic>{'role': 'secret'},
              },
            },
          },
          'value': <String, dynamic>{},
          'secrets': <dynamic>[
            <String, dynamic>{
              'path': <String>['apiKey'],
              'set': true,
            },
          ],
        },
      ]);

      expect(snapshot.sections, hasLength(2));
      final route = snapshot.defaultModelSection?.defaultModelRoute;
      expect(route?.provider, 'deepseek-account');
      expect(route?.model, 'deepseek-v4-pro');
      expect(route?.reasoningEffort, 'high');
      expect(snapshot.defaultModelSection?.title, '默认模型');

      final secret = snapshot.section('llm-deepseek')!.fields.single;
      expect(secret.kind, RemoteDshSettingFieldKind.secret);
      expect(secret.configured, isTrue);
      expect(secret.value, '已配置（不显示）');
    });

    test('也接受 {writable, namespaces} 形态并保留只读标记', () {
      final snapshot = parseRemoteDshSettings(<String, dynamic>{
        'writable': false,
        'namespaces': <dynamic>[
          <String, dynamic>{
            'ns': 'agent-default-model',
            'revision': 0,
            'schema': <String, dynamic>{
              'type': 'object',
              'dict': <String, dynamic>{
                'provider': <String, dynamic>{'type': 'string'},
                'model': <String, dynamic>{'type': 'string'},
              },
            },
            'value': <String, dynamic>{'provider': 'a', 'model': 'b'},
          },
        ],
      });
      expect(snapshot.writable, isFalse);
      expect(snapshot.defaultModelSection?.defaultModelRoute?.label, 'a/b');
    });

    test('顶层不是列表时抛可重试的读取失败', () {
      expect(
        () => parseRemoteDshSettings(<String, dynamic>{'unexpected': true}),
        throwsA(
          isA<PlatformException>().having(
            (failure) => failure.code,
            'code',
            'remote/bad-response',
          ),
        ),
      );
    });

    test('模型目录解析出分组、模型与推理强度', () {
      final catalog = parseRemoteDshModelCatalog(<String, dynamic>{
        'groups': <dynamic>[
          <String, dynamic>{
            'id': 'deepseek-account',
            'name': 'DeepSeek 账号',
            'models': <dynamic>[
              <String, dynamic>{
                'id': 'deepseek-v4-pro',
                'name': 'DeepSeek-V4-Pro',
                'reasoning': <String, dynamic>{
                  'efforts': <dynamic>[
                    <String, dynamic>{'id': 'high', 'name': '高'},
                  ],
                  'defaultEffort': 'high',
                },
              },
            ],
          },
        ],
        'failures': <dynamic>[
          <String, dynamic>{'name': '其他服务', 'message': '没有凭据'},
        ],
      });

      expect(catalog.groups.single.id, 'deepseek-account');
      expect(
        catalog.groups.single.models.single.reasoning?.efforts.single.id,
        'high',
      );
      expect(catalog.failures, <String>['其他服务：没有凭据']);
      expect(catalog.isEmpty, isFalse);
    });

    test('模型目录格式不对时抛坏响应', () {
      expect(
        () => parseRemoteDshModelCatalog(<dynamic>['not', 'a', 'map']),
        throwsA(
          isA<PlatformException>().having(
            (failure) => failure.code,
            'code',
            'remote/bad-response',
          ),
        ),
      );
    });
  });

  group('能力判定', () {
    RemoteHostInfo host({
      List<String> methods = const <String>[],
      List<String> unsupported = const <String>[],
    }) => RemoteHostInfo(
      protocolVersion: 1,
      name: '客厅的电脑',
      platform: 'win32',
      home: r'C:\DSH',
      methods: methods,
      unsupported: unsupported,
      capabilities: const <String>[],
    );

    test('全部方法都声明时可用', () {
      final capability = remoteDshCapabilityOf(
        host(methods: <String>['workspace.files.*']),
        <String>['workspace.files.list', 'workspace.files.read'],
      );
      expect(capability.state, RemoteDshCapabilityState.available);
      expect(capability.reason, isNull);
    });

    test('unsupported 优先于 methods 并给出原因', () {
      final capability = remoteDshCapabilityOf(
        host(
          methods: <String>['workspace.files.*'],
          unsupported: <String>['workspace.files.read'],
        ),
        <String>['workspace.files.list', 'workspace.files.read'],
      );
      expect(capability.state, RemoteDshCapabilityState.unavailable);
      expect(capability.reason, contains('workspace.files.read'));
    });

    test('方法表里缺方法时按未声明处理并点名方法', () {
      final capability = remoteDshCapabilityOf(
        host(methods: <String>['workspace.files.list']),
        <String>['workspace.files.list', 'workspace.files.read'],
      );
      expect(capability.state, RemoteDshCapabilityState.notDeclared);
      expect(capability.reason, contains('workspace.files.read'));
    });

    test('还没握手时按未声明处理', () {
      final capability = remoteDshCapabilityOf(null, <String>[
        'settings.describe',
        'settings.mutate',
      ]);
      expect(capability.state, RemoteDshCapabilityState.notDeclared);
      expect(capability.isAvailable, isFalse);
    });
  });
}
