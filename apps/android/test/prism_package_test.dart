import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/liquid_glass.dart';
import 'package:prism_ui/theme_data.dart';

/// Proves the vendored prism_ui package resolves, bundles its glass shader, and
/// builds its widgets under this app's Flutter version.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the package-bundled liquid glass shader loads', () async {
    final program = await ui.FragmentProgram.fromAsset(
      'packages/prism_ui/shaders/liquid_glass.frag',
    );
    expect(program.fragmentShader(), isNotNull);
  });

  testWidgets('liquid glass builds inside a prism theme', (tester) async {
    final theme = ThemeData();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: theme,
          child: Center(
            child: SizedBox(
              width: 120,
              height: 48,
              child: LiquidGlass(
                style: LiquidGlassStyle.regular(theme.colorScheme),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(LiquidGlass), findsOneWidget);
  });
}
