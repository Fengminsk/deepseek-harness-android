import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_android/entry_motion.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget host(Widget child, {bool reduceMotion = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Material(child: Center(child: child)),
  ),
);

void main() {
  int enabledFilters(WidgetTester tester) => tester
      .widgetList<ImageFiltered>(find.byType(ImageFiltered))
      .where((item) => item.enabled)
      .length;

  for (final lazy in [true, false]) {
    testWidgets(
      'recycled rows stay clear, but later new descendants enter (lazy=$lazy)',
      (tester) async {
        final controller = ScrollController();
        final added = ValueNotifier(false);
        addTearDown(controller.dispose);
        addTearDown(added.dispose);
        Widget row(int index) => SizedBox(
          key: ValueKey(index),
          height: 140,
          child: Column(
            children: [
              PocketTile(title: Text('row $index')),
              if (index == 0 && added.value)
                const PocketReveal(child: Text('new detail')),
            ],
          ),
        );
        await tester.pumpWidget(
          host(
            SizedBox(
              height: 240,
              child: ValueListenableBuilder<bool>(
                valueListenable: added,
                builder: (context, _, _) => lazy
                    ? PocketList.builder(
                        controller: controller,
                        itemCount: 100,
                        itemBuilder: (_, index) => row(index),
                      )
                    : PocketList(
                        controller: controller,
                        children: List.generate(100, row),
                      ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        controller.jumpTo(4000);
        await tester.pump();
        expect(find.byKey(const ValueKey(0)), findsNothing);
        // Eager widget construction must not prematurely mark offscreen rows seen.
        expect(enabledFilters(tester), greaterThan(0));
        await tester.pumpAndSettle();
        controller.jumpTo(0);
        await tester.pump();
        expect(find.byKey(const ValueKey(0)), findsOneWidget);
        expect(enabledFilters(tester), 0);
        await tester.pump();
        added.value = true;
        await tester.pump();
        expect(find.text('new detail'), findsOneWidget);
        expect(enabledFilters(tester), 1);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final keyed in [true, false]) {
    testWidgets(
      'a replacement child type enters at the same list slot (keyed=$keyed)',
      (tester) async {
        final replacement = ValueNotifier(false);
        addTearDown(replacement.dispose);
        await tester.pumpWidget(
          host(
            ValueListenableBuilder<bool>(
              valueListenable: replacement,
              builder: (_, value, _) => PocketList(
                children: [
                  value
                      ? Padding(
                          key: keyed ? const ValueKey('row') : null,
                          padding: EdgeInsets.zero,
                          child: const PocketTile(title: Text('replacement')),
                        )
                      : SizedBox(
                          key: keyed ? const ValueKey('row') : null,
                          child: const PocketTile(title: Text('original')),
                        ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        replacement.value = true;
        await tester.pump();
        expect(enabledFilters(tester), 1);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'reducing motion preserves editable state, focus and scroll position',
    (tester) async {
      Widget content(bool reduced) => host(
        PocketReveal(
          child: SizedBox(
            height: 240,
            child: ListView(
              children: [
                const TextField(key: ValueKey('draft')),
                ...List.generate(
                  30,
                  (index) => SizedBox(height: 60, child: Text('line $index')),
                ),
              ],
            ),
          ),
        ),
        reduceMotion: reduced,
      );
      await tester.pumpWidget(content(false));
      await tester.enterText(find.byType(TextField), 'unsaved text');
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      scroll.position.jumpTo(120);
      await tester.pump();
      final offset = scroll.position.pixels;
      await tester.pumpWidget(content(true));
      expect(
        tester.state<EditableTextState>(
          find.byType(EditableText, skipOffstage: false),
        ),
        same(editable),
      );
      expect(editable.textEditingValue.text, 'unsaved text');
      expect(editable.widget.focusNode.hasFocus, isTrue);
      expect(scroll.position.pixels, offset);
      expect(enabledFilters(tester), 0);
      await tester.pumpWidget(content(false));
      expect(
        tester.state<EditableTextState>(
          find.byType(EditableText, skipOffstage: false),
        ),
        same(editable),
      );
      expect(scroll.position.pixels, offset);
      expect(enabledFilters(tester), 0);
    },
  );

  testWidgets('explicit row transitions do not stack on an entering ancestor', (
    tester,
  ) async {
    final motion = ValueNotifier(.3);
    addTearDown(motion.dispose);
    await tester.pumpWidget(
      host(
        PocketReveal(
          child: ValueListenableBuilder<double>(
            valueListenable: motion,
            builder: (_, value, _) => PocketBlurTransition(
              animation: AlwaysStoppedAnimation(value),
              child: const Text('expanding tool row'),
            ),
          ),
        ),
      ),
    );
    expect(enabledFilters(tester), 1);
    motion.value = 1;
    await tester.pumpAndSettle();
    expect(enabledFilters(tester), 0);
  });

  for (final selected in [false, true]) {
    testWidgets(
      'group press fills rectangular rows and clips only the outer group (selected=$selected)',
      (tester) async {
        final captureKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: pocketTheme(Brightness.light).copyWith(
              highlightColor: const Color(0xff00ff00),
              // Grouped rows must suppress even a sparkling application theme.
              splashFactory: InkSparkle.splashFactory,
            ),
            home: Center(
              child: RepaintBoundary(
                key: captureKey,
                child: ColoredBox(
                  color: const Color(0xffff00ff),
                  child: SizedBox(
                    width: 320,
                    height: 280,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: PocketSection(
                        children: List.generate(
                          3,
                          (index) => PocketTile(
                            key: ValueKey('tile-$index'),
                            selected: selected,
                            title: Text('row $index'),
                            onTap: () {},
                          ),
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
        Future<({ByteData bytes, int width})> snapshot() async {
          final boundary =
              captureKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final result = await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            final width = image.width;
            image.dispose();
            return (bytes: bytes!, width: width);
          });
          return result!;
        }

        final origin = tester.getTopLeft(find.byKey(captureKey));
        int pixel(({ByteData bytes, int width}) shot, Offset global) {
          final local = global - origin;
          return shot.bytes.getUint32(
            (local.dy.floor() * shot.width + local.dx.floor()) * 4,
          );
        }

        final group = tester.widget<Material>(
          find.descendant(
            of: find.byType(PocketSection),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Material && widget.clipBehavior == Clip.antiAlias,
            ),
          ),
        );
        expect(group.shape, AppShape.xl);
        for (var index = 0; index < 3; index++) {
          final tile = find.byKey(ValueKey('tile-$index'));
          final ink = tester.widget<InkWell>(
            find.descendant(of: tile, matching: find.byType(InkWell)),
          );
          expect(ink.customBorder, AppShape.none);
          expect(ink.splashFactory, same(NoSplash.splashFactory));
          expect(ink.canRequestFocus, isTrue);
          expect(ink.excludeFromSemantics, isFalse);
          expect(ink.enableFeedback, isTrue);
          final rect = tester.getRect(tile);
          final topCorner = rect.topLeft + const Offset(2, 2);
          final bottomCorner = rect.bottomLeft + const Offset(2, -3);
          final before = await snapshot();
          final gesture = await tester.startGesture(rect.center);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 220));
          final after = await snapshot();
          expect(
            pixel(after, topCorner),
            index == 0
                ? pixel(before, topCorner)
                : isNot(pixel(before, topCorner)),
          );
          expect(
            pixel(after, bottomCorner),
            index == 2
                ? pixel(before, bottomCorner)
                : isNot(pixel(before, bottomCorner)),
          );
          await gesture.cancel();
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('standalone rows retain their rounded shape and themed splash', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(PocketTile(title: const Text('outside a group'), onTap: () {})),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<InkWell>(find.byType(InkWell)).customBorder,
      AppShape.xl,
    );
    expect(tester.widget<InkWell>(find.byType(InkWell)).splashFactory, isNull);
  });

  testWidgets(
    'list item identity survives insertions and reordering through entrance wrappers',
    (tester) async {
      final items = ['alpha', 'beta'];
      final repaint = ValueNotifier(0);
      addTearDown(repaint.dispose);
      await tester.pumpWidget(
        host(
          ValueListenableBuilder<int>(
            valueListenable: repaint,
            builder: (context, _, _) => PocketList.builder(
              itemCount: items.length,
              findChildIndexCallback: (key) =>
                  items.indexOf((key as ValueKey<String>).value),
              itemBuilder: (_, index) => TextField(key: ValueKey(items[index])),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('alpha')),
        'unsaved draft',
      );
      items.insert(0, items.removeLast());
      repaint.value++;
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('alpha')),
          matching: find.text('unsaved draft'),
        ),
        findsOneWidget,
      );
      items.insert(0, 'new');
      repaint.value++;
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('alpha')),
          matching: find.text('unsaved draft'),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widgetList<ImageFiltered>(find.byType(ImageFiltered))
            .where((item) => item.enabled),
        hasLength(1),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'entrance becomes clear without changing layout or replaying retained content',
    (tester) async {
      Widget content(String value) => host(
        PocketReveal(
          child: SizedBox(width: 140, height: 48, child: Text(value)),
        ),
      );
      await tester.pumpWidget(content('starting'));
      final before = tester.getRect(find.byType(PocketReveal));
      expect(
        tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled,
        isTrue,
      );
      await tester.pump(const Duration(milliseconds: 110));
      final opacity = tester.widget<Opacity>(find.byType(Opacity)).opacity;
      expect(opacity, inExclusiveRange(0, 1));
      expect(tester.getRect(find.byType(PocketReveal)), before);
      await tester.pumpAndSettle();
      expect(
        tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled,
        isFalse,
      );
      await tester.pumpWidget(content('streaming text updated'));
      expect(
        tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled,
        isFalse,
      );
      expect(tester.getRect(find.byType(PocketReveal)), before);
    },
  );

  testWidgets(
    'nested surfaces share one entrance and later insertions animate independently',
    (tester) async {
      Widget content(bool added) => host(
        PocketReveal(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const PocketReveal(key: ValueKey('old'), child: Text('existing')),
              if (added)
                const PocketReveal(key: ValueKey('new'), child: Text('new')),
            ],
          ),
        ),
      );
      int filters() => tester
          .widgetList<ImageFiltered>(find.byType(ImageFiltered))
          .where((item) => item.enabled)
          .length;
      await tester.pumpWidget(content(false));
      expect(filters(), 1);
      await tester.pumpAndSettle();
      expect(filters(), 0);
      await tester.pumpWidget(content(true));
      expect(filters(), 1);
      await tester.pumpAndSettle();
      expect(filters(), 0);
    },
  );

  testWidgets(
    'reduced motion immediately removes blur and ends active entrance',
    (tester) async {
      Widget content(bool reduced) => host(
        const PocketReveal(child: Text('content')),
        reduceMotion: reduced,
      );
      await tester.pumpWidget(content(false));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pumpWidget(content(true));
      expect(
        tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled,
        isFalse,
      );
      await tester.pumpWidget(content(false));
      expect(
        tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled,
        isFalse,
      );
    },
  );
}
