import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/settings.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Future<RuntimeController> openSettings(
  WidgetTester tester,
  Future<dynamic> Function(MethodCall) native,
) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final runtime = RuntimeController();
  addTearDown(runtime.dispose);
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(RuntimeController.channel, native);
  addTearDown(
    () => messenger.setMockMethodCallHandler(RuntimeController.channel, null),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: SettingsPage(runtime: runtime),
    ),
  );
  return runtime;
}

void main() {
  testWidgets('shows installed metadata without requiring a ready Agent', (
    tester,
  ) async {
    final response = Completer<String>();
    var reads = 0;
    final runtime = await openSettings(tester, (call) {
      expect(call.method, 'app.metadata');
      expect(call.arguments, isNull);
      reads++;
      return response.future;
    });
    expect(runtime.ready, isFalse);
    expect(find.text('正在读取版本信息…'), findsOneWidget);
    response.complete(jsonEncode({'version': '2.3.4', 'build': 987}));
    await tester.pumpAndSettle();
    expect(find.text('2.3.4 · 构建 987 · 开发预览'), findsOneWidget);
    runtime.notifyListeners();
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(tester.takeException(), isNull);
  });

  for (final failure in ['channel', 'invalid', 'timeout']) {
    testWidgets('retries $failure metadata without a fabricated version', (
      tester,
    ) async {
      var reads = 0;
      final pending = Completer<String>();
      await openSettings(tester, (call) async {
        expect(call.method, 'app.metadata');
        if (++reads > 1) {
          return jsonEncode({'version': '4.5.6', 'build': 1234});
        }
        if (failure == 'channel') {
          throw PlatformException(code: 'metadata-unavailable');
        }
        if (failure == 'timeout') return pending.future;
        return jsonEncode({'version': '4.5.6', 'build': 'unknown'});
      });
      await tester.pump();
      if (failure == 'timeout') {
        await tester.pump(const Duration(seconds: 11));
      }
      await tester.pumpAndSettle();
      expect(find.text('版本信息暂不可用 · 点按重试'), findsOneWidget);
      expect(find.textContaining(' · 构建 '), findsNothing);
      await tester.tap(find.byKey(const ValueKey('installed-app-version')));
      await tester.pumpAndSettle();
      expect(find.text('4.5.6 · 构建 1234 · 开发预览'), findsOneWidget);
      expect(reads, 2);
      if (failure == 'timeout') {
        pending.complete(jsonEncode({'version': 'old', 'build': 1}));
        await tester.pumpAndSettle();
        expect(find.text('4.5.6 · 构建 1234 · 开发预览'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
