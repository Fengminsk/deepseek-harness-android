import 'package:dsh_android/automation_recurrence.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget host(Widget child) =>
    MaterialApp(theme: pocketTheme(Brightness.light), home: child);

Future<void> openPage<T>(
  WidgetTester tester,
  Widget child,
  ValueChanged<T?> onResult,
) async {
  await tester.pumpWidget(host(const SizedBox()));
  tester
      .state<NavigatorState>(find.byType(Navigator))
      .push(PocketRoute<T>(builder: (_) => child))
      .then(onResult);
  await tester.pumpAndSettle();
}

Future<void> tapRow(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  test('repeat and interval labels preserve stored units', () {
    expect(automationRepeatLabel('weekly', '1,2,3,4,5'), '周一至周五');
    expect(automationRepeatLabel('weekly', '5,4,3,2,1'), '周一至周五');
    expect(automationRepeatLabel('weekly', '1,3'), '每周');
    expect(automationIntervalLabel(7200), '每 2 小时');
    expect(automationIntervalLabel(3900), '每 65 分钟');
    expect(automationIntervalLabel(3901), '每 3901 秒');
    expect(automationIntervalSummary('bad'), '检查间隔数值');
    expect(automationIntervalSummary('9007199254740992'), '检查间隔数值');
  });

  testWidgets('workdays selects exact weekdays without a host write', (
    tester,
  ) async {
    AutomationRepeatSelection? selection;
    await openPage<AutomationRepeatSelection>(
      tester,
      const AutomationRepeatPage(kind: 'every', weekdays: '1'),
      (value) => selection = value,
    );
    await tapRow(
      tester,
      find.byKey(const ValueKey('automation-repeat-workdays')),
    );
    expect(selection?.kind, 'weekly');
    expect(selection?.weekdays, '1,2,3,4,5');
  });

  testWidgets('switching from workdays to weekly opens a distinct rule', (
    tester,
  ) async {
    AutomationRepeatSelection? selection;
    await openPage<AutomationRepeatSelection>(
      tester,
      const AutomationRepeatPage(kind: 'weekly', weekdays: '1,2,3,4,5'),
      (value) => selection = value,
    );
    await tapRow(
      tester,
      find.byKey(const ValueKey('automation-repeat-weekly')),
    );
    expect(selection?.kind, 'weekly');
    expect(selection?.weekdays, '1');
  });

  testWidgets('interval editor converts units and rejects unsafe values', (
    tester,
  ) async {
    int? result;
    await openPage<int>(
      tester,
      const AutomationIntervalPage(seconds: '3600'),
      (value) => result = value,
    );
    final amount = find.byKey(const ValueKey('automation-interval-amount'));
    await tester.enterText(amount, '0');
    await tester.pumpAndSettle();
    expect(find.text('间隔至少 60 秒，且须为安全整数。'), findsOneWidget);
    expect(
      tester
          .widget<GlassButton>(
            find.byWidgetPredicate(
              (widget) => widget is GlassButton && widget.label == '完成间隔编辑',
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(amount, '3');
    await tester.pumpAndSettle();
    expect(find.text('每 3 小时'), findsOneWidget);
    await tapRow(
      tester,
      find.byKey(const ValueKey('automation-interval-unit-60')),
    );
    expect(find.text('每 3 分钟'), findsOneWidget);
    await tapRow(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is GlassButton && widget.label == '完成间隔编辑',
      ),
    );
    expect(result, 180);
  });

  testWidgets('invalid stored interval can be repaired without a build crash', (
    tester,
  ) async {
    int? result;
    await openPage<int>(
      tester,
      const AutomationIntervalPage(seconds: 'invalid'),
      (value) => result = value,
    );
    expect(find.text('间隔至少 60 秒，且须为安全整数。'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('automation-interval-amount')),
      '120',
    );
    await tester.pumpAndSettle();
    await tapRow(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is GlassButton && widget.label == '完成间隔编辑',
      ),
    );
    expect(result, 120);
  });

  testWidgets('weekday editor never saves an empty selection', (tester) async {
    String? result;
    await openPage<String>(
      tester,
      const AutomationWeekdaysPage(weekdays: '1'),
      (value) => result = value,
    );
    await tapRow(tester, find.byKey(const ValueKey('automation-weekday-1')));
    expect(find.text('至少选择一个星期。'), findsOneWidget);
    expect(
      tester
          .widget<GlassButton>(
            find.byWidgetPredicate(
              (widget) => widget is GlassButton && widget.label == '完成星期编辑',
            ),
          )
          .onPressed,
      isNull,
    );
    await tapRow(tester, find.byKey(const ValueKey('automation-weekday-7')));
    await tapRow(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is GlassButton && widget.label == '完成星期编辑',
      ),
    );
    expect(result, '7');
  });
}
