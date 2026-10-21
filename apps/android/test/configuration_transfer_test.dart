import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:dsh_android/configuration_transfer.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:dsh_android/text_document_page.dart';

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
  bool previewFails = false;
  int refreshes = 0;
  List<String> expectedSelection = ['agent'];
  List<Json>? exportSections;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method, jsonDecode(jsonEncode(params)) as Json));
    switch (method) {
      case 'configuration.transfer.preview':
        expect(params.keys, ['text']);
        if (previewFails) throw PlatformException(code: 'disconnected');
        return jsonDecode(jsonEncode(nextPreview));
      case 'configuration.transfer.apply':
        expect(params, {'id': 'held-preview', 'namespaces': expectedSelection});
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
          'sections':
              exportSections ??
              [
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

final captureKey = GlobalKey();
bool captureFontLoaded = false;
bool get captureEnabled => Platform.environment['POCKET_CAPTURE_DIR'] != null;

Future<void> open(
  WidgetTester tester,
  TransferRuntime runtime, {
  Size size = const Size(1000, 1800),
  double textScale = 1,
  Brightness brightness = Brightness.light,
  bool disableAnimations = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  if (captureEnabled && !captureFontLoaded) {
    await tester.runAsync(() async {
      final bytes = await File(Platform.environment['POCKET_CAPTURE_FONT']!)
          .readAsBytes();
      final loader = FontLoader('PocketCaptureCjk')
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      final iconLoader = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await iconLoader.load();
      captureFontLoaded = true;
    });
  }
  final theme = pocketTheme(brightness);
  await tester.pumpWidget(
    RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: disableAnimations,
          ),
          child: child!,
        ),
        theme: captureEnabled
            ? theme.copyWith(
                textTheme: theme.textTheme.apply(
                  fontFamily: 'PocketCaptureCjk',
                ),
                primaryTextTheme: theme.primaryTextTheme.apply(
                  fontFamily: 'PocketCaptureCjk',
                ),
              )
            : theme,
        home: ConfigurationTransferPage(runtime: runtime),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder get source => find.byKey(const Key('configuration-transfer-source'));
Finder get apply => find.byKey(const Key('configuration-transfer-apply'));
Finder get previewButton =>
    find.byKey(const Key('configuration-transfer-preview'));

Future<void> enterInput(WidgetTester tester) async {
  await tap(
    tester,
    find.byKey(const Key('configuration-transfer-import-entry')),
  );
  await tap(tester, find.text('粘贴 JSON 内容'));
}

Future<void> enterPreview(WidgetTester tester) async {
  await enterInput(tester);
  await tester.enterText(source, input);
  await tester.pumpAndSettle();
  await tap(tester, find.byTooltip('完成编辑'));
  await tap(tester, previewButton);
}

Future<void> capture(WidgetTester tester, String name) async {
  if (!captureEnabled) return;
  await tester.pumpAndSettle();
  final boundary =
      captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    final directory = Directory(Platform.environment['POCKET_CAPTURE_DIR']!);
    await directory.create(recursive: true);
    await File('${directory.path}/$name.png')
        .writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets(
    'entry separates import and export with scope collapsed and no apply action',
    (tester) async {
      final runtime = TransferRuntime();
      await open(tester, runtime);
      expect(find.text('导入与导出'), findsOneWidget);
      expect(find.text('导入设置'), findsOneWidget);
      expect(find.text('导出设置'), findsOneWidget);
      expect(find.textContaining('这不是全量备份'), findsNothing);
      expect(apply, findsNothing);
      expect(source, findsNothing);
      expect(runtime.calls, isEmpty);
      await tap(tester, find.text('迁移范围'));
      expect(find.textContaining('这不是全量备份'), findsOneWidget);
    },
  );

  testWidgets(
    'preview remains explicit and only applies held identity before showing a separate result',
    (tester) async {
      final runtime = TransferRuntime();
      await open(tester, runtime);
      await enterPreview(tester);
      expect(find.text('核对导入'), findsOneWidget);
      expect(
        runtime.calls.where((call) => call.$1.endsWith('.apply')),
        isEmpty,
      );
      expect(find.text('agent'), findsOneWidget);
      await tap(tester, find.text('agent'));
      expect(find.textContaining('当前：100\n导入：200'), findsOneWidget);
      await tap(tester, find.byTooltip('返回'));
      await tap(tester, apply);
      expect(
        runtime.calls.where((call) => call.$1.endsWith('.apply')),
        hasLength(1),
      );
      expect(find.text('导入结果'), findsOneWidget);
      expect(find.textContaining('1 处变更 · 已应用'), findsOneWidget);
      expect(apply, findsNothing);
      expect(runtime.refreshes, 1);
      await tap(tester, find.text('查看保留的导入内容'));
      expect(tester.widget<TextField>(source).controller!.text, input);
    },
  );

  testWidgets(
    'unsupported content blocks writes and retains the source behind explicit editing',
    (tester) async {
      final runtime = TransferRuntime()..nextPreview = preview(issue: true);
      await open(tester, runtime);
      await enterPreview(tester);
      expect(apply, findsNothing);
      await tap(tester, find.text('需要修正的内容'));
      expect(find.textContaining('凭据须单独管理'), findsOneWidget);
      await tap(tester, find.byTooltip('返回'));
      await tap(tester, find.text('编辑导入内容'));
      expect(tester.widget<TextField>(source).controller!.text, input);
      expect(
        runtime.calls.where((call) => call.$1.endsWith('.apply')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'editing invalidates the preview and a conflict keeps the draft without another apply action',
    (tester) async {
      final runtime = TransferRuntime()
        ..nextApply = preview(status: 'conflict');
      await open(tester, runtime);
      await enterPreview(tester);
      await tap(tester, find.text('编辑导入内容'));
      await tester.enterText(source, '$input\n');
      await tester.pumpAndSettle();
      await tap(tester, find.byTooltip('完成编辑'));
      expect(apply, findsNothing);
      expect(find.textContaining('预览已过期'), findsOneWidget);
      await tap(tester, previewButton);
      expect(
        runtime.calls.where((call) => call.$1.endsWith('.release')),
        hasLength(1),
      );
      await tap(tester, apply);
      expect(find.textContaining('1 处变更 · 版本冲突，未覆盖'), findsOneWidget);
      expect(apply, findsNothing);
      await tap(tester, find.text('查看保留的导入内容'));
      expect(tester.widget<TextField>(source).controller!.text, '$input\n');
    },
  );

  testWidgets(
    'lost acknowledgement has no repeat action until an explicit fresh preview',
    (tester) async {
      final runtime = TransferRuntime()..lostReply = true;
      await open(tester, runtime);
      await enterPreview(tester);
      await tap(tester, apply);
      expect(find.textContaining('可能已有部分设置生效'), findsOneWidget);
      expect(find.textContaining('1 处变更 · 写入结果未确认'), findsOneWidget);
      expect(apply, findsNothing);
      expect(
        runtime.calls.where((call) => call.$1.endsWith('.apply')),
        hasLength(1),
      );
      runtime.nextPreview = preview(revision: 2);
      await tap(tester, find.byKey(const Key('configuration-transfer-reread')));
      expect(
        runtime.calls.where((call) => call.$1.endsWith('.apply')),
        hasLength(1),
      );
      expect(apply, findsOneWidget);
      await tap(tester, find.text('agent'));
      expect(find.textContaining('配置标识：agent\n读取版本：2'), findsOneWidget);
    },
  );

  testWidgets(
    'selection and partial results stay per section without replaying unselected sections',
    (tester) async {
      final runtime = TransferRuntime();
      final other = {
        ...preview()['sections'][0] as Json,
        'ns': 'tool-android-shell',
      };
      runtime.nextPreview['sections'] = [
        ...runtime.nextPreview['sections'] as List,
        other,
      ];
      runtime.nextApply['sections'] = [
        ...runtime.nextApply['sections'] as List,
        other,
      ];
      await open(tester, runtime);
      await enterPreview(tester);
      await tap(
        tester,
        find.byKey(const ValueKey('configuration-transfer-tool-android-shell')),
      );
      expect(find.text('已选 1 项设置'), findsOneWidget);
      await tap(tester, apply);
      expect(find.textContaining('1 处变更 · 已应用'), findsOneWidget);
      expect(find.textContaining('1 处变更 · 尚未执行'), findsOneWidget);
      expect(apply, findsNothing);
      expect(
        runtime.calls.where((call) => call.$1.endsWith('.apply')),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'export only offers file save and retains its snapshot after a SAF failure',
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
      await tap(
        tester,
        find.byKey(const Key('configuration-transfer-export-entry')),
      );
      expect(native, isEmpty);
      expect(find.text('1 个字段'), findsOneWidget);
      expect(apply, findsNothing);
      expect(source, findsNothing);
      expect(find.text('agent'), findsOneWidget);
      await tap(tester, find.text('未包含的设置'));
      expect(find.textContaining('设备设置不迁移'), findsOneWidget);
      expect(find.textContaining('web-startup'), findsOneWidget);
      await tap(tester, find.byTooltip('返回'));
      await tap(tester, find.byKey(const Key('configuration-transfer-save')));
      expect(native.single.method, 'configurationTransfer.save');
      expect((native.single.arguments as Map)['text'], input);
      expect(find.textContaining('导出预览保留，可重新选择位置'), findsOneWidget);
      expect(find.text('1 个字段'), findsOneWidget);
      expect(apply, findsNothing);
    },
  );

  testWidgets(
    'cancelled replacement preserves source and never requests directory authorization',
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
      await enterInput(tester);
      await tester.enterText(source, input);
      await tester.pumpAndSettle();
      await tap(tester, find.byTooltip('完成编辑'));
      await tap(tester, find.text('重新选择文件'));
      expect(native, isEmpty);
      await tap(tester, find.text('继续选择并替换草稿'));
      expect(native.single.method, 'configurationTransfer.pick');
      expect((native.single.arguments as Map).keys, ['id']);
      await tap(tester, find.text('查看或编辑 JSON'));
      expect(tester.widget<TextField>(source).controller!.text, input);
      expect(runtime.calls, isEmpty);
    },
  );

  testWidgets(
    'small-screen layouts expose the current action and produce optional local CJK captures',
    (tester) async {
      final runtime = TransferRuntime()
        ..exportSections = [
          for (final ns in [
            'llm-deepseek',
            'tool-android-shell',
            'web-search-deepseek',
            'agent-preset',
          ])
            {
              'ns': ns,
              'fields': [
                {
                  'path': ['enabled'],
                  'value': true,
                },
                {
                  'path': ['maxTokens'],
                  'value': 1024,
                },
              ],
            },
        ];
      await open(tester, runtime, size: const Size(390, 844));
      await capture(tester, 'transfer-entry');
      await tap(
        tester,
        find.byKey(const Key('configuration-transfer-export-entry')),
      );
      expect(apply, findsNothing);
      expect(
        find.byKey(const Key('configuration-transfer-save')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await capture(tester, 'transfer-export');
      await tap(
        tester,
        find.byWidgetPredicate(
          (widget) => widget is GlassButton && widget.label == '返回',
        ),
      );
      await enterPreview(tester);
      expect(apply, findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, 'transfer-import-preview');
      await tap(tester, find.text('agent'));
      expect(find.byType(TextDocumentPage), findsOneWidget);
      await capture(tester, 'transfer-field-detail');
      expect(tester.takeException(), isNull);
      await tap(tester, find.byTooltip('返回'));
      await tap(tester, apply);
      expect(apply, findsNothing);
      await capture(tester, 'transfer-import-result');
    },
  );

  testWidgets(
    'failed reread retains previous partial results and cannot reuse a released plan',
    (tester) async {
      final runtime = TransferRuntime()
        ..nextApply = preview(status: 'conflict');
      await open(tester, runtime);
      await enterPreview(tester);
      await tap(tester, apply);
      runtime.previewFails = true;
      await tap(tester, find.byKey(const Key('configuration-transfer-reread')));
      expect(find.textContaining('版本冲突，未覆盖'), findsOneWidget);
      expect(find.textContaining('预览失败'), findsOneWidget);
      expect(apply, findsNothing);
      expect(
        runtime.calls.where((call) => call.$1.endsWith('.apply')),
        hasLength(1),
      );
      expect(
        runtime.calls.where((call) => call.$1.endsWith('.release')),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'selection owns a 48 dp target independently of the document link and reports toggle semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final runtime = TransferRuntime();
        await open(tester, runtime, size: const Size(390, 844));
        await enterPreview(tester);
        final selection = find.byKey(
          const Key('configuration-transfer-selection-target-agent'),
        );
        final bounds = tester.getRect(selection);
        expect(bounds.width, greaterThanOrEqualTo(48));
        expect(bounds.height, greaterThanOrEqualTo(48));
        expect(find.byType(TextDocumentPage), findsNothing);
        expect(
          tester.getSemantics(selection),
          isSemantics(
            label: '选择agent',
            hasToggledState: true,
            isToggled: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
        // These points are outside the 32 dp visual track but inside its target.
        await tester.tapAt(Offset(bounds.center.dx, bounds.top + 1));
        await tester.pumpAndSettle();
        expect(find.text('maxTokens'), findsNothing);
        expect(apply, findsNothing);
        expect(tester.getSemantics(selection), isSemantics(isToggled: false));
        await tester.tapAt(Offset(bounds.center.dx, bounds.bottom - 1));
        await tester.pumpAndSettle();
        expect(apply, findsOneWidget);
        expect(find.byType(TextDocumentPage), findsNothing);
        await tap(tester, find.text('agent'));
        expect(find.byType(TextDocumentPage), findsOneWidget);
        await tap(tester, find.byTooltip('返回'));
        expect(tester.getSemantics(selection), isSemantics(isToggled: true));
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'disabled selection padding does not navigate to the surrounding document',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final runtime = TransferRuntime()
          ..nextPreview = preview(status: 'conflict');
        await open(tester, runtime, disableAnimations: true);
        await enterPreview(tester);
        final selection = find.byKey(
          const Key('configuration-transfer-selection-target-agent'),
        );
        final bounds = tester.getRect(selection);
        expect(
          tester.getSemantics(selection),
          isSemantics(isEnabled: false, hasTapAction: false),
        );
        await tester.tapAt(Offset(bounds.center.dx, bounds.top + 1));
        await tester.pumpAndSettle();
        expect(find.text('maxTokens'), findsNothing);
        expect(apply, findsNothing);
        await tap(tester, find.text('agent'));
        expect(find.textContaining('maxTokens'), findsOneWidget);
        expect(find.byType(AnimatedSize), findsNothing);
        expect(tester.takeException(), isNull);
        await tap(tester, find.byTooltip('返回'));
        expect(find.textContaining('maxTokens'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'dark export and import preview remain readable with optional local captures',
    (tester) async {
      final runtime = TransferRuntime()
        ..exportSections = [
          for (final ns in [
            'llm-deepseek',
            'tool-android-shell',
            'web-search-deepseek',
            'agent-preset',
          ])
            {
              'ns': ns,
              'fields': [
                {
                  'path': ['enabled'],
                  'value': true,
                },
              ],
            },
        ];
      await open(
        tester,
        runtime,
        size: const Size(390, 844),
        brightness: Brightness.dark,
      );
      await tap(
        tester,
        find.byKey(const Key('configuration-transfer-export-entry')),
      );
      expect(apply, findsNothing);
      expect(tester.takeException(), isNull);
      await capture(tester, 'transfer-export-dark');
      await tap(
        tester,
        find.byWidgetPredicate(
          (widget) => widget is GlassButton && widget.label == '返回',
        ),
      );
      await enterPreview(tester);
      expect(apply, findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, 'transfer-preview-dark');
    },
  );

  testWidgets(
    '320 dp with larger text keeps import selection and export actions within the screen',
    (tester) async {
      final runtime = TransferRuntime();
      await open(tester, runtime, size: const Size(320, 1000), textScale: 1.4);
      await tap(
        tester,
        find.byKey(const Key('configuration-transfer-export-entry')),
      );
      expect(tester.takeException(), isNull);
      await capture(tester, 'transfer-export-large-text');
      await tap(
        tester,
        find.byWidgetPredicate(
          (widget) => widget is GlassButton && widget.label == '返回',
        ),
      );
      await enterPreview(tester);
      expect(tester.takeException(), isNull);
      await capture(tester, 'transfer-preview-large-text');
    },
  );
}
