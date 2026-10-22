import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:dsh_android/configuration_editor.dart';
import 'package:dsh_android/configuration_edits.dart';
import 'package:dsh_android/configuration_value_row.dart';
import 'package:dsh_android/configuration_fields_schema.dart';
import 'package:dsh_android/configuration_presentation.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/models.dart';
import 'package:dsh_android/models_data.dart';
import 'package:dsh_android/ui.dart';

class SettingsRuntime extends RuntimeController {
  SettingsRuntime(Json initial) : remote = cloneConfiguration(initial) {
    forms = [cloneConfiguration(remote)];
    phase = 'ready';
  }
  Json remote;
  final writes = <Json>[];
  final storedCredentials = <String, String>{};
  bool failReceipt = false;

  Json mutate(Json args, String revisionKey) {
    writes.add(cloneConfiguration(args));
    if (args[revisionKey] != remote['revision']) {
      throw PlatformException(
        code: revisionKey == 'revision'
            ? 'SETTINGS_CONFLICT'
            : 'settings/conflict',
        message: 'changed',
      );
    }
    for (final op in args['ops'] as List) {
      applyConfigurationEdit(remote['value'] as Json, op as Json);
      applyConfigurationEdit(remote['user'] as Json, op);
    }
    remote['revision'] = (remote['revision'] as int) + 1;
    return cloneConfiguration(remote);
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    switch (method) {
      case 'api.call':
        if (params['namespace'] != 'settings') {
          throw StateError('Unexpected namespace');
        }
        if (params['method'] == 'describe') {
          return {
            'writable': true,
            'namespaces': [cloneConfiguration(remote)],
          };
        }
        if (params['method'] == 'mutate') {
          if (failReceipt) {
            writes.add(cloneConfiguration(params['args'] as Json));
            throw PlatformException(code: 'transport/unavailable');
          }
          return mutate(params['args'] as Json, 'expectedRevision');
        }
        throw StateError('Unexpected API method');
      case 'settings.describe':
        return [cloneConfiguration(remote)];
      case 'settings.mutate':
        return [mutate(params, 'revision')];
      case 'credentials.describe':
        return {'configured': storedCredentials.containsKey(params['ref'])};
      case 'credentials.set':
        storedCredentials[params['ref'] as String] = params['value'] as String;
        return {'configured': true};
      default:
        throw StateError('Unexpected method $method');
    }
  }
}

Json fixture() => {
  'ns': 'llm-deepseek',
  'revision': 1,
  'value': {'baseURL': 'https://old.example', 'maxTokens': 1024},
  'user': {'baseURL': 'https://old.example'},
  'secrets': [
    {
      'path': ['apiKey'],
      'set': true,
    },
  ],
  'schema': {
    'uid': 1,
    'refs': {
      '1': {
        'uid': 1,
        'type': 'object',
        'dict': {'baseURL': 2, 'maxTokens': 3, 'apiKey': 4},
      },
      '2': {'uid': 2, 'type': 'string'},
      '3': {
        'uid': 3,
        'type': 'number',
        'meta': {'min': 1, 'step': 1},
      },
      '4': {
        'uid': 4,
        'type': 'string',
        'meta': {'role': 'secret'},
      },
    },
  },
};

Json androidToolsFixture() {
  final values = <String, dynamic>{
    'shellTimeoutMs': 60000,
    'shellOutputLimit': 65536,
    'appStreamMaxSubscriptions': 32,
    'appStreamMaxFrameBytes': 16777216,
    'streamPublishMs': 50,
    'documentSearchFileBytes': 8388608,
    'documentSearchTotalBytes': 67108864,
    'documentSearchMaxEntries': 2000,
    'documentSearchMaxFiles': 1000,
    'documentSearchMaxDepth': 32,
    'documentSearchMaxMatches': 200,
    'documentSearchPreviewChars': 600,
    'documentSearchMaxDurationMs': 30000,
    'documentSearchMaxRequests': 4,
    'workspaceReadPageBytes': 65536,
    'workspaceDirectoryMaxEntries': 5000,
    'workspaceDirectoryPageSize': 100,
    'attachmentFileMaxBytes': 268435456,
    'attachmentFileReadPageBytes': 65536,
    'attachmentFileMaxRequests': 4,
    'workspaceFilesCloseTimeoutMs': 5000,
    'libraryCloseTimeoutMs': 5000,
  };
  return {
    'ns': 'android-runtime',
    'revision': 1,
    'value': values,
    'user': {},
    'secrets': [],
    'schema': {
      'type': 'object',
      'dict': {
        for (final name in values.keys)
          name: {
            'type': 'number',
            'meta': {'min': 1, 'step': 1},
          },
      },
    },
  };
}

Finder group(String id) => find.byKey(ValueKey('configuration-group:$id'));

Future<void> openGroup(WidgetTester tester, String id) async {
  await tester.ensureVisible(group(id));
  await tester.tap(group(id));
  await tester.pumpAndSettle();
}

Future<void> back(WidgetTester tester) async {
  await tester.tap(find.byTooltip('返回'));
  await tester.pumpAndSettle();
}

Finder field(String name) =>
    find.byKey(ValueKey('configuration-field:${jsonEncode([name])}'));

Future<void> editField(
  WidgetTester tester,
  String name,
  String text, {
  bool complete = true,
}) async {
  await tester.ensureVisible(field(name));
  await tester.tap(field(name));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('structure-value')), text);
  await tester.pumpAndSettle();
  if (complete) {
    await tester.tap(find.byTooltip('完成编辑'));
    await tester.pumpAndSettle();
  }
}

String summary(WidgetTester tester, String name) =>
    tester.widget<ConfigurationValueRow>(field(name)).summary;

final captureKey = GlobalKey();

Future<void> openEditor(
  WidgetTester tester,
  SettingsRuntime runtime, {
  Brightness brightness = Brightness.light,
  double width = 800,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, width < 500 ? 900 : 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: RepaintBoundary(key: captureKey, child: child!),
      ),
      home: ConfigPage(runtime: runtime, descriptor: runtime.forms.single),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['POCKET_CAPTURE_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final image =
        await (captureKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    final path = Platform.environment['POCKET_CAPTURE_FONT'];
    if (path != null) {
      await (FontLoader('Roboto')..addFont(
            Future.value(ByteData.sublistView(await File(path).readAsBytes())),
          ))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.8]) {
      testWidgets(
        'compact settings ${brightness.name} $scale remain readable',
        (tester) async {
          final data = fixture();
          data['schema']['refs']['1']['dict']['enabled'] = 5;
          data['schema']['refs']['5'] = {'type': 'boolean'};
          data['value']['enabled'] = true;
          final runtime = SettingsRuntime(data);
          await openEditor(
            tester,
            runtime,
            brightness: brightness,
            width: 420,
            scale: scale,
          );
          await capture(tester, 'settings-mixed-${brightness.name}-$scale');
          expect(find.byType(TextField), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.tap(field('baseURL'));
          await tester.pumpAndSettle();
          await capture(tester, 'settings-text-${brightness.name}-$scale');
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets(
      'default session model ${brightness.name} uses one settings group',
      (tester) async {
        final runtime = SettingsRuntime({
          'ns': 'agent-default-model',
          'revision': 1,
          'user': {},
          'secrets': [],
          'value': {
            'provider': 'deepseek-official',
            'model': 'deepseek-flash',
            'reasoningEffort': 'high',
          },
          'schema': {
            'type': 'object',
            'dict': {
              'provider': {'type': 'string'},
              'model': {'type': 'string'},
              'reasoningEffort': {
                'type': 'union',
                'list': [
                  {'type': 'const', 'value': 'low'},
                  {'type': 'const', 'value': 'high'},
                ],
              },
            },
          },
        });
        await openEditor(tester, runtime, brightness: brightness, width: 420);
        await capture(tester, 'settings-default-model-${brightness.name}');
        expect(find.byType(TextField), findsNothing);
        expect(find.text('使用默认值'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(field('reasoningEffort'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('low'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('完成编辑'));
        await tester.pumpAndSettle();
        expect(summary(tester, 'reasoningEffort'), 'low');
        expect(runtime.writes, isEmpty);
      },
    );
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'session log ${brightness.name} shows a semantic switch and separate advanced tools',
      (tester) async {
        final runtime = SettingsRuntime({
          'ns': 'session-log-deepseek',
          'revision': 1,
          'value': {'enabled': true},
          'user': {},
          'secrets': [],
          'schema': {
            'type': 'object',
            'dict': {
              'enabled': {'type': 'boolean'},
            },
          },
        });
        await openEditor(tester, runtime, brightness: brightness, width: 420);
        expect(find.byType(PocketSwitchRow), findsOneWidget);
        expect(find.text('enabled'), findsNothing);
        expect(find.text('高级 JSON 编辑'), findsNothing);
        await capture(tester, 'semantic-session-log-${brightness.name}');
        await tester.tap(find.text('高级设置'));
        await tester.pumpAndSettle();
        expect(find.text('高级 JSON 编辑'), findsOneWidget);
        await capture(tester, 'semantic-advanced-${brightness.name}');
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'Android tool groups ${brightness.name} separate tuning and explain exact units',
      (tester) async {
        final runtime = SettingsRuntime(androidToolsFixture());
        await openEditor(tester, runtime, brightness: brightness, width: 420);
        for (final id in ['shell', 'file-search', 'workspace', 'attachments']) {
          expect(group(id), findsOneWidget);
        }
        expect(group('state-stream'), findsNothing);
        expect(group('shutdown'), findsNothing);
        expect(find.text('高级 JSON 编辑'), findsNothing);
        expect(find.byType(ConfigurationValueRow), findsNothing);
        expect(find.text('shellTimeoutMs'), findsNothing);
        expect(find.byType(TextField), findsNothing);
        await capture(tester, 'semantic-android-tools-${brightness.name}');
        const presentation = ConfigurationPresentation('android-runtime');
        for (final definition in presentation.groups.where(
          (item) => !item.advanced,
        )) {
          await openGroup(tester, definition.id);
          expect(find.text(definition.description), findsOneWidget);
          final controls = tester.widget<ConfigurationFields>(
            find.byType(ConfigurationFields),
          );
          expect(controls.paths, definition.paths);
          expect(find.byTooltip('保存并应用'), findsNothing);
          expect(find.text('高级 JSON 编辑'), findsNothing);
          if (definition.id == 'shell') {
            expect(find.text('执行超时（毫秒）'), findsOneWidget);
            expect(find.text('输出上限（字节）'), findsOneWidget);
            await capture(tester, 'semantic-android-shell-${brightness.name}');
            await tester.tap(field('shellOutputLimit'));
            await tester.pumpAndSettle();
            expect(find.textContaining('标准输出和错误输出各自'), findsOneWidget);
            await back(tester);
          }
          await back(tester);
        }
        await tester.ensureVisible(find.text('高级设置'));
        await tester.tap(find.text('高级设置'));
        await tester.pumpAndSettle();
        expect(group('shell'), findsNothing);
        for (final definition in presentation.groups.where(
          (item) => item.advanced,
        )) {
          await openGroup(tester, definition.id);
          expect(find.text(definition.description), findsOneWidget);
          expect(
            tester
                .widget<ConfigurationFields>(find.byType(ConfigurationFields))
                .paths,
            definition.paths,
          );
          await back(tester);
        }
        expect(runtime.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('Web chat ${brightness.name} uses real finite selections', (
      tester,
    ) async {
      final runtime = SettingsRuntime({
        'ns': 'ui-chat',
        'revision': 1,
        'value': {'collapseTiming': 'completion', 'linkOpening': 'sidebar'},
        'user': {},
        'secrets': [],
        'schema': {
          'type': 'object',
          'dict': {
            'collapseTiming': {
              'type': 'union',
              'list': [
                {'type': 'const', 'value': 'completion'},
                {'type': 'const', 'value': 'next-input'},
              ],
            },
            'linkOpening': {
              'type': 'union',
              'list': [
                {'type': 'const', 'value': 'sidebar'},
                {'type': 'const', 'value': 'new-tab'},
              ],
            },
          },
        },
      });
      await openEditor(tester, runtime, brightness: brightness, width: 420);
      await capture(tester, 'semantic-web-chat-${brightness.name}');
      await tester.tap(field('collapseTiming'));
      await tester.pumpAndSettle();
      expect(find.text('下一次输入时'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await capture(tester, 'semantic-web-choice-${brightness.name}');
      await tester.tap(find.text('下一次输入时'));
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(runtime.writes, isEmpty);
      await tester.tap(find.byTooltip('保存并应用'));
      await tester.pumpAndSettle();
      expect(runtime.remote['value']['collapseTiming'], 'next-input');
    });
  }

  testWidgets(
    'Android groups share one draft and preserve future settings and protected fields',
    (tester) async {
      final data = androidToolsFixture();
      data['schema']['dict'].addAll({
        'futureEnabled': {
          'type': 'boolean',
          'meta': {'title': '未来功能'},
        },
        'futureMode': {
          'type': 'transform',
          'meta': {'title': '扩展参数'},
        },
        'futureKey': {
          'type': 'string',
          'meta': {'role': 'secret', 'title': '扩展凭据'},
        },
      });
      data['value'].addAll({
        'futureEnabled': true,
        'futureMode': {
          'opaque': [1, 2],
        },
        'notInSchema': {'keep': true},
      });
      data['secrets'] = [
        {
          'path': ['futureKey'],
          'set': true,
        },
      ];
      final runtime = SettingsRuntime(data);
      await openEditor(tester, runtime, width: 420, scale: 1.8);
      await openGroup(tester, 'shell');
      await editField(tester, 'shellTimeoutMs', '90000');
      expect(summary(tester, 'shellTimeoutMs'), '90000');
      expect(find.byTooltip('保存并应用'), findsNothing);
      await back(tester);
      await openGroup(tester, 'workspace');
      await editField(tester, 'workspaceDirectoryPageSize', '77');
      await back(tester);
      await openGroup(tester, 'attachments');
      await editField(tester, 'attachmentFileMaxRequests', '8');
      await back(tester);
      await openGroup(tester, 'other');
      expect(find.text('未来功能'), findsOneWidget);
      expect(field('futureMode'), findsOneWidget);
      expect(
        tester.widget<ConfigurationValueRow>(field('futureMode')).onTap,
        isNotNull,
      );
      expect(
        tester.widget<ConfigurationValueRow>(field('futureKey')).onTap,
        isNull,
      );
      await tester.ensureVisible(field('futureEnabled'));
      await tester.tap(field('futureEnabled'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<PocketSwitchRow>(field('futureEnabled')).value,
        isFalse,
      );
      await back(tester);
      await openGroup(tester, 'shell');
      expect(summary(tester, 'shellTimeoutMs'), '90000');
      await back(tester);
      expect(runtime.writes, isEmpty);
      await tester.tap(find.byTooltip('保存并应用'));
      await tester.pumpAndSettle();
      expect(runtime.writes, hasLength(1));
      expect(runtime.writes.single['expectedRevision'], 1);
      expect(
        runtime.writes.single['ops'],
        unorderedEquals([
          {
            'op': 'set',
            'path': ['shellTimeoutMs'],
            'value': 90000,
          },
          {
            'op': 'set',
            'path': ['workspaceDirectoryPageSize'],
            'value': 77,
          },
          {
            'op': 'set',
            'path': ['attachmentFileMaxRequests'],
            'value': 8,
          },
          {
            'op': 'set',
            'path': ['futureEnabled'],
            'value': false,
          },
        ]),
      );
      expect(
        runtime.remote['value']['futureMode'],
        data['value']['futureMode'],
      );
      expect(runtime.remote['value']['notInSchema'], {'keep': true});
      expect(runtime.remote['value'].containsKey('futureKey'), isFalse);
      expect(runtime.remote['secrets'], data['secrets']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'group navigation accepts fresh state until editing then preserves the buffer and version conflict',
    (tester) async {
      final runtime = SettingsRuntime(androidToolsFixture());
      await openEditor(tester, runtime);
      await openGroup(tester, 'shell');
      runtime.remote['revision'] = 2;
      runtime.remote['value']['shellTimeoutMs'] = 80000;
      await runtime.refreshForms();
      await tester.pumpAndSettle();
      expect(summary(tester, 'shellTimeoutMs'), '80000');
      expect(
        find.byKey(const Key('configuration-group-message')),
        findsNothing,
      );

      await editField(tester, 'shellTimeoutMs', '-1', complete: false);
      runtime.remote['revision'] = 3;
      runtime.remote['value']['shellTimeoutMs'] = 120000;
      runtime.remote['value']['workspaceDirectoryPageSize'] = 80;
      await runtime.refreshForms();
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('structure-value'));
      expect(tester.widget<TextField>(input).controller!.text, '-1');
      expect(find.text('数值不能小于 1。'), findsOneWidget);
      expect(runtime.writes, isEmpty);
      await tester.enterText(input, '90000');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(summary(tester, 'shellTimeoutMs'), '90000');
      expect(find.textContaining('配置有新版本'), findsOneWidget);
      await tester.tap(find.text('返回配置页'));
      await tester.pumpAndSettle();
      expect(find.text('编辑基于版本 2，当前版本 3。'), findsOneWidget);
      expect(
        tester
            .widget<GlassButton>(find.byKey(const Key('configuration-save')))
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.text('保留我的修改'));
      await tester.tap(find.text('保留我的修改'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('合并到草稿'));
      await tester.tap(find.text('合并到草稿'));
      await tester.pumpAndSettle();
      await openGroup(tester, 'workspace');
      expect(summary(tester, 'workspaceDirectoryPageSize'), '80');
      await back(tester);
      expect(runtime.writes, isEmpty);
      await tester.tap(find.byTooltip('保存并应用'));
      await tester.pumpAndSettle();
      expect(runtime.writes.single['expectedRevision'], 3);
      expect(runtime.writes.single['ops'], [
        {
          'op': 'set',
          'path': ['shellTimeoutMs'],
          'value': 90000,
        },
      ]);
      expect(runtime.remote['value']['workspaceDirectoryPageSize'], 80);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'advanced groups preserve staged edits and return to parent for uncertain save recovery',
    (tester) async {
      final runtime = SettingsRuntime(androidToolsFixture());
      await openEditor(tester, runtime);
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      await openGroup(tester, 'state-stream');
      await editField(tester, 'streamPublishMs', '75');
      await back(tester);
      await back(tester);
      expect(runtime.writes, isEmpty);
      runtime.failReceipt = true;
      await tester.tap(find.byTooltip('保存并应用'));
      await tester.pumpAndSettle();
      expect(runtime.writes, hasLength(1));
      expect(find.text('核对保存结果'), findsOneWidget);
      await tester.ensureVisible(find.text('高级设置'));
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      await openGroup(tester, 'state-stream');
      expect(summary(tester, 'streamPublishMs'), '75');
      expect(
        tester.widget<ConfigurationValueRow>(field('streamPublishMs')).onTap,
        isNull,
      );
      expect(find.textContaining('保存结果仍需核对'), findsOneWidget);
      await tester.tap(find.text('返回配置页'));
      await tester.pumpAndSettle();
      expect(find.text('核对保存结果'), findsOneWidget);
      expect(find.text('高级 JSON 编辑'), findsNothing);
      expect(runtime.writes, hasLength(1));
      await tester.ensureVisible(find.text('采用当前配置'));
      await tester.tap(find.text('采用当前配置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('高级设置'));
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      await openGroup(tester, 'state-stream');
      expect(summary(tester, 'streamPublishMs'), '50');
      expect(
        tester.widget<ConfigurationValueRow>(field('streamPublishMs')).onTap,
        isNotNull,
      );
      expect(runtime.writes, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'JSON subpage holds the original revision while remote updates remain reviewable',
    (tester) async {
      final runtime = SettingsRuntime(fixture());
      await openEditor(tester, runtime);
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高级 JSON 编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('configuration-json')),
        '{"baseURL":"https://local.example","maxTokens":1024}',
      );
      runtime.remote['revision'] = 2;
      runtime.remote['value']['maxTokens'] = 2048;
      await runtime.refreshForms();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(runtime.writes, isEmpty);
      expect(find.text('版本比较'), findsOneWidget);
      expect(find.textContaining('编辑基于版本 1，当前版本 2'), findsOneWidget);
      expect(summary(tester, 'baseURL'), 'https://local.example');
      expect(summary(tester, 'maxTokens'), '1024');
      expect(
        tester
            .widget<GlassButton>(find.byKey(const Key('configuration-save')))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'long text edits return to the parent draft without writing or truncating',
    (tester) async {
      final descriptor = fixture();
      final original = List.filled(10, 'prompt line').join('\n');
      descriptor['value']['baseURL'] = original;
      final runtime = SettingsRuntime(descriptor);
      await openEditor(tester, runtime);
      await tester.tap(field('baseURL'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      final next = '$original\nnew line';
      await tester.enterText(find.byType(TextField), next);
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(runtime.writes, isEmpty);
      expect(find.text('${next.length} 个字符'), findsOneWidget);
      await tester.tap(field('baseURL'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        next,
      );
    },
  );

  testWidgets(
    'JSON protection rejects before leaving the text buffer and normal edits remain staged only',
    (tester) async {
      final runtime = SettingsRuntime(fixture());
      await openEditor(tester, runtime);
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高级 JSON 编辑'));
      await tester.pumpAndSettle();
      final text = find.byKey(const Key('configuration-json'));
      const protected =
          '{"baseURL":"https://draft.example","maxTokens":1024,"apiKey":"never-save-this"}';
      await tester.enterText(text, protected);
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(text).controller!.text, protected);
      expect(find.textContaining('输入已保留'), findsWidgets);
      expect(runtime.writes, isEmpty);
      await tester.enterText(
        text,
        '{"baseURL":"https://draft.example","maxTokens":1024}',
      );
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(text, findsNothing);
      expect(runtime.writes, isEmpty);
      expect(summary(tester, 'baseURL'), 'https://draft.example');
      await tester.tap(find.byTooltip('保存并应用'));
      await tester.pumpAndSettle();
      expect(runtime.writes, hasLength(1));
      expect(runtime.remote['value']['baseURL'], 'https://draft.example');
      expect(runtime.remote['value'].containsKey('apiKey'), isFalse);
    },
  );

  Json structuredFixture() => {
    'ns': 'llm-example',
    'revision': 1,
    'user': {},
    'secrets': [],
    'value': {
      'models': [
        {'id': 'before', 'unknown': true},
      ],
      'other': 'original',
    },
    'schema': {
      'type': 'object',
      'dict': {
        'models': {
          'type': 'array',
          'inner': {
            'type': 'object',
            'dict': {
              'id': {
                'type': 'string',
                'meta': {'required': true},
              },
            },
          },
        },
        'other': {'type': 'string'},
      },
    },
  };

  Future<void> openModelField(WidgetTester tester) async {
    await tester.tap(field('models'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('structure-item:0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('structure-entry:id')));
    await tester.pumpAndSettle();
  }

  Future<void> finishStructure(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
    }
  }

  testWidgets(
    'structured arrays stage once and save one atomic field with revision',
    (tester) async {
      final runtime = SettingsRuntime(structuredFixture());
      await openEditor(tester, runtime);
      await openModelField(tester);
      await tester.enterText(find.byKey(const Key('structure-value')), 'after');
      await finishStructure(tester);
      expect(runtime.writes, isEmpty);
      await tester.tap(find.byTooltip('保存并应用'));
      await tester.pumpAndSettle();
      expect(runtime.writes.single['expectedRevision'], 1);
      expect(runtime.writes.single['ops'], [
        {
          'op': 'set',
          'path': ['models'],
          'value': [
            {'id': 'after', 'unknown': true},
          ],
        },
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'remote update during structured draft becomes atomic conflict and keeps input',
    (tester) async {
      final runtime = SettingsRuntime(structuredFixture());
      await openEditor(tester, runtime);
      await openModelField(tester);
      await tester.enterText(find.byKey(const Key('structure-value')), 'local');
      runtime.remote['revision'] = 2;
      runtime.remote['value']['models'] = [
        {'id': 'remote'},
      ];
      await runtime.refreshForms();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('structure-value')))
            .controller!
            .text,
        'local',
      );
      await finishStructure(tester);
      expect(find.text('编辑基于版本 1，当前版本 2。'), findsOneWidget);
      expect(find.textContaining('local'), findsWidgets);
      final save = find.byKey(const Key('configuration-save'));
      expect(tester.widget<GlassButton>(save).onPressed, isNull);
      expect(runtime.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('discarded child leaves outer configuration unchanged', (
    tester,
  ) async {
    final runtime = SettingsRuntime(structuredFixture());
    await openEditor(tester, runtime);
    await openModelField(tester);
    await tester.enterText(find.byKey(const Key('structure-value')), 'discard');
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃编辑并返回'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('保存并应用'));
    await tester.pumpAndSettle();
    expect(runtime.writes, isEmpty);
    expect(runtime.remote['value']['models'], [
      {'id': 'before', 'unknown': true},
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'secret-bearing array never exposes structured replacement controls',
    (tester) async {
      final data = structuredFixture();
      data['schema']['dict']['models']['inner']['dict']['token'] = {
        'type': 'string',
        'meta': {'role': 'secret'},
      };
      data['secrets'] = [
        {
          'path': ['models', '0', 'token'],
          'set': true,
        },
      ];
      final runtime = SettingsRuntime(data);
      await openEditor(tester, runtime);
      expect(
        tester.widget<ConfigurationValueRow>(field('models')).onTap,
        isNull,
      );
      expect(find.text('包含凭据 · 已保护'), findsOneWidget);
      expect(runtime.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('bundled model and Web settings have distinct functional titles', () {
    const expected = {
      'llm-deepseek': 'DeepSeek API 密钥接入',
      'llm-deepseek-account': 'DeepSeek 账号模型接入',
      'subagent-model-selection-settings': '子 Agent 模型选择',
      'ui-settings-account': '原版桌面引导记录',
      'ui-theme': 'Web 主题与字体',
      'ui-settings': '开发者工具',
      'ui-conversation': 'Web 繁忙时发送行为',
      'ui-chat': 'Web 聊天展示',
    };
    for (final entry in expected.entries) {
      expect(configurationNamespaceTitle(entry.key), entry.value);
    }
    final titles = [
      ...expected.keys,
      'session-log-deepseek',
      'agent-default-model',
      'llm-pi-ai',
      'subagent',
      'web',
      'web-search-deepseek',
      'web-deepseek-api',
    ].map(configurationNamespaceTitle).toList();
    expect(titles.toSet(), hasLength(titles.length));
  });

  test(
    'unknown settings retain their exact identity without keyword guesses',
    () {
      for (final namespace in [
        'agent',
        'custom-llm',
        'custom-model',
        'custom-shell',
        'custom-bash',
        'custom-search',
        'custom-web',
        'custom-preset',
        'custom-persona',
        'custom-subagent',
      ]) {
        expect(configurationNamespaceTitle(namespace), namespace);
      }
    },
  );

  testWidgets(
    'native fields save only their changes without writing the hidden key or defaults',
    (tester) async {
      final runtime = SettingsRuntime(fixture());
      await openEditor(tester, runtime);
      expect(find.text('已配置 · 凭据中管理'), findsOneWidget);
      await editField(tester, 'baseURL', 'https://new.example');
      await tester.tap(find.byTooltip('保存并应用'));
      await tester.pumpAndSettle();
      expect(runtime.writes.single['ops'], [
        {
          'op': 'set',
          'path': ['baseURL'],
          'value': 'https://new.example',
        },
      ]);
      expect(find.text('已保存并应用。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a stale save retains the draft and merges remote changes after an explicit conflict choice',
    (tester) async {
      final runtime = SettingsRuntime(fixture());
      await openEditor(tester, runtime);
      await editField(tester, 'baseURL', 'https://mine.example');
      runtime.remote['revision'] = 2;
      runtime.remote['value'] = {
        'baseURL': 'https://remote.example',
        'maxTokens': 2048,
      };
      await tester.tap(find.byTooltip('保存并应用'));
      await tester.pumpAndSettle();
      expect(summary(tester, 'baseURL'), 'https://mine.example');
      expect(runtime.remote['value']['baseURL'], 'https://remote.example');
      await tester.ensureVisible(find.text('保留我的修改'));
      await tester.tap(find.text('保留我的修改'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('合并到草稿'));
      await tester.tap(find.text('合并到草稿'));
      await tester.pumpAndSettle();
      expect(summary(tester, 'baseURL'), 'https://mine.example');
      expect(summary(tester, 'maxTokens'), '2048');
      expect(runtime.writes, isEmpty);
      await tester.tap(find.byTooltip('保存并应用'));
      await tester.pumpAndSettle();
      expect(runtime.writes.last['expectedRevision'], 2);
      expect(runtime.remote['value'], {
        'baseURL': 'https://mine.example',
        'maxTokens': 2048,
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'invalid numeric input stays in its detached editor across remote updates',
    (tester) async {
      final runtime = SettingsRuntime(fixture());
      await openEditor(tester, runtime);
      await editField(tester, 'maxTokens', '-1', complete: false);
      expect(find.text('数值不能小于 1。'), findsOneWidget);
      final complete = tester.widget<GlassButton>(
        find.widgetWithIcon(GlassButton, Icons.check_rounded),
      );
      expect(complete.onPressed, isNull);
      final input = find.byKey(const Key('structure-value'));
      expect(tester.widget<TextField>(input).controller!.text, '-1');
      runtime.remote['revision'] = 2;
      runtime.remote['value']['maxTokens'] = 2048;
      await runtime.refreshForms();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, '-1');
      expect(runtime.writes, isEmpty);
      await tester.enterText(input, '4096');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      expect(summary(tester, 'maxTokens'), '4096');
      expect(find.text('编辑基于版本 1，当前版本 2。'), findsOneWidget);
      expect(
        tester
            .widget<GlassButton>(find.byKey(const Key('configuration-save')))
            .onPressed,
        isNull,
      );
      expect(runtime.writes, isEmpty);
    },
  );

  testWidgets(
    'single-field default is only offered in detail and stages an unset',
    (tester) async {
      final runtime = SettingsRuntime(fixture());
      await openEditor(tester, runtime);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('使用默认值'), findsNothing);
      await tester.tap(field('baseURL'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用默认值'));
      await tester.pumpAndSettle();
      expect(summary(tester, 'baseURL'), '使用默认值');
      expect(runtime.writes, isEmpty);
      await tester.tap(find.byTooltip('保存并应用'));
      await tester.pumpAndSettle();
      expect(runtime.writes.single['ops'], [
        {
          'op': 'unset',
          'path': ['baseURL'],
        },
      ]);
      expect(runtime.remote['value']['maxTokens'], 1024);
      expect(runtime.remote['secrets'], fixture()['secrets']);
    },
  );

  test('bundled labels name their actual behavior without relabeling unknown plugins', () {
    final field = ConfigurationFieldSchema(ConfigurationSchema({}), {
      'type': 'boolean',
    });
    expect(
      const ConfigurationPresentation('session-log-deepseek')
          .title(['enabled'], field),
      '上传会话日志',
    );
    expect(
      const ConfigurationPresentation('session-log-deepseek')
          .description(['enabled'], field),
      contains('不会删除'),
    );
    expect(
      const ConfigurationPresentation('subagent-model-selection-settings')
          .description(['enabled'], field),
      contains('新建'),
    );
    expect(
      const ConfigurationPresentation('custom-plugin')
          .title(['enabled'], field),
      'enabled',
    );
    expect(
      const ConfigurationPresentation('custom-plugin')
          .title(['maxTokens'], field),
      'maxTokens',
    );
    expect(
      const ConfigurationPresentation('android-runtime')
          .title(['shellTimeoutMs'], field),
      '执行超时（毫秒）',
    );
  });

  testWidgets(
    'boolean controls stage exact boolean edits and preserve conflict review',
    (tester) async {
      final runtime = SettingsRuntime({
        'ns': 'session-log-deepseek',
        'revision': 1,
        'value': {'enabled': true},
        'user': {'enabled': true},
        'secrets': [],
        'schema': {
          'type': 'object',
          'dict': {
            'enabled': {'type': 'boolean'},
          },
        },
      });
      await openEditor(tester, runtime);
      expect(find.text('上传会话日志'), findsOneWidget);
      expect(
        tester
            .widget<GlassButton>(find.byKey(const Key('configuration-save')))
            .onPressed,
        isNull,
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.text('高级 JSON 编辑'), findsNothing);
      expect(tester.widget<PocketSwitchRow>(field('enabled')).value, isTrue);
      await tester.tap(field('enabled'));
      await tester.pumpAndSettle();
      expect(tester.widget<PocketSwitchRow>(field('enabled')).value, isFalse);
      expect(find.text('未保存'), findsOneWidget);
      expect(
        tester
            .widget<GlassButton>(find.byKey(const Key('configuration-save')))
            .onPressed,
        isNotNull,
      );
      expect(runtime.writes, isEmpty);
      runtime.remote['revision'] = 2;
      await runtime.refreshForms();
      await tester.pumpAndSettle();
      expect(tester.widget<PocketSwitchRow>(field('enabled')).value, isFalse);
      expect(
        tester
            .widget<GlassButton>(find.byKey(const Key('configuration-save')))
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.text('合并到草稿'));
      await tester.tap(find.text('合并到草稿'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('保存并应用'));
      await tester.pumpAndSettle();
      expect(runtime.writes.single['ops'], [
        {
          'op': 'set',
          'path': ['enabled'],
          'value': false,
        },
      ]);
      expect(runtime.writes.single['expectedRevision'], 2);
    },
  );

  testWidgets(
    'explicit default and binary boolean choices use switches without duplicate advanced rows',
    (tester) async {
      final runtime = SettingsRuntime({
        'ns': 'custom-plugin',
        'revision': 1,
        'value': {'binary': false},
        'user': {},
        'secrets': [],
        'schema': {
          'type': 'object',
          'dict': {
            'enabled': {
              'type': 'boolean',
              'meta': {'default': true},
            },
            'binary': {
              'type': 'union',
              'list': [
                {'type': 'const', 'value': true},
                {'type': 'const', 'value': false},
              ],
            },
          },
        },
      });
      await openEditor(tester, runtime);
      expect(tester.widget<PocketSwitchRow>(field('enabled')).value, isTrue);
      expect(find.text('使用默认值'), findsOneWidget);
      expect(tester.widget<PocketSwitchRow>(field('binary')).value, isFalse);
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      expect(find.text('开关说明与默认值'), findsNothing);
      expect(find.text('enabled'), findsNothing);
      await back(tester);
      await tester.tap(field('enabled'));
      await tester.pumpAndSettle();
      await tester.tap(field('binary'));
      await tester.pumpAndSettle();
      expect(runtime.writes, isEmpty);
      await tester.tap(find.byTooltip('保存并应用'));
      await tester.pumpAndSettle();
      expect(
        runtime.writes.single['ops'],
        unorderedEquals([
          {
            'op': 'set',
            'path': ['enabled'],
            'value': false,
          },
          {
            'op': 'set',
            'path': ['binary'],
            'value': true,
          },
        ]),
      );
      expect(runtime.writes.single['expectedRevision'], 1);
    },
  );

  testWidgets(
    'missing and transformed boolean values never masquerade as false switches',
    (tester) async {
      final runtime = SettingsRuntime({
        'ns': 'custom-plugin',
        'revision': 1,
        'value': {'wrapped': true},
        'user': {},
        'secrets': [],
        'schema': {
          'type': 'object',
          'dict': {
            'enabled': {'type': 'boolean'},
            'wrapped': {
              'type': 'transform',
              'inner': {'type': 'boolean'},
              'callback': '(v) => !v',
            },
          },
        },
      });
      await openEditor(tester, runtime);
      expect(find.byType(PocketSwitchRow), findsNothing);
      expect(summary(tester, 'enabled'), '使用默认值');
      await tester.tap(field('wrapped'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(PocketSwitchRow), findsNothing);
      expect(find.text('高级工具'), findsOneWidget);
      expect(runtime.writes, isEmpty);
    },
  );

  testWidgets(
    'compact grouped rows reveal editors without duplicate field cards',
    (tester) async {
      final runtime = SettingsRuntime(fixture());
      await openEditor(tester, runtime);
      final group = find.byKey(const Key('configuration-values'));
      expect(
        find.descendant(of: group, matching: find.byType(PocketSection)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: group,
          matching: find.byType(ConfigurationValueRow),
        ),
        findsNWidgets(3),
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.text('调整后保存生效'), findsNothing);
      expect(tester.getSize(group).height, lessThan(250));
      expect(
        tester.widget<ConfigurationValueRow>(field('apiKey')).onTap,
        isNull,
      );
      final page = tester.widget<PocketScaffold>(find.byType(PocketScaffold));
      expect(page.bottom, isNull);
      final save = find.byKey(const Key('configuration-save'));
      final saveSize = tester.getSize(save);
      expect(saveSize.width, saveSize.height);
      expect(tester.widget<GlassButton>(save).solid, isTrue);
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: field('baseURL'),
                matching: find.text('https://old.example'),
              ),
            )
            .maxLines,
        1,
      );
      final rowElement = tester.element(field('baseURL'));
      await editField(tester, 'baseURL', 'https://local.example');
      expect(summary(tester, 'baseURL'), 'https://local.example');
      expect(runtime.writes, isEmpty);
      expect(find.byType(TextField), findsNothing);
      expect(tester.element(field('baseURL')), same(rowElement));
      await tester.tap(find.byTooltip('保存并应用'));
      await tester.pumpAndSettle();
      expect(tester.element(field('baseURL')), same(rowElement));
    },
  );

  testWidgets(
    'uncertain save exposes the observed configuration before explicit adoption',
    (tester) async {
      final runtime = SettingsRuntime(fixture())..failReceipt = true;
      await openEditor(tester, runtime);
      await editField(tester, 'baseURL', 'https://mine.example');
      await tester.tap(find.byTooltip('保存并应用'));
      await tester.pumpAndSettle();
      expect(find.text('核对保存结果'), findsOneWidget);
      expect(summary(tester, 'baseURL'), 'https://mine.example');
      expect(
        tester.widget<ConfigurationValueRow>(field('baseURL')).onTap,
        isNull,
      );
      await tester.tap(find.text('查看当前配置（凭据已隐藏）'));
      await tester.pumpAndSettle();
      expect(find.textContaining('https://old.example'), findsOneWidget);
      expect(find.textContaining('此次保存没有覆盖新版本'), findsNothing);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('继续核对'));
      await tester.tap(find.text('继续核对'));
      await tester.pumpAndSettle();
      expect(runtime.writes, hasLength(1));
      await tester.ensureVisible(find.text('采用当前配置'));
      await tester.tap(find.text('采用当前配置'));
      await tester.pumpAndSettle();
      expect(summary(tester, 'baseURL'), 'https://old.example');
      expect(find.text('核对保存结果'), findsNothing);
      expect(runtime.writes, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'invalid raw JSON survives incoming configuration and is guarded on exit',
    (tester) async {
      final runtime = SettingsRuntime(fixture());
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ConfigPage(
                    runtime: runtime,
                    descriptor: runtime.forms.single,
                  ),
                ),
              ),
              child: const Text('open editor'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open editor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高级 JSON 编辑'));
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('configuration-json'));
      await tester.enterText(input, '{ invalid draft');
      runtime.remote['revision'] = 2;
      runtime.remote['value']['baseURL'] = 'new';
      await runtime.refreshForms();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        '{ invalid draft',
      );
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('保留当前编辑？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        '{ invalid draft',
      );
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃编辑并返回'));
      await tester.pumpAndSettle();
      expect(find.text('高级设置'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('open editor'), findsOneWidget);
      expect(runtime.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'default model save uses the revisioned settings owner and reports persistence',
    (tester) async {
      final runtime = SettingsRuntime({
        'ns': 'agent-default-model',
        'revision': 4,
        'value': {'provider': 'deepseek-official', 'model': 'deepseek-flash'},
        'user': {},
        'secrets': [],
      });
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: DefaultModelPage(
            runtime: runtime,
            snapshot: ModelsSnapshot([], runtime.forms, {
              'groups': [
                {
                  'id': 'deepseek-official',
                  'name': 'DeepSeek',
                  'models': [
                    {'id': 'deepseek-flash', 'name': 'Flash'},
                    {'id': 'deepseek-pro', 'name': 'Pro'},
                  ],
                },
              ],
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pro'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('保存默认模型'));
      await tester.tap(find.byTooltip('保存默认模型'));
      await tester.pumpAndSettle();
      expect(runtime.writes.single['revision'], 4);
      expect(runtime.remote['value']['model'], 'deepseek-pro');
      expect(runtime.model, 'deepseek-pro');
      expect(find.text('已保存。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
