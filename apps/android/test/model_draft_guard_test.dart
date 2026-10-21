import 'package:dsh_android/models.dart' show ModelDraftGuard;
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _inputKey = Key('guard-input');
const _underlyingKey = Key('guard-underlying-action');

Future<void> mountGuard(
  WidgetTester tester, {
  required TextEditingController input,
  required FocusNode focus,
  ValueChanged<String?>? onResult,
  VoidCallback? onUnderlying,
  ValueNotifier<bool>? busy,
  Size size = const Size(390, 844),
  double scale = 1,
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: reduceMotion,
        ),
        child: child!,
      ),
      home: Builder(
        builder: (context) => PocketScaffold(
          title: const Text('父页面'),
          body: Center(
            child: PocketButton(
              onPressed: () async {
                final result = await Navigator.of(context).push<String>(
                  PocketRoute(
                    builder: (context) {
                      Widget page(bool isBusy) => ModelDraftGuard(
                        busy: isBusy,
                        hasEdits: () => input.text != 'original',
                        child: PocketScaffold(
                          title: const Text('草稿页面'),
                          trailing: GlassButton(
                            icon: Icons.check_rounded,
                            label: '完成草稿',
                            onPressed: () =>
                                Navigator.of(context).pop(input.text),
                          ),
                          body: PocketList(
                            children: [
                              TextField(
                                key: _inputKey,
                                controller: input,
                                focusNode: focus,
                                maxLines: null,
                              ),
                              PocketButton(
                                key: _underlyingKey,
                                onPressed: onUnderlying ?? () {},
                                child: const Text('底层操作'),
                              ),
                            ],
                          ),
                        ),
                      );

                      return busy == null
                          ? page(false)
                          : ValueListenableBuilder<bool>(
                              valueListenable: busy,
                              builder: (context, value, _) => page(value),
                            );
                    },
                  ),
                );
                onResult?.call(result);
              },
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('编辑'));
  await tester.pumpAndSettle();
}

void main() {
  late TextEditingController input;
  late FocusNode focus;

  setUp(() {
    input = TextEditingController(text: 'original');
    focus = FocusNode();
  });
  tearDown(() {
    input.dispose();
    focus.dispose();
  });

  testWidgets(
    'review closes selection and keyboard, blocks the form, and continuing retains the exact editor',
    (tester) async {
      var underlyingCalls = 0;
      await mountGuard(
        tester,
        input: input,
        focus: focus,
        onUnderlying: () => underlyingCalls++,
      );
      await tester.enterText(find.byKey(_inputKey), 'unsaved text');
      input.selection = const TextSelection(baseOffset: 0, extentOffset: 7);
      await tester.pump();
      final editor = tester.state<EditableTextState>(find.byType(EditableText));
      editor.showToolbar();
      await tester.pumpAndSettle();
      expect(editor.selectionOverlay?.toolbarIsVisible, isTrue);
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      final underneath = tester.getCenter(find.byKey(_underlyingKey));

      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('保留当前编辑？'), findsOneWidget);
      expect(focus.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(editor.selectionOverlay?.toolbarIsVisible ?? false, isFalse);
      await tester.tapAt(underneath);
      await tester.tapAt(const Offset(10, 820));
      await tester.pumpAndSettle();
      expect(underlyingCalls, 0);
      expect(find.text('保留当前编辑？'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('保留当前编辑？'), findsOneWidget);
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isFalse);

      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.text('保留当前编辑？'), findsNothing);
      expect(
        tester.state<EditableTextState>(find.byType(EditableText)),
        same(editor),
      );
      expect(input.text, 'unsaved text');
      await tester.tap(find.byKey(_inputKey));
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('保留当前编辑？'), findsOneWidget);
      await tester.tap(find.text('放弃编辑并返回'));
      await tester.pumpAndSettle();
      expect(find.text('父页面'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'small screen and large text keep both actions reachable above keyboard',
    (tester) async {
      await mountGuard(
        tester,
        input: input,
        focus: focus,
        size: const Size(320, 480),
        scale: 2,
      );
      input.text = 'draft';
      // Keep platform insets set even after unfocus, as while the IME is closing.
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      final viewport = find.byKey(const Key('draft-review-scroll'));
      expect(tester.getBottomLeft(viewport).dy, lessThanOrEqualTo(260));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.text('继续编辑').hitTestable(), findsOneWidget);
      await tester.ensureVisible(find.text('放弃编辑并返回'));
      await tester.pumpAndSettle();
      expect(find.text('放弃编辑并返回').hitTestable(), findsOneWidget);
      expect(tester.getCenter(find.text('放弃编辑并返回')).dy, lessThan(260));
      await tester.tap(find.text('放弃编辑并返回'));
      await tester.pumpAndSettle();
      expect(find.text('父页面'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit completed result returns once without a discard prompt',
    (tester) async {
      final results = <String?>[];
      await mountGuard(
        tester,
        input: input,
        focus: focus,
        onResult: results.add,
      );
      await tester.enterText(find.byKey(_inputKey), 'validated draft');
      await tester.tap(find.byTooltip('完成草稿'));
      await tester.pumpAndSettle();
      expect(results, ['validated draft']);
      expect(find.text('保留当前编辑？'), findsNothing);
      expect(find.text('父页面'), findsOneWidget);
    },
  );

  testWidgets('unchanged form leaves directly and busy form cannot leave', (
    tester,
  ) async {
    final busy = ValueNotifier(true);
    addTearDown(busy.dispose);
    final results = <String?>[];
    await mountGuard(
      tester,
      input: input,
      focus: focus,
      busy: busy,
      onResult: results.add,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(results, isEmpty);
    expect(find.text('草稿页面'), findsOneWidget);
    expect(find.text('保留当前编辑？'), findsNothing);
    busy.value = false;
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(results, [null]);
    expect(find.text('父页面'), findsOneWidget);
  });

  for (final reduced in [false, true]) {
    testWidgets(
      'confirmation uses shared appearance motion (reduced=$reduced)',
      (tester) async {
        await mountGuard(
          tester,
          input: input,
          focus: focus,
          reduceMotion: reduced,
        );
        input.text = 'draft';
        await tester.tap(find.byTooltip('返回'));
        await tester.pump();
        final filters = tester.widgetList<ImageFiltered>(
          find.byType(ImageFiltered),
        );
        expect(filters.any((filter) => filter.enabled), !reduced);
        await tester.pumpAndSettle();
        expect(find.text('继续编辑').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
