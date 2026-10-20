import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:dsh_android/configuration_transfer.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';

const input =
    '{"format":"pocket-harness-settings","version":1,'
    '"sections":[{"ns":"agent","fields":[{"path":["maxTokens"],"value":200}]}]}';

Json preview({
  String status = 'pending',
  bool issue = false,
  int revision = 1,
}) => {
  'id': 'held-preview',
  'busy': false,
  'sections': [
    {
      'ns': 'agent',
      'revision': revision,
      'status': status,
      'changes': [
        {
          'path': ['maxTokens'],
          'before': 100,
          'after': 200,
        },
      ],
    },
  ],
  'issues': [
    if (issue)
      {
        'ns': 'agent',
        'path': ['apiKey'],
        'reason': '凭据须单独管理',
      },
  ],
  'excluded': [
    {'ns': 'web-startup', 'reason': '设备设置不迁移'},
  ],
};

class TransferRuntime extends RuntimeController {
  TransferRuntime() {
    phase = 'ready';
  }
  final calls = <(String, Json)>[];
  Json nextPreview = preview();
  Json nextApply = preview(status: 'applied');
  bool lostReply = false;
  int refreshes = 0;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method, jsonDecode(jsonEncode(params)) as Json));
    switch (method) {
      case 'configuration.transfer.preview':
        expect(params.keys, ['text']);
        return jsonDecode(jsonEncode(nextPreview));
      case 'configuration.transfer.apply':
        expect(params, {
          'id': 'held-preview',
          'namespaces': ['agent'],
        });
        if (lostReply) {
          throw PlatformException(code: 'disconnected', message: '连接中断');
        }
        return jsonDecode(jsonEncode(nextApply));
      case 'configuration.transfer.release':
        expect(params, {'id': 'held-preview'});
        return {'released': true};
      case 'configuration.transfer.export':
        expect(params, isEmpty);
        return {
          'text': input,
          'sections': [
            {
              'ns': 'agent',
              'fields': [
                {
                  'path': ['maxTokens'],
                  'value': 200,
                },
              ],
            },
          ],
          'excluded': [
            {'ns': 'web-startup', 'reason': '设备设置不迁移'},
          ],
        };
      default:
        throw StateError('Unexpected $method');
    }
  }

  @override
  Future<void> refreshForms() async {
    refreshes++;
  }
}

Future<void> open(WidgetTester tester, TransferRuntime runtime) async {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: ConfigurationTransferPage(runtime: runtime),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder get source => find.byKey(const Key('configuration-transfer-source'));
Finder get apply => find.byKey(const Key('configuration-transfer-apply'));
Finder get previewButton =>
    find.byKey(const Key('configuration-transfer-preview'));

Future<void> enterPreview(WidgetTester tester) async {
  await tester.enterText(source, input);
  await tester.pumpAndSettle();
  await tap(tester, previewButton);
}

void main() {
  testWidgets(
    'preview is explicit, shows field comparison and writes only held plan identity',
    (tester) async {
      final runtime = TransferRuntime();
      await open(tester, runtime);
      expect(find.text('运行设置导入导出'), findsOneWidget);
      expect(find.textContaining('这不是全量备份'), findsOneWidget);
      expect(tester.widget<PocketButton>(apply).onPressed, isNull);
      await enterPreview(tester);
      expect(
        runtime.calls.where((call) => call.$1.endsWith('.apply')),
        isEmpty,
      );
      await tap(tester, find.text('maxTokens'));
      expect(find.textContaining('当前：100\n导入：200'), findsOneWidget);
      await tap(tester, apply);
      expect(
        runtime.calls.where((call) => call.$1.endsWith('.apply')).length,
        1,
      );
      expect(find.textContaining('agent：已应用'), findsOneWidget);
      expect(tester.widget<PocketButton>(apply).onPressed, isNull);
      expect(runtime.refreshes, 1);
      expect(find.widgetWithText(TextField, input), findsOneWidget);
    },
  );

  testWidgets(
    'unsupported content blocks all writes while retaining editable file contents',
    (tester) async {
      final runtime = TransferRuntime()..nextPreview = preview(issue: true);
      await open(tester, runtime);
      await enterPreview(tester);
      expect(tester.widget<PocketButton>(apply).onPressed, isNull);
      await tap(tester, find.text('必须处理的问题'));
      expect(find.textContaining('凭据须单独管理'), findsOneWidget);
      expect(find.widgetWithText(TextField, input), findsOneWidget);
      expect(
        runtime.calls.where((call) => call.$1.endsWith('.apply')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'edited draft invalidates preview and conflict keeps both draft and explicit receipt',
    (tester) async {
      final runtime = TransferRuntime()
        ..nextApply = preview(status: 'conflict');
      await open(tester, runtime);
      await enterPreview(tester);
      await tester.enterText(source, '$input\n');
      await tester.pumpAndSettle();
      expect(tester.widget<PocketButton>(apply).onPressed, isNull);
      expect(find.textContaining('预览已过期'), findsOneWidget);
      await tap(tester, previewButton);
      expect(
        runtime.calls.where((call) => call.$1.endsWith('.release')).length,
        1,
      );
      await tap(tester, apply);
      expect(find.textContaining('agent：版本冲突，未覆盖'), findsOneWidget);
      expect(find.widgetWithText(TextField, '$input\n'), findsOneWidget);
      expect(tester.widget<PocketButton>(apply).onPressed, isNull);
    },
  );

  testWidgets(
    'lost acknowledgement retains input and requires rereading before another apply',
    (tester) async {
      final runtime = TransferRuntime()..lostReply = true;
      await open(tester, runtime);
      await enterPreview(tester);
      await tap(tester, apply);
      expect(find.textContaining('可能已有部分设置生效'), findsOneWidget);
      expect(find.text('写入结果未确认'), findsOneWidget);
      expect(tester.widget<PocketButton>(apply).onPressed, isNull);
      expect(find.widgetWithText(TextField, input), findsOneWidget);
      expect(
        runtime.calls.where((call) => call.$1.endsWith('.apply')).length,
        1,
      );
      runtime.nextPreview = preview(revision: 2);
      await tap(tester, previewButton);
      expect(find.text('agent · 版本 2'), findsOneWidget);
      expect(
        runtime.calls.where((call) => call.$1.endsWith('.apply')).length,
        1,
      );
      expect(tester.widget<PocketButton>(apply).onPressed, isNotNull);
    },
  );

  testWidgets(
    'export previews exact fields before SAF save and preserves snapshot after failure',
    (tester) async {
      final runtime = TransferRuntime();
      final native = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async {
          native.add(call);
          throw PlatformException(code: 'provider', message: '文件提供方写入失败');
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await open(tester, runtime);
      await tap(tester, find.text('读取本机运行设置'));
      expect(native, isEmpty);
      expect(find.text('agent · 1 个字段'), findsOneWidget);
      await tap(tester, find.text('实际未包含的命名空间和字段'));
      expect(find.textContaining('web-startup：设备设置不迁移'), findsOneWidget);
      await tap(tester, find.byKey(const Key('configuration-transfer-save')));
      expect(native.single.method, 'configurationTransfer.save');
      expect((native.single.arguments as Map)['text'], input);
      expect(find.textContaining('导出预览保留，可重新选择位置'), findsOneWidget);
      expect(find.text('agent · 1 个字段'), findsOneWidget);
    },
  );

  testWidgets(
    'cancelled file selection preserves existing draft and never grants a directory',
    (tester) async {
      final runtime = TransferRuntime();
      final native = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async {
          native.add(call);
          return jsonEncode({'status': 'cancelled'});
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await open(tester, runtime);
      await tester.enterText(source, input);
      await tap(tester, find.text('选择运行设置 JSON'));
      expect(native, isEmpty);
      await tap(tester, find.text('继续选择并替换草稿'));
      expect(native.single.method, 'configurationTransfer.pick');
      expect((native.single.arguments as Map).keys, ['id']);
      expect(find.widgetWithText(TextField, input), findsOneWidget);
      expect(runtime.calls, isEmpty);
    },
  );
}
