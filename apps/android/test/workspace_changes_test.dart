import 'dart:async';

import 'package:dsh_android/chat_changes.dart';
import 'package:dsh_android/workspace_changes.dart';
import 'package:dsh_android/workspace_changes_preference.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workspace_changes_fixtures.dart';

void main() {
  test('projection waits for end, keeps latest announcement, supports late announcement', () {
    final events = [
      changeEvent(1, 'turn/start', 1),
      changeEvent(2, 'workspace/changes', 1),
    ];
    final projection = ChatChangesProjection()..reconcile(events);
    expect(projection.entries, isEmpty);
    events.add(changeEvent(3, 'turn/end', 1));
    projection.reconcile(events);
    expect(projection.entries.single.seq, 3);
    expect(projection.entries.single.announcementSeq, 2);
    events.add(changeEvent(4, 'workspace/changes', 1));
    projection.reconcile(events);
    expect(projection.entries.single.announcementSeq, 4);
    expect(projection.entries.single.seq, 3);
    expect(projection.processedEventCount, 4);
    projection.reconcile(events);
    expect(projection.processedEventCount, 4);
    projection.reconcile([
      changeEvent(1, 'turn/start', 5),
      changeEvent(2, 'turn/end', 5),
    ]);
    expect(projection.entries, isEmpty);
  });

  test(
    'projection does not infer changes from file tools or assistant prose',
    () {
      final projection = ChatChangesProjection()
        ..reconcile([
          changeEvent(1, 'turn/start', 1),
          {...changeEvent(2, 'tool/result', 1), 'text': 'modified 8 files'},
          {
            ...changeEvent(3, 'assistant/message', 1),
            'text': 'changed example.dart',
          },
          changeEvent(4, 'turn/end', 1),
          {
            'seq': 5,
            'type': 'workspace/changes',
            'data': {'turn': 1.5},
          },
        ]);
      expect(projection.entries, isEmpty);
    },
  );

  test('summary preserves complete totals and original array order and refuses malformed payload', () {
    final summary = WorkspaceChangesSummary.parse(
      changeSummary(files: [changedFile('z'), changedFile('a')], total: 9),
    )!;
    expect(summary.files.map((file) => file.path), ['z', 'a']);
    expect(summary.total, 9);
    expect(summary.added, 10);
    expect(
      WorkspaceChangesSummary.parse({
        ...changeSummary(),
        'files': [changedFile(''), changedFile('a')],
      }),
      isNull,
    );
    expect(
      WorkspaceChangedFile.parse({...changedFile('a'), 'binary': false}),
      isNull,
    );
    expect(
      WorkspaceChangedFile.parse({...changedFile('a'), 'added': 0.5}),
      isNull,
    );
    expect(
      WorkspaceChangesSummary.parse({...changeSummary(), 'turn': 0}),
      isNull,
    );
  });

  test('hunks retain old/new line numbers and empty/unicode lines exactly', () {
    final diff = WorkspaceFileDiff.parse(
      textDiff(lines: [' 原内容', '-old', '+新内容', '+', ' last']),
    )!;
    final rows = workspaceHunkRows(diff.hunks.single);
    expect(rows.map((row) => (row.oldLine, row.newLine)), [
      (8, 14),
      (9, null),
      (null, 15),
      (null, 16),
      (10, 17),
    ]);
    expect(rows.map((row) => row.text), ['原内容', 'old', '新内容', '', 'last']);
    expect(diff.hunks.single.header, '@@ -8,3 +14,3 @@');
    expect(
      WorkspaceFileDiff.parse(textDiff(lines: ['invalid prefix'])),
      isNull,
    );
    expect(WorkspaceFileDiff.parse({...textDiff(), 'coarse': null}), isNull);
    expect(
      WorkspaceFileDiff.parse({'kind': 'binary', 'path': 'a', 'display': 'a'})!
          .kind,
      WorkspaceDiffKind.binary,
    );
    expect(
      WorkspaceFileDiff.parse({
        'kind': 'oversized',
        'path': 'a',
        'display': 'a',
      })!.kind,
      WorkspaceDiffKind.oversized,
    );
  });

  test(
    '5000-line display budget preserves served hunk coordinates and source',
    () {
      final diff = WorkspaceFileDiff.parse(
        textDiff(lines: List.generate(5002, (i) => '+$i')),
      )!;
      final view = workspaceRenderedHunks(diff.hunks);
      expect(view.truncated, isTrue);
      expect(view.hunks.single.lines.length, 5000);
      expect(view.hunks.single.newLines, 3);
      expect(diff.hunks.single.lines.length, 5002);
      expect(
        workspaceRenderedHunks(
          WorkspaceFileDiff.parse(textDiff(lines: List.filled(5000, '+x')))!
              .hunks,
        ).truncated,
        isFalse,
      );
    },
  );

  test('preference waits for accepted Host bool and follows changes without local default', () async {
    final runtime = ChangesRuntime()..preferenceRead = Completer();
    final preference = WorkspaceChangesPreference(runtime);
    addTearDown(() {
      preference.dispose();
      runtime.dispose();
    });
    final load = preference.start();
    expect(preference.enabled, isFalse);
    expect(preference.confirmed, isFalse);
    runtime.preferenceRead!.complete(runtime.settingsAnswer());
    await load;
    runtime.preferenceRead = null;
    expect(preference.enabled, isTrue);
    runtime.settingsChanged(false);
    expect(preference.enabled, isFalse);
    await flushChanges();
    expect(preference.confirmed, isTrue);
    expect(preference.enabled, isFalse);
    runtime.settingsChanged(true);
    await flushChanges();
    expect(preference.enabled, isTrue);
    runtime.malformedPreference = true;
    runtime.reconnect();
    expect(preference.enabled, isFalse);
    await flushChanges();
    expect(preference.confirmed, isFalse);
  });

  test('controller gates all reads, fixed Session coordinates and UUID cancellation', () async {
    final runtime = ChangesRuntime()..developerEnabled = false;
    final controller = WorkspaceChangesController(
      runtime: runtime,
      sessionId: 'session-a',
    );
    addTearDown(() {
      controller.dispose();
      runtime.dispose();
    });
    await controller.loadSummary(9);
    await controller.initialize();
    expect(runtime.reads('workspaceChanges.summary'), isEmpty);
    runtime.settingsChanged(true);
    await flushChanges();
    expect(controller.enabled, isTrue);
    final args = runtime.reads('workspaceChanges.summary').single.$2;
    expect(args['sessionId'], 'session-a');
    expect(args['seq'], 9);
    expect(args.keys.toSet(), {'requestId', 'sessionId', 'seq'});
    expect(
      args['requestId'],
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    await controller.loadSummary(9);
    expect(runtime.reads('workspaceChanges.summary'), hasLength(1));
  });

  test(
    'missing summary is cached until reconnect; stale old reply cannot return',
    () async {
      final runtime = ChangesRuntime();
      final old = Completer<dynamic>();
      var first = true;
      runtime.handler = (_, _) =>
          first ? (first = false, old.future).$2 : Future.value(unavailable());
      final controller = WorkspaceChangesController(
        runtime: runtime,
        sessionId: 'fixed',
      );
      addTearDown(() {
        controller.dispose();
        runtime.dispose();
      });
      await controller.initialize();
      final pending = controller.loadSummary(3);
      runtime.reconnect();
      await flushChanges();
      expect(controller.summary(3).value.phase, WorkspaceReadPhase.missing);
      old.complete(accepted(changeSummary()));
      await pending;
      expect(controller.summary(3).value.phase, WorkspaceReadPhase.missing);
      await controller.loadSummary(3);
      expect(runtime.reads('workspaceChanges.summary'), hasLength(2));
      expect(runtime.reads('workspaceChanges.cancel'), hasLength(1));
    },
  );

  test(
    'diff missing differs from retryable error and carries original file index',
    () async {
      final runtime = ChangesRuntime();
      var count = 0;
      runtime.handler = (method, args) async {
        if (method == 'workspaceChanges.summary') {
          return accepted(
            changeSummary(files: [changedFile('a'), changedFile('b')]),
          );
        }
        count++;
        if (count == 1) {
          return {
            'ok': false,
            'error': {'code': 'workspace-changes/read-failed'},
          };
        }
        return accepted(textDiff(path: 'b'));
      };
      final controller = WorkspaceChangesController(
        runtime: runtime,
        sessionId: 'fixed',
      );
      addTearDown(() {
        controller.dispose();
        runtime.dispose();
      });
      await controller.initialize();
      await controller.loadSummary(7);
      await controller.loadDiff(7, 1);
      expect(controller.diff(7, 1).value.phase, WorkspaceReadPhase.error);
      await controller.loadDiff(7, 1);
      expect(controller.diff(7, 1).value.value!.path, 'b');
      expect(runtime.reads('workspaceChanges.diff').last.$2['index'], 1);
      runtime.handler = (_, _) async => unavailable();
      await controller.loadDiff(7, 0);
      expect(controller.diff(7, 0).value.phase, WorkspaceReadPhase.missing);
      await controller.loadDiff(7, 0);
      expect(runtime.reads('workspaceChanges.diff'), hasLength(3));
    },
  );

  test(
    'last diff reader cancels, ignores settlement and allows reopen',
    () async {
      final runtime = ChangesRuntime();
      final pending = Completer<dynamic>();
      runtime.handler = (_, _) => pending.future;
      final controller = WorkspaceChangesController(
        runtime: runtime,
        sessionId: 'fixed',
      );
      addTearDown(() {
        controller.dispose();
        runtime.dispose();
      });
      await controller.initialize();
      final leaveA = controller.retainDiff(7, 2),
          leaveB = controller.retainDiff(7, 2);
      final work = controller.loadDiff(7, 2);
      leaveA();
      expect(runtime.reads('workspaceChanges.cancel'), isEmpty);
      leaveB();
      leaveB();
      expect(runtime.reads('workspaceChanges.cancel'), hasLength(1));
      expect(runtime.reads('workspaceChanges.cancel').single.$2.keys, [
        'requestId',
      ]);
      pending.complete(accepted(textDiff()));
      await work;
      expect(controller.diff(7, 2).value.phase, WorkspaceReadPhase.idle);
      await controller.loadDiff(7, 2);
      expect(controller.diff(7, 2).value.phase, WorkspaceReadPhase.ready);
    },
  );

  test(
    'disabling preference cancels pending diff and will not start a new read',
    () async {
      final runtime = ChangesRuntime();
      final pending = Completer<dynamic>();
      runtime.handler = (_, _) => pending.future;
      final controller = WorkspaceChangesController(
        runtime: runtime,
        sessionId: 'fixed',
      );
      addTearDown(() {
        controller.dispose();
        runtime.dispose();
      });
      await controller.initialize();
      final work = controller.loadDiff(7, 0);
      runtime.settingsChanged(false);
      await flushChanges();
      expect(controller.enabled, isFalse);
      expect(runtime.reads('workspaceChanges.cancel'), hasLength(1));
      pending.complete(accepted(textDiff()));
      await work;
      await controller.loadDiff(7, 0);
      expect(runtime.reads('workspaceChanges.diff'), hasLength(1));
    },
  );

  test(
    'mismatched file path and malformed envelopes become retryable diff errors',
    () async {
      final runtime = ChangesRuntime();
      final controller = WorkspaceChangesController(
        runtime: runtime,
        sessionId: 'fixed',
      );
      addTearDown(() {
        controller.dispose();
        runtime.dispose();
      });
      await controller.initialize();
      await controller.loadSummary(1);
      runtime.handler = (_, _) async =>
          accepted(textDiff(path: 'another-file'));
      await controller.loadDiff(1, 0);
      expect(controller.diff(1, 0).value.phase, WorkspaceReadPhase.error);
      runtime.handler = (_, _) async => textDiff();
      await controller.loadDiff(1, 0);
      expect(controller.diff(1, 0).value.phase, WorkspaceReadPhase.error);
      runtime.handler = (_, _) async => accepted(textDiff());
      await controller.loadDiff(1, 0);
      expect(controller.diff(1, 0).value.phase, WorkspaceReadPhase.ready);
    },
  );

  test(
    'disabling cancels pending summary and does not publish its late answer',
    () async {
      final runtime = ChangesRuntime();
      final pending = Completer<dynamic>();
      runtime.handler = (_, _) => pending.future;
      final controller = WorkspaceChangesController(
        runtime: runtime,
        sessionId: 'fixed',
      );
      addTearDown(() {
        controller.dispose();
        runtime.dispose();
      });
      await controller.initialize();
      final read = controller.loadSummary(1);
      runtime.settingsChanged(false);
      await flushChanges();
      expect(runtime.reads('workspaceChanges.cancel'), hasLength(1));
      pending.complete(accepted(changeSummary()));
      await read;
      expect(controller.summary(1).value.value, isNull);
    },
  );
}
