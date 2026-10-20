import 'dart:async';

import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/subagents.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'subagents_data_test.dart' as fixture;

class _Runtime extends fixture.SubagentsRuntime {
  bool failSend = false;
  String mode = 'continuable';
  Json catalog(String parent) => {
    'parentSessionId': parent,
    'parentAvailable': true,
    'entries': [
      if (parent == 'parent') ...[
        {
          'id': 'child',
          'createdAt': 1,
          'mode': mode,
          'label': '文件分析员',
          'address': {...fixture.address.json, 'mode': mode},
          'attached': false,
          'running': false,
        },
        {
          'id': 'external',
          'createdAt': 2,
          'mode': 'external',
          'label': '外部任务条目',
          'address': null,
          'attached': false,
          'running': false,
        },
      ],
    ],
    'nextOffset': null,
  };

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method, params));
    switch (method) {
      case 'subagents.catalog':
        return catalog(params['parentSessionId'] as String);
      case 'subagents.inspect':
        return fixture.inspection(
          mode: mode,
          canPrompt: mode == 'continuable',
          reason: mode == 'one-shot' ? 'one-shot' : null,
          submission: params['requestId'] == null
              ? null
              : {'requestId': params['requestId'], 'state': 'not-observed'},
        );
      case 'subagents.send':
        if (failSend) throw TimeoutException('lost acknowledgement');
        return {'messageId': 'accepted'};
      default:
        throw StateError('Unexpected $method');
    }
  }
}

Future<void> open(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(480, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      builder: (_, child) => MediaQuery(
        data: const MediaQueryData(
          size: Size(480, 1000),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: page,
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

Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('refresh preserves more than one hundred loaded child rows', (
    tester,
  ) async {
    final runtime = fixture.SubagentsRuntime();
    addTearDown(runtime.dispose);
    runtime.handle = (method, params) async {
      expect(method, 'subagents.catalog');
      final offset = params['offset'] as int;
      final end = (offset + (params['limit'] as int)).clamp(0, 125);
      return {
        'parentSessionId': 'parent',
        'parentAvailable': true,
        'entries': [
          for (var i = offset; i < end; i++)
            {
              'id': 'child-$i',
              'createdAt': i,
              'mode': 'one-shot',
              'label': '任务 $i',
              'address': {
                ...fixture.address.json,
                'childSessionId': 'child-$i',
                'mode': 'one-shot',
              },
              'attached': false,
              'running': false,
            },
        ],
        'nextOffset': end < 125 ? end : null,
      };
    };
    await open(
      tester,
      SubagentsPage(runtime: runtime, parentSessionId: 'parent'),
    );
    for (var i = 0; i < 3; i++) {
      await tester.scrollUntilVisible(
        find.text('加载更多子 Agent'),
        700,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 100,
      );
      await tap(tester, find.text('加载更多子 Agent'));
    }
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('subagent-child-119')),
      700,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 100,
    );
    expect(find.byKey(const ValueKey('subagent-child-119')), findsOneWidget);
    final before = runtime.calls.length;
    await tap(tester, find.byTooltip('刷新子 Agent 列表'));
    expect(
      runtime.calls.skip(before).take(2).map((call) => call.$2['offset']),
      [0, 100],
    );
    expect(runtime.calls.skip(before).take(2).map((call) => call.$2['limit']), [
      100,
      20,
    ]);
    expect(find.byKey(const ValueKey('subagent-child-119')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets(
    'long transcript starts at latest and requested older window stays readable',
    (tester) async {
      final runtime = fixture.SubagentsRuntime();
      addTearDown(runtime.dispose);
      runtime.currentInspection = fixture.inspection(
        cursor: 60,
        records: [for (var i = 31; i <= 60; i++) fixture.record(i, '历史消息 $i')],
        hasMore: true,
      );
      runtime.older = {
        'records': [for (var i = 1; i <= 30; i++) fixture.record(i, '历史消息 $i')],
        'hasMore': false,
      };
      await open(
        tester,
        SubagentConversationPage(runtime: runtime, address: fixture.address),
      );
      final timeline = tester.widget<ChatTimeline>(find.byType(ChatTimeline));
      expect(timeline.controller.position.extentAfter, lessThan(1));
      expect(find.text('历史消息 60'), findsOneWidget);
      await tap(tester, find.byKey(const Key('subagent-load-older')));
      expect(timeline.controller.offset, 0);
      expect(find.text('历史消息 1'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(timeline.controller.offset, 0);
      expect(find.text('历史消息 1'), findsOneWidget);
      expect(
        runtime.calls.where((call) => call.$1 == 'subagents.page'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'catalog opens addressed shared transcript and lists nested children without activation',
    (tester) async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      await open(
        tester,
        SubagentsPage(
          runtime: runtime,
          parentSessionId: 'parent',
          parentTitle: '原始任务',
        ),
      );
      expect(find.text('文件分析员'), findsOneWidget);
      expect(find.text('外部任务条目'), findsOneWidget);
      await tap(tester, find.text('文件分析员'));
      expect(find.byType(ChatTimeline), findsOneWidget);
      expect(find.text('saved input'), findsOneWidget);
      expect(runtime.calls.last.$1, 'subagents.inspect');
      expect(runtime.calls.last.$2['address'], fixture.address.json);
      await tap(tester, find.byTooltip('父子关系与任务记录'));
      expect(find.text('父会话：parent'), findsOneWidget);
      expect(find.text('子会话：child'), findsOneWidget);
      expect(find.text('queued input'), findsOneWidget);
      await tap(tester, find.text('查看其下级子 Agent'));
      expect(find.text('此会话尚无子 Agent'), findsOneWidget);
      expect(runtime.calls.last.$2['parentSessionId'], 'child');
      expect(
        runtime.calls.every(
          (call) =>
              ['subagents.catalog', 'subagents.inspect'].contains(call.$1),
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'one-shot page stays read-only and keeps original transcript accessible',
    (tester) async {
      final runtime = _Runtime()..mode = 'one-shot';
      addTearDown(runtime.dispose);
      await open(
        tester,
        SubagentConversationPage(
          runtime: runtime,
          address: const SubagentAddress(
            parentSessionId: 'parent',
            childSessionId: 'child',
            mode: 'one-shot',
          ),
        ),
      );
      expect(find.text('saved input'), findsOneWidget);
      expect(find.textContaining('一次性任务不支持后续消息'), findsOneWidget);
      expect(find.byKey(const Key('subagent-draft')), findsNothing);
      expect(find.byKey(const Key('subagent-send')), findsNothing);
      expect(find.byKey(const Key('subagent-stop')), findsNothing);
      await close(tester);
      expect(
        runtime.calls.every((call) => call.$1 == 'subagents.inspect'),
        isTrue,
      );
    },
  );

  testWidgets(
    'uncertain send retains editable draft and only refreshes its original request',
    (tester) async {
      final runtime = _Runtime()..failSend = true;
      addTearDown(runtime.dispose);
      await open(
        tester,
        SubagentConversationPage(runtime: runtime, address: fixture.address),
      );
      await tester.enterText(
        find.byKey(const Key('subagent-draft')),
        '保留子任务消息',
      );
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const ValueKey('subagent-delivery-steer')));
      await tap(tester, find.byKey(const Key('subagent-send')));
      expect(find.text('保留子任务消息'), findsOneWidget);
      expect(find.textContaining('发送结果未确认'), findsOneWidget);
      final send = runtime.calls
          .singleWhere((call) => call.$1 == 'subagents.send')
          .$2;
      expect(send['delivery'], 'steer');
      expect(send['address'], fixture.address.json);
      await tap(tester, find.byKey(const Key('subagent-check-submission')));
      expect(runtime.calls.last.$2['requestId'], send['requestId']);
      expect(
        runtime.calls.where((call) => call.$1 == 'subagents.send'),
        hasLength(1),
      );
      final button = tester.widget<GlassButton>(
        find.byKey(const Key('subagent-send')),
      );
      expect(button.onPressed, isNull);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets('a stalled send becomes unconfirmed and is never replayed', (
    tester,
  ) async {
    final runtime = fixture.SubagentsRuntime();
    addTearDown(runtime.dispose);
    final receipt = Completer<Json>();
    runtime.handle = (method, params) async {
      if (method == 'subagents.send') return receipt.future;
      return fixture.inspection(
        submission: params['requestId'] == null
            ? null
            : {'requestId': params['requestId'], 'state': 'not-observed'},
      );
    };
    await open(
      tester,
      SubagentConversationPage(runtime: runtime, address: fixture.address),
    );
    await tester.enterText(find.byKey(const Key('subagent-draft')), '超时后也保留');
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const Key('subagent-send')));
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.textContaining('发送结果未确认'), findsOneWidget);
    expect(find.text('超时后也保留'), findsOneWidget);
    expect(
      tester
          .widget<GlassButton>(find.byKey(const Key('subagent-send')))
          .onPressed,
      isNull,
    );
    receipt.complete({'messageId': 'late-admission'});
    await tester.pumpAndSettle();
    expect(find.text('超时后也保留'), findsOneWidget);
    expect(
      runtime.calls.where((call) => call.$1 == 'subagents.send'),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('leaving an unsubmitted child draft offers to keep editing', (
    tester,
  ) async {
    final runtime = _Runtime();
    addTearDown(runtime.dispose);
    await open(
      tester,
      SubagentConversationPage(runtime: runtime, address: fixture.address),
    );
    await tester.enterText(find.byKey(const Key('subagent-draft')), '尚未提交');
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('保留当前编辑？'), findsOneWidget);
    await tap(tester, find.text('继续编辑'));
    expect(find.text('尚未提交'), findsOneWidget);
    expect(runtime.calls.where((call) => call.$1 == 'subagents.send'), isEmpty);
    await close(tester);
  });

  testWidgets(
    'runtime failure disables control without discarding draft or history',
    (tester) async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      await open(
        tester,
        SubagentConversationPage(runtime: runtime, address: fixture.address),
      );
      await tester.enterText(find.byKey(const Key('subagent-draft')), '留待连接恢复');
      runtime.phase = 'failed';
      runtime.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('状态待确认'), findsOneWidget);
      expect(find.text('saved input'), findsOneWidget);
      expect(find.text('留待连接恢复'), findsOneWidget);
      expect(
        tester
            .widget<GlassButton>(find.byKey(const Key('subagent-send')))
            .onPressed,
        isNull,
      );
      await close(tester);
    },
  );
}
