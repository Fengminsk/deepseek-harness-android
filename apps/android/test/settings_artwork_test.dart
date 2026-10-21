import 'dart:convert';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/settings.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
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
