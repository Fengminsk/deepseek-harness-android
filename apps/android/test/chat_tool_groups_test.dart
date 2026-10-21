import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/chat_tool_groups.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/tool_activity_data.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_projection_test.dart' as chat;
import 'tool_activity_fixture.dart' as tool;

void main() {
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
