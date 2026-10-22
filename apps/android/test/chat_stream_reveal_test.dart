import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_stream_reveal.dart';
import 'package:dsh_android/entry_motion.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _before = 'Retained paragraph\n\n```text\nretained_code\n```\n\nTail old';

class _Harness {
  final boundaryKey = GlobalKey();
  int layouts = 0;

  Widget view(
    String text, {
    bool reduced = false,
    Future<void> Function(Uri)? onOpenLink,
  }) => MaterialApp(
    theme: pocketTheme(Brightness.dark),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: boundaryKey,
            child: SizedBox(
              width: 400,
              height: 500,
              child: ColoredBox(
                color: Colors.black,
                child: _LayoutProbe(
                  onLayout: () => layouts++,
                  child: ChatContent(
                    storageId: 'stream',
                    streaming: true,
                    content: [
                      {'type': 'text', 'text': text},
                    ],
                    onOpenLink: onOpenLink,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<Uint8List> pixels(WidgetTester tester) async =>
      (await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        return data!.buffer.asUint8List();
      }))!;

  List<Rect> boxes(WidgetTester tester, String text, int start, int end) {
    final paragraph = tester.allRenderObjects
        .whereType<RenderParagraph>()
        .firstWhere((paragraph) => paragraph.text.toPlainText().contains(text));
    final textOffset = paragraph.text.toPlainText().indexOf(text);
    final boundary = boundaryKey.currentContext!.findRenderObject()!;
    final transform = paragraph.getTransformTo(boundary);
    return [
      for (final box in paragraph.getBoxesForSelection(
        TextSelection(
          baseOffset: textOffset + start,
          extentOffset: textOffset + end,
        ),
      ))
        MatrixUtils.transformRect(transform, box.toRect()),
    ];
  }
}

List<int> _region(Uint8List pixels, Iterable<Rect> boxes) => [
  for (final box in boxes)
    for (
      var y = box.top.floor().clamp(0, 499);
      y < box.bottom.ceil().clamp(0, 500);
      y++
    )
      for (
        var x = box.left.floor().clamp(0, 399);
        x < box.right.ceil().clamp(0, 400);
        x++
      )
        pixels[(y * 400 + x) * 4],
];

int _light(Uint8List pixels, Iterable<Rect> boxes) =>
    _region(pixels, boxes).fold(0, (sum, value) => sum + value);

void main() {
  testWidgets(
    'Markdown after a composited code block reveals only its appended glyphs',
    (tester) async {
      final harness = _Harness();
      await tester.pumpWidget(harness.view(_before));
      await tester.pumpAndSettle();
      expect(find.byType(ChatStreamReveal), findsOneWidget);
      expect(
        tester
            .stateList<ScrollableState>(find.byType(Scrollable))
            .where(
              (state) =>
                  axisDirectionToAxis(state.axisDirection) == Axis.horizontal,
            ),
        isNotEmpty,
      );
      final original = await harness.pixels(tester);
      final oldBoxes = harness.boxes(tester, 'Tail old', 0, 8);
      final retainedCode = harness.boxes(tester, 'retained_code', 0, 13);

      await tester.pumpWidget(harness.view('$_before fresh'));
      final newBoxes = harness.boxes(tester, 'Tail old fresh', 9, 14);
      final initial = await harness.pixels(tester);
      final layoutCount = harness.layouts;
      expect(tester.layers.whereType<ShaderMaskLayer>(), hasLength(1));
      await tester.pump(const Duration(milliseconds: 90));
      final middle = await harness.pixels(tester);
      await tester.pump(PocketEntryMotion.duration);
      final settled = await harness.pixels(tester);
      expect(
        _region(initial, oldBoxes),
        orderedEquals(_region(original, oldBoxes)),
      );
      expect(
        _region(middle, oldBoxes),
        orderedEquals(_region(original, oldBoxes)),
      );
      expect(
        _region(initial, retainedCode),
        orderedEquals(_region(original, retainedCode)),
      );
      expect(_light(middle, newBoxes), greaterThan(_light(initial, newBoxes)));
      expect(_light(settled, newBoxes), greaterThan(_light(middle, newBoxes)));
      expect(
        harness.layouts,
        layoutCount,
        reason: 'animation only invalidates paint',
      );
      expect(tester.layers.whereType<ShaderMaskLayer>(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion remains fully visible and cancels an in-flight reveal',
    (tester) async {
      final harness = _Harness();
      await tester.pumpWidget(harness.view(_before));
      await tester.pumpAndSettle();
      await tester.pumpWidget(harness.view('$_before fresh'));
      expect(tester.layers.whereType<ShaderMaskLayer>(), hasLength(1));
      await tester.pumpWidget(harness.view('$_before fresh', reduced: true));
      final now = await harness.pixels(tester);
      await tester.pump(PocketEntryMotion.duration);
      expect(await harness.pixels(tester), orderedEquals(now));
      expect(tester.layers.whereType<ShaderMaskLayer>(), isEmpty);
      await tester.pumpWidget(
        harness.view('$_before fresh final', reduced: true),
      );
      final finalPixels = await harness.pixels(tester);
      await tester.pump(PocketEntryMotion.duration);
      expect(await harness.pixels(tester), orderedEquals(finalPixels));
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'streamed Markdown keeps links, tables, semantics and code scrolling interactive',
    (tester) async {
      final harness = _Harness();
      final opened = <Uri>[];
      const markdown =
          '[Documentation](https://example.com/docs)\n\n'
          '```text\n01234567890123456789012345678901234567890123456789012345678901234567890\n```\n\n'
          '| Name | Value |\n| --- | --- |\n| preserved | 42 |\n\nTail';
      Future<void> onOpenLink(Uri uri) async => opened.add(uri);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(harness.view(markdown, onOpenLink: onOpenLink));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        harness.view('$markdown new text', onOpenLink: onOpenLink),
      );
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.text('preserved', findRichText: true), findsOneWidget);
      expect(find.text('42', findRichText: true), findsOneWidget);
      expect(find.bySemanticsLabel('Tail new text'), findsOneWidget);
      await tester.tap(find.text('Documentation', findRichText: true));
      await tester.pump();
      expect(opened, [Uri.parse('https://example.com/docs')]);
      final horizontal = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .singleWhere(
            (state) =>
                axisDirectionToAxis(state.axisDirection) == Axis.horizontal,
          );
      expect(horizontal.position.maxScrollExtent, greaterThan(0));
      await tester.drag(
        find.byType(Scrollable).first,
        const Offset(-150, 0),
      );
      await tester.pumpAndSettle();
      expect(horizontal.position.pixels, greaterThan(0));
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
}

class _LayoutProbe extends SingleChildRenderObjectWidget {
  const _LayoutProbe({required this.onLayout, required super.child});
  final VoidCallback onLayout;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _LayoutRender(onLayout);
}

class _LayoutRender extends RenderProxyBox {
  _LayoutRender(this.onLayout);
  final VoidCallback onLayout;
  @override
  void performLayout() {
    onLayout();
    super.performLayout();
  }
}
