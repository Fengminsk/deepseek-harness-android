import 'package:dsh_android/account_presentation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('authorization palette keeps opaque and repeated Host parameters', () {
    final light = Uri.parse(
      accountAuthorizeUrl(
        'https://platform.deepseek.com/authorize?opaque=a%2Bb&scope=a&scope=b&theme=dark',
        Brightness.light,
      ),
    );
    expect(light.queryParametersAll['scope'], ['a', 'b']);
    expect(light.queryParameters['opaque'], 'a+b');
    expect(light.queryParameters['theme'], 'light');
    expect(
      Uri.parse(accountAuthorizeUrl(light.toString(), Brightness.dark))
          .queryParameters['theme'],
      'dark',
    );
  });

  test(
    'balance presentation matches Platform decimal rules without doubles',
    () {
      expect(formatAccountBalance('0', 'CNY'), '¥0.00');
      expect(formatAccountBalance('0.0001', 'CNY'), '<¥0.01');
      expect(
        formatAccountBalance('12345678901234567890.0199', 'USD'),
        '\$12,345,678,901,234,567,890.01',
      );
      expect(formatAccountBalance('-0.0001', 'USD'), '-\$0.01');
      expect(formatAccountBalance('-0.015', 'USD'), '-\$0.02');
      expect(formatAccountBalance('-999.999', 'CNY'), '-¥1,000.00');
      expect(formatAccountBalance('not-a-balance', 'CNY'), 'not-a-balance');
      expect(accountBalanceIsPositive('0.0001'), isTrue);
      expect(accountBalanceIsPositive('0.00'), isFalse);
      expect(accountBalanceIsPositive('-1'), isFalse);
    },
  );
}
