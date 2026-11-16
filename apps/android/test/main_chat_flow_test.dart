import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_turn_navigation.dart';
import 'package:dsh_android/composer_commands.dart';
import 'package:dsh_android/main.dart';
import 'package:dsh_android/pocket_composer.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/resource_hub.dart';
import 'package:dsh_android/session_document.dart';
import 'package:dsh_android/session_trajectory.dart';
import 'package:dsh_android/tasks.dart';
import 'package:dsh_android/subagents.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_projection_test.dart' as fixture;
import 'subagents_data_test.dart' as child_fixture;

class _ChatRuntime extends RuntimeController {
  _ChatRuntime(this.history) {
    phase = 'ready';
    sessions = [
      {
        'header': {'id': 'history', 'title': '历史会话'},
      },
    ];
  }
  final List<Json> history;
  final calls = <({String method, Json params})>[];
  int draft = 0;
  bool codingToolsEnabled = true;
  bool childCatalogEnabled = false;
  String catalogTitle = '历史会话';
  final libraryStreams = <String, List<StreamController<Json>>>{};

  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) {
    late final StreamController<Json> stream;
    stream = StreamController<Json>(
      onListen: () => scheduleMicrotask(
        () => stream.add({
          'type': 'item',
          'value': {'type': 'baseline'},
        }),
      ),
    );
    libraryStreams.putIfAbsent(namespace, () => []).add(stream);
    return stream.stream;
  }

  @override
  void dispose() {
    super.dispose();
    for (final streams in libraryStreams.values) {
      for (final stream in streams) {
        unawaited(stream.close());
      }
    }
  }

  @override
  String newSession() {
    final id = 'draft-${draft++}';
    timelines[id] = [];
    return id;
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method: method, params: params));
    switch (method) {
      case 'userText.mask':
        return {'ranges': <Json>[]};
      case 'api.call':
        if (params['namespace'] == 'settings' &&
            params['method'] == 'describe') {
          return {
            'writable': true,
            'namespaces': [
              {
                'ns': 'ui-settings',
                'revision': 1,
                'value': {'enabled': codingToolsEnabled},
                'schema': <String, dynamic>{},
                'secrets': <String>[],
              },
            ],
          };
        }
        if (params['namespace'] == 'session' &&
            params['method'] == 'projections') {
          return null;
        }
        throw StateError(
          'Unexpected API ${params['namespace']}.${params['method']}',
        );
      case 'library.catalog':
        return {
          'workspaces': <Json>[],
          'sessions': [
            {
              'sessionId': 'history',
              'updatedAt': 1,
              'running': false,
              'blank': false,
              'cwd': '/fixture',
              'projections': {
                'values': {'title': catalogTitle},
              },
            },
          ],
          'archivedSessionIds': <String>[],
          'pinnedSessionIds': <String>[],
          'defaultDirectory': '/fixture',
        };
      case 'session.read':
        if (params['sessionId'] != 'history') {
          throw StateError('Unexpected session read');
        }
        return {
          'events': history
              .where((row) => (row['seq'] as int) >= (params['offset'] as int))
              .take(200)
              .toList(),
        };
      case 'session.readWindow':
        if (params['sessionId'] != 'history') {
          throw StateError('Unexpected session window read');
        }
        final before = params['beforeSeq'] as int?;
        final eligible = history
            .where((row) => before == null || (row['seq'] as int) < before)
            .toList();
        final page = eligible.length <= 200
            ? eligible
            : eligible.sublist(eligible.length - 200);
        return {
          'events': page,
          'firstSeq': page.isEmpty ? null : page.first['seq'],
          'throughSeq': history.isEmpty ? -1 : history.last['seq'],
          'hasMore': eligible.length > page.length,
        };
      case 'session.turnOutline':
        if (params['sessionId'] != 'history') {
          throw StateError('Unexpected turn outline read');
        }
        return {
          'asOfSeq': history.isEmpty ? -1 : history.last['seq'],
          'turns': history.isEmpty
              ? <Json>[]
              : <Json>[
                  {
                    'turn': 1,
                    'seq': history.first['seq'],
                    'prompt': 'Question',
                    'response': '',
                  },
                ],
        };
      case 'tasks.list':
        return {
          'epoch': 'fixture-epoch',
          'revision': 1,
          'summary': {
            'running': 0,
            'waiting': 0,
            'backgroundJobs': 0,
            'packageOperations': 0,
          },
          'active': <Json>[],
          'sessions': <Json>[],
          'nextOffset': null,
        };
      case 'interactions.list':
        return {'revision': 1, 'requests': <Json>[]};
      case 'subagents.catalog':
        return {
          'parentSessionId': params['parentSessionId'],
          'parentAvailable': false,
          'entries': <Json>[
            if (childCatalogEnabled && params['parentSessionId'] == 'history')
              {
                'id': 'child',
                'mode': 'continuable',
                'label': '分析员',
                'address': {
                  'parentSessionId': 'history',
                  'childSessionId': 'child',
                  'mode': 'continuable',
                },
                'attached': false,
                'running': false,
              },
          ],
          'nextOffset': null,
        };
      case 'subagents.inspect':
        if (!childCatalogEnabled) throw StateError('Unexpected child inspect');
        return {
          ...child_fixture.inspection(),
          'address': {
            'parentSessionId': 'history',
            'childSessionId': 'child',
            'mode': 'continuable',
          },
        };
    }
    throw StateError('Unexpected $method');
  }

  void append(Json event) {
    timelines['history']!.add(event);
    if (event['type'] == 'session/title') {
      catalogTitle = event['data']['title'] as String;
      for (final stream
          in libraryStreams['session'] ?? <StreamController<Json>>[]) {
        stream.add({
          'type': 'item',
          'value': {'type': 'projection', 'key': 'title'},
        });
      }
    }
    notifyListeners();
  }

  void live({required int revision}) {
    liveMessages['history'] = {
      'attemptId': 'fixture-attempt',
      'revision': revision,
      'turn': 2,
      'step': 1,
      'content': [
        {'type': 'text', 'text': 'Live delta $revision'},
      ],
      'interrupted': false,
    };
    notifyListeners();
  }

  void routeTasks() {
    navigationRequest = {'route': 'tasks'};
    notifyListeners();
  }

  void routeSession(String sessionId) {
    navigationRequest = {'route': 'session', 'sessionId': sessionId};
    notifyListeners();
  }
}

/// 会话模型目录与 `selectModel` 的测试替身：推理面板的档位、默认强度与切换回执
/// 都走与 `SessionModelPage` 相同的门面方法，`selectModel` 成功后把
/// `model/selection` 写进会话日志（与真实核心一致），供页面投影回显。
class _ModelChatRuntime extends _ChatRuntime {
  _ModelChatRuntime(super.history);

  final modelCalls = <({String method, Json params})>[];

  static const _catalog = <String, dynamic>{
    'default': {
      'provider': 'deepseek-official',
      'model': 'deepseek-flash',
      'reasoningEffort': 'low',
    },
    'groups': [
      {
        'id': 'deepseek-official',
        'name': 'DeepSeek',
        'models': [
          {
            'id': 'deepseek-flash',
            'name': 'DeepSeek-V4.1-Flash',
            'reasoning': {
              'defaultEffort': 'low',
              'efforts': [
                {'id': 'low', 'name': '低'},
                {'id': 'medium', 'name': '中'},
                {'id': 'high', 'name': '高'},
              ],
            },
          },
        ],
      },
    ],
    'failures': <Json>[],
    'routableProviders': ['deepseek-official'],
  };

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method == 'session.ensure') return {'sessionId': params['sessionId']};
    if (method == 'session.cancel') return <String, dynamic>{};
    if (method == 'api.call' && params['namespace'] == 'session') {
      switch (params['method']) {
        case 'modelCatalog':
          modelCalls.add((method: 'modelCatalog', params: params));
          return _catalog;
        case 'selectModel':
          modelCalls.add((method: 'selectModel', params: params));
          final request = (params['args'] as Json)['request'] as Json;
          final selected = <String, dynamic>{
            'provider': request['provider'],
            'model': request['model'],
            'reasoningEffort': request['reasoningEffort'],
          };
          final id = request['sessionId'] as String;
          final timeline = timelines[id] ??= <Json>[];
          timeline.add({
            'seq': timeline.length,
            'time': 0,
            'type': 'model/selection',
            'surfaceOp': 'append',
            'data': selected,
          });
          notifyListeners();
          return {'selected': selected};
        case 'projections':
          return null;
      }
    }
    if (method == 'api.call' &&
        params['namespace'] == 'commands' &&
        params['method'] == 'list') {
      return <Json>[
        {
          'name': 'permission',
          'definitionId': '@deepseek-ai/dsh-permission-presets',
          'description': '切换权限预设（沙箱模式与审批策略）',
        },
      ];
    }
    if (method == 'api.call' &&
        params['namespace'] == 'permissionPresets' &&
        params['method'] == 'catalog') {
      return {
        'options': [
          {'value': 'read-only', 'name': '仅可查看'},
          {'value': 'workspace-write', 'name': '工作区内修改'},
        ],
      };
    }
    return super.call(method, params);
  }
}

Widget _host(_ChatRuntime runtime) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  builder: (_, child) => MediaQuery(
    data: const MediaQueryData(size: Size(390, 844), disableAnimations: true),
    child: child!,
  ),
  home: ChatPage(runtime: runtime),
);
void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _openHistory(WidgetTester tester) async {
  await tester.tap(find.byTooltip('打开侧栏'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('历史会话'));
  await tester.tap(find.text('历史会话'));
  await tester.pumpAndSettle();
}

ScrollController _scroll(WidgetTester tester) =>
    tester.widget<ChatTimeline>(find.byType(ChatTimeline)).controller;

/// 输入卡当前渲染状态（browse/composing/picker）。
PocketComposerMode _composerMode(WidgetTester tester) => tester
    .widget<PocketComposer>(find.byKey(const ValueKey('chat-composer')))
    .mode;

void main() {
  testWidgets('external keyboard searches sessions and starts a new chat', (
    tester,
  ) async {
    _phone(tester);
    final runtime = _ChatRuntime([]);
    addTearDown(runtime.dispose);
    await tester.pumpWidget(_host(runtime));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('sidebar-search'));
    expect(search, findsOneWidget);
    expect(tester.widget<TextField>(search).focusNode?.hasFocus, isTrue);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '拼音',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(runtime.draft, 1);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '拼音',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(search, findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(runtime.draft, 2);
    expect(
      tester
          .widget<TextField>(find.byKey(PocketComposer.inputKey))
          .focusNode
          ?.hasFocus,
      isTrue,
    );
  });

  testWidgets(
    'assistant file link opens the original document route with its Session and line',
    (tester) async {
      _phone(tester);
      final runtime = _ChatRuntime([
        fixture.input(0, 'Show the report'),
        fixture.assistant(1, '[查看报告](../reports/report.md#L12-L18)'),
      ]);
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await _openHistory(tester);
      await tester.tap(find.text('查看报告', findRichText: true).last);
      await tester.pumpAndSettle();
      final page = tester.widget<SessionDocumentPage>(
        find.byType(SessionDocumentPage),
      );
      expect(
        (page.sessionId, page.path, page.line),
        ('history', '../reports/report.md', 12),
      );
      expect(
        runtime.calls.any(
          (call) =>
              call.method == 'session.ensure' ||
              call.method == 'session.send' ||
              call.method.startsWith('attachments.'),
        ),
        false,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ChatTimeline), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.linux}),
  );

  testWidgets('optional local composer layout captures', (tester) async {
    final output = Platform.environment['POCKET_COMPOSER_CAPTURE_DIR'];
    if (output == null) return;
    _phone(tester);
    await tester.runAsync(() async {
      final bytes = await File(Platform.environment['POCKET_CAPTURE_FONT']!)
          .readAsBytes();
      await (FontLoader(
        'PocketCapture',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      await Directory(output).create(recursive: true);
    });
    for (final brightness in Brightness.values) {
      for (final layout in ['empty', 'multiline', 'keyboard', 'large']) {
        final runtime = _ChatRuntime([]);
        addTearDown(runtime.dispose);
        final boundary = GlobalKey();
        final theme = pocketTheme(brightness);
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: 'PocketCapture'),
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  disableAnimations: true,
                  textScaler: TextScaler.linear(layout == 'large' ? 1.6 : 1),
                  viewInsets: EdgeInsets.only(
                    bottom: layout == 'keyboard' ? 300 : 0,
                  ),
                ),
                child: LiquidGlassScope(enabled: true, child: child!),
              ),
              home: ChatPage(runtime: runtime),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (layout == 'multiline') {
          await tester.enterText(
            find.byKey(PocketComposer.inputKey),
            '读取选中的文件\n整理主要内容\n列出需要确认的问题',
          );
          await tester.pumpAndSettle();
        }
        await tester.runAsync(() async {
          final picture =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          try {
            final data = await picture.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File('$output/composer-${brightness.name}-$layout.png')
                .writeAsBytes(data!.buffer.asUint8List());
          } finally {
            picture.dispose();
          }
        });
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('composer starts collapsed and expands when focused', (
    tester,
  ) async {
    _phone(tester);
    final runtime = _ChatRuntime([]);
    addTearDown(runtime.dispose);
    await tester.pumpWidget(_host(runtime));
    await tester.pumpAndSettle();
    final field = find.byKey(PocketComposer.inputKey);
    final plus = find.byTooltip('添加与指令');
    final send = find.byTooltip('发送');
    // 缩小态：加号与发送圆钮跟输入框在同一行、垂直居中。
    expect(
      tester.getRect(plus).center.dy,
      closeTo(tester.getRect(field).center.dy, .01),
    );
    expect(
      tester.getRect(send).center.dy,
      closeTo(tester.getRect(field).center.dy, .01),
    );
    expect(find.byKey(PocketComposer.rootKey), findsOneWidget);

    // 聚焦展开：加号与发送圆钮移到输入区下方工具条，输入区在上。
    await tester.tap(field);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(plus).top,
      greaterThanOrEqualTo(tester.getRect(field).bottom),
    );
    expect(
      tester.getRect(send).top,
      greaterThanOrEqualTo(tester.getRect(field).bottom),
    );
    expect(
      tester.getRect(send).center.dy,
      closeTo(tester.getRect(plus).center.dy, .01),
    );

    // 失焦且草稿为空：缩回浏览态。
    tester.binding.focusManager.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(
      tester.getRect(plus).center.dy,
      closeTo(tester.getRect(field).center.dy, .01),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard hides collapse the composer only without a draft', (
    tester,
  ) async {
    _phone(tester);
    final runtime = _ChatRuntime([]);
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: ChatPage(runtime: runtime),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(PocketComposer.inputKey);
    final plus = find.byTooltip('添加与指令');
    expect(
      tester.getRect(plus).center.dy,
      closeTo(tester.getRect(field).center.dy, .01),
    );

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(
      _composerMode(tester),
      PocketComposerMode.composing,
      reason: '键盘弹起时输入卡展开',
    );
    expect(
      tester.getRect(plus).top,
      greaterThanOrEqualTo(tester.getRect(field).bottom),
      reason: '键盘弹起时输入卡展开',
    );

    tester.view.viewInsets = const FakeViewPadding();
    await tester.pumpAndSettle();
    expect(
      _composerMode(tester),
      PocketComposerMode.browse,
      reason: '键盘收起且没有草稿时缩回浏览态',
    );
    expect(
      tester.getRect(plus).center.dy,
      closeTo(tester.getRect(field).center.dy, .01),
      reason: '键盘收起且没有草稿时缩回浏览态',
    );

    await tester.enterText(field, '保留的草稿');
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pumpAndSettle();
    expect(
      _composerMode(tester),
      PocketComposerMode.composing,
      reason: '有草稿时即使键盘收起也保持展开',
    );
    expect(
      tester.getRect(plus).top,
      greaterThanOrEqualTo(tester.getRect(field).bottom),
      reason: '有草稿时即使键盘收起也保持展开',
    );
    expect(find.text('保留的草稿'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'composer stays expanded through metrics jitter before the keyboard shows',
    (tester) async {
      _phone(tester);
      final runtime = _ChatRuntime([]);
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await tester.pumpAndSettle();
      final field = find.byKey(PocketComposer.inputKey);
      await tester.tap(field);
      await tester.pumpAndSettle();
      expect(_composerMode(tester), PocketComposerMode.composing);

      // 聚焦后、键盘真正弹起前，Android 还会派发「键盘仍不可见」的 metrics
      // （窗口尺寸抖动）。输入卡不得因此缩回，也不得被解焦。
      for (var jitter = 0; jitter < 5; jitter++) {
        tester.binding.handleMetricsChanged();
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(
        _composerMode(tester),
        PocketComposerMode.composing,
        reason: '键盘还没起来时的 metrics 抖动不得缩回输入卡',
      );
      expect(find.byTooltip('推理强度'), findsOneWidget);
      expect(
        tester.widget<TextField>(field).focusNode?.hasFocus,
        isTrue,
        reason: 'metrics 抖动不得把输入框解焦',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tapping the collapsed composer focuses the input and requests the IME',
    (tester) async {
      _phone(tester);
      final runtime = _ChatRuntime([]);
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await tester.pumpAndSettle();
      final field = find.byKey(PocketComposer.inputKey);
      expect(_composerMode(tester), PocketComposerMode.browse);
      tester.testTextInput.log.clear();

      // 卡片底部内边距不属于输入框：点它也要聚焦并展开。
      final card = tester.getRect(find.byKey(PocketComposer.cardKey));
      await tester.tapAt(Offset(card.center.dx, card.bottom - 4));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(_composerMode(tester), PocketComposerMode.composing);
      expect(
        tester.widget<TextField>(field).focusNode?.hasFocus,
        isTrue,
        reason: '点卡片空白处也要聚焦输入框',
      );
      expect(
        tester.testTextInput.log.map((call) => call.method),
        contains('TextInput.show'),
        reason: '聚焦后要显式请求一次输入法显示',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'composer plus opens the data-driven command sheet and keeps the draft',
    (tester) async {
      _phone(tester);
      final runtime = _ChatRuntime([]);
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(PocketComposer.inputKey), '保留的草稿');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加与指令'));
      await tester.pumpAndSettle();
      expect(find.byType(ComposerCommands), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ComposerCommands), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(PocketComposer.inputKey))
            .controller!
            .text,
        '保留的草稿',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'composer reasoning panel reads the session model catalog and applies an effort',
    (tester) async {
      _phone(tester);
      final runtime = _ModelChatRuntime([]);
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(PocketComposer.inputKey));
      await tester.pumpAndSettle();
      final catalogReadsBefore = runtime.modelCalls
          .where((call) => call.method == 'modelCatalog')
          .length;
      await tester.tap(find.byTooltip('推理强度'));
      await tester.pumpAndSettle();
      expect(
        runtime.modelCalls.where((call) => call.method == 'modelCatalog'),
        hasLength(catalogReadsBefore + 1),
        reason: '打开面板时按会话模型目录读一次档位',
      );
      final models = find.byKey(PocketComposer.modelsKey);
      expect(models, findsOneWidget);
      expect(
        find.descendant(of: models, matching: find.text('DeepSeek-V4.1-Flash')),
        findsOneWidget,
      );
      // 当前会话没有显式选择时用目录声明的默认强度回显。
      expect(
        find.descendant(of: models, matching: find.text('低')),
        findsOneWidget,
      );
      expect(find.byKey(PocketComposer.stopKeyFor('high')), findsOneWidget);

      await tester.tap(find.byKey(PocketComposer.stopKeyFor('high')));
      await tester.pumpAndSettle();
      final selectModel = runtime.modelCalls
          .where((call) => call.method == 'selectModel')
          .single;
      final selectRequest =
          (selectModel.params['args'] as Json)['request'] as Json;
      expect(selectRequest['sessionId'], runtime.timelines.keys.single);
      expect(selectRequest['reasoningEffort'], 'high');
      // 会话日志里的 model/selection 让面板回显新档位。
      expect(
        find.descendant(of: models, matching: find.text('高')),
        findsOneWidget,
      );

      // 模型名那一行连接既有会话模型页（与页头标题同一入口）；这里只断言接线，
      // 不真的推页：`SessionModelPage` 打开时插件状态刷新会在调试构建里触发一条
      // 既有的「setState during build」断言（与本输入卡无关，另行报告）。
      expect(tester.widget<InkWell>(models).onTap, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('composer permission shield opens the local permission page', (
    tester,
  ) async {
    _phone(tester);
    final runtime = _ModelChatRuntime([]);
    addTearDown(runtime.dispose);
    await tester.pumpWidget(_host(runtime));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(PocketComposer.inputKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('权限预设'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionPermissionPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(PocketComposer.inputKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 1.6]) {
    for (final keyboard in [0.0, 300.0]) {
      testWidgets(
        'composer composes input above the toolbar within the viewport: scale=$scale keyboard=$keyboard',
        (tester) async {
          _phone(tester);
          final runtime = _ChatRuntime([]);
          addTearDown(runtime.dispose);
          await tester.pumpWidget(
            MaterialApp(
              theme: pocketTheme(Brightness.light),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  disableAnimations: true,
                  textScaler: TextScaler.linear(scale),
                  viewInsets: EdgeInsets.only(bottom: keyboard),
                ),
                child: child!,
              ),
              home: ChatPage(runtime: runtime),
            ),
          );
          await tester.pumpAndSettle();
          final field = find.byKey(PocketComposer.inputKey);
          final card = find.byKey(PocketComposer.cardKey);
          for (final draft in ['', '一行输入', '第一行\n第二行\n第三行']) {
            await tester.enterText(field, draft);
            await tester.pumpAndSettle();
            final bar = tester.getRect(card);
            final input = tester.getRect(field);
            final plus = tester.getRect(find.byTooltip('添加与指令'));
            final send = tester.getRect(find.byTooltip('发送'));
            // 展开态：输入区一行、工具条一行；工具条在输入区下方。
            expect(plus.top, greaterThanOrEqualTo(input.bottom));
            expect(send.top, greaterThanOrEqualTo(input.bottom));
            expect(plus.center.dy, closeTo(send.center.dy, .01));
            expect(plus.size.width, closeTo(plus.size.height, .01));
            expect(send.size.width, closeTo(send.size.height, .01));
            expect(bar.bottom, lessThanOrEqualTo(844 - keyboard));
            expect(tester.takeException(), isNull);
          }
          expect(
            runtime.calls.any((call) => call.method == 'session.send'),
            isFalse,
          );
        },
      );
    }
  }

  testWidgets(
    'opening variable-height long history reaches the actual last reply',
    (tester) async {
      _phone(tester);
      final history = <Json>[
        ...List.generate(
          300,
          (index) => fixture.assistant(
            index,
            index < 270
                ? 'Reply $index'
                : 'Reply $index\n\n${'A longer paragraph in the final portion of the saved conversation.\n\n' * 8}',
            step: index + 1,
          ),
        ),
        fixture.assistant(300, 'LAST_SAVED_REPLY', step: 301),
      ];
      final runtime = _ChatRuntime(history);
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await _openHistory(tester);
      expect(
        runtime.calls.where((call) => call.method == 'session.readWindow'),
        hasLength(1),
      );
      expect(
        _scroll(tester).position.extentAfter,
        lessThan(2),
        reason:
            'One jump to an estimated ListView extent is not the true tail.',
      );
      expect(find.text('LAST_SAVED_REPLY', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a saved conversation keeps turn navigation reachable from the top bar',
    (tester) async {
      _phone(tester);
      final runtime = _ChatRuntime([fixture.input(0, 'Question')]);
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await _openHistory(tester);
      await tester.tap(find.byTooltip('会话更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('会话轮次').last);
      await tester.pumpAndSettle();
      expect(find.byType(ChatTurnNavigatorPage), findsOneWidget);
      expect(find.text('Question'), findsOneWidget);
      expect(
        runtime.calls.any((call) => call.method == 'session.turnOutline'),
        isTrue,
      );
      expect(
        runtime.calls.any((call) => call.method == 'session.send'),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a saved conversation opens its resource navigation without sending work',
    (tester) async {
      _phone(tester);
      final runtime = _ChatRuntime([fixture.input(0, 'Question')]);
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await _openHistory(tester);
      await tester.tap(find.byTooltip('会话更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('会话资源'));
      await tester.pumpAndSettle();
      expect(find.byType(SessionResourcesPage), findsOneWidget);
      expect(find.text('文件改动'), findsOneWidget);
      expect(
        runtime.calls.any((call) => call.method == 'session.send'),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a saved conversation opens its read-only trajectory', (
    tester,
  ) async {
    _phone(tester);
    final runtime = _ChatRuntime([fixture.input(0, 'Question')]);
    addTearDown(runtime.dispose);
    await tester.pumpWidget(_host(runtime));
    await _openHistory(tester);
    await tester.tap(find.byTooltip('会话更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('会话轨迹'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionTrajectoryPage), findsOneWidget);
    expect(runtime.calls.any((call) => call.method == 'session.read'), isTrue);
    expect(runtime.calls.any((call) => call.method == 'session.send'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Coding Tools hides the trajectory entry without changing session data',
    (tester) async {
      _phone(tester);
      final runtime = _ChatRuntime([fixture.input(0, 'Question')])
        ..codingToolsEnabled = false;
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await _openHistory(tester);
      await tester.tap(find.byTooltip('会话更多'));
      await tester.pumpAndSettle();
      expect(find.text('会话轨迹'), findsNothing);
      expect(find.text('会话资源'), findsOneWidget);
      await tester.tapAt(const Offset(10, 500));
      await tester.pumpAndSettle();
      runtime.codingToolsEnabled = true;
      runtime.forms = <Json>[];
      runtime.notifyListeners();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('会话更多'));
      await tester.pumpAndSettle();
      expect(find.text('会话轨迹'), findsOneWidget);
      expect(
        runtime.calls.any((call) => call.method == 'session.send'),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reading older messages is not displaced by live deltas or appended replies',
    (tester) async {
      _phone(tester);
      final runtime = _ChatRuntime(
        List.generate(
          80,
          (index) =>
              fixture.assistant(index, 'Saved reply $index', step: index + 1),
        ),
      );
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await _openHistory(tester);
      final scroll = _scroll(tester);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      final position = scroll.offset;
      runtime.live(revision: 1);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(position, .01));
      runtime.live(revision: 2);
      runtime.append(fixture.assistant(80, 'New settled reply', turn: 2));
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(position, .01));
      expect(find.text('Saved reply 0', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'loaded session title updates its sidebar entry without a second history read',
    (tester) async {
      _phone(tester);
      final runtime = _ChatRuntime([fixture.input(0, 'Question')]);
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await _openHistory(tester);
      runtime.append(fixture.event(1, 'session/title', {'title': '可读的新标题'}));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('打开侧栏'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('可读的新标题'));
      expect(find.text('可读的新标题'), findsOneWidget);
      expect(find.text('历史会话'), findsNothing);
      expect(
        runtime.calls.where((call) => call.method == 'session.readWindow'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final ready in [true, false]) {
    testWidgets(
      'tasks notification opens native task page and preserves draft when ready=$ready',
      (tester) async {
        _phone(tester);
        final runtime = _ChatRuntime([]);
        if (!ready) runtime.phase = 'failed';
        addTearDown(runtime.dispose);
        await tester.pumpWidget(_host(runtime));
        await tester.enterText(find.byType(TextField), '保留的聊天草稿');
        runtime.routeTasks();
        await tester.pumpAndSettle();
        expect(find.byType(TasksPage), findsOneWidget);
        expect(runtime.navigationRequest, isNull);
        if (ready) {
          expect(find.text('当前没有运行中的任务'), findsOneWidget);
        } else {
          expect(find.text('任务状态暂不可用'), findsOneWidget);
          expect(runtime.calls, isEmpty);
        }
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(TasksPage), findsNothing);
        expect(find.text('保留的聊天草稿'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'completion notification returns to its session from another page',
    (tester) async {
      _phone(tester);
      final runtime = _ChatRuntime([
        fixture.input(0, 'Question'),
        fixture.assistant(1, 'Task completed'),
      ]);
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      runtime.routeTasks();
      await tester.pumpAndSettle();
      expect(find.byType(TasksPage), findsOneWidget);

      runtime.routeSession('history');
      await tester.pumpAndSettle();
      expect(find.byType(TasksPage), findsNothing);
      expect(find.text('Task completed', findRichText: true), findsWidgets);
      expect(
        runtime.calls.where((call) => call.method == 'session.readWindow'),
        hasLength(1),
      );
      expect(runtime.navigationRequest, isNull);
      expect(
        runtime.calls.any((call) => call.method == 'session.send'),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('sidebar opens current parent catalog and retains its draft', (
    tester,
  ) async {
    _phone(tester);
    final runtime = _ChatRuntime([fixture.input(0, 'Question')]);
    addTearDown(runtime.dispose);
    await tester.pumpWidget(_host(runtime));
    await _openHistory(tester);
    await tester.enterText(find.byType(TextField), '父会话未发送的草稿');
    await tester.tap(find.byTooltip('打开侧栏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('当前会话的子 Agent'));
    await tester.pumpAndSettle();
    expect(find.byType(SubagentsPage), findsOneWidget);
    final call = runtime.calls.singleWhere(
      (call) => call.method == 'subagents.catalog',
    );
    expect(call.params['parentSessionId'], 'history');
    expect(runtime.calls.any((call) => call.method == 'session.send'), isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('父会话未发送的草稿'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('child transcript returns to the same parent draft and scroll', (
    tester,
  ) async {
    _phone(tester);
    final runtime = _ChatRuntime([
      fixture.input(0, 'Question'),
      for (var i = 1; i <= 80; i++)
        fixture.assistant(i, 'Parent reply $i', step: i),
    ])..childCatalogEnabled = true;
    addTearDown(runtime.dispose);
    await tester.pumpWidget(_host(runtime));
    await _openHistory(tester);
    await tester.enterText(find.byType(TextField), '保留的父会话草稿');
    final parentScroll = _scroll(tester);
    expect(parentScroll.position.maxScrollExtent, greaterThan(120));
    parentScroll.jumpTo(120);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('打开侧栏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('当前会话的子 Agent'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分析员'));
    await tester.pumpAndSettle();
    expect(find.byType(SubagentConversationPage), findsOneWidget);
    expect(find.text('saved input'), findsOneWidget);
    expect(
      runtime.calls.where((call) => call.method == 'subagents.inspect'),
      hasLength(2),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('保留的父会话草稿'), findsOneWidget);
    expect(identical(_scroll(tester), parentScroll), isTrue);
    expect(_scroll(tester).offset, closeTo(120, 1));
    expect(runtime.calls.any((call) => call.method == 'session.send'), isFalse);
    expect(tester.takeException(), isNull);
  });
}
