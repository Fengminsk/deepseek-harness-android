import 'package:dsh_android/design/daylight.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Wait for finite UI motion while allowing the page's ambient light ticker.
/// Unlike a fixed delay, unexpected animation or a stuck spring still fails.
Future<void> settleUi(WidgetTester tester) async {
  var stable = 0;
  for (var step = 0; step < 50; step++) {
    await tester.pump(const Duration(milliseconds: 100));
    final ambient = find.byType(DaylightBackdrop).evaluate().where((element) {
      return !MediaQuery.disableAnimationsOf(element) &&
          TickerMode.valuesOf(element).enabled &&
          Theme.of(element).colorScheme.surface.toARGB32() != 0xff000000;
    }).length;
    if (tester.binding.transientCallbackCount == ambient) {
      if (++stable == 2) return;
    } else {
      stable = 0;
    }
  }
  fail('Finite UI animations did not settle within five seconds.');
}
