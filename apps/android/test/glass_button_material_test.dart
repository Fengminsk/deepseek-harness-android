import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_android/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget host(
  Widget child, {
  Brightness brightness = Brightness.light,
  bool glass = true,
  bool reduceMotion = false,
  String? font,
}) {
  var theme = pocketTheme(brightness, seed: const Color(0xff176dff));
  if (font != null) {
    theme = theme.copyWith(textTheme: theme.textTheme.apply(fontFamily: font));
  }
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    themeAnimationDuration: Duration.zero,
    theme: theme,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: LiquidGlassScope(
      enabled: glass,
      quality: LiquidGlassQuality.standard,
      child: LiquidGlassHost(
        enabled: glass,
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'tinted bevel is visible while the central primary face stays unchanged ($brightness)',
      (tester) async {
        final boundary = GlobalKey();
        final scheme = pocketTheme(brightness).colorScheme;
        final dark = brightness == Brightness.dark;
        // The build 25 material is a visual regression baseline for its face.
        final previous = LiquidGlassStyle(
          tint: scheme.primary.withValues(alpha: .82),
          saturation: 1.2,
          rim: dark ? .14 : .2,
          rimWidth: 1.2,
          rimTail: .17,
          rimFocus: 1,
          rimAdded: .38,
          hairline: dark ? 0 : .34,
          hairlineSide: dark ? .73 : .5,
        );
        final next = LiquidGlassStyle.tinted(scheme, scheme.primary);
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: host(
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in [('before', previous), ('after', next)])
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: LiquidGlass(
                        key: ValueKey(item.$1),
                        style: item.$2,
                        borderRadius: BorderRadius.circular(22),
                        child: const SizedBox(width: 180, height: 44),
                      ),
                    ),
                ],
              ),
              brightness: brightness,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final originalRect = tester.getRect(
          find.byKey(const ValueKey('before')),
        );
        final revisedRect = tester.getRect(find.byKey(const ValueKey('after')));
        final sample = await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          try {
            final data = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            Color colorAt(Offset position) {
              final offset =
                  ((position.dy * 2).floor() * image.width +
                      (position.dx * 2).floor()) *
                  4;
              return Color.fromARGB(
                data.getUint8(offset + 3),
                data.getUint8(offset),
                data.getUint8(offset + 1),
                data.getUint8(offset + 2),
              );
            }

            return (
              oldFace: colorAt(originalRect.center),
              face: colorAt(revisedRect.center),
              oldEdge: colorAt(originalRect.topCenter + const Offset(0, 1)),
              edge: colorAt(revisedRect.topCenter + const Offset(0, 1)),
            );
          } finally {
            image.dispose();
          }
        });
        expect(
          sample!.face,
          sample.oldFace,
          reason:
              'onPrimary must keep the same central background and contrast.',
        );
        expect(
          sample.edge.computeLuminance(),
          greaterThan(sample.oldEdge.computeLuminance() + .015),
          reason: 'The primary rim must be visibly lighter than the flat build 25 edge.',
        );
        expect(tester.takeException(), isNull);
      },
    );
    for (final enabled in [true, false]) {
      testWidgets(
        'primary circle uses one tinted glass pane with state colors ($brightness/$enabled)',
        (tester) async {
          await tester.pumpWidget(
            host(
              GlassButton(
                icon: Icons.arrow_upward_rounded,
                label: '发送',
                solid: true,
                onPressed: enabled ? () {} : null,
              ),
              brightness: brightness,
            ),
          );
          await tester.pumpAndSettle();
          final button = find.byType(IconButton);
          final colors = Theme.of(tester.element(button)).colorScheme;
          final states = enabled ? <WidgetState>{} : {WidgetState.disabled};
          final pane = tester.widget<LiquidGlass>(find.byType(LiquidGlass));
          expect(
            pane.style.tint,
            enabled
                ? LiquidGlassStyle.tinted(colors, colors.primary).tint
                : LiquidGlassStyle.regular(colors).tint,
          );
          expect(pane.style.tint.a, inExclusiveRange(0, 1));
          expect(pane.style.rim, greaterThan(0));
          final style = tester.widget<IconButton>(button).style!;
          expect(style.backgroundColor!.resolve(states), Colors.transparent);
          final icon = find.descendant(of: button, matching: find.byType(Icon));
          expect(
            IconTheme.of(tester.element(icon)).color,
            enabled
                ? colors.onPrimary
                : colors.onSurface.withValues(alpha: .38),
          );
          final box = tester.renderObject<RenderBox>(button);
          expect(box.size, const Size.square(44));
          final clip = pane.clipper!.getClip(box.size);
          expect(clip.contains(Offset.zero), isFalse);
          expect(clip.contains(const Offset(22, 1)), isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }
    for (final tonal in [true, false]) {
      testWidgets(
        'filled action defaults to a transparent glass backing ($brightness/tonal=$tonal)',
        (tester) async {
          for (final enabled in [true, false]) {
            await tester.pumpWidget(
              host(
                PocketButton(
                  tonal: tonal,
                  onPressed: enabled ? () {} : null,
                  child: const Text('保存'),
                ),
                brightness: brightness,
              ),
            );
            await tester.pumpAndSettle();
            final button = find.byType(FilledButton);
            final context = tester.element(button);
            final colors = Theme.of(context).colorScheme;
            final pane = tester.widget<LiquidGlass>(find.byType(LiquidGlass));
            final expected = !tonal && enabled
                ? LiquidGlassStyle.tinted(colors, colors.primary)
                : LiquidGlassStyle.regular(colors);
            expect(pane.style.tint, expected.tint);
            expect(pane.style.tint.a, inExclusiveRange(0, 1));
            final states = enabled ? <WidgetState>{} : {WidgetState.disabled};
            expect(
              FilledButtonTheme.of(context).style!.backgroundColor!
                  .resolve(states),
              Colors.transparent,
              reason: 'An opaque Material must not obscure the glass pane.',
            );
            expect(
              DefaultTextStyle.of(tester.element(find.text('保存'))).style.color!
                  .toARGB32(),
              (!enabled
                      ? colors.onSurface.withValues(alpha: .38)
                      : tonal
                      ? colors.onSurface
                      : colors.onPrimary)
                  .toARGB32(),
            );
            expect(tester.takeException(), isNull);
          }
        },
      );
    }
  }

  testWidgets(
    'glass preference off and explicit opt-out retain flat state colors',
    (tester) async {
      await tester.pumpWidget(
        host(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GlassButton(
                icon: Icons.add,
                label: '添加',
                solid: true,
                onPressed: () {},
              ),
              PocketButton(onPressed: () {}, child: const Text('主操作')),
              PocketButton.tonal(onPressed: () {}, child: const Text('次操作')),
            ],
          ),
          glass: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LiquidGlass), findsNothing);
      final icon = find.byType(IconButton);
      final colors = Theme.of(tester.element(icon)).colorScheme;
      expect(
        tester.widget<IconButton>(icon).style!.backgroundColor!.resolve({}),
        colors.primary,
      );
      expect(
        DefaultTextStyle.of(tester.element(find.text('主操作'))).style.color,
        colors.onPrimary,
      );
      expect(
        DefaultTextStyle.of(tester.element(find.text('次操作'))).style.color,
        colors.onSurface,
      );
      await tester.pumpWidget(
        host(
          PocketButton(
            glass: false,
            onPressed: () {},
            child: const Text('关闭玻璃'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LiquidGlass), findsNothing);
    },
  );

  testWidgets(
    'colored circle follows a press and drag without becoming an ellipse or committing on cancel',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        host(
          GlassButton(
            icon: Icons.arrow_upward_rounded,
            label: '发送',
            solid: true,
            onPressed: () => calls++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byType(IconButton);
      final box = tester.renderObject<RenderBox>(button);
      final rest = ElasticPress.paintBoundsOf(box);
      final gesture = await tester.startGesture(tester.getCenter(button));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(
        tester.widget<LiquidGlass>(find.byType(LiquidGlass)).pressed,
        isTrue,
      );
      await gesture.moveBy(const Offset(14, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      final dragged = ElasticPress.paintBoundsOf(box);
      expect(dragged.width, greaterThan(rest.width));
      expect(dragged.width, closeTo(dragged.height, .001));
      expect(dragged.center.dx, greaterThan(rest.center.dx));
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(
        tester.widget<LiquidGlass>(find.byType(LiquidGlass)).pressed,
        isFalse,
      );
      expect(ElasticPress.paintBoundsOf(box).width, closeTo(rest.width, .1));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(calls, 1);
    },
  );

  testWidgets('disabled and reduced-motion colored controls never deform', (
    tester,
  ) async {
    for (final disabled in [true, false]) {
      await tester.pumpWidget(
        host(
          GlassButton(
            icon: Icons.add,
            label: '添加',
            solid: true,
            onPressed: disabled ? null : () {},
          ),
          reduceMotion: !disabled,
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byType(IconButton);
      final box = tester.renderObject<RenderBox>(button);
      final rest = ElasticPress.paintBoundsOf(box);
      final gesture = await tester.startGesture(tester.getCenter(button));
      await gesture.moveBy(const Offset(12, 4));
      await tester.pumpAndSettle();
      expect(ElasticPress.paintBoundsOf(box), rest);
      if (disabled) {
        expect(
          tester.widget<LiquidGlass>(find.byType(LiquidGlass)).pressed,
          isFalse,
        );
      }
      await gesture.cancel();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('optional local button material captures', (tester) async {
    final directory = Platform.environment['POCKET_BUTTON_CAPTURE_DIR'];
    if (directory == null) return;
    tester.view.physicalSize = const Size(390, 470);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final bytes = await File(
        Platform.environment['POCKET_BUTTON_CAPTURE_FONT']!,
      ).readAsBytes();
      await (FontLoader(
        'ButtonCapture',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    for (final brightness in Brightness.values) {
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: host(
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Pocket Harness',
                    style: TextStyle(
                      fontFamily: 'ButtonCapture',
                      fontSize: 24,
                      color: brightness == Brightness.dark
                          ? Colors.white
                          : Colors.black,
                    ),
                  ),
                  const SizedBox(height: 24),
                  GlassButton(
                    icon: Icons.arrow_upward_rounded,
                    label: '发送',
                    solid: true,
                    onPressed: () {},
                  ),
                  const SizedBox(height: 16),
                  PocketButton(onPressed: () {}, child: const Text('保存并应用')),
                  PocketButton.tonal(
                    onPressed: () {},
                    child: const Text('继续编辑'),
                  ),
                  const PocketButton(onPressed: null, child: Text('暂不可用')),
                ],
              ),
            ),
            brightness: brightness,
            font: 'ButtonCapture',
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> capture(String state) async => tester.runAsync(() async {
        final image =
            await (captureKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 2);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(directory).create(recursive: true);
          await File('$directory/buttons-${brightness.name}-$state.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      await capture('idle');
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('保存并应用')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      await capture('pressed');
      await gesture.cancel();
      await tester.pumpAndSettle();
    }
  });
}
