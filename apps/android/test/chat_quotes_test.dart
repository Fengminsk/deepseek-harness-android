import 'package:dsh_android/chat_message_actions.dart';
import 'package:dsh_android/chat_quotes.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _host(Widget child) => MaterialApp(
  theme: pocketTheme(Brightness.dark),
  home: Scaffold(body: child),
);

void main() {
  test('quoted markdown prefixes every line and drops trailing blanks', () {
    expect(quotedMessageMarkdown('第一行\n第二行'), '> 第一行\n> 第二行');
    expect(quotedMessageMarkdown('段落\n\n后续\n'), '> 段落\n>\n> 后续');
    expect(quotedMessageMarkdown('   '), '');
    expect(quotedMessageMarkdown(''), '');
  });

  test('quoting into an empty draft leaves the caret on the next line', () {
    final next = insertMessageQuote(TextEditingValue.empty, '你好');
    expect(next.text, '> 你好\n');
    expect(next.selection, const TextSelection.collapsed(offset: '> 你好\n'.length));
  });

  test('quoting inside existing text keeps both sides and places the caret', () {
    const draft = TextEditingValue(text: '前缀后缀', selection: TextSelection.collapsed(offset: 2));
    final next = insertMessageQuote(draft, '引用');
    expect(next.text, '前缀\n> 引用\n后缀');
    expect(next.selection, const TextSelection.collapsed(offset: '前缀\n> 引用\n'.length));
  });

  testWidgets('the quote action appears only when a composer can receive it', (tester) async {
    final quoted = <String>[];
    await tester.pumpWidget(
      _host(
        ChatMessageActions(
          text: '回答正文',
          onQuote: quoted.add,
          child: const Text('回答正文'),
        ),
      ),
    );
    await tester.longPress(find.byType(ChatMessageActions));
    await tester.pumpAndSettle();
    expect(find.text('引用'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    await tester.tap(find.text('引用'));
    await tester.pumpAndSettle();
    expect(quoted, ['回答正文']);
    expect(find.text('已引用'), findsOneWidget);
  });

  testWidgets('without a composer the menu keeps copy and selection only', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      _host(const ChatMessageActions(text: '回答正文', child: Text('回答正文'))),
    );
    await tester.longPress(find.byType(ChatMessageActions));
    await tester.pumpAndSettle();
    expect(find.text('引用'), findsNothing);
    expect(find.text('选择文本'), findsOneWidget);
  });
}
