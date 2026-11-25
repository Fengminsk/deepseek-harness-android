import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/session_model_projection.dart';
import 'package:flutter_test/flutter_test.dart';

/// The runtime hands the projection a fresh list on every update; only the
/// preserved prefix makes it an append, so a new list must not replay history.
void main() {
  test('a fresh list with the same prefix is treated as an append', () {
    final events = <Json>[
      {
        'seq': 1,
        'type': 'model/selection',
        'data': {'provider': 'deepseek', 'model': 'first'},
      },
    ];
    final projection = SessionModelProjection();
    projection.reconcile(List<Json>.of(events));
    expect(projection.processedEventCount, 1);

    events.add({
      'seq': 2,
      'type': 'request/header',
      'data': {
        'header': {
          'config': {'provider': 'deepseek', 'model': 'first'},
        },
      },
    });
    projection.reconcile(List<Json>.of(events));
    expect(
      projection.processedEventCount,
      2,
      reason: 'only the appended event is consumed, not the whole window again',
    );
    expect(projection.next?['model'], 'first');

    // A replaced window (new element objects) still starts a fresh projection.
    final replaced = <Json>[
      for (final event in events) Map<String, dynamic>.of(event),
    ];
    projection.reconcile(replaced);
    expect(
      projection.processedEventCount,
      4,
      reason: 'a replacement replays the window from the start',
    );
    expect(projection.next?['model'], 'first');
  });
}
