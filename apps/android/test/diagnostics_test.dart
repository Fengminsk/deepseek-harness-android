import 'package:dsh_android/diagnostics.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Runtime extends RuntimeController {
  _Runtime() {
    phase = 'failed';
    error = 'Node startup failed';
  }
  int restarts = 0;
  bool reject = false;
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
    expect(find.text('Node startup failed'), findsOneWidget);
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
