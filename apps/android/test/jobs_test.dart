import 'dart:async';

import 'package:dsh_android/job_output.dart';
import 'package:dsh_android/jobs.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Json _job(String status, {int earliest = 0}) => {
  'id': 'bash-123',
  'label': '整理工作区',
  'kind': 'bash',
  'owner': 'session-a',
  'status': status,
  'output': {'earliest': earliest, 'total': 100},
};

class _JobsRuntime extends RuntimeController {
  _JobsRuntime() {
    phase = 'ready';
  }
  final feeds = <StreamController<Json>>[];
  final resumeArguments = <Json Function()>[];
  final calls = <Json>[];
  int cancellations = 0;

  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) {
    expect(namespace, 'job');
    resumeArguments.add(resumeArgs ?? () => args);
    final feed = StreamController<Json>(
      sync: true,
      onCancel: () async {
        cancellations++;
      },
    );
    feeds.add(feed);
    return feed.stream;
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add({'method': method, ...params});
    return {'outcome': 'requested'};
  }
}

Widget _host(Widget child) =>
    MaterialApp(theme: pocketTheme(Brightness.light), home: child);

void main() {
  test(
    'DSH byte cursor survives reconnect while displayed output is retained',
    () {
      final output = JobOutput();
      output.apply({'type': 'opened', 'job': _job('running'), 'from': 0});
      output.apply({
        'type': 'output',
        'chunks': [
          {'at': 0, 'text': '中文'},
        ],
        'next': 6,
      });
      expect(output.cursor, 6);
      output.apply({'type': 'opened', 'job': _job('running'), 'from': 6});
      output.apply({
        'type': 'output',
        'chunks': [
          {'at': 6, 'text': '🙂'},
        ],
        'next': 10,
      });
      expect(output.text, '中文🙂');
      expect(output.cursor, 10);
      expect(output.settled, isFalse);
      output.apply({'type': 'status', 'job': _job('completed')});
      expect(output.settled, isTrue);
    },
  );

  test('retention gaps are visible and render trimming keeps surrogate pairs whole', () {
    final output = JobOutput();
    output.apply({
      'type': 'opened',
      'job': _job('running', earliest: 10),
      'from': 10,
    });
    expect(output.gapBefore, isTrue);
    output.apply({
      'type': 'output',
      'chunks': [
        {'at': 10, 'text': '🙂${'x' * (JobOutput.renderTailLimit - 1)}'},
      ],
      'next': 999999,
    });
    expect(output.text, 'x' * (JobOutput.renderTailLimit - 1));
    expect(output.cursor, 999999);
  });

  testWidgets(
    'job roster replaces a complete baseline and releasing it never kills work',
    (tester) async {
      final runtime = _JobsRuntime();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        _host(JobsPage(runtime: runtime, sessionId: 'session-a')),
      );
      await tester.pumpAndSettle();
      expect(runtime.resumeArguments.single(), {
        'request': {'sessionId': 'session-a'},
      });
      runtime.feeds.single.add({
        'type': 'item',
        'value': {
          'type': 'rows',
          'jobs': [_job('running')],
        },
      });
      await tester.pumpAndSettle();
      expect(find.text('整理工作区'), findsOneWidget);
      runtime.feeds.single.add({
        'type': 'item',
        'value': {'type': 'rows', 'jobs': []},
      });
      await tester.pumpAndSettle();
      expect(find.text('当前没有子进程任务'), findsOneWidget);
      expect(find.text('整理工作区'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(runtime.cancellations, 1);
      expect(runtime.calls, isEmpty);
      await tester.runAsync(() => runtime.feeds.single.close());
    },
  );

  testWidgets(
    'job output reconnects from last byte and stop waits for terminal frame',
    (tester) async {
      final runtime = _JobsRuntime();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        _host(
          JobOutputPage(
            runtime: runtime,
            sessionId: 'session-a',
            job: _job('running'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      runtime.feeds.single.add({
        'type': 'item',
        'value': {'type': 'opened', 'job': _job('running'), 'from': 0},
      });
      runtime.feeds.single.add({
        'type': 'item',
        'value': {
          'type': 'output',
          'chunks': [
            {'at': 0, 'text': '中文'},
          ],
          'next': 6,
        },
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('重新连接任务输出'));
      await tester.pumpAndSettle();
      expect(runtime.resumeArguments.last(), {
        'request': {'sessionId': 'session-a', 'jobId': 'bash-123', 'from': 6},
      });
      expect(find.text('中文'), findsOneWidget);
      runtime.feeds.last.add({
        'type': 'item',
        'value': {'type': 'opened', 'job': _job('running'), 'from': 6},
      });
      await tester.pumpAndSettle();
      expect(runtime.feeds, hasLength(2));
      await tester.tap(find.text('停止子进程'));
      await tester.pumpAndSettle();
      expect(runtime.calls.single['args'], {
        'request': {'sessionId': 'session-a', 'jobId': 'bash-123'},
      });
      expect(find.text('正在停止'), findsOneWidget);
      runtime.feeds.last.add({
        'type': 'item',
        'value': {'type': 'status', 'job': _job('killed')},
      });
      await tester.pumpAndSettle();
      expect(find.text('已停止'), findsOneWidget);
      expect(find.text('停止子进程'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (final feed in runtime.feeds) {
          await feed.close();
        }
      });
    },
  );
}
