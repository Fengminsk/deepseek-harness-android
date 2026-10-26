import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_android/manual_run_response_gate.dart';

void main() {
  test('a late initial read cannot replace a newly submitted run', () {
    final responses = ManualRunResponseGate();
    final initialRead = responses.begin();
    final submission = responses.begin();

    expect(responses.accepts(initialRead), isFalse);
    expect(responses.accepts(submission), isTrue);
  });

  test('only the newest status read for the current run may update UI', () {
    final responses = ManualRunResponseGate();
    final generation = responses.begin();
    final earlier = responses.nextStatusTicket();
    final latest = responses.nextStatusTicket();

    expect(
      responses.acceptsStatus(generation, earlier, 'run-a', 'run-a'),
      isFalse,
    );
    expect(
      responses.acceptsStatus(generation, latest, 'run-a', 'run-b'),
      isFalse,
    );
    expect(
      responses.acceptsStatus(generation, latest, 'run-a', 'run-a'),
      isTrue,
    );

    responses.begin();
    expect(
      responses.acceptsStatus(generation, latest, 'run-a', 'run-a'),
      isFalse,
    );
  });
}
