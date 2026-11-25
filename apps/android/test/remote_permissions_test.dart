// B3：远程权限预设 —— 目录/当前值解析、三态与二次确认门槛。
//
// 这些测试不连宿主：目录、能力探测与投影由
// `test/support/remote_conversation_fakes.dart` 的假数据源应答，弹层是纯展示组件。
// 覆盖设计文档 §4.5 / §4.6 B3 的测试点：catalog 解析、`/permission <值>` 的线上
// 参数、`danger-full-access` 的二次确认门槛、宿主未启用权限预设时的三态、目录
// 读取失败可重试（不写永久不支持缓存）、切换后重读投影。

import 'package:dsh_android/composer_commands.dart';
import 'package:dsh_android/remote_connection.dart';
import 'package:dsh_android/remote_conversation_source.dart';
import 'package:dsh_android/remote_dsh_widgets.dart';
import 'package:dsh_android/remote_permissions.dart';
import 'package:dsh_android/runtime_transport.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/remote_conversation_fakes.dart';

/// `permissionPresets.catalog` 的真实形状（`PermissionCatalog`）。
Map<String, dynamic> _catalogJson() => <String, dynamic>{
  'options': <Map<String, dynamic>>[
    <String, dynamic>{
      'value': 'read-only',
      'name': 'read-only',
      'description': 'Read-only file access.',
    },
    <String, dynamic>{
      'value': 'workspace-write',
      'name': 'workspace-write',
      'description': 'Write inside the workspace.',
    },
    <String, dynamic>{
      'value': 'danger-full-access',
      'name': 'danger-full-access',
      'description': 'Full file access without approval prompts.',
    },
  ],
  'defaultOptions': <Map<String, dynamic>>[
    <String, dynamic>{'value': 'workspace-write', 'name': 'workspace-write'},
  ],
  'defaultPreset': 'workspace-write',
};

/// `runtime.permissions` 的桌面形状（远程宿主不回答 Android 的 `android_shell`）。
Map<String, dynamic> _runtimePermissions({required bool available}) =>
    <String, dynamic>{
      'shell': <String, dynamic>{
        'tool': 'desktop-host',
        'available': false,
        'reason': 'desktop-remote-host',
        'executionIdentity': null,
        'approval': 'unavailable',
        'workspaceConfinement': false,
      },
      'fileTools': <String, dynamic>{'sandboxMode': 'workspace-write'},
      'presets': <String, dynamic>{'available': available},
    };

/// `session.projections` 的返回：只带权限投影时页面也应当能读。
Map<String, dynamic> _projections(String currentValue) => <String, dynamic>{
  'kind': 'sequenced',
  'asOfSeq': 3,
  'values': <String, dynamic>{
    'permissions': <String, dynamic>{'currentValue': currentValue},
  },
};

List<RemotePermissionOption> _options() => const <RemotePermissionOption>[
  RemotePermissionOption(value: 'read-only', name: 'read-only'),
  RemotePermissionOption(
    value: 'workspace-write',
    name: 'workspace-write',
    description: 'Write inside the workspace.',
  ),
  RemotePermissionOption(
    value: 'danger-full-access',
    name: 'danger-full-access',
    description: 'Full file access without approval prompts.',
  ),
];

const Set<String> _baseSupported = <String>{
  remoteConversationReadMethod,
  remoteConversationSendMethod,
  remoteConversationCommandMethod,
  remoteConversationRenameMethod,
  remoteConversationInteractionsListMethod,
  remoteConversationInteractionsReplyMethod,
  remoteConversationApiCallMethod,
};

/// 一个会话页假数据源：默认电脑启用了权限预设、当前是 workspace-write。
FakeRemoteConversationSource _source({
  bool presetsAvailable = true,
  bool supportsProbe = true,
}) {
  final source = FakeRemoteConversationSource(
    supported: <String>{
      ..._baseSupported,
      if (supportsProbe) remotePermissionRuntimeMethod,
    },
  )..projections = _projections('workspace-write');
  source.answers[remotePermissionRuntimeMethod] = (_) =>
      _runtimePermissions(available: presetsAvailable);
  return source;
}

/// 打开权限预设弹层（`showRemotePermissionSheet` + `RemotePermissionSheet`）。
Future<void> _openSheet(
  WidgetTester tester,
  RemotePermissionSheet sheet,
) async {
  // 先清掉上一次测试残留的弹层路由，避免遮罩挡住新的打开按钮。
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () =>
                  showRemotePermissionSheet(context, builder: (_) => sheet),
              child: const Text('打开权限预设'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开权限预设'));
  await tester.pumpAndSettle();
}

void main() {
  group('catalog / 能力 / 当前值解析', () {
    test('目录按宿主形状解析：顺序、显示名回退与默认预设', () {
      final catalog = RemotePermissionCatalog.parse(_catalogJson());
      expect(catalog.options.map((option) => option.value), <String>[
        'read-only',
        'workspace-write',
        'danger-full-access',
      ]);
      expect(catalog.options.first.name, 'read-only');
      expect(
        catalog.options.last.description,
        'Full file access without approval prompts.',
      );
      expect(catalog.defaultPreset, 'workspace-write');
      expect(catalog.optionOf('workspace-write')?.value, 'workspace-write');
      expect(catalog.optionOf('missing'), isNull);
      expect(() => RemotePermissionCatalog.parse(null), throwsFormatException);
      expect(
        () => RemotePermissionCatalog.parse(<String, dynamic>{
          'defaultPreset': 'x',
        }),
        throwsFormatException,
      );
    });

    test('目录里形状不完整的项被跳过，不拖垮整个入口', () {
      final catalog = RemotePermissionCatalog.parse(<String, dynamic>{
        'options': <Object?>[
          <String, dynamic>{'value': ''},
          <String, dynamic>{'name': 'no value'},
          'not an object',
          <String, dynamic>{'value': 'auto', 'name': 'auto'},
        ],
        'defaultPreset': 3,
      });
      expect(catalog.options.single.value, 'auto');
      expect(catalog.defaultPreset, isNull);
    });

    test('runtime.permissions 只取 presets.available，不要求 Android 形状', () {
      expect(
        remotePermissionPresetsAvailable(_runtimePermissions(available: true)),
        isTrue,
      );
      expect(
        remotePermissionPresetsAvailable(_runtimePermissions(available: false)),
        isFalse,
      );
      expect(
        () => remotePermissionPresetsAvailable(<String, dynamic>{
          'shell': <String, dynamic>{},
        }),
        throwsFormatException,
      );
      expect(
        () => remotePermissionPresetsAvailable(null),
        throwsFormatException,
      );
    });

    test('当前预设来自 session.projections 的 values.permissions', () {
      expect(remotePermissionCurrentValue(_projections('auto')), 'auto');
      expect(
        remotePermissionCurrentValue(<String, dynamic>{
          'kind': 'sequenced',
          'values': <String, dynamic>{},
        }),
        isNull,
      );
      expect(remotePermissionCurrentValue(null), isNull);
    });

    test('显示名与风险门槛与本地权限页共用', () {
      expect(
        permissionPresetLabel('workspace-write', 'workspace-write'),
        '工作区内修改',
      );
      expect(
        permissionPresetLabel('plugin-preset', 'Plugin preset'),
        'Plugin preset',
      );
      expect(permissionPresetNeedsConfirmation('danger-full-access'), isTrue);
      expect(permissionPresetNeedsConfirmation('auto'), isTrue);
      expect(permissionPresetNeedsConfirmation('workspace-write'), isFalse);
    });
  });

  group('RemotePermissionController', () {
    test('能力探测可用时读当前值，未就绪时保持 pending', () async {
      final source = _source();
      final controller = RemotePermissionController(source: source);
      addTearDown(controller.dispose);

      expect(controller.availability, RemotePermissionAvailability.pending);
      await controller.start();
      expect(controller.availability, RemotePermissionAvailability.available);
      expect(controller.presetsReady, isTrue);
      expect(controller.currentValue, 'workspace-write');
      expect(controller.currentLabel, '工作区内修改');
      expect(
        source.requests.single.method,
        remotePermissionRuntimeMethod,
        reason: '先探测宿主能力',
      );
      expect(source.projectionReads, 1);
    });

    test('未连接时不发请求，探测保持 pending', () async {
      final source = _source()..phase = RemoteConnectionPhase.connecting;
      final controller = RemotePermissionController(source: source);
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.availability, RemotePermissionAvailability.pending);
      expect(controller.presetsReady, isFalse);
      expect(source.requests, isEmpty);
      expect(source.projectionReads, 0);
    });

    test('presets.available=false 时入口置灰并给出原因', () async {
      final source = _source(presetsAvailable: false);
      final controller = RemotePermissionController(source: source);
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.availability, RemotePermissionAvailability.unavailable);
      expect(controller.unavailableReason, '这台电脑未启用权限预设');
      expect(controller.presetsReady, isFalse);
    });

    test('方法表里没有 runtime.permissions 时按未启用处理，不发请求', () async {
      final source = _source(supportsProbe: false);
      final controller = RemotePermissionController(source: source);
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.availability, RemotePermissionAvailability.unavailable);
      expect(controller.unavailableReason, '这台电脑未启用权限预设');
      expect(source.requests, isEmpty);
    });

    test('探测遇到断连时保持 pending，重连后重新探测', () async {
      final source = _source();
      source.answers[remotePermissionRuntimeMethod] = (_) =>
          throw const RuntimeTransportFailure(
            code: 'gateway/unavailable',
            message: '连接已断开',
          );
      final controller = RemotePermissionController(source: source);
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.availability, RemotePermissionAvailability.pending);

      source.answers[remotePermissionRuntimeMethod] = (_) =>
          _runtimePermissions(available: true);
      source.setPhase(RemoteConnectionPhase.reconnecting);
      expect(controller.availability, RemotePermissionAvailability.pending);
      await pumpEventQueue();
      source.setPhase(RemoteConnectionPhase.ready);
      await pumpEventQueue();
      expect(controller.availability, RemotePermissionAvailability.available);
      expect(controller.currentValue, 'workspace-write');
    });

    test('目录读取失败只记录错误可重试，不写永久不支持缓存', () async {
      final source = _source();
      final controller = RemotePermissionController(source: source);
      addTearDown(controller.dispose);
      await controller.start();

      var failing = true;
      source.answers['api.call'] = (params) {
        if (failing) throw StateError('目录不可用');
        return _catalogJson();
      };
      await controller.loadCatalog();
      expect(controller.catalog, isNull);
      expect(controller.catalogError, contains('无法读取权限预设'));
      expect(controller.availability, RemotePermissionAvailability.available);

      failing = false;
      await controller.loadCatalog();
      expect(controller.catalogError, isNull);
      expect(controller.catalog?.defaultPreset, 'workspace-write');
      expect(source.ensureCalls, 0, reason: '全局目录读取无需等待会话恢复');
      final calls = source.requests
          .where(
            (request) =>
                request.method == 'api.call' &&
                request.params['namespace'] == 'permissionPresets',
          )
          .toList();
      expect(calls, hasLength(2), reason: '失败后重试会重新请求，不复用失败结果');
      expect(calls.last.params, <String, dynamic>{
        'namespace': 'permissionPresets',
        'method': 'catalog',
        'args': <String, dynamic>{},
      });
    });

    test('切换预设写 /permission 指令，成功后重读投影并更新回显', () async {
      final source = _source();
      final controller = RemotePermissionController(source: source);
      addTearDown(controller.dispose);
      await controller.start();
      expect(source.projectionReads, 1);

      source.answers['session.command'] = (params) {
        source.projections = _projections('danger-full-access');
        return <String, dynamic>{
          'commandId': 'command-1',
          'result': <String, dynamic>{
            'kind': 'success',
            'text': 'preset danger-full-access',
          },
        };
      };

      expect(await controller.apply('danger-full-access'), isNull);
      final command = source.requests.singleWhere(
        (request) => request.method == 'session.command',
      );
      expect(command.params, <String, dynamic>{
        'sessionId': 's-1',
        'line': '/permission danger-full-access',
        'attachmentIds': <String>[],
      });
      expect(controller.currentValue, 'danger-full-access');
      expect(controller.currentLabel, '完全权限');
      expect(source.projectionReads, 2, reason: '写回后以宿主投影为准');
    });

    test('切换失败返回宿主原因，不刷新当前值', () async {
      final source = _source();
      final controller = RemotePermissionController(source: source);
      addTearDown(controller.dispose);
      await controller.start();

      source.answers['session.command'] = (_) => <String, dynamic>{
        'commandId': 'command-1',
        'result': <String, dynamic>{
          'kind': 'error',
          'text': 'unknown preset "nope"',
        },
      };
      expect(await controller.apply('nope'), 'unknown preset "nope"');
      expect(controller.currentValue, 'workspace-write');
      expect(source.projectionReads, 1);
    });

    test('传输失败与未识别指令都给出可展示的未确认说明', () async {
      final source = _source();
      final controller = RemotePermissionController(source: source);
      addTearDown(controller.dispose);
      await controller.start();

      source.answers['session.command'] = (_) =>
          throw const RuntimeTransportFailure(
            code: 'gateway/cancelled',
            message: '连接已断开，请重试。',
          );
      expect(await controller.apply('read-only'), contains('操作未确认'));

      source.answers['session.command'] = (_) => null;
      expect(await controller.apply('read-only'), contains('没有识别'));
    });
  });

  group('RemotePermissionSheet', () {
    testWidgets('按目录渲染、当前项打勾；普通预设直接提交并收起弹层', (tester) async {
      final applied = <String>[];
      await _openSheet(
        tester,
        RemotePermissionSheet(
          options: _options(),
          currentValue: 'workspace-write',
          onApply: (value) async {
            applied.add(value);
            return null;
          },
        ),
      );

      expect(find.text('仅可查看'), findsOneWidget);
      expect(find.text('工作区内修改'), findsOneWidget);
      expect(find.text('完全权限'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);

      await tester.tap(find.text('仅可查看'));
      await tester.pumpAndSettle();
      expect(applied, <String>['read-only']);
      expect(
        find.byType(RemotePermissionSheet),
        findsNothing,
        reason: '成功后退回会话页',
      );
    });

    testWidgets('完全权限必须先勾选风险确认，取消回到列表', (tester) async {
      final applied = <String>[];
      await _openSheet(
        tester,
        RemotePermissionSheet(
          options: _options(),
          currentValue: 'workspace-write',
          onApply: (value) async {
            applied.add(value);
            return null;
          },
        ),
      );

      await tester.tap(find.text('完全权限'));
      await tester.pumpAndSettle();
      expect(find.text('确认启用完全权限？'), findsOneWidget);
      expect(applied, isEmpty, reason: '只点选项不提交');
      await tester.tap(find.text('启用'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(applied, isEmpty, reason: '未勾选风险确认时启用不可用');

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('仅可查看'), findsOneWidget, reason: '取消回到预设列表');

      await tester.tap(find.text('完全权限'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我已了解风险，并愿意继续'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('启用'));
      await tester.pumpAndSettle();
      expect(applied, <String>['danger-full-access']);
    });

    testWidgets('提交失败时弹层保留并显示原因', (tester) async {
      await _openSheet(
        tester,
        RemotePermissionSheet(
          options: _options(),
          currentValue: 'workspace-write',
          onApply: (value) async => '电脑没有接受这次权限切换。',
        ),
      );

      await tester.tap(find.text('仅可查看'));
      await tester.pumpAndSettle();
      expect(find.byType(RemotePermissionSheet), findsOneWidget);
      expect(find.text('电脑没有接受这次权限切换。'), findsOneWidget);
    });

    testWidgets('读取中与读取失败的状态都在弹层内，失败可重试', (tester) async {
      var retries = 0;
      await _openSheet(
        tester,
        RemotePermissionSheet(
          options: const <RemotePermissionOption>[],
          loading: true,
        ),
      );
      expect(find.text('正在读取权限预设…'), findsOneWidget);

      await _openSheet(
        tester,
        RemotePermissionSheet(
          options: const <RemotePermissionOption>[],
          error: '无法读取权限预设：连接中断',
          onRetry: () => retries++,
        ),
      );
      expect(find.text('无法读取权限预设'), findsOneWidget);
      expect(find.textContaining('连接中断'), findsOneWidget);
      await tester.tap(find.text('重新读取'));
      await tester.pumpAndSettle();
      expect(retries, 1);
    });
  });
}
