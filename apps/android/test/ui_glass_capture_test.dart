import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:dsh_android/ui.dart';

import 'support/settings_layout_capture.dart';

/// Optional local artifacts for visual comparison across a component migration.
///
/// Writes PNGs only when `POCKET_CAPTURE_DIR` is set, so the suite stays
/// artifact-free in CI. Pairs with `POCKET_CAPTURE_FONT` for real text.
void main() {
  for (final brightness in Brightness.values) {
    testWidgets('glass surfaces preview (${brightness.name})', (tester) async {
      await loadSettingsCaptureFonts();
      tester.view.physicalSize = const Size(390, 460);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final capture = SettingsLayoutCapture();
      final theme = pocketTheme(brightness);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: Builder(
            builder: (context) => LiquidGlassScope(
              enabled: true,
              child: LiquidGlassHost(
                enabled: true,
                child: capture.wrap(
                  context,
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          const Color(0xff779fc8),
                          const Color(0xfffff9ec),
                          const Color(0xffb2c4df),
                        ],
                      ),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 24,
                        children: [
                          GlassSurface(
                            radius: 30,
                            child: Padding(
                              padding: const EdgeInsets.all(18),
                              child: Text(
                                '玻璃面板 Glass panel',
                                style: TextStyle(
                                  fontSize: 15,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ),
                          GlassButton(
                            icon: Icons.auto_awesome,
                            label: '按钮 Button',
                            onPressed: () {},
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await capture.save(tester, 'glass-${brightness.name}');
      expect(tester.takeException(), isNull);
    });
  }
}
