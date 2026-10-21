import 'dart:convert';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/settings.dart';
import 'package:dsh_android/ui.dart';
import 'package:dsh_android/configuration_editor.dart';
import 'package:dsh_android/configuration_model_destination.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class UnavailableSettingsRuntime extends RuntimeController {
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async =>
      throw StateError('Synthetic unavailable catalog');
}

void main() {
  testWidgets(
    'model entry uses its catalog workflow and Web preferences stay grouped',
    (tester) async {
      final runtime = UnavailableSettingsRuntime()
        ..phase = 'ready'
        ..forms = [
          {'ns': 'agent-default-model'},
          {'ns': 'ui-theme'},
          {'ns': 'custom-plugin'},
        ];
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(home: ConfigurationListPage(runtime: runtime)),
      );
      await tester.pumpAndSettle();
      for (final entry in {
        'ui-theme': '原版 Web 界面',
        'custom-plugin': '扩展设置',
      }.entries) {
        final group = find.ancestor(
          of: find.byKey(ValueKey('settings-entry:${entry.key}')),
          matching: find.byType(PocketSection),
        );
        expect(tester.widget<PocketSection>(group).title, entry.value);
      }
      await tester.tap(find.text('默认会话模型'));
      await tester.pumpAndSettle();
      expect(find.byType(ConfigurationModelDestination), findsOneWidget);
      expect(find.byType(ConfigPage), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('重新读取模型设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings show their declared image and distinct category fallbacks',
    (tester) async {
      final runtime = RuntimeController()
        ..phase = 'ready'
        ..forms = [
          {'ns': 'web-search-deepseek'},
          {'ns': 'ui-theme'},
          {
            'ns': 'custom-tool',
            'display': {
              'icon':
                  'data:image/svg+xml;base64,${base64Encode(utf8.encode('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2 2h20v20H2z" fill="#ff8a16"/></svg>'))}',
            },
          },
        ];
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: ConfigurationListPage(runtime: runtime),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.search_rounded), findsOneWidget);
      expect(find.byIcon(Icons.palette_outlined), findsOneWidget);
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(find.text('custom-tool'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
