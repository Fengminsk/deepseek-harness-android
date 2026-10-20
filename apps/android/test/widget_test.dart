import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:dsh_android/main.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/ui.dart';

class FailingRuntime extends RuntimeController {
  FailingRuntime() {
    phase = 'ready';
    info = {'workspace': '/private/workspace'};
  }
  @override
  Future<void> send(String id, String text) async => throw StateError('连接中断');

  @override
  String newSession() => 'test-session';

  void reportSessionError(String id, String message) {
    sessionErrors[id] = message;
    notifyListeners();
  }
}

void main() {
  testWidgets('an accepted turn failure is visible only in its own session', (
    tester,
  ) async {
    final runtime = FailingRuntime();
    await tester.pumpWidget(MaterialApp(home: ChatPage(runtime: runtime)));
    await tester.enterText(find.byType(TextField), '继续编辑的草稿');
    runtime.reportSessionError('other-session', '另一会话的失败');
    await tester.pumpAndSettle();
    expect(find.text('另一会话的失败'), findsNothing);
    runtime.reportSessionError('test-session', '模型登录凭据不可用');
    await tester.pumpAndSettle();
    expect(find.text('本轮任务未完成'), findsOneWidget);
    expect(find.text('模型登录凭据不可用'), findsOneWidget);
    expect(find.text('模型与凭据'), findsOneWidget);
    expect(find.text('继续编辑的草稿'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    runtime.dispose();
  });

  testWidgets('a failed submission retains the user draft', (tester) async {
    final runtime = FailingRuntime();
    await tester.pumpWidget(MaterialApp(home: ChatPage(runtime: runtime)));
    await tester.enterText(find.byType(TextField), '读取我的授权文件');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(find.text('读取我的授权文件'), findsOneWidget);
    expect(find.textContaining('连接中断'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    runtime.dispose();
  });
  testWidgets('durable user events render their saved text', (tester) async {
    final projection = ChatProjection()
      ..reconcile([
        {
          'seq': 0,
          'time': 0,
          'type': 'user/message',
          'surfaceOp': 'append',
          'data': {
            'id': 'saved-user',
            'role': 'user',
            'source': {'kind': 'user'},
            'content': [
              {'type': 'text', 'text': '保存的消息'},
            ],
          },
        },
      ]);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: PocketScaffold(
          title: const Text('会话'),
          body: ChatTimeline(
            sessionId: 'saved-session',
            projection: projection,
            controller: scroll,
          ),
        ),
      ),
    );
    expect(find.text('保存的消息'), findsOneWidget);
  });
}
