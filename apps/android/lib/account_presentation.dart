import 'package:material_ui/material_ui.dart';

/// Match the original account page's Platform link without discarding the
/// attempt's opaque query parameters. The Host still owns URL validation.
String accountAuthorizeUrl(String raw, Brightness brightness) {
  final uri = Uri.parse(raw);
  final parameters = Map<String, List<String>>.from(uri.queryParametersAll);
  parameters['theme'] = [brightness == Brightness.dark ? 'dark' : 'light'];
  return uri.replace(queryParameters: parameters).toString();
}

/// Platform balance rules are intentionally string based. Converting a
/// server-authored decimal to double can silently change cents at scale.
String formatAccountBalance(String raw, String currency) {
  final match = RegExp(r'^(-?)(\d+)(?:\.(\d+))?$').firstMatch(raw);
  if (match == null) return raw;
  final symbol = currency == 'CNY' ? '¥' : '\$';
  final negative = match.group(1) == '-';
  final integer = match.group(2)!.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  final fraction = match.group(3) ?? '';
  final zero =
      RegExp(r'^0+$').hasMatch(integer) &&
      (fraction.isEmpty || RegExp(r'^0+$').hasMatch(fraction));
  if (zero) {
    return '${symbol}0.00';
  }
  if (!negative &&
      integer == '0' &&
      (fraction.isEmpty || fraction.startsWith('00'))) {
    return '<${symbol}0.01';
  }
  var cents = fraction.padRight(2, '0').substring(0, 2);
  var whole = integer;
  if (negative) {
    // Big.js toFixed(2) uses half-up rounding for negative balances.
    if (fraction.length > 2 && int.parse(fraction[2]) >= 5) {
      final rounded = int.parse(cents) + 1;
      if (rounded == 100) {
        whole = (BigInt.parse(whole) + BigInt.one).toString();
        cents = '00';
      } else {
        cents = rounded.toString().padLeft(2, '0');
      }
    }
    if (whole == '0' && cents == '00') cents = '01';
  }
  final grouped = whole.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return '${negative ? '-' : ''}$symbol$grouped.$cents';
}

bool accountBalanceIsPositive(String raw) {
  final match = RegExp(r'^(-?)(\d+)(?:\.(\d+))?$').firstMatch(raw);
  if (match == null || match.group(1) == '-') return false;
  return RegExp(r'[1-9]').hasMatch('${match.group(2)}${match.group(3) ?? ''}');
}
