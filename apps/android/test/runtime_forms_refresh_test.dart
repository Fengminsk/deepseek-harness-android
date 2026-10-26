import 'dart:async';

import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

class _Runtime extends RuntimeController {
  final reads = <Completer<dynamic>>[];
  int generation = 0;
  @override
  int get connectionGeneration => generation;
  @override
  Future<dynamic> call(String method, [Json params = const {}]) {
    expectSync(method, 'settings.describe');
    final read = Completer<dynamic>();
    reads.add(read);
    return read.future;
  }
}

List<Json> _forms(String model) => [
  {
    'ns': 'agent-default-model',
    'value': {'provider': 'fixture', 'model': model},
  },
];

void main() {
  testWidgets('a settings burst reads once plus the latest invalidation', (
    tester,
  ) async {
    final runtime = _Runtime();
    addTearDown(runtime.dispose);
    var publications = 0;
    runtime.addListener(() => publications++);
    final burst = List.generate(100, (_) => runtime.refreshForms());
    expect(runtime.reads, hasLength(1));
    runtime.reads.first.complete(_forms('obsolete'));
    await tester.pump();
    expect(runtime.reads, hasLength(2));
    expect(publications, 0);
    runtime.reads.last.complete(_forms('current'));
    await Future.wait(burst);
    expect(publications, 1);
    expect(runtime.model, 'current');
  });

  test(
    'a late old connection cannot replace forms or clear the new flight',
    () async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      final old = runtime.refreshForms();
      runtime.generation++;
      final fresh = runtime.refreshForms();
      runtime.reads.first.complete(_forms('old'));
      await old;
      runtime.reads.last.complete(_forms('new'));
      await fresh;
      expect(runtime.model, 'new');
      expect(runtime.reads, hasLength(2));
    },
  );

  testWidgets('an invalidation at publication is not lost on completion', (
    tester,
  ) async {
    final runtime = _Runtime();
    addTearDown(runtime.dispose);
    var publications = 0;
    runtime.addListener(() {
      if (++publications == 1) {
        scheduleMicrotask(() => unawaited(runtime.refreshForms()));
      }
    });
    final read = runtime.refreshForms();
    runtime.reads.first.complete(_forms('first'));
    await tester.pump();
    expect(runtime.reads, hasLength(2));
    runtime.reads.last.complete(_forms('last'));
    await read;
    expect(runtime.model, 'last');
    expect(publications, 2);
  });

  test('a failed read releases the flight for explicit retry', () async {
    final runtime = _Runtime();
    addTearDown(runtime.dispose);
    final failed = expectLater(runtime.refreshForms(), throwsStateError);
    runtime.reads.first.completeError(StateError('offline'));
    await failed;
    final retry = runtime.refreshForms();
    runtime.reads.last.complete(_forms('recovered'));
    await retry;
    expect(runtime.reads, hasLength(2));
    expect(runtime.model, 'recovered');
  });
}
