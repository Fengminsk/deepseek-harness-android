// 输入区「+」的指令菜单已从 FlClash 的锚定弹层（`CommonPopupBox`）改成与远程
// 会话页一致的底部弹层（`showRemoteCommandsSheet` + `ComposerCommands`）：
// 语音/推理面板等按钮与「+」同在共享悬浮卡里，弹层无法再从卡片内部的按钮坐标
// 长出来。原文件里针对旧弹层的弹出/回缩几何与动画断言因此不再成立，这里按
// **行为意图**保留等价覆盖：打开与关闭、返回键/点击外部收起、关闭时草稿与
// 页面位置不变、没有提交、减少动态效果时立即打开/关闭、在途目录响应晚到也不
// 会重新打开或提交、放大字体与键盘下弹层仍完整可达、关闭后输入卡仍可编辑。

import 'dart:async';

import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/composer_commands.dart';
import 'package:dsh_android/main.dart';
import 'package:dsh_android/pocket_composer.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/settle_ui.dart';

/// 指令菜单的目录；含需要输入参数的指令，覆盖真实菜单的排布。
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
    'name': 'compact',
    'definitionId': '@deepseek-ai/dsh-command-compact',
    'description': 'Compact conversation history',
  },
];

class _Runtime extends RuntimeController {
  _Runtime() {
    phase = 'ready';
  }

  final calls = <({String method, Json params})>[];
  Completer<List<Json>>? catalogResponse;

  /// 有内容的会话：让弹层的打开/关闭发生在真实聊天布局上（可断言位置不变）。
  @override
  String newSession() {
    final id = super.newSession();
    timelines[id]!.addAll([
      for (var turn = 1; turn <= 6; turn++) ...[
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
                {'type': 'text', 'text': '回复 $turn：弹层关闭后可以继续编辑。'},
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
    if (method == 'session.ensure') return {'sessionId': params['sessionId']};
    if (method == 'api.call' &&
        params['namespace'] == 'commands' &&
        params['method'] == 'list') {
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
        params['namespace'] == 'session' &&
        params['method'] == 'modelCatalog') {
      return {'groups': <Json>[]};
    }
    if (method == 'api.call' &&
        params['namespace'] == 'pluginInventory' &&
        params['method'] == 'list') {
      return {'managementAvailable': false, 'entries': <Json>[]};
    }
    if (method == 'api.call' &&
        params['namespace'] == 'settings' &&
        params['method'] == 'describe') {
      return {'revision': 0, 'values': <String, dynamic>{}};
    }
    throw StateError('Unexpected runtime action: $method $params');
  }

  /// 关闭菜单不得提交任务、不得执行会话指令。
  void expectNoSubmission() {
    for (final call in calls) {
      expect(
        call.method == 'session.command' || call.method == 'session.send',
        isFalse,
        reason: '关闭菜单不应提交或执行任何内容：$call',
      );
    }
  }
}

Future<_Runtime> _chat(
  WidgetTester tester, {
  bool reduceMotion = false,
  double scale = 1,
  bool keyboard = false,
}) async {
  tester.view
    ..physicalSize = const Size(360, 800)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  final runtime = _Runtime();
  addTearDown(runtime.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduceMotion,
          textScaler: TextScaler.linear(scale),
          viewInsets: EdgeInsets.only(bottom: keyboard ? 320 : 0),
        ),
        child: LiquidGlassScope(
          enabled: false,
          child: LiquidGlassHost(enabled: false, child: child!),
        ),
      ),
      home: ChatPage(runtime: runtime),
    ),
  );
  await settleUi(tester);
  return runtime;
}

Finder get _plus => find.byTooltip('添加与指令');

Finder get _editor => find.byKey(PocketComposer.inputKey);

/// 输入草稿并等一帧：草稿出现后输入卡才展开、发送圆钮按可用性重建。
Future<void> _draft(WidgetTester tester, String text) async {
  await tester.enterText(_editor, text);
  await tester.pump();
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(_plus);
  await settleUi(tester);
}

void main() {
  testWidgets(
    'system back dismisses the command sheet, keeping the draft and position',
    (tester) async {
      final runtime = await _chat(tester);
      await _draft(tester, '保留这段未发送草稿');
      final editor = tester.getRect(_editor);
      final scroll = tester
          .widget<ChatTimeline>(find.byType(ChatTimeline))
          .controller
          .position
          .pixels;
      await _openMenu(tester);
      expect(find.byType(ComposerCommands), findsOneWidget);
      expect(find.byKey(const ValueKey('remote-commands-popup')), findsOneWidget);

      await tester.binding.handlePopRoute();
      await settleUi(tester);
      expect(find.byType(ComposerCommands), findsNothing);
      expect(tester.widget<TextField>(_editor).controller!.text, '保留这段未发送草稿');
      expect(tester.getRect(_editor), editor);
      expect(
        tester
            .widget<ChatTimeline>(find.byType(ChatTimeline))
            .controller
            .position
            .pixels,
        scroll,
      );
      runtime.expectNoSubmission();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'outside tap dismisses the command sheet without sending the draft',
    (tester) async {
      final runtime = await _chat(tester);
      await _draft(tester, '只编辑不发送');
      await _openMenu(tester);
      expect(find.byType(ComposerCommands), findsOneWidget);

      await tester.tapAt(const Offset(350, 80));
      await settleUi(tester);
      expect(find.byType(ComposerCommands), findsNothing);
      expect(tester.widget<TextField>(_editor).controller!.text, '只编辑不发送');
      runtime.expectNoSubmission();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'opening the command sheet does not submit the visible draft immediately',
    (tester) async {
      final runtime = await _chat(tester);
      await _draft(tester, '/compact');
      await _openMenu(tester);
      expect(find.byType(ComposerCommands), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settleUi(tester);
      expect(tester.widget<TextField>(_editor).controller!.text, '/compact');
      runtime.expectNoSubmission();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion opens and dismisses the sheet in one frame', (
    tester,
  ) async {
    final runtime = await _chat(tester, reduceMotion: true);
    await tester.tap(_plus);
    await tester.pump();
    expect(find.byType(ComposerCommands), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(ComposerCommands), findsNothing);
    runtime.expectNoSubmission();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a late catalog response after dismissal cannot reopen or submit',
    (tester) async {
      final runtime = await _chat(tester);
      runtime.catalogResponse = Completer<List<Json>>();
      await tester.tap(_plus);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(ComposerCommands), findsOneWidget);
      expect(find.text('正在读取会话菜单…'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await settleUi(tester);
      expect(find.byType(ComposerCommands), findsNothing);

      runtime.catalogResponse!.complete(_catalog);
      runtime.catalogResponse = null;
      await settleUi(tester);
      expect(find.byType(ComposerCommands), findsNothing);
      runtime.expectNoSubmission();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large text and a visible keyboard keep the sheet bounded and the composer reachable',
    (tester) async {
      final runtime = await _chat(tester, scale: 1.5, keyboard: true);
      await _draft(tester, '一\n二\n三\n四\n五');
      await _openMenu(tester);
      final sheet = tester.getRect(find.byType(ComposerCommands));
      expect(sheet.top, greaterThanOrEqualTo(0));
      expect(sheet.bottom, lessThanOrEqualTo(800));
      await tester.ensureVisible(find.text('压缩  compact'));
      expect(find.text('压缩  compact'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await settleUi(tester);
      expect(find.byType(ComposerCommands), findsNothing);
      expect(_plus.hitTestable(), findsOneWidget);
      expect(_editor.hitTestable(), findsOneWidget);
      runtime.expectNoSubmission();
      expect(tester.takeException(), isNull);
    },
  );
}
