import 'package:dsh_android/configuration_value_row.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Future<void> mountRow(
  WidgetTester tester, {
  required String title,
  required String summary,
  required VoidCallback onTap,
  double width = 390,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: PocketSection(
          divided: true,
          children: [
            ConfigurationValueRow(title: title, summary: summary, onTap: onTap),
            const ConfigurationValueRow(
              title: '已保护的设置',
              summary: '包含凭据 · 已保护',
              protected: true,
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('ordinary setting keeps its value on the same line', (
    tester,
  ) async {
    var taps = 0;
    await mountRow(
      tester,
      title: '模型 ID',
      summary: 'Flash',
      onTap: () => taps++,
    );
    final label = tester.getRect(find.text('模型 ID'));
    final value = tester.getRect(find.text('Flash'));
    expect((label.center.dy - value.center.dy).abs(), lessThan(1));
    expect(value.left, greaterThan(label.right));
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    await tester.tapAt(
      tester.getCenter(find.byIcon(Icons.chevron_right_rounded)),
    );
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320dp and large text reveal complete long labels and values', (
    tester,
  ) async {
    const title = '默认会话模型的提供方及其启用状态说明';
    const summary =
        'provider/account/very-long-model-identifier-with-revision-2026-10-25';
    await mountRow(
      tester,
      title: title,
      summary: summary,
      onTap: () {},
      width: 320,
      textScale: 1.7,
    );
    final label = tester.getRect(find.text(title));
    final value = tester.getRect(find.text(summary));
    expect(value.top, greaterThanOrEqualTo(label.bottom));
    for (final content in [title, summary]) {
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text(content),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
      final rect = tester.getRect(find.text(content));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
    }
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
