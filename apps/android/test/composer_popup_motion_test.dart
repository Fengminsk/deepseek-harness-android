import 'dart:async';

import 'package:dsh_android/composer_commands.dart';
import 'package:dsh_android/chat_goal.dart';
import 'package:dsh_android/flclash/popup.dart';
import 'package:dsh_android/main.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

// The original commands.list descriptor fields, including input-bearing commands
// and an unrelated plugin row, exercise the actual command menu arrangement.
const _catalog = <Json>[
  {
    'name': 'goal',
    'definitionId': '@deepseek-ai/dsh-command-goal',
    'description': 'Set or view the goal for a long-running task',
    'input': {
      'hint': '[<objective>|clear|edit <objective>|pause|resume]',
      'attachments': true,
    },
  },
  {
    'name': 'plan',
    'definitionId': '@deepseek-ai/dsh-plan-mode',
    'description': 'Enter or leave plan mode',
    'input': {'hint': '[off|message]', 'attachments': true},
  },
  {
    'name': 'feedback',
    'definitionId': '@deepseek-ai/dsh-command-feedback',
    'description': 'Send feedback about the current session',
    'input': {'hint': '<feedback>', 'attachments': true},
  },
  {
    'name': 'compact',
    'definitionId': '@deepseek-ai/dsh-command-compact',
    'description': 'Compact conversation history',
  },
  {
    'name': 'permission',
    'definitionId': '@deepseek-ai/dsh-permission-presets',
    'description': 'Select a permission preset',
  },
  {
    'name': 'export',
    'definitionId': '@deepseek-ai/dsh-session-log-export',
    'description': 'Export session logs',
  },
  {
    'name': 'plugin-status',
    'description': 'Show the installed plugin status without running a task',
  },
];

class _Runtime extends RuntimeController {
  _Runtime() {
    phase = 'ready';
  }

  final calls = <({String method, Json params})>[];
  Completer<List<Json>>? catalogResponse;

  @override
  String newSession() {
    final id = super.newSession();
    timelines[id]!.addAll([
      for (var turn = 1; turn <= 12; turn++) ...[
        {
          'seq': turn * 2 - 1,
          'time': (turn * 2 - 1) * 1000,
          'type': 'user/message',
          'surfaceOp': 'append',
          'data': {
            'id': 'fixture-user-$turn',
            'role': 'user',
            'source': {'kind': 'user'},
            'content': [
              {'type': 'text', 'text': '问题 $turn：请保留当前聊天位置。'},
            ],
          },
        },
        {
          'seq': turn * 2,
          'time': turn * 2 * 1000,
          'type': 'assistant/message',
          'surfaceOp': 'append',
          'data': {
            'turn': turn,
            'step': 1,
            'message': {
              'id': 'fixture-assistant-$turn',
              'role': 'assistant',
              'source': {
                'kind': 'model',
                'provider': 'fixture-provider',
                'model': 'fixture-model',
              },
              'content': [
                {'type': 'text', 'text': '回复 $turn：菜单应悬浮在内容之上，关闭后可以继续编辑。'},
              ],
            },
            'stream': <Json>[],
          },
        },
      ],
    ]);
    return id;
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method: method, params: params));
    if (method == 'userText.mask') return {'ranges': <Json>[]};
    if (method == 'session.ensure') {
      expect(timelines.containsKey(params['sessionId']), isTrue);
      return {'sessionId': params['sessionId'], 'created': false};
    }
    if (method == 'api.call' &&
        params['namespace'] == 'commands' &&
        params['method'] == 'list') {
      expect(params['args'], {'agentId': timelines.keys.single});
      return catalogResponse == null ? _catalog : await catalogResponse!.future;
    }
    if (method == 'api.call' &&
        params['namespace'] == 'session' &&
        params['method'] == 'projections') {
      return {
        'kind': 'sequenced',
        'asOfSeq': 0,
        'values': {'goal': null, 'plan': null},
      };
    }
    if (method == 'api.call' &&
        params['namespace'] == 'settings' &&
        params['method'] == 'describe') {
      return {'revision': 0, 'values': <String, dynamic>{}};
    }
    throw StateError('Unexpected runtime action: $method $params');
  }

  void expectOnlyDiscovery() {
    expect(calls, isNotEmpty);
    for (final call in calls) {
      expect(
        call.method == 'session.ensure' ||
            call.method == 'userText.mask' ||
            (call.method == 'api.call' &&
                ((call.params['namespace'] == 'commands' &&
                        call.params['method'] == 'list') ||
                    (call.params['namespace'] == 'session' &&
                        call.params['method'] == 'projections') ||
                    (call.params['namespace'] == 'settings' &&
                        call.params['method'] == 'describe'))),
        isTrue,
        reason: 'Dismissal must not submit a prompt or run a command: $call',
      );
    }
  }
}

class _Routes extends NavigatorObserver {
  final popups = <CommonPopupRoute<dynamic>>[];
  final active = <Route<dynamic>>{};
  int maxActive = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is CommonPopupRoute) {
      popups.add(route);
      active.add(route);
      if (active.length > maxActive) maxActive = active.length;
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    active.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    active.remove(route);
  }
}

Future<(_Runtime, _Routes)> _chat(
  WidgetTester tester, {
  bool reduceMotion = false,
  double scale = 1,
  bool glass = false,
  _Runtime? runtime,
}) async {
  tester.view
    ..physicalSize = const Size(360, 800)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  final service = runtime ?? _Runtime();
  addTearDown(service.dispose);
  final routes = _Routes();
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      navigatorObservers: [routes],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduceMotion,
          textScaler: TextScaler.linear(scale),
        ),
        child: LiquidGlassScope(
          enabled: glass,
          child: LiquidGlassHost(enabled: glass, child: child!),
        ),
      ),
      home: ChatPage(runtime: service),
    ),
  );
  await tester.pumpAndSettle();
  return (service, routes);
}

// The header also has a session menu. Keep geometry and opacity assertions
// anchored to the composer popup, whose parent carries a stable product key.
Finder get _source => find.descendant(
  of: find.byKey(const ValueKey('chat-composer'), skipOffstage: false),
  matching: find.byType(CommonPopupBox, skipOffstage: false),
);
Finder get _editor => find.byType(TextField, skipOffstage: false);
Finder get _chatList => find.descendant(
  of: find.byType(PocketList, skipOffstage: false),
  matching: find.byType(ListView, skipOffstage: false),
);

double _sourceOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find.descendant(of: _source, matching: find.byType(Opacity)).first,
    )
    .opacity;

// Follow the original FlClash popup_test.dart layer assertions. A menu also has
// its own clip; the morph's outer clip contains the blurred/fading content.
Rect _openingPlatter(WidgetTester tester) {
  final clip = tester.layers.whereType<ClipPathLayer>().where((layer) {
    final opacity = layer.firstChild;
    return opacity is OpacityLayer && opacity.firstChild is ImageFilterLayer;
  }).single;
  return clip.clipPath!.getBounds();
}

Rect _returningContent(WidgetTester tester) {
  final content = tester.layers
      .whereType<ImageFilterLayer>()
      .where((layer) => layer.firstChild is TransformLayer)
      .last;
  final transform = content.firstChild! as TransformLayer;
  final popup = tester.getRect(find.byType(ComposerCommands));
  return MatrixUtils.transformRect(
    transform.transform!,
    Offset.zero & popup.size,
  ).shift(popup.topLeft);
}

bool _rowPressed(WidgetTester tester, String label) {
  final decoration = tester
      .widget<DecoratedBox>(
        find
            .ancestor(of: find.text(label), matching: find.byType(DecoratedBox))
            .first,
      )
      .decoration;
  return (decoration as ShapeDecoration).color != null;
}

OneSequenceGestureRecognizer _rowRecognizer(WidgetTester tester) {
  final detectors = tester.widgetList<RawGestureDetector>(
    find.descendant(
      of: find.byType(CommonPopupMenu),
      matching: find.byType(RawGestureDetector),
    ),
  );
  for (final detector in detectors) {
    for (final factory in detector.gestures.values) {
      final recognizer = factory.constructor();
      if (recognizer.debugDescription == 'menu row press') {
        factory.initializer(recognizer);
        return recognizer as OneSequenceGestureRecognizer;
      }
      recognizer.dispose();
    }
  }
  throw StateError('The actual command menu must register its row recognizer.');
}

void main() {
  for (final glass in [false, true]) {
    testWidgets(
      'chat plus paints intermediate opening and returning frames (glass=$glass)',
      (tester) async {
        final (runtime, routes) = await _chat(tester, glass: glass);
        final anchor = tester.getRect(_source);
        final press = await tester.startGesture(anchor.center);
        // The composer is scrollable, so FlClash waits for the press timeout
        // before taking the pointer away from scrolling.
        await tester.pump(kPressTimeout + const Duration(milliseconds: 1));
        await tester.pump();
        expect(find.byType(ComposerCommands), findsOneWidget);
        expect(routes.popups, hasLength(1));
        await tester.pump(const Duration(milliseconds: 100));
        final route = routes.popups.single;
        expect(route.animation!.status, AnimationStatus.forward);
        expect(route.animation!.value, inExclusiveRange(0, 1));
        final opening = _openingPlatter(tester);
        final menu = tester.getRect(find.byType(ComposerCommands));
        expect(opening.width, inExclusiveRange(anchor.width, menu.width));
        expect(opening.height, inExclusiveRange(anchor.height, menu.height));
        expect(_sourceOpacity(tester), 0);
        await press.up();
        await tester.pumpAndSettle();
        expect(route.animation!.status, AnimationStatus.completed);
        expect(find.text('文件  file'), findsOneWidget);
        expect(find.text('目标  goal'), findsOneWidget);
        expect(_sourceOpacity(tester), 0);

        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(find.byType(ComposerCommands), findsOneWidget);
        expect(route.animation!.status, AnimationStatus.reverse);
        final returning = _returningContent(tester);
        expect(returning.width, inExclusiveRange(0, menu.width));
        expect(returning.height, inExclusiveRange(0, menu.height));
        expect(returning.center.dy, greaterThan(menu.center.dy));
        expect(_sourceOpacity(tester), 0);
        await tester.pumpAndSettle();
        expect(find.byType(ComposerCommands), findsNothing);
        expect(_sourceOpacity(tester), 1);
        runtime.expectOnlyDiscovery();
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final useBack in [false, true]) {
    testWidgets(
      '${useBack ? 'system back' : 'outside tap'} dismisses without sending or moving the conversation',
      (tester) async {
        final (runtime, routes) = await _chat(tester);
        await tester.enterText(_editor, '保留这段未发送草稿');
        await tester.pumpAndSettle();
        final editor = tester.getRect(_editor);
        final viewport = tester.getRect(_chatList);
        final list = tester.widget<ListView>(_chatList);
        final scrollOffset = list.controller!.offset;
        await tester.tap(find.byTooltip('添加与指令'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.getRect(_editor), editor);
        expect(tester.getRect(_chatList), viewport);
        expect(list.controller!.offset, scrollOffset);
        await tester.pumpAndSettle();
        expect(tester.getRect(_editor), editor);
        expect(tester.getRect(_chatList), viewport);
        expect(list.controller!.offset, scrollOffset);
        if (useBack) {
          await tester.binding.handlePopRoute();
        } else {
          final menu = tester.getRect(find.byType(ComposerCommands));
          const outside = Offset(350, 150);
          expect(menu.contains(outside), isFalse);
          await tester.tapAt(outside);
        }
        await tester.pumpAndSettle();
        expect(routes.active, isEmpty);
        expect(find.byType(ChatPage), findsOneWidget);
        expect(find.byType(ComposerCommands), findsNothing);
        expect(tester.widget<TextField>(_editor).controller!.text, '保留这段未发送草稿');
        expect(tester.getRect(_editor), editor);
        expect(tester.getRect(_chatList), viewport);
        expect(list.controller!.offset, scrollOffset);
        runtime.expectOnlyDiscovery();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'rapid presses and a mid-opening dismissal never stack popup routes',
    (tester) async {
      final (runtime, routes) = await _chat(tester);
      final anchor = tester.getCenter(_source);
      await tester.tapAt(anchor);
      await tester.tapAt(anchor);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(routes.popups, hasLength(1));
      expect(find.byType(ComposerCommands), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(routes.popups.single.animation!.status, AnimationStatus.reverse);
      await tester.tapAt(anchor);
      await tester.pump();
      expect(routes.popups, hasLength(1));
      await tester.pumpAndSettle();
      expect(find.byType(ComposerCommands), findsNothing);
      await tester.tapAt(anchor);
      await tester.pumpAndSettle();
      expect(routes.popups, hasLength(2));
      expect(routes.maxActive, 1);
      expect(find.byType(ComposerCommands), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      runtime.expectOnlyDiscovery();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion opens and dismisses without elapsed animation time',
    (tester) async {
      final (runtime, routes) = await _chat(tester, reduceMotion: true);
      await tester.tap(find.byTooltip('添加与指令'));
      await tester.pump();
      await tester.pump();
      final route = routes.popups.single;
      expect(route.transitionDuration, Duration.zero);
      expect(route.animation!.status, AnimationStatus.completed);
      expect(find.text('文件  file'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump();
      expect(find.byType(ComposerCommands), findsNothing);
      expect(_sourceOpacity(tester), 1);
      runtime.expectOnlyDiscovery();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an accepted row press can be cancelled and the next drag still selects',
    (tester) async {
      final (runtime, _) = await _chat(tester);
      await tester.tap(find.byTooltip('添加与指令'));
      await tester.pumpAndSettle();
      final recognizer = _rowRecognizer(tester);
      addTearDown(recognizer.dispose);
      final file = tester.getCenter(find.text('文件  file'));
      final goal = tester.getCenter(find.text('目标  goal'));

      // Use the mounted menu's factory and real row callbacks. Give this
      // recognizer the arena explicitly so the test exercises cancellation
      // after acceptance, independently of Scrollable's competing drag.
      recognizer.addPointer(PointerDownEvent(pointer: 7001, position: file));
      tester.binding.gestureArena
        ..close(7001)
        ..sweep(7001);
      await tester.pump();
      expect(_rowPressed(tester, '文件  file'), isTrue);
      tester.binding.pointerRouter.route(
        PointerCancelEvent(pointer: 7001, position: file),
      );
      await tester.pump();
      expect(_rowPressed(tester, '文件  file'), isFalse);
      expect(find.byType(ComposerCommands), findsOneWidget);

      recognizer.addPointer(PointerDownEvent(pointer: 7002, position: file));
      tester.binding.gestureArena
        ..close(7002)
        ..sweep(7002);
      tester.binding.pointerRouter.route(
        PointerMoveEvent(pointer: 7002, position: goal),
      );
      await tester.pump();
      expect(_rowPressed(tester, '文件  file'), isFalse);
      expect(_rowPressed(tester, '目标  goal'), isTrue);
      tester.binding.pointerRouter.route(
        PointerUpEvent(pointer: 7002, position: goal),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ComposerCommands), findsNothing);
      expect(find.byType(ChatGoalPage), findsOneWidget);
      runtime.expectOnlyDiscovery();
      expect(tester.takeException(), isNull);
    },
  );

  for (final reduceMotion in [false, true]) {
    testWidgets(
      'a carried press stretches the menu only when motion is enabled (reduced=$reduceMotion)',
      (tester) async {
        final (runtime, _) = await _chat(
          tester,
          reduceMotion: reduceMotion,
          glass: true,
        );
        final press = await tester.startGesture(tester.getCenter(_source));
        await tester.pump(kPressTimeout + const Duration(milliseconds: 1));
        await tester.pumpAndSettle();
        final surface = tester.renderObject<RenderBox>(
          find.byType(PopupMenuCard),
        );
        final resting = ElasticPress.paintBoundsOf(surface);
        await press.moveTo(tester.getCenter(find.text('文件  file')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final pressed = ElasticPress.paintBoundsOf(surface);
        final menu = tester.getRect(find.byType(CommonPopupMenu));
        await press.moveTo(Offset(menu.left - 80, menu.center.dy));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final pulled = ElasticPress.paintBoundsOf(surface);
        if (reduceMotion) {
          expect(pressed, resting);
          expect(pulled, resting);
        } else {
          expect(pressed.width, greaterThan(resting.width + 4));
          expect(pulled.center.dx, lessThan(resting.center.dx - 4));
          expect(
            pulled.width / pulled.height,
            greaterThan(resting.width / resting.height),
          );
        }
        await press.up();
        await tester.pumpAndSettle();
        expect(ElasticPress.paintBoundsOf(surface), resting);
        expect(find.byType(ComposerCommands), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        runtime.expectOnlyDiscovery();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'large text and a visible keyboard keep the floating menu bounded and scrollable',
    (tester) async {
      final (runtime, _) = await _chat(tester, scale: 2);
      await tester.enterText(_editor, '第一行\n第二行\n第三行\n第四行\n第五行');
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      final editor = tester.getRect(_editor);
      final viewport = tester.getRect(_chatList);
      await tester.tap(find.byTooltip('添加与指令'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      final menu = tester.getRect(find.byType(ComposerCommands));
      expect(menu.left, greaterThanOrEqualTo(0));
      expect(menu.right, lessThanOrEqualTo(360));
      expect(menu.top, greaterThanOrEqualTo(16));
      expect(menu.bottom, lessThanOrEqualTo(480));
      expect(tester.getRect(_editor), editor);
      expect(tester.getRect(_chatList), viewport);
      expect(
        tester.getRect(find.byTooltip('发送', skipOffstage: false)).bottom,
        lessThanOrEqualTo(480),
      );
      final menuScroll = find.descendant(
        of: find.byType(ComposerCommands),
        matching: find.byType(Scrollable),
      );
      expect(menuScroll, findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('plugin-status  plugin-status'),
        150,
        scrollable: menuScroll,
      );
      await tester.pumpAndSettle();
      expect(
        find.text('plugin-status  plugin-status').hitTestable(),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_editor).controller!.text,
        contains('第五行'),
      );
      runtime.expectOnlyDiscovery();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a late catalog response after dismissal cannot reopen or submit',
    (tester) async {
      final runtime = _Runtime()..catalogResponse = Completer<List<Json>>();
      final (_, routes) = await _chat(tester, runtime: runtime);
      await tester.tap(find.byTooltip('添加与指令'));
      await tester.pumpAndSettle();
      expect(find.text('正在读取会话菜单…'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      runtime.catalogResponse!.complete(_catalog);
      await tester.pumpAndSettle();
      expect(find.byType(ComposerCommands), findsNothing);
      expect(routes.popups, hasLength(1));
      expect(routes.active, isEmpty);
      runtime.expectOnlyDiscovery();
      expect(tester.takeException(), isNull);
    },
  );
}
