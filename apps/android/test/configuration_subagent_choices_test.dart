import 'package:dsh_android/configuration_fields.dart';
import 'package:dsh_android/configuration_edits.dart';
import 'package:dsh_android/configuration_fields_schema.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Future<ValueNotifier<ConfigurationFieldResult?>> open(
    WidgetTester tester, {
    required String path,
    required int initial,
    required Map<String, dynamic> meta,
  }) async {
    final result = ValueNotifier<ConfigurationFieldResult?>(null);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result.value = await Navigator.of(context)
                    .push<ConfigurationFieldResult>(
                      PocketRoute(
                        builder: (_) => ConfigurationStructurePage(
                          field: ConfigurationFieldSchema(
                            ConfigurationSchema(const {}),
                            {'type': 'number', 'meta': meta},
                          ),
                          title: path == 'maxDepth'
                              ? '最大递归深度（层）'
                              : '子 Agent 并行上限（个）',
                          namespace: 'subagent',
                          path: [path],
                          value: initial,
                        ),
                      ),
                    );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('depth offers bounded choices and stages a validated number', (
    tester,
  ) async {
    final result = await open(
      tester,
      path: 'maxDepth',
      initial: 1,
      meta: {'step': 1, 'min': 0, 'max': 2, 'default': 1},
    );
    expect(find.text('关闭子 Agent'), findsOneWidget);
    expect(find.text('1 层'), findsOneWidget);
    expect(find.text('2 层'), findsOneWidget);
    expect(find.text('3 层'), findsNothing);
    expect(find.text('高级 JSON 编辑'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('subagent-choice:0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('structure-value')), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '0',
    );
    await tester.tap(find.byTooltip('完成编辑'));
    await tester.pumpAndSettle();
    expect(result.value?.value, 0);
    expect(find.text('打开'), findsOneWidget);
  });

  testWidgets(
    'capacity accepts custom integer and rejects schema-invalid value',
    (tester) async {
      final result = await open(
        tester,
        path: 'maxActiveSubagents',
        initial: 8,
        meta: {'step': 1, 'min': 1, 'max': 8, 'default': 8},
      );
      expect(find.text('16 个'), findsNothing);
      await tester.enterText(find.byType(TextField), '0');
      await tester.pumpAndSettle();
      expect(find.textContaining('不能小于'), findsOneWidget);
      final save = find.ancestor(
        of: find.byTooltip('完成编辑'),
        matching: find.byType(GlassButton),
      );
      final button = tester.widget<GlassButton>(save);
      expect(button.onPressed, isNull);
      await tester.enterText(find.byType(TextField), '5');
      await tester.pumpAndSettle();
      expect(tester.widget<GlassButton>(save).onPressed, isNotNull);
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(result.value?.value, 5);
      expect(find.text('打开'), findsOneWidget);
    },
  );
}
