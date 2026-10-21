import 'dart:async';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/settings.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class WebTestRuntime extends RuntimeController {
  Json status = {
    'enabled': false,
    'scope': 'local',
    'port': 3080,
    'phase': 'disabled',
  };
  final writes = <Json>[];
  Future<Json> Function()? read;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    switch (method) {
      case 'web.status':
        return read == null ? Map<String, dynamic>.of(status) : read!();
      case 'web.configure':
        writes.add(Map.of(params));
        status = {
          ...status,
          ...params,
          'phase': params['enabled'] == true ? 'listening' : 'disabled',
          'host': params['scope'] == 'lan' ? '192.168.1.2' : '127.0.0.1',
          'url': 'http://127.0.0.1:${params['port']}/?token=test-only',
        };
        return Map<String, dynamic>.of(status);
      default:
        throw StateError('Unexpected Web operation $method');
    }
  }
}

void main() {
  late WebTestRuntime runtime;
  setUp(() => runtime = WebTestRuntime());
  tearDown(() => runtime.dispose());

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: WebSettingsPage(runtime: runtime),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String title) async {
    final target = find.text(title);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets('scope changes preserve unapplied port drafts', (tester) async {
    await mount(tester);
    await tester.enterText(find.byType(TextField), '9090');
    await tester.pump();
    await tap(tester, '局域网');
    expect(runtime.writes.single['scope'], 'lan');
    expect(runtime.writes.single['port'], 3080);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '9090',
    );
    await tap(tester, '保存端口');
    expect(runtime.writes.last['port'], 9090);
    expect(find.text('保存端口'), findsNothing);
  });

  testWidgets('invalid ports are visible and never submitted', (tester) async {
    await mount(tester);
    await tester.enterText(find.byType(TextField), '99999');
    await tester.pump();
    await tap(tester, '保存端口');
    expect(runtime.writes, isEmpty);
    expect(find.text('请输入 1024–65535 之间的端口。'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '99999',
    );
  });

  testWidgets('refresh keeps drafts and failed reads remove access actions', (
    tester,
  ) async {
    runtime.status = {
      ...runtime.status,
      'enabled': true,
      'phase': 'listening',
      'host': '127.0.0.1',
      'url': 'http://127.0.0.1:3080/?token=test-only',
    };
    await mount(tester);
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '9090');
    await tester.pump();
    runtime.status = {...runtime.status, 'port': 8080};
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is GlassButton && widget.label == '刷新 Web 状态',
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '9090',
    );
    runtime.read = () async => throw StateError('Service disconnected');
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is GlassButton && widget.label == '刷新 Web 状态',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('打开浏览器'), findsNothing);
    expect(find.text('复制访问链接'), findsNothing);
    expect(find.text('状态尚未确认'), findsOneWidget);
    expect(find.textContaining('Web 状态未确认'), findsOneWidget);
  });

  testWidgets('an older status read cannot undo a newer scope change', (
    tester,
  ) async {
    await mount(tester);
    final pending = Completer<Json>();
    final old = Map<String, dynamic>.of(runtime.status);
    runtime.read = () => pending.future;
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is GlassButton && widget.label == '刷新 Web 状态',
      ),
    );
    await tester.pump();
    await tap(tester, '局域网');
    pending.complete(old);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SegmentedControl<String>>(
            find.byType(SegmentedControl<String>),
          )
          .value,
      'lan',
    );
    expect(runtime.writes.length, 1);
  });
}
