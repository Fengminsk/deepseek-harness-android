import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:dsh_android/appearance.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String stored = '{}';
  bool reject = false;
  setUp(() {
    stored = '{}';
    reject = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RuntimeController.channel, (call) async {
          if (call.method == 'appearance.load') return stored;
          if (call.method == 'appearance.save') {
            if (reject) throw PlatformException(code: 'disk', message: '无法保存');
            stored = call.arguments as String;
            return null;
          }
          throw MissingPluginException();
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RuntimeController.channel, null),
  );
  test('theme choices restore after a controller restart and a failed save preserves the previous choice', () async {
    final first = AppearanceController();
    await first.load();
    await first.update({
      'mode': 'dark',
      'glass': 'none',
      'pureBlack': true,
      'seed': 0xff4268b3,
    });
    final second = AppearanceController();
    await second.load();
    expect(second.mode, ThemeMode.dark);
    expect(second.glassEnabled, false);
    expect(second.pureBlack, true);
    expect(second.seed, 0xff4268b3);
    reject = true;
    await second.update({'mode': 'light'});
    expect(second.mode, ThemeMode.dark);
    expect(jsonDecode(stored)['mode'], 'dark');
    expect(second.error, contains('未保存'));
    first.dispose();
    second.dispose();
  });
  testWidgets(
    'theme controls can be used when the Agent service is unavailable',
    (tester) async {
      final settings = AppearanceController();
      await tester.pumpWidget(
        AppearanceScope(
          controller: settings,
          child: MaterialApp(
            theme: pocketTheme(Brightness.light),
            home: const AppearancePage(),
          ),
        ),
      );
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(settings.mode, ThemeMode.dark);
      expect(jsonDecode(stored)['mode'], 'dark');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    },
  );
}
