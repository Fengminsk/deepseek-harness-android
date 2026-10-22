import 'package:dsh_android/models_label.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('1017 is limited to the two official exact Flash catalog entries', () {
    for (final provider in ['deepseek-account', 'deepseek-official']) {
      expect(
        showsDeepSeek1017Badge(
          providerId: provider,
          modelId: 'deepseek-flash',
          modelName: 'DeepSeek-V4.1-Flash',
        ),
        isTrue,
      );
    }
    for (final input in [
      ('custom-deepseek', 'deepseek-flash', 'DeepSeek-V4.1-Flash'),
      ('deepseek-official', 'deepseek-flash-copy', 'DeepSeek-V4.1-Flash'),
      ('deepseek-account', 'deepseek-flash', 'My Flash'),
      ('deepseek-account', 'deepseek-flash', 'DeepSeek-V4.1-Flash-1017'),
      ('deepseek-official', 'deepseek-flash', 'DeepSeek-V4.1-Flash-1024'),
    ]) {
      expect(
        showsDeepSeek1017Badge(
          providerId: input.$1,
          modelId: input.$2,
          modelName: input.$3,
        ),
        isFalse,
        reason: '$input must preserve the catalog label',
      );
    }
    expect(
      showsDeepSeek1017Badge(
        providerId: 'deepseek-account',
        modelId: 'deepseek-flash',
        modelName: 'DeepSeek-V4.1-Flash',
        enabled: false,
      ),
      isFalse,
    );
  });

  testWidgets('inline badge is visual and can be disabled without renaming', (
    tester,
  ) async {
    Widget page(bool enabled) => MaterialApp(
      home: Scaffold(
        body: ModelReleaseLabel(
          providerId: 'deepseek-official',
          modelId: 'deepseek-flash',
          modelName: 'DeepSeek-V4.1-Flash',
          suffix: ' · High',
          badgeEnabled: enabled,
        ),
      ),
    );
    await tester.pumpWidget(page(true));
    expect(find.text('1017'), findsOneWidget);
    expect(find.textContaining('DeepSeek-V4.1-Flash'), findsOneWidget);
    await tester.pumpWidget(page(false));
    expect(find.text('1017'), findsNothing);
    expect(find.text('DeepSeek-V4.1-Flash · High'), findsOneWidget);
  });
}
