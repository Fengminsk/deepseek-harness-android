import 'dart:convert';

import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/chat_progress.dart';
import 'package:dsh_android/chat_tool_groups.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/tool_activity_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_projection_test.dart' as chat;
import 'tool_activity_fixture.dart' as tool;

void main() {
  testWidgets('group header uses the actual call count and fits large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final projection = ChatProjection()
      ..reconcile([
        tool.callEvent(0, id: 'a', name: 'web_search'),
        tool.callEvent(1, id: 'b', name: 'web_search'),
      ]);
    final group = groupChatTools(projection.entries).single.group!;
    var toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: Scaffold(
          body: ChatToolGroupHeader(
            group: group,
            expanded: false,
            onToggle: () => toggles++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<ChatRollingCount>(find.byType(ChatRollingCount)).value,
      2,
    );
    expect(find.textContaining('网站'), findsNothing);
    expect(find.textContaining('项工具调用'), findsNothing);
    await tester.tap(find.byType(ChatToolGroupHeader));
    await tester.pumpAndSettle();
    expect(toggles, 1);
    expect(tester.takeException(), isNull);
  });
  test(
    'different tool families remain separate and shell aliases can group',
    () {
      final projection = ChatProjection()
        ..reconcile([
          tool.callEvent(0, id: 'shell-a'),
          tool.callEvent(1, id: 'shell-b', name: 'bash'),
          tool.callEvent(2, id: 'read', name: 'read'),
          tool.callEvent(3, id: 'search-a', name: 'web_search'),
          tool.callEvent(4, id: 'search-b', name: 'web_search'),
          tool.callEvent(5, id: 'fetch', name: 'web_fetch'),
        ]);
      final display = groupChatTools(projection.entries);
      expect(display.length, 4);
      expect(display[0].group!.title, '正在调用 2 条命令');
      expect(display[1].entry!.tool!.callId, 'read');
      expect(display[2].group!.title, '正在调用 2 次联网搜索');
      expect(display[3].entry!.tool!.callId, 'fetch');
    },
  );

  test(
    'group exposes nonzero process exit even when transport returned normally',
    () {
      final projection = ChatProjection()
        ..reconcile([
          tool.callEvent(0, id: 'a'),
          tool.resultEvent(
            1,
            id: 'a',
            text: jsonEncode({'stdout': '', 'exitCode': 7}),
          ),
          tool.callEvent(2, id: 'b'),
          tool.resultEvent(
            3,
            id: 'b',
            text: jsonEncode({'stdout': '', 'exitCode': 0}),
          ),
        ]);
      final group = groupChatTools(projection.entries).single.group!;
      expect(group.title, '2 条命令 · 1 项需查看');
      expect(group.needsAttention, isTrue);
      expect(group.pendingCount, 0);
    },
  );
  testWidgets(
    'mixed group shows pending and failed counts without calling every command running',
    (tester) async {
      final projection = ChatProjection()
        ..reconcile([
          tool.callEvent(0, id: 'completed'),
          tool.resultEvent(
            1,
            id: 'completed',
            text: jsonEncode({'stdout': 'ok', 'exitCode': 0}),
          ),
          tool.callEvent(2, id: 'pending'),
          tool.callEvent(3, id: 'failed'),
          tool.resultEvent(
            4,
            id: 'failed',
            text: jsonEncode({'stdout': '', 'exitCode': 7}),
          ),
        ]);
      final group = groupChatTools(projection.entries).single.group!;
      expect(group.title, '3 条命令 · 1 项需查看 · 1 项等待结果');
      expect(group.status, '1 项等待结果 · 2 项已返回');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatToolGroupHeader(
              group: group,
              expanded: false,
              onToggle: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('正在调用 '), findsNothing);
      expect(find.text(' 条命令 · 1 项需查看 · 1 项等待结果'), findsOneWidget);
      expect(
        tester.widget<ChatRollingCount>(find.byType(ChatRollingCount)).value,
        3,
      );
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'consecutive original calls group within one turn, across steps only',
    () {
      final projection = ChatProjection()
        ..reconcile([
          tool.callEvent(0, id: 'a'),
          tool.resultEvent(1, id: 'a'),
          tool.callEvent(2, id: 'b', step: 2),
          tool.resultEvent(3, id: 'b', step: 2),
          tool.callEvent(4, id: 'c', turn: 2),
        ]);
      final display = groupChatTools(projection.entries);
      expect(display.length, 2);
      expect(display.first.group!.entries.map((row) => row.tool!.callId), [
        'a',
        'b',
      ]);
      expect(display.last.entry!.tool!.callId, 'c');
      expect(display.first.group!.status, '2 项已返回');
    },
  );

  test('visible messages and orphan results are grouping boundaries', () {
    final projection = ChatProjection()
      ..reconcile([
        tool.callEvent(0, id: 'a'),
        chat.assistant(1, 'checking'),
        tool.callEvent(2, id: 'b'),
        tool.resultEvent(3, id: 'orphan'),
        tool.callEvent(4, id: 'c'),
      ]);
    final display = groupChatTools(projection.entries);
    expect(display.every((item) => item.group == null), isTrue);
    expect(display.length, 5);
  });

  test('unknown call coordinates are never inferred from ids', () {
    final call = tool.callEvent(0);
    (call['data'] as Json).remove('turn');
    // Exercise the display boundary directly: the Session decoder requires
    // coordinates on normal tool/call records and rejects this malformed log.
    final unknown = ChatEntry(
      key: 'unknown',
      seq: 0,
      kind: ChatEntryKind.tool,
      event: call,
      tool: ToolActivity(
        identity: '[1,1,"call-0"]',
        callId: 'call-0',
        anchorSeq: 0,
        name: 'android_shell',
        phase: ToolActivityPhase.unknown,
        events: [call],
        children: const [],
        hasCall: true,
      ),
    );
    final projection = ChatProjection()
      ..reconcile([tool.callEvent(1, id: 'next')]);
    expect(
      groupChatTools([unknown, ...projection.entries])
          .every((item) => item.group == null),
      isTrue,
    );
  });

  test(
    'group status does not describe pending or interrupted calls as completed',
    () {
      final projection = ChatProjection()
        ..reconcile([tool.callEvent(0, id: 'a'), tool.callEvent(1, id: 'b')]);
      expect(
        groupChatTools(projection.entries).single.group!.status,
        '2 项等待结果',
      );
    },
  );
}
