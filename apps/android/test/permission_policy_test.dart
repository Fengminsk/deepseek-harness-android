import 'dart:async';

import 'package:dsh_android/permission_policy.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Json snapshot({String? fileMode = 'workspace-write', bool presets = false}) => {
  'shell': {
    'tool': 'android_shell',
    'executionIdentity': 'app-uid',
    'approval': 'every-invocation',
    'workspaceConfinement': false,
  },
  'fileTools': {'sandboxMode': fileMode},
  'presets': {'available': presets},
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
  });

  testWidgets('read-only page shows actual Shell and file-tool boundaries', (
    tester,
  ) async {
    final runtime = PolicyRuntime();
    await open(tester, runtime);
    expect(runtime.reads, 1);
    expect(find.textContaining('每条命令执行前都需单次授权'), findsOneWidget);
    expect(find.textContaining('默认限于工作区'), findsOneWidget);
    expect(find.textContaining('Shell 尚无逐命令文件隔离'), findsOneWidget);
    expect(find.byType(PocketSwitchRow), findsNothing);
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
