import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:dsh_android/main.dart';
import 'package:dsh_android/runtime.dart';

class FailingRuntime extends RuntimeController {
  FailingRuntime() {
    phase = 'ready';
    info = {'workspace': '/private/workspace'};
  }
  @override
  Future<void> send(String id, String text) async => throw StateError('连接中断');
}

void main() {
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
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EventCard(
            event: {
              'type': 'user/message',
              'data': {
                'content': [
                  {'type': 'text', 'text': '保存的消息'},
                ],
              },
            },
          ),
        ),
      ),
    );
    expect(find.text('保存的消息'), findsOneWidget);
  });
}
