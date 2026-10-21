import 'dart:convert';

import 'package:dsh_android/diagnostics.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class _Runtime extends RuntimeController {
  _Runtime() {
    phase = 'failed';
    error = 'Node startup failed';
  }
  int restarts = 0;
  bool reject = false;
  List<Json> observations = [];
  int calls = 0;
  @override
  List<Json> get observationDiagnostics => observations;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls++;
    throw StateError('Diagnostics must not make runtime calls');
  }

  @override
  Future<void> restart() async {
    restarts++;
    phase = 'starting';
    error = null;
    notifyListeners();
    if (reject) {
      this.fail(StateError('Old service did not exit'));
      throw StateError('Old service did not exit');
    }
  }

  void readyNow() {
    phase = 'ready';
    notifyListeners();
  }
}

Widget _host(_Runtime runtime) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  home: DiagnosticsPage(runtime: runtime),
);

void main() {
  testWidgets('observation stages can be refreshed and copied without RPCs', (
    tester,
  ) async {
    final runtime = _Runtime()
      ..error = null
      ..observations = [
        {
          'namespace': 'account',
          'method': 'watch',
          'state': 'waiting-first-frame',
          'sequence': 0,
        },
      ];
    addTearDown(runtime.dispose);
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(_host(runtime));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('刷新观察状态'), 200);
    await tester.pumpAndSettle();
    expect(find.text('account.watch'), findsOneWidget);
    expect(find.text('等待首帧 · 已接收序号 0'), findsOneWidget);

    runtime.observations = [
      {
        'namespace': 'account',
        'method': 'watch',
        'state': 'received',
        'sequence': 2,
      },
    ];
    await tester.tap(find.text('刷新观察状态'));
    await tester.pumpAndSettle();
    expect(find.text('已接收 · 已接收序号 2'), findsOneWidget);
    expect(runtime.calls, 0);
    expect(runtime.restarts, 0);

    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is GlassButton && widget.label == '复制运行诊断',
      ),
    );
    await tester.pumpAndSettle();
    expect(jsonDecode(copied!), {
      'phase': 'failed',
      'error': null,
      'lastFailure': null,
      'environment': {},
      'observations': [
        {
          'namespace': 'account',
          'method': 'watch',
          'state': 'received',
          'sequence': 2,
        },
      ],
    });
    expect(runtime.calls, 0);
  });

  test('all observation stages have diagnostic labels', () {
    expect(observationStage('waiting-service'), '等待服务就绪');
    expect(observationStage('subscribing'), '正在发起订阅');
    expect(observationStage('waiting-first-frame'), '等待首帧');
    expect(observationStage('received'), '已接收');
    expect(observationStage('disconnected'), '已断开，等待重连');
  });

  testWidgets('recovery requires a decision and actual ready after admission', (
    tester,
  ) async {
    final runtime = _Runtime();
    addTearDown(runtime.dispose);
    await tester.pumpWidget(_host(runtime));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重启本地服务'));
    await tester.pumpAndSettle();
    expect(runtime.restarts, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(runtime.restarts, 0);
    await tester.tap(find.text('重启本地服务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认重启'));
    await tester.pumpAndSettle();
    expect(runtime.restarts, 1);
    expect(find.text('本地服务已重新就绪。'), findsNothing);
    expect(find.text('确认重启'), findsNothing);
    await tester.ensureVisible(find.text('查看错误详情'));
    await tester.tap(find.text('查看错误详情'));
    await tester.pumpAndSettle();
    expect(find.text('Node startup failed'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    runtime.readyNow();
    await tester.pumpAndSettle();
    expect(find.text('本地服务已重新就绪。'), findsOneWidget);
    expect(find.text('重启本地服务'), findsOneWidget);
  });

  testWidgets('recovery failure is visible and permits an explicit retry', (
    tester,
  ) async {
    final runtime = _Runtime()..reject = true;
    addTearDown(runtime.dispose);
    await tester.pumpWidget(_host(runtime));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重启本地服务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认重启'));
    await tester.pumpAndSettle();
    expect(find.textContaining('未能恢复本地服务'), findsOneWidget);
    expect(find.text('本地服务已重新就绪。'), findsNothing);
    expect(find.text('重启本地服务'), findsOneWidget);
    runtime.reject = false;
    await tester.tap(find.text('重启本地服务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认重启'));
    await tester.pumpAndSettle();
    expect(runtime.restarts, 2);
    expect(find.textContaining('未能恢复本地服务'), findsNothing);
  });
}
