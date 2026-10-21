import 'package:dsh_android/confirmation.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final glass in [false, true]) {
      testWidgets('compact equal actions in $brightness with glass=$glass', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var accepted = 0;
        var background = 0;
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: pocketTheme(brightness),
              home: LiquidGlassScope(
                enabled: glass,
                child: PocketConfirmationLayer(
                  confirmation: PocketConfirmation(
                    title: '保留当前编辑？',
                    message: '当前内容尚未保存。继续编辑会保留所有输入。',
                    secondaryLabel: '继续编辑',
                    onSecondary: () {},
                    primaryLabel: '放弃编辑并返回',
                    onPrimary: () => accepted++,
                  ),
                  child: PocketScaffold(
                    title: const Text('底层页面'),
                    body: Center(
                      child: PocketButton(
                        onPressed: () => background++,
                        child: const Text('底层操作'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.bySemanticsLabel('底层操作'), findsNothing);
          Finder action(String text) => find.ancestor(
            of: find.text(text),
            matching: find.byType(FilledButton),
          );
          final secondary = tester.getRect(action('继续编辑'));
          final primary = tester.getRect(action('放弃编辑并返回'));
          expect(secondary.top, closeTo(primary.top, .1));
          expect(secondary.width, closeTo(primary.width, .1));
          expect(secondary.right, lessThan(primary.left));
          expect(primary.height, greaterThanOrEqualTo(44));
          final primaryText = find.text('放弃编辑并返回');
          final colorScheme = Theme.of(tester.element(primaryText)).colorScheme;
          expect(tester.widget<Text>(primaryText).style?.color, isNull);
          expect(
            DefaultTextStyle.of(tester.element(primaryText)).style.color,
            colorScheme.onPrimary,
          );
          final panel = find
              .descendant(
                of: find.byType(PocketConfirmation),
                matching: glass
                    ? find.byType(LiquidGlass)
                    : find.byType(GlassSurface),
              )
              .first;
          final panelBounds = tester.getRect(panel);
          expect(panelBounds.width, lessThanOrEqualTo(360));
          expect(panelBounds.height, lessThan(300));
          await tester.tapAt(const Offset(8, 800));
          await tester.pumpAndSettle();
          expect(background, 0);
          expect(accepted, 0);
          expect(find.text('保留当前编辑？'), findsOneWidget);
          await tester.tap(find.text('放弃编辑并返回'));
          expect(accepted, 1);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
    testWidgets('disabled confirmation inherits subdued text in $brightness', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(brightness),
          home: LiquidGlassScope(
            enabled: true,
            child: PocketConfirmationLayer(
              confirmation: PocketConfirmation(
                title: '等待当前操作',
                message: '正在核对结果。',
                secondaryLabel: '继续编辑',
                onSecondary: () {},
                primaryLabel: '确认',
                onPrimary: null,
              ),
              child: const Scaffold(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final label = find.text('确认');
      final colors = Theme.of(tester.element(label)).colorScheme;
      expect(tester.widget<Text>(label).style?.color, isNull);
      expect(
        DefaultTextStyle.of(tester.element(label)).style.color?.toARGB32(),
        colors.onSurface.withValues(alpha: .38).toARGB32(),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
