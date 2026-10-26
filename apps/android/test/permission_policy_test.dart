import 'dart:async';

import 'package:dsh_android/permission_policy.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Json snapshot({
  String? fileMode = 'workspace-write',
  bool presets = false,
  bool legacyShell = false,
}) => {
  'shell': legacyShell
      ? {
          'tool': 'android_shell',
          'executionIdentity': 'app-uid',
          'approval': 'every-invocation',
          'workspaceConfinement': false,
        }
      : {
          'tool': 'android_shell',
          'available': false,
          'reason': 'isolated-executor-unavailable',
          'executionIdentity': null,
          'approval': 'unavailable',
          'workspaceConfinement': false,
        },
  'fileTools': {'sandboxMode': fileMode},
  'presets': {'available': presets},
  'programmaticTools': {
    'available': false,
    'filesystem': 'read-only',
    'writableRoots': [],
    'network': 'off',
    'reason': 'isolated-executor-unwired',
  },
};

class PolicyRuntime extends RuntimeController {
  PolicyRuntime() {
    phase = 'ready';
  }

  Json value = snapshot();
  Future<Json>? pending;
  int reads = 0;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    expect(method, 'runtime.permissions');
    expect(params, isEmpty);
    reads++;
    return pending ?? value;
  }

  void disconnect() => super.fail('connection lost');

  void reconnect() {
    phase = 'ready';
    notifyListeners();
  }
}

Future<void> open(WidgetTester tester, PolicyRuntime runtime) async {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: ExecutionPermissionsPage(runtime: runtime),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('malformed or falsely confined Shell policy is never displayed', () {
    final invalid = snapshot();
    (invalid['shell'] as Json)['workspaceConfinement'] = true;
    expect(
      () => ExecutionPermissionPolicy.parse(invalid),
      throwsFormatException,
    );
    expect(
      () => ExecutionPermissionPolicy.parse({'fileTools': {}}),
      throwsFormatException,
    );
    expect(
      ExecutionPermissionPolicy.parse(snapshot(fileMode: null)).fileSummary,
      '文件工具策略未确认',
    );
    expect(ExecutionPermissionPolicy.parse(snapshot()).shellAvailable, false);
    expect(
      ExecutionPermissionPolicy.parse(snapshot(legacyShell: true))
          .shellAvailable,
      true,
    );
    final falselyAvailable = snapshot();
    (falselyAvailable['shell'] as Json)['available'] = true;
    expect(
      () => ExecutionPermissionPolicy.parse(falselyAvailable),
      throwsFormatException,
    );
    for (final change in <void Function(Json)>{
      (value) => (value['programmaticTools'] as Json)['available'] = true,
      (value) => (value['programmaticTools'] as Json)['filesystem'] =
          'workspace-write',
      (value) => (value['programmaticTools'] as Json)['writableRoots'] = [
        'private-data',
      ],
      (value) => (value['programmaticTools'] as Json)['network'] = 'restricted',
    }) {
      final value = snapshot();
      change(value);
      expect(
        () => ExecutionPermissionPolicy.parse(value),
        throwsFormatException,
      );
    }
  });

  testWidgets('read-only page shows actual Shell and file-tool boundaries', (
    tester,
  ) async {
    final runtime = PolicyRuntime();
    await open(tester, runtime);
    expect(runtime.reads, 1);
    expect(find.textContaining('模型不能运行任意命令'), findsOneWidget);
    expect(find.textContaining('默认限于工作区'), findsOneWidget);
    expect(find.textContaining('隔离 Shell 尚未就绪'), findsWidgets);
    expect(find.text('脚本执行沙箱'), findsOneWidget);
    expect(find.text('文件：只读'), findsOneWidget);
    expect(find.text('网络：关闭'), findsOneWidget);
    expect(find.textContaining('尚未接入模型工具'), findsOneWidget);
    expect(find.textContaining('插件与自定义配置'), findsOneWidget);
    expect(find.textContaining('不受隔离脚本的路径和网络策略约束'), findsOneWidget);
    expect(find.byType(PocketSwitchRow), findsNothing);
  });

  testWidgets('explicit internal migration mode is labeled as unconfined', (
    tester,
  ) async {
    final runtime = PolicyRuntime()..value = snapshot(legacyShell: true);
    await open(tester, runtime);
    expect(find.textContaining('内部迁移模式：以 App 身份运行'), findsOneWidget);
    expect(find.textContaining('无路径或网络隔离'), findsOneWidget);
    expect(find.textContaining('模型不能运行任意命令'), findsNothing);
  });

  testWidgets(
    'disconnect discards a late policy reply and rereads on recovery',
    (tester) async {
      final runtime = PolicyRuntime();
      final pending = Completer<Json>();
      runtime.pending = pending.future;
      await open(tester, runtime);
      expect(runtime.reads, 1);
      runtime.disconnect();
      await tester.pump();
      expect(find.textContaining('默认限于工作区'), findsNothing);
      runtime.pending = null;
      runtime.value = snapshot(fileMode: 'read-only');
      runtime.reconnect();
      await tester.pumpAndSettle();
      expect(runtime.reads, 2);
      expect(find.textContaining('只读；修改请求'), findsOneWidget);
      pending.complete(snapshot(fileMode: 'danger-full-access'));
      await tester.pumpAndSettle();
      expect(find.textContaining('只读；修改请求'), findsOneWidget);
      expect(find.textContaining('未受工作区范围限制'), findsNothing);
    },
  );
}
