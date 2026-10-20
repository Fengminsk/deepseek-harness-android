import 'dart:async';

import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

class _Runtime extends RuntimeController {
  final reads = <Completer<List<Json>>>[];
  @override
  Future<dynamic> call(String method, [Json params = const {}]) {
    expect(method, 'sessions.list');
    final read = Completer<List<Json>>();
    reads.add(read);
    return read.future;
  }
}

void main() {
  test(
    'a workspace change during a read schedules one fresh authoritative read',
    () async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      final first = runtime.refreshSessions();
      final changed = runtime.refreshSessions();
      final changedAgain = runtime.refreshSessions();
      expect(runtime.reads, hasLength(1));
      runtime.reads.first.complete([
        {
          'header': {'id': 'before-archive'},
        },
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(runtime.reads, hasLength(2));
      runtime.reads.last.complete([
        {
          'header': {'id': 'pinned'},
          'pinned': true,
        },
      ]);
      await Future.wait([first, changed, changedAgain]);
      expect(runtime.sessions.single['header']['id'], 'pinned');
    },
  );

  test(
    'a failed read preserves the displayed list and allows explicit refresh',
    () async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      runtime.sessions = [
        {
          'header': {'id': 'retained'},
        },
      ];
      final read = runtime.refreshSessions();
      final error = expectLater(read, throwsStateError);
      runtime.reads.single.completeError(StateError('disconnected'));
      await error;
      expect(runtime.sessions.single['header']['id'], 'retained');
      final retry = runtime.refreshSessions();
      runtime.reads.last.complete([]);
      await retry;
      expect(runtime.sessions, isEmpty);
    },
  );

  test(
    'disposing before the list response cannot publish stale rows',
    () async {
      final runtime = _Runtime();
      final read = runtime.refreshSessions();
      runtime.dispose();
      runtime.reads.single.complete([
        {
          'header': {'id': 'late'},
        },
      ]);
      await read;
      expect(runtime.sessions, isEmpty);
    },
  );
  test('a queued invalidation is not lost when the older read fails', () async {
    final runtime = _Runtime()..phase = 'ready';
    addTearDown(runtime.dispose);
    final old = runtime.refreshSessions();
    final changed = runtime.refreshSessions();
    runtime.reads.single.completeError(StateError('old read failed'));
    await Future<void>.delayed(Duration.zero);
    expect(runtime.reads, hasLength(2));
    runtime.reads.last.complete([
      {
        'header': {'id': 'after-change'},
      },
    ]);
    await Future.wait([old, changed]);
    expect(runtime.sessions.single['header']['id'], 'after-change');
  });
}
