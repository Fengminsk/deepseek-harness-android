import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as material;
import 'package:prism_ui/color_scheme.dart' as prism;
import 'package:prism_ui/surface.dart' as prism;

import 'package:dsh_android/prism_bridge.dart';
import 'package:dsh_android/ui.dart';

void main() {
  /// Every role the app generates must arrive unchanged in prism's scheme.
  test('the bridge copies the app palette into prism roles', () {
    for (final brightness in Brightness.values) {
      final scheme = pocketTheme(brightness).colorScheme;
      final bridged = prismColorSchemeOf(scheme);

      expect(bridged.brightness, scheme.brightness);
      expect(bridged.primary, scheme.primary);
      expect(bridged.onPrimary, scheme.onPrimary);
      expect(bridged.secondary, scheme.secondary);
      expect(bridged.error, scheme.error);
      expect(bridged.surface, scheme.surface);
      expect(bridged.onSurface, scheme.onSurface);
      expect(bridged.surfaceContainerHigh, scheme.surfaceContainerHigh);
      expect(bridged.outlineVariant, scheme.outlineVariant);
    }
  });

  test('pure black dark mode reaches prism unchanged', () {
    final scheme = pocketTheme(Brightness.dark, pureBlack: true).colorScheme;
    final bridged = prismColorSchemeOf(scheme);
    expect(bridged.surface, scheme.surface);
    expect(bridged.brightness, Brightness.dark);
  });

  testWidgets('prism widgets below the scope read the app palette', (
    tester,
  ) async {
    final scheme = pocketTheme(Brightness.dark).colorScheme;
    prism.ColorScheme? seen;

    await tester.pumpWidget(
      material.Theme(
        data: pocketTheme(Brightness.dark),
        child: PocketPrismScope(
          child: Builder(
            builder: (context) {
              seen = prism.ColorScheme.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(seen, isNotNull);
    expect(seen!.primary, scheme.primary);
    expect(seen!.surface, scheme.surface);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a prism surface builds on the bridged theme', (tester) async {
    await tester.pumpWidget(
      material.Theme(
        data: pocketTheme(Brightness.light),
        child: PocketPrismScope(
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: prism.Surface(child: SizedBox.shrink()),
          ),
        ),
      ),
    );

    expect(find.byType(prism.Surface), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
