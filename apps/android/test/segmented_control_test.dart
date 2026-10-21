import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_android/appearance.dart';
import 'package:dsh_android/flclash/color.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _segments = [('day', '日'), ('week', '周'), ('month', '月'), ('six', '6个月')];
final _control = find.byKey(const Key('selection'));
Finder get _thumb =>
    find.descendant(of: _control, matching: find.byType(Positioned));

class _Fixture extends StatefulWidget {
  const _Fixture({super.key, this.brightness = Brightness.light, this.font});
  final Brightness brightness;
  final String? font;
  @override
  State<_Fixture> createState() => _FixtureState();
}

class _FixtureState extends State<_Fixture> {
  final changes = <String>[];
  final scroll = ScrollController();
  String value = 'day';
  List<(String, String)> segments = _segments;
  bool enabled = true, glass = true, reduce = false;
  TextDirection direction = TextDirection.ltr;
  double scale = 1;
  void revise(VoidCallback edit) => setState(edit);
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    themeAnimationDuration: Duration.zero,
    theme: pocketTheme(widget.brightness).copyWith(
      textTheme: pocketTheme(widget.brightness).textTheme
          .apply(fontFamily: widget.font),
    ),
    home: MediaQuery(
      data: MediaQueryData(
        disableAnimations: reduce,
        textScaler: TextScaler.linear(scale),
      ),
      child: Directionality(
        textDirection: direction,
        child: LiquidGlassScope(
          enabled: glass,
          child: LiquidGlassHost(
            enabled: glass,
            child: Scaffold(
              body: SingleChildScrollView(
                controller: scroll,
                child: Column(
                  children: [
                    const SizedBox(height: 140),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: SegmentedControl<String>(
                        key: const Key('selection'),
                        segments: segments,
                        value: value,
                        onChanged: enabled
                            ? (next) => setState(() {
                                changes.add(next);
                                value = next;
                              })
                            : null,
                      ),
                    ),
                    const SizedBox(height: 1300),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<_FixtureState> _mount(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey<_FixtureState>();
  await tester.pumpWidget(_Fixture(key: key));
  await tester.pumpAndSettle();
  return key.currentState!;
}

void main() {
  testWidgets('tap changes once and tapping the selected segment is a no-op', (
    tester,
  ) async {
    final state = await _mount(tester);
    await tester.tap(find.text('周'));
    await tester.pumpAndSettle();
    expect(state.changes, ['week']);
    expect(
      tester.getCenter(_thumb).dx,
      closeTo(tester.getCenter(find.text('周')).dx, .1),
    );
    await tester.tap(find.text('周'));
    await tester.pumpAndSettle();
    expect(state.changes, ['week']);
  });

  testWidgets(
    'hold becomes a clear lens and horizontal drag follows before committing once',
    (tester) async {
      final state = await _mount(tester);
      final semantics = tester.ensureSemantics();
      try {
        final start = tester.getCenter(find.text('日'));
        final finish = tester.getCenter(find.text('月'));
        final gesture = await tester.startGesture(start);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(find.byType(LiquidGlass), findsOneWidget);
        expect(
          tester.widget<LiquidGlass>(find.byType(LiquidGlass)).style.tint.a,
          0,
        );
        expect(state.changes, isEmpty);
        await gesture.moveTo(Offset((start.dx + finish.dx) / 2 + 8, start.dy));
        await tester.pump();
        final intermediate = tester.getCenter(_thumb).dx;
        expect(intermediate, greaterThan(start.dx));
        expect(intermediate, lessThan(finish.dx));
        await gesture.moveTo(finish);
        await tester.pump();
        expect(tester.getCenter(_thumb).dx, closeTo(finish.dx, .1));
        expect(state.value, 'day');
        expect(state.changes, isEmpty);
        expect(
          tester
              .getSemantics(find.bySemanticsLabel('日'))
              .getSemanticsData()
              .flagsCollection
              .isSelected,
          ui.Tristate.isTrue,
        );
        expect(
          tester
              .getSemantics(find.bySemanticsLabel('月'))
              .getSemanticsData()
              .flagsCollection
              .isSelected,
          ui.Tristate.isFalse,
        );
        await gesture.up();
        await tester.pumpAndSettle();
        expect(state.changes, ['month']);
        expect(find.byType(LiquidGlass), findsNothing);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'release selects the nearest segment and dragging back to current does not save',
    (tester) async {
      final state = await _mount(tester);
      final start = tester.getCenter(find.text('日'));
      final week = tester.getCenter(find.text('周'));
      final month = tester.getCenter(find.text('月'));
      final gesture = await tester.startGesture(start);
      await gesture.moveTo(Offset((week.dx + month.dx) / 2 + 3, start.dy));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(state.changes, ['month']);
      final back = await tester.startGesture(month);
      await back.moveTo(start);
      await back.moveTo(month);
      await back.up();
      await tester.pumpAndSettle();
      expect(state.changes, ['month']);
    },
  );

  testWidgets('pointer cancel restores the committed value without saving', (
    tester,
  ) async {
    final state = await _mount(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.text('日')));
    await gesture.moveTo(tester.getCenter(find.text('6个月')));
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(state.changes, isEmpty);
    expect(
      tester.getCenter(_thumb).dx,
      closeTo(tester.getCenter(find.text('日')).dx, .1),
    );
  });

  testWidgets(
    'vertical scrolling wins the gesture and never persists a segment',
    (tester) async {
      final state = await _mount(tester);
      await tester.drag(find.text('周'), const Offset(0, -110));
      await tester.pumpAndSettle();
      expect(state.scroll.offset, greaterThan(0));
      expect(state.changes, isEmpty);
      expect(find.byType(LiquidGlass), findsNothing);
    },
  );

  testWidgets(
    'leaving the track vertically after a horizontal drag cancels it',
    (tester) async {
      final state = await _mount(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('日')),
      );
      final month = tester.getCenter(find.text('月'));
      await gesture.moveTo(month);
      await gesture.moveTo(month + const Offset(0, 90));
      await gesture.moveTo(month);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(state.changes, isEmpty);
      expect(state.value, 'day');
    },
  );

  testWidgets(
    'an external value update invalidates an outstanding drag and tap',
    (tester) async {
      final state = await _mount(tester);
      final drag = await tester.startGesture(tester.getCenter(find.text('日')));
      await drag.moveTo(tester.getCenter(find.text('月')));
      state.revise(() => state.value = 'week');
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(state.changes, isEmpty);
      expect(state.value, 'week');
      final tap = await tester.startGesture(tester.getCenter(find.text('6个月')));
      state.revise(() => state.value = 'day');
      await tester.pump();
      await tap.up();
      await tester.pumpAndSettle();
      expect(state.changes, isEmpty);
      expect(
        tester.getCenter(_thumb).dx,
        closeTo(tester.getCenter(find.text('日')).dx, .1),
      );
    },
  );

  testWidgets(
    'changing options or disabling mid-drag never commits stale coordinates',
    (tester) async {
      final state = await _mount(tester);
      final drag = await tester.startGesture(tester.getCenter(find.text('日')));
      await drag.moveTo(tester.getCenter(find.text('月')));
      state.revise(() => state.segments = const [('day', '日'), ('week', '周')]);
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(state.changes, isEmpty);
      final second = await tester.startGesture(
        tester.getCenter(find.text('日')),
      );
      await second.moveTo(tester.getCenter(find.text('周')));
      state.revise(() => state.enabled = false);
      await tester.pump();
      await second.up();
      await tester.pumpAndSettle();
      expect(state.changes, isEmpty);
    },
  );

  testWidgets('RTL reverses visual placement and drag mapping', (tester) async {
    final state = await _mount(tester);
    state.revise(() => state.direction = TextDirection.rtl);
    await tester.pumpAndSettle();
    final day = tester.getCenter(find.text('日'));
    final month = tester.getCenter(find.text('月'));
    expect(day.dx, greaterThan(month.dx));
    expect(tester.getCenter(_thumb).dx, closeTo(day.dx, .1));
    final drag = await tester.startGesture(day);
    await drag.moveTo(month);
    await drag.up();
    await tester.pumpAndSettle();
    expect(state.changes, ['month']);
    expect(tester.getCenter(_thumb).dx, closeTo(month.dx, .1));
  });

  testWidgets(
    'single, empty and unmatched values do not invent a selected option',
    (tester) async {
      final state = await _mount(tester);
      state.revise(() {
        state.segments = const [('only', '唯一')];
        state.value = 'missing';
      });
      await tester.pumpAndSettle();
      expect(_thumb, findsNothing);
      await tester.tap(find.text('唯一'));
      await tester.pumpAndSettle();
      expect(state.changes, ['only']);
      expect(_thumb, findsOneWidget);
      await tester.drag(find.text('唯一'), const Offset(150, 0));
      await tester.pumpAndSettle();
      expect(state.changes, ['only']);
      state.revise(() => state.segments = const []);
      await tester.pumpAndSettle();
      expect(_thumb, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('glass disabled keeps a solid selected surface while dragging', (
    tester,
  ) async {
    final state = await _mount(tester);
    state.revise(() => state.glass = false);
    await tester.pump();
    final gesture = await tester.startGesture(tester.getCenter(find.text('日')));
    await gesture.moveTo(tester.getCenter(find.text('月')));
    await tester.pump(const Duration(milliseconds: 160));
    expect(find.byType(LiquidGlass), findsNothing);
    final decorations = tester.widgetList<DecoratedBox>(
      find.descendant(of: _thumb, matching: find.byType(DecoratedBox)),
    );
    final fill = decorations
        .map((item) => item.decoration)
        .whereType<ShapeDecoration>()
        .single;
    expect(fill.color!.a, 1);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(state.changes, ['month']);
  });

  testWidgets(
    'reduced motion snaps without pending animation and enlarged text fits',
    (tester) async {
      final state = await _mount(tester);
      state.revise(() {
        state.reduce = true;
        state.scale = 2.5;
      });
      await tester.pumpAndSettle();
      expect(tester.getSize(_control).height, greaterThan(44));
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('日')),
      );
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.text('6个月')));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(state.changes, ['six']);
      expect(
        tester.getCenter(_thumb).dx,
        closeTo(tester.getCenter(find.text('6个月')).dx, .1),
      );
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keyboard arrows, Home and End change one value per key in both directions',
    (tester) async {
      final state = await _mount(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(state.changes, ['week']);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      expect(state.changes, ['week', 'six', 'day']);
      state.revise(() => state.direction = TextDirection.rtl);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(state.changes.last, 'week');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(state.changes.length, 4);
    },
  );

  testWidgets(
    'semantic selection reflects committed values and disabled actions are absent',
    (tester) async {
      final state = await _mount(tester);
      final handle = tester.ensureSemantics();
      try {
        final day = tester.getSemantics(find.bySemanticsLabel('日'));
        expect(
          day.getSemanticsData().flagsCollection.isSelected,
          ui.Tristate.isTrue,
        );
        final week = tester.getSemantics(find.bySemanticsLabel('周'));
        expect(
          week.getSemanticsData().flagsCollection.isInMutuallyExclusiveGroup,
          isTrue,
        );
        tester.binding.performSemanticsAction(
          ui.SemanticsActionEvent(
            type: ui.SemanticsAction.tap,
            nodeId: week.id,
            viewId: tester.view.viewId,
          ),
        );
        await tester.pumpAndSettle();
        expect(state.changes, ['week']);
        state.revise(() => state.enabled = false);
        await tester.pumpAndSettle();
        final disabled = tester
            .getSemantics(find.bySemanticsLabel('月'))
            .getSemanticsData();
        expect(disabled.flagsCollection.isEnabled, ui.Tristate.isFalse);
        expect(disabled.hasAction(ui.SemanticsAction.tap), isFalse);
        await tester.tap(find.text('月'));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(state.changes, ['week']);
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets('disposing during a drag leaves no callback or animation owner', (
    tester,
  ) async {
    final state = await _mount(tester);
    final changes = state.changes;
    final gesture = await tester.startGesture(tester.getCenter(find.text('日')));
    await gesture.moveTo(tester.getCenter(find.text('月')));
    await tester.pumpWidget(const SizedBox());
    await gesture.up();
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'appearance uses three segmented groups and persists a drag once on release',
    (tester) async {
      final settings = AppearanceController();
      final writes = <Json>[];
      final saving = Completer<void>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async {
          if (call.method == 'appearance.save') {
            writes.add(jsonDecode(call.arguments as String) as Json);
            await saving.future;
          }
          return null;
        },
      );
      addTearDown(() async {
        if (!saving.isCompleted) saving.complete();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        settings.dispose();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: AppearanceScope(
            controller: settings,
            child: const AppearancePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SegmentedControl<ThemeMode>), findsOneWidget);
      final mode = find.byType(SegmentedControl<ThemeMode>);
      final gesture = await tester.startGesture(
        tester.getCenter(find.descendant(of: mode, matching: find.text('系统'))),
      );
      await gesture.moveTo(
        tester.getCenter(find.descendant(of: mode, matching: find.text('深色'))),
      );
      await tester.pump();
      expect(writes, isEmpty);
      await gesture.up();
      await tester.pump();
      expect(writes.length, 1);
      expect(writes.single['mode'], 'dark');
      expect(
        tester.widget<SegmentedControl<ThemeMode>>(mode).onChanged,
        isNull,
      );
      saving.complete();
      await tester.pumpAndSettle();
      expect(settings.mode, ThemeMode.dark);
      await tester.scrollUntilVisible(
        find.byType(SegmentedControl<ColorStyle>),
        200,
      );
      expect(find.byType(SegmentedControl<ColorStyle>), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byType(SegmentedControl<String>),
        200,
      );
      expect(find.byType(SegmentedControl<String>), findsOneWidget);
    },
  );

  testWidgets('optional local segmented idle and held lens captures', (
    tester,
  ) async {
    final directory = Platform.environment['POCKET_SEGMENT_CAPTURE_DIR'];
    if (directory == null) return;
    tester.view.physicalSize = const Size(390, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final bytes = await File(
        Platform.environment['POCKET_SEGMENT_CAPTURE_FONT']!,
      ).readAsBytes();
      await (FontLoader(
        'SegmentCapture',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    });
    for (final brightness in Brightness.values) {
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: _Fixture(brightness: brightness, font: 'SegmentCapture'),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> capture(String state) async {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(directory).create(recursive: true);
            await File('$directory/segmented-${brightness.name}-$state.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }

      await capture('idle');
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('日')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      await gesture.moveTo(
        tester.getCenter(find.text('周')) + const Offset(16, 0),
      );
      await tester.pumpAndSettle();
      await capture('drag');
      await gesture.cancel();
      await tester.pumpAndSettle();
    }
  });
}
