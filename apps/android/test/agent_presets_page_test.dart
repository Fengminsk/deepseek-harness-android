import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_android/agent_presets.dart';
import 'package:dsh_android/agent_presets_data.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const declaration =
    'name: 手机 Agent\n'
    'description: 在手机上使用应用权限内的工具\n'
    'plugins:\n  - name: android-shell\n  - name: android-files\n';

class PresetPageRuntime extends RuntimeController {
  PresetPageRuntime() {
    phase = 'ready';
  }

  final calls = <({String method, Json params})>[];
  final control = StreamController<Json>.broadcast(sync: true);
  List<Json> presets = [
    {'id': 'android', 'name': '手机 Agent', 'description': '在手机上处理文件与日常任务'},
    {'id': 'reviewer', 'name': '审阅助手', 'description': '审阅代码、整理建议与检查变更'},
    {
      'id': 'broken',
      'name': '自定义助手',
      'description': '工作区中的自定义预设',
      'broken': '缺少插件 android-example，请检查预设声明中的插件名称。',
    },
  ];
  String defaultPreset = 'android';
  String? currentPreset = 'android';
  bool exists = false, started = false, readFails = false, conflictOnce = false;
  bool loseWriteReply = false;
  int revision = 1;
  Completer<dynamic>? documentReply;

  Json get descriptor => {
    'ns': agentPresetSettingsNamespace,
    'revision': revision,
    'value': {'default': 'android', 'selectedDefault': defaultPreset},
  };

  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) => control.stream;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method: method, params: jsonDecode(jsonEncode(params)) as Json));
    final operation = method == 'api.call'
        ? '${params['namespace']}.${params['method']}'
        : method;
    switch (operation) {
      case 'agentPresets.list':
        return {
          'presets': [
            for (final preset in presets)
              {...preset, 'isDefault': preset['id'] == defaultPreset},
          ],
        };
      case 'settings.describe':
        return {
          'writable': true,
          'namespaces': [descriptor],
        };
      case 'session.list':
        return {
          'items': [
            if (exists) {'sessionId': 'session-A', 'blank': !started},
          ],
        };
      case 'session.projections':
        return exists
            ? {
                'kind': 'sequenced',
                'asOfSeq': 2,
                'values': {'agentPreset': currentPreset},
              }
            : null;
      case 'agentPresets.read':
        if (readFails) throw PlatformException(code: 'agent-preset/not-found');
        if (documentReply != null) return documentReply!.future;
        return {
          'agentPreset': params['args']['agentPreset'],
          'content': declaration,
        };
      case 'settings.update':
        if (loseWriteReply) throw PlatformException(code: 'disconnected');
        if (conflictOnce) {
          conflictOnce = false;
          revision++;
          throw PlatformException(code: 'settings/conflict');
        }
        expect(params['args']['expectedRevision'], revision);
        defaultPreset = params['args']['patch']['selectedDefault'] as String;
        revision++;
        return descriptor;
      case 'session.selectPreset':
        exists = true;
        currentPreset = params['agentPreset'] as String;
        return currentPreset;
      default:
        throw StateError('Unexpected preset operation: $operation');
    }
  }

  List<({String method, Json params})> get writes => calls
      .where(
        (entry) =>
            entry.method == 'session.selectPreset' ||
            entry.method == 'api.call' && entry.params['method'] == 'update',
      )
      .toList();

  @override
  void dispose() {
    unawaited(control.close());
    super.dispose();
  }
}

final captureKey = GlobalKey();
bool captureFontLoaded = false;
bool get captureEnabled => Platform.environment['POCKET_CAPTURE_DIR'] != null;

Future<void> openPage(
  WidgetTester tester,
  PresetPageRuntime runtime, {
  String? sessionId,
  bool chip = false,
  Brightness brightness = Brightness.light,
  double textScale = 1,
  Size size = const Size(420, 960),
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
      await (FontLoader(
        'PocketCaptureCjk',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      // Widget tests otherwise render the explicit code font as Ahem boxes.
      await (FontLoader(
        'monospace',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      captureFontLoaded = true;
    });
  }
  final theme = pocketTheme(brightness);
  await tester.pumpWidget(
    RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
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
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: chip
            ? Scaffold(
                body: SessionPresetChip(
                  runtime: runtime,
                  sessionId: sessionId!,
                ),
              )
            : AgentPresetsPage(runtime: runtime, sessionId: sessionId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder option(String id) => find.byKey(ValueKey('agent-preset-$id'));
Finder get apply => find.byKey(const ValueKey('apply-agent-preset'));
Finder get applied => find.byKey(const ValueKey('applied-agent-preset'));
Finder document(String id) => find.byKey(ValueKey('agent-preset-document-$id'));

Future<void> capture(WidgetTester tester, String name) async {
  if (!captureEnabled) return;
  final boundary =
      captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    final folder = Directory(Platform.environment['POCKET_CAPTURE_DIR']!);
    await folder.create(recursive: true);
    await File('${folder.path}/$name.png')
        .writeAsBytes(data.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets('default selection stages without writing until explicit apply', (
    tester,
  ) async {
    final runtime = PresetPageRuntime();
    await openPage(tester, runtime);
    expect(
      find.descendant(of: applied, matching: find.text('手机 Agent')),
      findsOneWidget,
    );
    await tap(tester, option('reviewer'));
    expect(runtime.writes, isEmpty);
    expect(find.text('待应用 · 审阅助手'), findsOneWidget);
    expect(
      find.descendant(of: applied, matching: find.text('手机 Agent')),
      findsOneWidget,
    );
    await tap(tester, apply);
    expect(runtime.writes, hasLength(1));
    expect(runtime.defaultPreset, 'reviewer');
    expect(
      find.descendant(of: applied, matching: find.text('审阅助手')),
      findsOneWidget,
    );
    expect(find.text('待应用 · 审阅助手'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'started session shows actual preset and cannot select global default',
    (tester) async {
      final runtime = PresetPageRuntime()
        ..exists = true
        ..started = true
        ..currentPreset = 'reviewer';
      await openPage(tester, runtime, sessionId: 'session-A');
      expect(
        find.descendant(of: applied, matching: find.text('审阅助手')),
        findsOneWidget,
      );
      expect(find.text('此会话已开始，预设不能再切换。'), findsOneWidget);
      expect(apply, findsNothing);
      expect(tester.widget<PocketTile>(option('android')).onTap, isNull);
      expect(runtime.writes, isEmpty);
      await tap(tester, document('reviewer'));
      expect(find.text('预设声明'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('agent-preset-document-content')),
        findsOneWidget,
      );
      expect(runtime.writes, isEmpty);
    },
  );

  testWidgets(
    'known absence of a composition is not shown as unknown or default',
    (tester) async {
      final runtime = PresetPageRuntime()
        ..exists = true
        ..started = true
        ..currentPreset = null;
      await openPage(tester, runtime, sessionId: 'session-A');
      expect(
        find.descendant(of: applied, matching: find.text('未使用预设')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: applied, matching: find.text('手机 Agent')),
        findsNothing,
      );
      expect(find.text('尚未确认'), findsNothing);
    },
  );

  testWidgets(
    'single preset chip can inspect without creating a session or inventing choices',
    (tester) async {
      final runtime = PresetPageRuntime();
      runtime.presets = [runtime.presets.first];
      await openPage(tester, runtime, sessionId: 'session-A', chip: true);
      expect(find.text('手机 Agent'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('session-preset-chip')));
      expect(find.text('会话预设'), findsOneWidget);
      expect(option('android'), findsOneWidget);
      expect(find.text('审阅助手'), findsNothing);
      expect(runtime.writes, isEmpty);
      expect(
        runtime.calls.any((entry) => entry.method == 'session.ensure'),
        isFalse,
      );
      expect(tester.widget<PocketButton>(apply).onPressed, isNull);
    },
  );

  testWidgets(
    'blank session applies its choice through the original session operation',
    (tester) async {
      final runtime = PresetPageRuntime();
      await openPage(tester, runtime, sessionId: 'session-A');
      await tap(tester, option('reviewer'));
      expect(runtime.exists, isFalse);
      await tap(tester, apply);
      expect(runtime.writes.single.method, 'session.selectPreset');
      expect(runtime.writes.single.params, {
        'sessionId': 'session-A',
        'agentPreset': 'reviewer',
      });
      expect(runtime.defaultPreset, 'android');
    },
  );

  testWidgets(
    'unavailable preset is inspectable and its reason is expanded on demand',
    (tester) async {
      final runtime = PresetPageRuntime();
      await openPage(tester, runtime);
      await tester.ensureVisible(option('broken'));
      expect(tester.widget<PocketTile>(option('broken')).onTap, isNull);
      await tap(tester, document('broken'));
      expect(find.text('暂不可用的原因'), findsOneWidget);
      final reason = runtime.presets.last['broken'] as String;
      expect(find.text(reason), findsNothing);
      await tap(tester, find.text('暂不可用的原因'));
      expect(find.text(reason), findsOneWidget);
      expect(runtime.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('declaration is selectable and copies exact content', (
    tester,
  ) async {
    final runtime = PresetPageRuntime();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await openPage(tester, runtime);
    await tap(tester, document('android'));
    final content = tester.widget<SelectableText>(
      find.byKey(const ValueKey('agent-preset-document-content')),
    );
    expect(content.data, declaration);
    await tap(tester, find.byTooltip('复制预设声明'));
    expect(copied, declaration);
    expect(find.text('已复制声明'), findsOneWidget);
    expect(runtime.writes, isEmpty);
  });

  testWidgets(
    'conflict retains the staged choice and needs deliberate reconciliation',
    (tester) async {
      final runtime = PresetPageRuntime()..conflictOnce = true;
      await openPage(tester, runtime);
      await tap(tester, option('reviewer'));
      await tap(tester, apply);
      expect(runtime.writes, hasLength(1));
      expect(find.text('待应用 · 审阅助手'), findsOneWidget);
      expect(find.text('预设已变化'), findsOneWidget);
      expect(tester.widget<PocketButton>(apply).onPressed, isNull);
      await tap(tester, find.text('保留我的选择'));
      expect(runtime.writes, hasLength(1));
      await tap(tester, apply);
      expect(runtime.writes, hasLength(2));
      expect(runtime.defaultPreset, 'reviewer');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('declaration can be left while read is pending', (tester) async {
    final runtime = PresetPageRuntime()..documentReply = Completer<dynamic>();
    await openPage(tester, runtime);
    await tap(tester, document('android'));
    expect(find.text('正在读取声明…'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    runtime.documentReply!.complete({
      'agentPreset': 'android',
      'content': declaration,
    });
    await tester.pumpAndSettle();
    expect(find.text('预设声明'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'uncertain write can be checked or discarded without replaying it',
    (tester) async {
      final runtime = PresetPageRuntime()..loseWriteReply = true;
      await openPage(tester, runtime);
      await tap(tester, option('reviewer'));
      await tap(tester, apply);
      expect(find.text('核对应用结果'), findsOneWidget);
      expect(find.text('待应用 · 审阅助手'), findsOneWidget);
      expect(tester.widget<PocketButton>(apply).onPressed, isNull);
      await tap(tester, find.text('继续核对'));
      expect(runtime.writes, hasLength(1));
      await tap(tester, find.text('采用当前预设'));
      expect(find.text('待应用 · 审阅助手'), findsNothing);
      expect(
        find.descendant(of: applied, matching: find.text('手机 Agent')),
        findsOneWidget,
      );
      expect(runtime.writes, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed declaration read remains recoverable inside the page', (
    tester,
  ) async {
    final runtime = PresetPageRuntime()..readFails = true;
    await openPage(tester, runtime);
    await tap(tester, document('android'));
    expect(find.text('重新读取'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('agent-preset-document-content')),
      findsNothing,
    );
    runtime.readFails = false;
    await tap(tester, find.text('重新读取'));
    expect(
      find.byKey(const ValueKey('agent-preset-document-content')),
      findsOneWidget,
    );
    expect(runtime.writes, isEmpty);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      '${brightness.name} grouped layout remains usable at phone width',
      (tester) async {
        final runtime = PresetPageRuntime();
        await openPage(tester, runtime, brightness: brightness);
        await capture(tester, '${brightness.name}-presets');
        await tap(tester, option('reviewer'));
        await capture(tester, '${brightness.name}-draft');
        await tap(tester, document('reviewer'));
        await capture(tester, '${brightness.name}-declaration');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'large text can scroll to every preset and declaration without overflow',
    (tester) async {
      final runtime = PresetPageRuntime();
      await openPage(
        tester,
        runtime,
        textScale: 1.8,
        size: const Size(360, 800),
        brightness: Brightness.dark,
      );
      await capture(tester, 'large-presets');
      await tap(tester, option('reviewer'));
      expect(find.text('待应用 · 审阅助手'), findsOneWidget);
      await capture(tester, 'large-draft');
      await tap(tester, document('broken'));
      await tap(tester, find.text('暂不可用的原因'));
      await tester.ensureVisible(
        find.byKey(const ValueKey('agent-preset-document-content')),
      );
      await tester.pumpAndSettle();
      await capture(tester, 'large-declaration');
      expect(tester.takeException(), isNull);
      expect(runtime.writes, isEmpty);
    },
  );
}
