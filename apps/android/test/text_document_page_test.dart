import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:dsh_android/text_document_page.dart';
import 'package:dsh_android/ui.dart';

Future<void> mountDocument(
  WidgetTester tester,
  Widget page, {
  ValueChanged<String?>? onResult,
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => PocketScaffold(
          title: const Text('父草稿'),
          body: PocketButton(
            onPressed: () async {
              final result = await Navigator.of(context)
                  .push<String>(PocketRoute(builder: (_) => page));
              onResult?.call(result);
            },
            child: const Text('打开文档'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开文档'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('explanations are plain reading pages without editor actions', (
    tester,
  ) async {
    await mountDocument(
      tester,
      const TextDocumentPage(title: '配置说明', text: '说明配置如何影响运行。'),
    );
    expect(find.text('说明配置如何影响运行。'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(EditableText), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
    expect(find.byTooltip('复制全文'), findsNothing);
    expect(find.byTooltip('完成编辑'), findsNothing);
    await tester.longPress(find.text('说明配置如何影响运行。'));
    await tester.pumpAndSettle();
    expect(find.text('Select all'), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'sensitive documents mask locally and disable IME learning and copy',
    (tester) async {
      String? result;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          return {'text': 'updated-synthetic-secret'};
        }
        if (call.method == 'Clipboard.hasStrings') return {'value': true};
        if (call.method == 'Clipboard.setData') {
          fail('Masked credentials must not be copied.');
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await mountDocument(
        tester,
        const TextDocumentPage(
          title: '凭据',
          text: 'synthetic-secret',
          readOnly: false,
          obscureText: true,
        ),
        onResult: (value) => result = value,
      );
      var field = tester.widget<TextField>(find.byType(TextField));
      expect(field.obscureText, isTrue);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      expect(field.enableInteractiveSelection, isTrue);
      expect(field.maxLines, 1);
      expect(field.keyboardType, TextInputType.visiblePassword);
      expect(find.byTooltip('复制全文'), findsNothing);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      field.controller!.selection = TextSelection(
        baseOffset: 0,
        extentOffset: field.controller!.text.length,
      );
      expect(editable.copyEnabled, isFalse);
      expect(editable.cutEnabled, isFalse);
      await editable.pasteText(SelectionChangedCause.toolbar);
      await tester.pumpAndSettle();
      expect(field.controller!.text, 'updated-synthetic-secret');
      await tester.tap(find.text('显示凭据'));
      await tester.pumpAndSettle();
      field = tester.widget<TextField>(find.byType(TextField));
      expect(field.obscureText, isFalse);
      expect(field.enableInteractiveSelection, isTrue);
      expect(field.maxLines, 1);
      expect(result, isNull);
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(result, 'updated-synthetic-secret');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'touching viewport whitespace or the field gutter dismisses focus without losing the draft',
    (tester) async {
      String? result;
      await mountDocument(
        tester,
        const TextDocumentPage(title: '文本编辑', text: 'before', readOnly: false),
        onResult: (value) => result = value,
      );
      final input = find.byType(TextField);
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      await tester.enterText(input, 'retained local draft');
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(editable.widget.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      final body = tester.getRect(find.byType(PocketList));
      final blank = Offset(body.center.dx, body.bottom - 28);
      expect(tester.getRect(input).contains(blank), isFalse);
      await tester.tapAt(blank, kind: PointerDeviceKind.touch);
      await tester.pumpAndSettle();
      expect(editable.widget.focusNode.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(editable.widget.controller.text, 'retained local draft');
      expect(result, isNull);

      await tester.tap(input, kind: PointerDeviceKind.touch);
      await tester.pumpAndSettle();
      expect(editable.widget.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      final field = tester.getRect(input);
      await tester.tapAt(
        Offset(field.left - 8, field.center.dy),
        kind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();
      expect(editable.widget.focusNode.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(editable.widget.controller.text, 'retained local draft');
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(result, 'retained local draft');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'body taps preserve text focus and selection while gutter drags still scroll',
    (tester) async {
      final text = List.filled(
        80,
        'selectable words remain in the draft',
      ).join('\n');
      await mountDocument(
        tester,
        TextDocumentPage(title: '文本编辑', text: text, readOnly: false),
      );
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      final word =
          tester.getTopLeft(find.byType(EditableText)) + const Offset(20, 12);
      await tester.tapAt(word, kind: PointerDeviceKind.touch);
      await tester.pumpAndSettle();
      expect(editable.widget.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.longPressAt(word, kind: PointerDeviceKind.touch);
      await tester.pumpAndSettle();
      expect(editable.widget.focusNode.hasFocus, isTrue);
      expect(editable.widget.controller.selection.isCollapsed, isFalse);
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(PocketList),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final before = scroll.position.pixels;
      await tester.dragFrom(const Offset(8, 600), const Offset(0, -250));
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, greaterThan(before));
      expect(editable.widget.controller.text, text);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shared document fields also dismiss touch focus outside a standalone host',
    (tester) async {
      final controller = TextEditingController(text: 'shared field');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: PocketScaffold(
            title: const Text('共享编辑器'),
            body: PocketList(
              children: [TextDocumentField(controller: controller)],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField), kind: PointerDeviceKind.touch);
      await tester.pumpAndSettle();
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      expect(editable.widget.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      final body = tester.getRect(find.byType(PocketList));
      await tester.tapAt(
        Offset(body.center.dx, body.bottom - 20),
        kind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();
      expect(editable.widget.focusNode.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(controller.text, 'shared field');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a 64 KiB readonly log scrolls to its last character and copies the full buffer',
    (tester) async {
      final text = List.generate(1024, (index) {
        final line = '${index.toString().padLeft(4, '0')} diagnostic line'
            .padRight(63, '.');
        return '$line\n';
      }).join();
      final clipboard = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') clipboard.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      expect(text.length, 64 * 1024);
      await mountDocument(
        tester,
        TextDocumentPage(
          title: '完整诊断日志',
          text: text,
          monospace: true,
          selectable: true,
        ),
      );
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(PocketList),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(scroll.position.maxScrollExtent, greaterThan(844));
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, scroll.position.maxScrollExtent);
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      final lastCharacter = editable.localToGlobal(
        editable.getLocalRectForCaret(TextPosition(offset: text.length)).center,
      );
      expect(lastCharacter.dy, inInclusiveRange(0, 844));
      expect(find.byTooltip('复制全文').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('复制全文'));
      await tester.pumpAndSettle();
      expect(clipboard.single.arguments, {'text': text});
      expect(tester.testTextInput.isVisible, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a multi-ten-thousand character document keeps its full buffer after editing and scrolling',
    (tester) async {
      final original = List.generate(
        1200,
        (index) => '$index: configuration diagnostic with preserved content',
      ).join('\n');
      String? result;
      await mountDocument(
        tester,
        TextDocumentPage(title: '长文本', text: original, readOnly: false),
        onResult: (text) => result = text,
        scale: 1.8,
      );
      expect(original.length, greaterThan(50000));
      final next = '$original\nlast line';
      await tester.enterText(find.byType(TextField), next);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(PocketList), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        next,
      );
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(result, next);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'readonly document selects and copies text without offering save or a keyboard',
    (tester) async {
      final clipboard = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') clipboard.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await mountDocument(
        tester,
        const TextDocumentPage(
          title: '诊断原文',
          selectable: true,
          text: '{"status":"pending"}',
          monospace: true,
        ),
      );
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.readOnly, isTrue);
      expect(field.enableInteractiveSelection, isTrue);
      expect(field.maxLines, isNull);
      expect(field.minLines, 1);
      expect(find.byTooltip('完成编辑'), findsNothing);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(find.byTooltip('复制全文'));
      await tester.pumpAndSettle();
      expect(clipboard.single.arguments, {'text': '{"status":"pending"}'});
      expect(find.byTooltip('已复制'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editable text grows with content and returns only an explicit local result',
    (tester) async {
      String? returned;
      await mountDocument(
        tester,
        const TextDocumentPage(title: '提示词', text: '短文本', readOnly: false),
        onResult: (result) => returned = result,
      );
      final input = find.byType(TextField);
      final before = tester.getSize(input).height;
      await tester.tap(input);
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      final text = List.filled(24, '一段需要完整保留的长文本').join('\n');
      await tester.enterText(input, text);
      await tester.pumpAndSettle();
      expect(tester.getSize(input).height, greaterThan(before * 4));
      expect(returned, isNull);
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(returned, text);
      expect(find.text('父草稿'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invalid input stays on the page until corrected or explicitly discarded',
    (tester) async {
      String? returned;
      await mountDocument(
        tester,
        TextDocumentPage(
          title: 'JSON',
          text: '{}',
          readOnly: false,
          validate: (text) => text == '{}' ? null : 'JSON 无法解析，输入已保留。',
        ),
        onResult: (result) => returned = result,
      );
      await tester.enterText(find.byType(TextField), '{ invalid');
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(find.text('JSON 无法解析，输入已保留。'), findsOneWidget);
      expect(returned, isNull);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('保留当前编辑？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '{ invalid',
      );
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃编辑并返回'));
      await tester.pumpAndSettle();
      expect(returned, isNull);
      expect(find.text('父草稿'), findsOneWidget);
    },
  );

  testWidgets(
    'owner becoming uncertain prevents applying and retains the local buffer',
    (tester) async {
      final editable = ValueNotifier(true);
      addTearDown(editable.dispose);
      await mountDocument(
        tester,
        TextDocumentPage(
          title: '配置',
          text: 'before',
          readOnly: false,
          editingState: editable,
          canEdit: () => editable.value,
        ),
      );
      await tester.enterText(find.byType(TextField), 'local draft');
      editable.value = false;
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      expect(
        tester
            .widget<GlassButton>(
              find.byWidgetPredicate(
                (widget) => widget is GlassButton && widget.label == '完成编辑',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'local draft',
      );
      editable.value = true;
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).readOnly,
        isFalse,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'local draft',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large text uses one scrollable document field under a centered floating title',
    (tester) async {
      await mountDocument(
        tester,
        TextDocumentPage(
          title: '配置原文',
          selectable: true,
          text: List.filled(80, '原始代码与详细诊断').join('\n'),
        ),
        scale: 1.8,
      );
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(TextDocumentField), findsOneWidget);
      expect(tester.getCenter(find.text('配置原文')).dx, closeTo(195, 1));
      expect(tester.getSize(find.byType(TextField)).height, greaterThan(844));
      await tester.drag(find.byType(PocketList), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.byTooltip('复制全文').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
