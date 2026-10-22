import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/session_browser.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'browser entry refuses local addresses and launches Custom Tabs path',
    (tester) async {
      final runtime = RuntimeController()
        ..phase = 'ready'
        ..web = {'phase': 'listening', 'host': '127.0.0.1', 'port': 3080};
      addTearDown(runtime.dispose);
      final calls = <MethodCall>[];
      const channel = MethodChannel('dsh/runtime');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: SessionBrowserPage(runtime: runtime),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AndroidView), findsNothing);

      for (final address in [
        'http://localhost:3080/',
        'http://localhost:4040/',
        'http://192.168.1.5/',
      ]) {
        await tester.enterText(
          find.byKey(const ValueKey('browser-address')),
          address,
        );
        await tester.tap(find.byTooltip('打开网址'));
        await tester.pump();
        expect(find.text('请输入有效的远程网页地址。'), findsOneWidget);
      }
      expect(calls.where((call) => call.method == 'browser.open'), isEmpty);

      await tester.enterText(
        find.byKey(const ValueKey('browser-address')),
        'example.org',
      );
      await tester.tap(find.byTooltip('打开网址'));
      await tester.pumpAndSettle();
      expect(
        calls.where((call) => call.method == 'browser.open').single.arguments,
        'https://example.org',
      );
      expect(find.byKey(const ValueKey('browser-history')), findsOneWidget);
      expect(find.text('https://example.org'), findsNWidgets(2));
      expect(find.byType(AndroidView), findsNothing);
    },
  );

  testWidgets('failed native browser launch does not enter history', (
    tester,
  ) async {
    final runtime = RuntimeController()..phase = 'ready';
    addTearDown(runtime.dispose);
    const channel = MethodChannel('dsh/runtime');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(
        code: 'browser/unavailable',
        message: '没有浏览器',
      ),
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: SessionBrowserPage(runtime: runtime),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('browser-address')),
      'example.org',
    );
    await tester.tap(find.byTooltip('打开网址'));
    await tester.pumpAndSettle();
    expect(find.text('没有浏览器'), findsOneWidget);
    expect(find.byKey(const ValueKey('browser-history')), findsNothing);
  });
}
