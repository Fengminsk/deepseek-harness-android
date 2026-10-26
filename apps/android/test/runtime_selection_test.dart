import 'dart:async';

import 'package:dsh_android/configuration_state.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/runtime_selection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Runtime extends RuntimeController {
  _Runtime() {
    phase = 'ready';
  }
  final reads = <Completer<dynamic>>[];
  int generation = 0;
  @override
  int get connectionGeneration => generation;
  @override
  Future<dynamic> call(String method, [Json params = const {}]) {
    expect(
      (method, params['namespace'], params['method']),
      ('api.call', 'settings', 'describe'),
    );
    final reply = Completer<dynamic>();
    reads.add(reply);
    return reply.future;
  }

  void signal() => notifyListeners();
}

Json _catalog() => {
  'writable': true,
  'namespaces': [
    for (final ns in ['one', 'two'])
      {
        'ns': ns,
        'revision': 1,
        'value': {'enabled': true},
        'user': <String, dynamic>{},
        'base': {'enabled': true},
        'schema': {
          'type': 'object',
          'dict': {
            'enabled': {'type': 'boolean'},
          },
        },
        'secrets': <dynamic>[],
      },
  ],
};

void main() {
  test(
    'concurrent form readers share one flight and publish one settled state',
    () async {
      final runtime = _Runtime();
      final one = ConfigurationEditingController(runtime, namespace: 'one');
      final two = ConfigurationEditingController(runtime, namespace: 'two');
      addTearDown(() {
        one.dispose();
        two.dispose();
        runtime.dispose();
      });
      var settled = 0;
      one.addListener(() {
        if (one.fresh && !one.loading) settled++;
      });
      final first = one.start();
      final second = two.start();
      expect(runtime.reads, hasLength(1));
      runtime.reads.single.complete(_catalog());
      await Future.wait([first, second]);
      expect(one.fresh && two.fresh, isTrue);
      expect(settled, 1);
      final next = one.refresh();
      expect(runtime.reads, hasLength(2));
      runtime.reads.last.complete(_catalog());
      await next;
      expect(settled, 2);
    },
  );

  test(
    'catalog, connection and write fences cannot share an older read',
    () async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      final first = runtime.describeConfiguration();
      expect(identical(first, runtime.describeConfiguration()), isTrue);
      runtime.forms = [];
      final next = runtime.describeConfiguration();
      runtime.reads[0].complete('old');
      await first;
      expect(identical(next, runtime.describeConfiguration()), isTrue);
      runtime.generation++;
      final reconnected = runtime.describeConfiguration();
      runtime.invalidateConfigurationRead();
      final afterWrite = runtime.describeConfiguration();
      expect(runtime.reads, hasLength(4));
      for (var i = 1; i < runtime.reads.length; i++) {
        runtime.reads[i].complete(i);
      }
      expect(await Future.wait([next, reconnected, afterWrite]), [1, 2, 3]);
    },
  );

  testWidgets(
    'a hung shared read expires and explicit retry gets a new flight',
    (tester) async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      Object? failure;
      final read = runtime.describeConfiguration().catchError((Object e) {
        failure = e;
        return null;
      });
      await tester.pump(RuntimeController.configurationReadTimeout);
      await read;
      expect(failure, isA<TimeoutException>());
      final retry = runtime.describeConfiguration();
      expect(runtime.reads, hasLength(2));
      runtime.reads.first.complete('late');
      await tester.pump();
      expect(identical(retry, runtime.describeConfiguration()), isTrue);
      runtime.reads.last.complete('fresh');
      expect(await retry, 'fresh');
    },
  );

  testWidgets(
    'selection observes in-place appends and swaps owners without stale listeners',
    (tester) async {
      final old = _Runtime(), next = _Runtime();
      addTearDown(() {
        old.dispose();
        next.dispose();
      });
      var builds = 0;
      Widget screen(_Runtime runtime, String local) => Directionality(
        textDirection: TextDirection.ltr,
        child: RuntimeSelectionBuilder(
          runtime: runtime,
          select: () => (runtime.phase, runtime.timelines['s']?.length),
          builder: (_, value) {
            builds++;
            return Text('$local:${value.$1}:${value.$2}');
          },
        ),
      );
      await tester.pumpWidget(screen(old, 'a'));
      old.taskState = {'revision': 2};
      old.signal();
      await tester.pump();
      expect(builds, 1);
      old.timelines['s'] = [];
      old.signal();
      await tester.pump();
      old.timelines['s']!.add({'seq': 1});
      old.signal();
      await tester.pump();
      expect(find.text('a:ready:1'), findsOneWidget);
      await tester.pumpWidget(screen(old, 'local'));
      expect(find.text('local:ready:1'), findsOneWidget);
      await tester.pumpWidget(screen(next, 'b'));
      final before = builds;
      old.phase = 'failed';
      old.signal();
      await tester.pump();
      expect(builds, before);
      next.phase = 'restarting';
      next.signal();
      await tester.pump();
      expect(find.text('b:restarting:null'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      next.signal();
      expect(tester.takeException(), isNull);
    },
  );
}
