import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_android/configuration_edits.dart';
import 'package:dsh_android/configuration_fields.dart';
import 'package:dsh_android/configuration_fields_schema.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

ConfigurationFieldSchema shape(Map<String, dynamic> node) =>
    ConfigurationFieldSchema(ConfigurationSchema(node), node);
final modelSchema = shape({
  'type': 'object',
  'dict': {
    'id': {
      'type': 'string',
      'meta': {'required': true},
    },
    'maxTokens': {
      'type': 'number',
      'meta': {'min': 1, 'step': 1},
    },
    'input': {
      'type': 'array',
      'inner': {
        'type': 'union',
        'list': [
          {'type': 'const', 'value': 'text'},
          {'type': 'const', 'value': 'image'},
        ],
      },
    },
  },
});

final captureKey = GlobalKey();
Future<void> open(
  WidgetTester tester,
  ConfigurationFieldSchema schema,
  dynamic value,
  ValueChanged<dynamic> result, {
  bool adding = false,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = Size(scale > 1 ? 360 : 420, scale > 1 ? 800 : 960);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: RepaintBoundary(key: captureKey, child: child!),
      ),
      home: Builder(
        builder: (context) => PocketButton(
          child: const Text('打开'),
          onPressed: () async {
            final next = await Navigator.of(context)
                .push<ConfigurationFieldResult>(
                  PocketRoute(
                    builder: (_) => ConfigurationStructurePage(
                      field: schema,
                      title: '模型参数',
                      value: value,
                      adding: adding,
                      labels: const {
                        'id': '模型 ID',
                        'maxTokens': '最大输出 Token',
                        'input': '输入类型',
                      },
                    ),
                  ),
                );
            if (next != null) result(next.value);
          },
        ),
      ),
    ),
  );
  await tap(tester, find.text('打开'));
}

Future<void> tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['POCKET_CAPTURE_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final bytes =
        await (captureKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
    final png = await bytes.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(png!.buffer.asUint8List());
    bytes.dispose();
  });
}

void main() {
  setUpAll(() async {
    final path = Platform.environment['POCKET_CAPTURE_FONT'];
    if (path != null) {
      final loader = FontLoader('Roboto')
        ..addFont(
          Future.value(ByteData.sublistView(await File(path).readAsBytes())),
        );
      await loader.load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  test(
    'real uid refs schemas resolve object arrays, enums and typed dict keys',
    () {
      final wire = ConfigurationSchema({
        'uid': 1,
        'refs': {
          '1': {'type': 'array', 'inner': 2},
          '2': {
            'type': 'object',
            'dict': {'id': 3, 'input': 4},
          },
          '3': {
            'type': 'string',
            'meta': {'required': true},
          },
          '4': {'type': 'array', 'inner': 5},
          '5': {
            'type': 'union',
            'list': [6, 7],
          },
          '6': {'type': 'const', 'value': 'text'},
          '7': {'type': 'const', 'value': 'image'},
        },
      });
      final field = ConfigurationFieldSchema(wire, wire.root);
      expect(
        field.validate([
          {
            'id': 'exact',
            'input': ['image'],
            'unknown': true,
          },
        ]),
        isNull,
      );
      expect(
        field.validate([
          {
            'input': ['image'],
          },
        ]),
        contains('id'),
      );
      expect(
        field.validate([
          {
            'id': 'exact',
            'input': ['audio'],
          },
        ]),
        contains('选项'),
      );
      // Required means non-null in Schemastery; it does not imply nonempty.
      expect(
        field.validate([
          {'id': ''},
        ]),
        isNull,
      );
    },
  );
  test(
    'serialized regex and range enforce reliable input constraints only',
    () {
      final urls = shape({
        'type': 'array',
        'inner': {
          'type': 'string',
          'meta': {
            'pattern': {'source': r'^https?://\S+$', 'flags': 'u'},
          },
        },
      });
      expect(urls.validate(['https://example.test/index.json']), isNull);
      expect(urls.validate(['file:///local']), contains('格式'));
      expect(
        modelSchema.validate({'id': 'a', 'maxTokens': 0}),
        contains('不能小于'),
      );
      expect(
        modelSchema.validate({'id': 'a', 'maxTokens': 1.5}),
        contains('整数'),
      );
      expect(
        shape({
          'type': 'array',
          'meta': {'min': 2},
          'inner': {
            'type': 'string',
            'meta': {'default': 'x'},
          },
        }).validate([]),
        isNull,
      );
    },
  );
  test(
    'primitive unions have typed branches and secret structures stay protected',
    () {
      expect(
        shape({
          'type': 'union',
          'list': [
            {'type': 'boolean'},
            {'type': 'object'},
          ],
        }).native,
        isTrue,
      );
      expect(
        shape({
          'type': 'array',
          'inner': {
            'type': 'object',
            'dict': {
              'token': {
                'type': 'string',
                'meta': {'role': 'secret'},
              },
            },
          },
        }).secret,
        isTrue,
      );
    },
  );

  test(
    'mixed branch validation preserves JSON kinds and disjoint intersections',
    () {
      final nullable = shape({
        'type': 'union',
        'list': [
          {'type': 'string'},
          {'type': 'const', 'value': null},
        ],
      });
      expect(nullable.branchChoice, isTrue);
      expect(nullable.validate('value'), isNull);
      expect(nullable.validate(null), isNull);
      expect(nullable.validate(false), isNotNull);
      final joined = shape({
        'type': 'intersect',
        'list': [
          {
            'type': 'object',
            'dict': {
              'enabled': {'type': 'boolean'},
            },
          },
          {
            'type': 'object',
            'dict': {
              'limit': {
                'type': 'number',
                'meta': {'min': 1},
              },
            },
          },
        ],
      });
      expect(joined.type, 'object');
      expect(joined.fields.keys, ['enabled', 'limit']);
      expect(joined.validate({'enabled': true, 'limit': 0}), contains('不能小于'));
      expect(
        shape({
          'type': 'intersect',
          'list': [
            {
              'type': 'object',
              'dict': {
                'value': {'type': 'boolean'},
              },
            },
            {
              'type': 'object',
              'dict': {
                'value': {'type': 'string'},
              },
            },
          ],
        }).native,
        isFalse,
      );
      expect(
        shape({
          'type': 'transform',
          'inner': {'type': 'boolean'},
        }).native,
        isFalse,
      );
    },
  );

  testWidgets(
    'nullable dictionary edits choose exact types without exposing JSON',
    (tester) async {
      final schema = shape({
        'type': 'union',
        'list': [
          {'type': 'const', 'value': false},
          {
            'type': 'dict',
            'sKey': {'type': 'string'},
            'inner': {
              'type': 'union',
              'list': [
                {'type': 'string'},
                {'type': 'const', 'value': null},
              ],
            },
          },
        ],
      });
      dynamic result;
      await open(tester, schema, {
        'high': 'wire-high',
      }, (next) => result = next);
      expect(find.byType(TextField), findsNothing);
      await tap(tester, find.text('键值列表'));
      await tap(tester, find.byKey(const Key('structure-entry:high')));
      expect(find.byKey(const Key('structure-json')), findsNothing);
      await tap(tester, find.text('空值'));
      await tap(tester, find.byTooltip('完成编辑'));
      await tap(tester, find.byTooltip('完成编辑'));
      expect(result, isNull);
      await tap(tester, find.byTooltip('完成编辑'));
      expect(result, {'high': null});
    },
  );

  testWidgets(
    'unknown union values survive until an explicit branch replacement',
    (tester) async {
      dynamic result;
      final schema = shape({
        'type': 'union',
        'list': [
          {'type': 'boolean'},
          {'type': 'number'},
        ],
      });
      await open(
        tester,
        schema,
        'unknown saved string',
        (next) => result = next,
      );
      expect(find.text('unknown saved string'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tap(tester, find.text('数字'));
      await tester.enterText(find.byKey(const Key('structure-value')), '7');
      await tap(tester, find.byTooltip('添加到草稿'));
      expect(result, isNull);
      await tap(tester, find.byTooltip('完成编辑'));
      expect(result, 7);
      expect(result, isNot(isA<String>()));
    },
  );

  testWidgets(
    'nested object stages exact field values and preserves unknown keys',
    (tester) async {
      dynamic result;
      await open(tester, modelSchema, {
        'id': 'old',
        'unknown': {'keep': true},
      }, (value) => result = value);
      await tap(tester, find.byKey(const Key('structure-entry:id')));
      await tester.enterText(
        find.byKey(const Key('structure-value')),
        'new-exact-id',
      );
      await tap(tester, find.byTooltip('完成编辑'));
      expect(result, isNull);
      await tap(tester, find.byTooltip('完成编辑'));
      expect(result, {
        'id': 'new-exact-id',
        'unknown': {'keep': true},
      });
    },
  );
  testWidgets(
    'nested boolean choices and explicit defaults stage values without JSON',
    (tester) async {
      dynamic result;
      final schema = shape({
        'type': 'object',
        'dict': {
          'active': {
            'type': 'union',
            'list': [
              {'type': 'const', 'value': true},
              {'type': 'const', 'value': false},
            ],
          },
          'preview': {
            'type': 'boolean',
            'meta': {'default': false},
          },
        },
      });
      await open(tester, schema, {
        'active': true,
        'unknown': 'keep',
      }, (next) => result = next);
      final active = find.byKey(const ValueKey('structure-entry:active'));
      final preview = find.byKey(const ValueKey('structure-entry:preview'));
      expect(tester.widget<PocketSwitchRow>(active).value, isTrue);
      expect(tester.widget<PocketSwitchRow>(preview).value, isFalse);
      expect(find.byKey(const Key('structure-json')), findsNothing);
      await tap(tester, active);
      await tap(tester, preview);
      await tap(tester, find.byTooltip('完成编辑'));
      expect(result, {'active': false, 'preview': true, 'unknown': 'keep'});
    },
  );
  testWidgets('explicit boolean default stays inherited until toggled', (
    tester,
  ) async {
    dynamic result;
    final schema = shape({
      'type': 'boolean',
      'meta': {'default': true},
    });
    await open(
      tester,
      schema,
      configurationValueAt(const {}, ['missing']),
      (next) => result = next,
    );
    expect(
      tester.widget<PocketSwitchRow>(find.byType(PocketSwitchRow)).value,
      isTrue,
    );
    expect(find.text('使用默认值'), findsOneWidget);
    await tap(tester, find.byTooltip('完成编辑'));
    expect(result, isNull);

    await open(
      tester,
      schema,
      configurationValueAt(const {}, ['missing']),
      (next) => result = next,
    );
    await tap(tester, find.byType(PocketSwitchRow));
    await tap(tester, find.byTooltip('完成编辑'));
    expect(result, isFalse);
  });
  testWidgets(
    'scalar detail releases touch focus in blank space and preserves its buffer',
    (tester) async {
      dynamic result;
      await open(
        tester,
        shape({'type': 'string'}),
        'before',
        (value) => result = value,
      );
      final input = find.byKey(const Key('structure-value'));
      await tester.enterText(input, 'unsaved value');
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tapAt(const Offset(210, 600));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      expect(tester.widget<TextField>(input).controller!.text, 'unsaved value');
      await tap(tester, find.byTooltip('完成编辑'));
      expect(result, 'unsaved value');
    },
  );
  testWidgets(
    'nested field default removes only that value and preserves unknown siblings',
    (tester) async {
      dynamic result;
      await open(tester, modelSchema, {
        'id': 'kept',
        'maxTokens': 1024,
        'unknown': {'keep': true},
      }, (value) => result = value);
      expect(find.text('使用默认值'), findsNothing);
      await tap(tester, find.byKey(const Key('structure-entry:maxTokens')));
      await tap(tester, find.text('使用默认值'));
      expect(result, isNull);
      await tap(tester, find.byTooltip('完成编辑'));
      expect(result, {
        'id': 'kept',
        'unknown': {'keep': true},
      });
    },
  );
  testWidgets(
    'invalid numeric buffer stays visible and exit requires explicit discard',
    (tester) async {
      dynamic result;
      await open(
        tester,
        shape({'type': 'number'}),
        10,
        (value) => result = value,
      );
      await tester.enterText(find.byKey(const Key('structure-value')), 'oops');
      await tester.pumpAndSettle();
      final button = find.widgetWithIcon(GlassButton, Icons.check_rounded);
      expect(tester.widget<GlassButton>(button).onPressed, isNull);
      await tap(tester, find.byTooltip('返回'));
      expect(find.text('保留当前编辑？'), findsOneWidget);
      await tap(tester, find.text('继续编辑'));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('structure-value')))
            .controller!
            .text,
        'oops',
      );
      await tap(tester, find.byTooltip('返回'));
      await tap(tester, find.text('放弃编辑并返回'));
      expect(result, isNull);
    },
  );
  testWidgets(
    'object arrays add, edit and remove entries without mutating input',
    (tester) async {
      dynamic result;
      final initial = [
        {'id': 'first', 'unknown': 3},
        {'id': 'second'},
      ];
      final array = shape({'type': 'array', 'inner': modelSchema.node});
      await open(tester, array, initial, (value) => result = value);
      await tap(tester, find.byTooltip('移除 第 2 项'));
      await tap(tester, find.text('添加项目'));
      await tap(tester, find.byKey(const Key('structure-entry:id')));
      await tester.enterText(find.byKey(const Key('structure-value')), 'third');
      await tap(tester, find.byTooltip('完成编辑'));
      await tap(tester, find.byTooltip('添加到草稿'));
      await tap(tester, find.byTooltip('完成编辑'));
      expect(result, [
        {'id': 'first', 'unknown': 3},
        {'id': 'third'},
      ]);
      expect(initial, hasLength(2));
      expect(initial.last['id'], 'second');
    },
  );
  testWidgets('typed dictionary refuses duplicate key and stages new value', (
    tester,
  ) async {
    dynamic result;
    await open(
      tester,
      shape({
        'type': 'dict',
        'sKey': {'type': 'string'},
        'inner': {'type': 'string'},
      }),
      {'Authorization-Type': 'custom'},
      (value) => result = value,
    );
    await tap(tester, find.text('添加项目'));
    await tester.enterText(
      find.byKey(const Key('structure-key')),
      'Authorization-Type',
    );
    await tap(tester, find.text('继续'));
    expect(find.text('此名称已存在，请使用其他名称。'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('structure-key')), 'X-Client');
    await tap(tester, find.text('继续'));
    await tester.enterText(find.byKey(const Key('structure-value')), 'Pocket');
    await tap(tester, find.byTooltip('添加到草稿'));
    await tap(tester, find.byTooltip('完成编辑'));
    expect(result, {'Authorization-Type': 'custom', 'X-Client': 'Pocket'});
  });
  testWidgets('enum arrays choose schema values without inventing defaults', (
    tester,
  ) async {
    dynamic result;
    await open(
      tester,
      modelSchema.fields['input']!,
      [],
      (value) => result = value,
    );
    await tap(tester, find.text('添加项目'));
    await tap(tester, find.text('image'));
    await tap(tester, find.byTooltip('添加到草稿'));
    await tap(tester, find.byTooltip('完成编辑'));
    expect(result, ['image']);
  });
  testWidgets(
    'advanced child preserves malformed JSON until corrected or discarded',
    (tester) async {
      dynamic result;
      await open(tester, shape({'type': 'any'}), {
        'x': 1,
      }, (value) => result = value);
      expect(find.byKey(const Key('structure-json')), findsNothing);
      await tap(tester, find.text('高级工具'));
      await tester.enterText(find.byKey(const Key('structure-json')), '{ bad');
      await tap(tester, find.byTooltip('完成编辑'));
      expect(find.text('JSON 无法解析，输入已保留。'), findsOneWidget);
      await tap(tester, find.byTooltip('返回'));
      expect(find.text('保留当前编辑？'), findsOneWidget);
      await tap(tester, find.text('继续编辑'));
      await tester.enterText(
        find.byKey(const Key('structure-json')),
        '{"x":2}',
      );
      await tap(tester, find.byTooltip('完成编辑'));
      expect(result, isNull);
      await tap(tester, find.byTooltip('完成编辑'));
      expect(result, {'x': 2});
    },
  );
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.8]) {
      testWidgets(
        'structured list ${brightness.name} $scale fits floating controls',
        (tester) async {
          await open(
            tester,
            modelSchema,
            {
              'id': 'example/custom-model-name',
              'maxTokens': 32768,
              'input': ['text', 'image'],
              'unknown': {'preserved': true},
            },
            (_) {},
            brightness: brightness,
            scale: scale,
          );
          await capture(tester, 'configuration-${brightness.name}-$scale');
          expect(tester.takeException(), isNull);
          expect(
            tester.getRect(find.byTooltip('完成编辑')).bottom,
            lessThan(scale > 1 ? 800 : 960),
          );
          await tap(tester, find.byKey(const Key('structure-entry:input')));
          await capture(
            tester,
            'configuration-array-${brightness.name}-$scale',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
