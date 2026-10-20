import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:dsh_android/ui.dart';
import 'package:dsh_android/appearance.dart';

Widget host(Widget child, {bool reduceMotion = false, double scale = 1}) =>
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduceMotion,
          textScaler: TextScaler.linear(scale),
        ),
        child: child!,
      ),
      home: child,
    );

void main() {
  testWidgets(
    'glass press grows, follows a drag, cancels action and springs home',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          Scaffold(
            body: Center(
              child: GlassButton(
                icon: Icons.add,
                label: 'press',
                onPressed: () => taps++,
              ),
            ),
          ),
        ),
      );
      final button = find.byType(IconButton);
      final box = tester.renderObject<RenderBox>(button);
      final rest = ElasticPress.paintBoundsOf(box);
      final gesture = await tester.startGesture(tester.getCenter(button));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        ElasticPress.paintBoundsOf(box).width,
        greaterThan(rest.width + 2),
      );
      await gesture.moveBy(const Offset(70, 25));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        ElasticPress.paintBoundsOf(box).center.dx,
        greaterThan(rest.center.dx + 2),
      );
      // Layout and hit testing stay where the button was; its paint alone moves.
      expect(box.size.width, rest.width);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(taps, 0);
      expect(
        (ElasticPress.paintBoundsOf(box).center - rest.center).distance,
        lessThan(.1),
      );
      expect(ElasticPress.paintBoundsOf(box).width, closeTo(rest.width, .1));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(taps, 1);
      final cancelled = await tester.startGesture(tester.getCenter(button));
      await tester.pump(const Duration(milliseconds: 200));
      await cancelled.cancel();
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(ElasticPress.paintBoundsOf(box).width, closeTo(rest.width, .1));
    },
  );

  testWidgets('reduce motion leaves a pressed button still', (tester) async {
    await tester.pumpWidget(
      host(
        Scaffold(
          body: Center(
            child: GlassButton(
              icon: Icons.add,
              label: 'press',
              onPressed: () {},
            ),
          ),
        ),
        reduceMotion: true,
      ),
    );
    final button = find.byType(IconButton);
    final box = tester.renderObject<RenderBox>(button);
    final rest = ElasticPress.paintBoundsOf(box);
    final gesture = await tester.startGesture(tester.getCenter(button));
    await gesture.moveBy(const Offset(45, 20));
    await tester.pump(const Duration(milliseconds: 500));
    expect(ElasticPress.paintBoundsOf(box), rest);
    await gesture.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'scroll viewport extends under both floating edges and keyboard keeps bottom above inset',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        host(
          PocketScaffold(
            title: const Text('Title'),
            bottom: const GlassSurface(
              child: SizedBox(key: Key('composer'), height: 60),
            ),
            body: PocketList(
              children: List.generate(
                30,
                (index) => SizedBox(height: 80, child: Text('row $index')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final viewport = tester.getRect(find.byType(ListView));
      expect(viewport.top, 0);
      expect(viewport.bottom, 844);
      expect(
        tester.getRect(find.byKey(const Key('composer'))).bottom,
        lessThan(viewport.bottom),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -230));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.text('row 2')).top,
        lessThan(tester.getRect(find.text('Title')).bottom),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const Key('composer'))).bottom,
        lessThanOrEqualTo(544),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('header title stays at screen center with unequal side actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const PocketScaffold(
          title: Text('Centered'),
          leading: SizedBox(width: 20),
          trailing: SizedBox(width: 80),
          body: SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.text('Centered')).dx,
      closeTo(
        tester.view.physicalSize.width / tester.view.devicePixelRatio / 2,
        .1,
      ),
    );
  });

  testWidgets('theme page fits a phone with enlarged text', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final appearance = AppearanceController();
    await tester.pumpWidget(
      AppearanceScope(
        controller: appearance,
        child: host(const AppearancePage(), scale: 1.3),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    appearance.dispose();
  });
}
