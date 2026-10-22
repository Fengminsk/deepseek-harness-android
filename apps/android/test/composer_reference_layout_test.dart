import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_android/chat_references.dart';
import 'package:dsh_android/entry_motion.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _LayoutRuntime extends RuntimeController {
  _LayoutRuntime() {
    phase = 'ready';
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method == 'references.cancel') return {'cancelled': true};
    expectSync(method, 'references.list');
    final drilled = (params['query'] as String).contains('/');
    return <String, dynamic>{
      'files': {
        'ok': true,
        'value': [
          if (!drilled) {'kind': 'directory', 'path': 'documents'},
          for (var index = 0; index < 16; index++)
            {
              'kind': 'file',
              'path': '${drilled ? 'documents/' : ''}reference-$index.md',
            },
        ],
      },
      'sessions': {'ok': true, 'value': <Json>[]},
    };
  }
}

const _listKey = Key('composer-reference-list');
const _headerKey = Key('composer-reference-header');
const _revealKey = Key('composer-reference-reveal');

class _Harness {
  final runtime = _LayoutRuntime();
  final input = TextEditingController();
  final focus = FocusNode();
  final paint = GlobalKey();

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(412, 892),
    double scale = 1,
    double keyboard = 0,
    bool font = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final base = pocketTheme(Brightness.dark);
    await tester.pumpWidget(
      RepaintBoundary(
        key: paint,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: font
              ? base.copyWith(
                  textTheme: base.textTheme.apply(fontFamily: 'ScreenshotFont'),
                )
              : base,
          builder: (context, child) => MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(scale),
              padding: const EdgeInsets.only(top: 24, bottom: 16),
              viewInsets: EdgeInsets.only(bottom: keyboard),
            ),
            child: LiquidGlassScope(
              enabled: true,
              quality: LiquidGlassQuality.standard,
              child: child!,
            ),
          ),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ComposerReferenceSuggestions(
                      runtime: runtime,
                      sessionId: 'bound',
                      input: input,
                      focus: focus,
                      prepare: () async {},
                    ),
                    TextField(controller: input, focusNode: focus),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    edit('@');
    await tester.pump();
  }

  void edit(String text) => input.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    input.dispose();
    focus.dispose();
    runtime.dispose();
  }
}

ScrollableState _listState(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(_listKey),
            matching: find.byType(Scrollable),
          )
          .first,
    );

void _expectCircle(WidgetTester tester, String tooltip) {
  final rect = tester.getRect(find.byTooltip(tooltip));
  expect(rect.width, rect.height);
  expect(rect.width, 44);
}

void main() {
  testWidgets(
    'narrow keyboard layout keeps a full viewport below floating chrome',
    (tester) async {
      final harness = _Harness();
      await harness.mount(
        tester,
        size: const Size(320, 700),
        scale: 1.8,
        keyboard: 280,
      );
      await harness.settle(tester);
      final list = tester.getRect(find.byKey(_listKey));
      final header = tester.getRect(find.byKey(_headerKey));
      expect(list.top, header.top);
      expect(list.left, header.left);
      expect(list.right, header.right);
      expect(list.bottom, lessThan(700 - 280));
      expect(list.height, greaterThan(header.height * 2));
      expect(list.height, lessThan(200));
      _expectCircle(tester, '关闭引用选择');
      _expectCircle(tester, '浏览 documents/');

      final folder = find.byKey(const ValueKey('@documents/'));
      final before = tester.getRect(folder);
      _listState(tester).position.jumpTo(40);
      await tester.pumpAndSettle();
      final after = tester.getRect(folder);
      expect(after.top, before.top - 40);
      expect(after.top, lessThan(header.bottom));
      expect(after.bottom, greaterThan(header.top));
      expect(tester.getRect(find.byKey(_headerKey)), header);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭引用选择'));
      await tester.pumpAndSettle();
      expect(find.byKey(_listKey), findsNothing);
      expect(harness.input.text, '@');
      await harness.close(tester);
    },
  );

  testWidgets(
    'breadcrumbs scroll with files and drill preserves round controls',
    (tester) async {
      final harness = _Harness();
      await harness.mount(tester);
      await harness.settle(tester);
      _expectCircle(tester, '浏览 documents/');
      await tester.tap(find.byTooltip('浏览 documents/'));
      await harness.settle(tester);
      expect(harness.input.text, '@documents/');
      final crumb = find.text('工作区');
      final before = tester.getRect(crumb);
      final header = tester.getRect(find.byKey(_headerKey));
      _listState(tester).position.jumpTo(36);
      await tester.pumpAndSettle();
      expect(tester.getRect(crumb).top, before.top - 36);
      expect(tester.getRect(find.byKey(_headerKey)), header);
      expect(tester.takeException(), isNull);
      await harness.close(tester);
    },
  );

  testWidgets('the chooser reveals once per opening, not per query', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    final reveal = tester.state(find.byKey(_revealKey));
    PocketBlurTransition transition() => tester.widget<PocketBlurTransition>(
      find
          .descendant(
            of: find.byKey(_revealKey),
            matching: find.byType(PocketBlurTransition),
          )
          .first,
    );
    expect(transition().animation.value, lessThan(1));
    await harness.settle(tester);
    expect(transition().animation.value, 1);
    final settledBounds = tester.getRect(find.byKey(_listKey));
    harness.edit('@ref');
    await tester.pump();
    expect(tester.state(find.byKey(_revealKey)), same(reveal));
    expect(transition().animation.value, 1);
    expect(tester.getRect(find.byKey(_listKey)), settledBounds);
    await harness.settle(tester);
    await tester.tap(find.byTooltip('关闭引用选择'));
    await tester.pumpAndSettle();
    harness.edit('@reference');
    await tester.pump();
    expect(tester.state(find.byKey(_revealKey)), isNot(same(reveal)));
    expect(transition().animation.value, lessThan(1));
    await harness.close(tester);
  });

  testWidgets('412-wide picker has readable floating glass header', (
    tester,
  ) async {
    const capture = bool.fromEnvironment('REFERENCE_LAYOUT_CAPTURE');
    if (capture) {
      await tester.runAsync(() async {
        for (final entry in {
          'ScreenshotFont': r'C:\Windows\Fonts\msyh.ttc',
          'MaterialIcons': '../../.cache/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(entry.key)..addFont(
                File(entry.value).readAsBytes().then(ByteData.sublistView),
              ))
              .load();
        }
      });
    }
    final harness = _Harness();
    await harness.mount(tester, font: capture, keyboard: 300);
    await harness.settle(tester);
    _listState(tester).position.jumpTo(32);
    await tester.pumpAndSettle();
    expect(find.byType(FloatingHeader), findsOneWidget);
    expect(find.byType(FloatingEdgeScrim), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    if (capture) {
      await tester.runAsync(() async {
        final boundary =
            harness.paint.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final picture = await boundary.toImage(pixelRatio: 2);
        try {
          final png = await picture.toByteData(format: ui.ImageByteFormat.png);
          final file = File('../../.cache/android/composer-reference-412.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(png!.buffer.asUint8List());
        } finally {
          picture.dispose();
        }
      });
    }
    await harness.close(tester);
  });
}
