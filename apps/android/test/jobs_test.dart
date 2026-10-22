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
  int replacementGeneration = 0;
  Completer<Json>? stopReply;

  @override
  int get connectionGeneration => replacementGeneration;

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
    if (params['namespace'] == 'job' && params['method'] == 'kill') {
      final pending = stopReply;
      if (pending != null) return pending.future;
    }
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

  for (final replacement in [
    'watch',
    'runtime',
    'observation',
    'disconnected',
  ]) {
    for (final failed in [false, true]) {
      testWidgets(
        'old stop ${failed ? 'failure' : 'success'} cannot change the $replacement successor',
        (tester) async {
          final runtime = _JobsRuntime();
          final reply = Completer<Json>();
          runtime.stopReply = reply;
          addTearDown(() async {
            if (!reply.isCompleted) reply.complete({'outcome': 'requested'});
            await tester.pumpWidget(const SizedBox());
            await tester.pump();
            for (final feed in runtime.feeds) {
              await feed.close();
            }
            runtime.dispose();
          });
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
          await tester.pumpAndSettle();
          await tester.tap(find.text('停止子进程'));
          await tester.pumpAndSettle();
          expect(runtime.calls, hasLength(1));
          expect(reply.isCompleted, isFalse);
          expect(find.text('正在停止'), findsOneWidget);

          switch (replacement) {
            case 'watch':
              await tester.tap(find.byTooltip('重新连接任务输出'));
              await tester.pumpAndSettle();
              expect(runtime.feeds, hasLength(2));
              runtime.feeds.last.add({
                'type': 'item',
                'value': {'type': 'opened', 'job': _job('running'), 'from': 0},
              });
            case 'runtime':
              // The runtime invalidates ownership before delivery of a new
              // stream baseline, so a late reply can land in that interval.
              runtime.replacementGeneration++;
            case 'observation':
              runtime.feeds.single.add({'type': 'opening'});
              runtime.feeds.single.add({
                'type': 'item',
                'value': {'type': 'opened', 'job': _job('running'), 'from': 0},
              });
            case 'disconnected':
              runtime.feeds.single.add({'type': 'disconnected'});
          }
          await tester.pumpAndSettle();
          if (failed) {
            reply.completeError(StateError('old stop transport failed'));
          } else {
            reply.complete({'outcome': 'requested'});
          }
          await tester.pumpAndSettle();
          expect(find.text('停止请求已接受，等待任务结束。'), findsNothing);
          expect(find.textContaining('停止请求的结果未确认'), findsNothing);
          expect(
            find.text(switch (replacement) {
              'runtime' => '正在停止',
              'disconnected' => '核对停止状态',
              _ => '停止子进程',
            }),
            findsOneWidget,
          );
          if (replacement == 'watch' || replacement == 'observation') {
            expect(find.text('任务仍在运行，如需停止请重新发起。'), findsOneWidget);
          } else if (replacement == 'disconnected') {
            expect(find.text('停止结果待核对，恢复输出后确认任务状态。'), findsOneWidget);
            expect(find.text('输出连接中断；已读内容保留，恢复后从原位置继续读取。'), findsOneWidget);
          }
          expect(runtime.calls, hasLength(1));
        },
      );
    }
  }

  for (final settled in [false, true]) {
    testWidgets(
      settled ? 'terminal output outranks a delayed stop failure' : 'current stop failure remains visible without replaying the request',
      (tester) async {
        final runtime = _JobsRuntime();
        final reply = Completer<Json>();
        runtime.stopReply = reply;
        addTearDown(() async {
          if (!reply.isCompleted) reply.complete({'outcome': 'requested'});
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          for (final feed in runtime.feeds) {
            await feed.close();
          }
          runtime.dispose();
        });
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
        await tester.pumpAndSettle();
        await tester.tap(find.text('停止子进程'));
        await tester.pumpAndSettle();
        expect(runtime.calls, hasLength(1));
        expect(reply.isCompleted, isFalse);
        if (settled) {
          runtime.feeds.single.add({
            'type': 'item',
            'value': {'type': 'status', 'job': _job('killed')},
          });
          await tester.pumpAndSettle();
          expect(find.text('已停止'), findsOneWidget);
        }
        reply.completeError(StateError('late stop failure'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('停止请求的结果未确认'),
          settled ? findsNothing : findsOneWidget,
        );
        expect(find.text('正在停止'), findsNothing);
        expect(find.text(settled ? '已停止' : '停止子进程'), findsOneWidget);
        expect(runtime.calls, hasLength(1));
      },
    );
  }

  for (final status in ['running', 'stopping', 'completed']) {
    testWidgets('reopened $status baseline replaces an old stop receipt', (
      tester,
    ) async {
      final runtime = _JobsRuntime();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        for (final feed in runtime.feeds) {
          await feed.close();
        }
        runtime.dispose();
      });
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
      await tester.pumpAndSettle();
      await tester.tap(find.text('停止子进程'));
      await tester.pumpAndSettle();
      expect(find.text('停止请求已接受，等待任务结束。'), findsOneWidget);

      runtime.feeds.single.add({'type': 'disconnected'});
      await tester.pumpAndSettle();
      expect(find.text('停止请求已接受，等待任务结束。'), findsNothing);
      expect(find.text('停止结果待核对，恢复输出后确认任务状态。'), findsOneWidget);
      expect(find.text('核对停止状态'), findsOneWidget);
      runtime.feeds.single.add({'type': 'opening'});
      runtime.feeds.single.add({
        'type': 'item',
        'value': {'type': 'opened', 'job': _job(status), 'from': 0},
      });
      await tester.pumpAndSettle();
      expect(find.text('停止结果待核对，恢复输出后确认任务状态。'), findsNothing);
      expect(find.text('核对停止状态'), findsNothing);
      expect(
        find.text(switch (status) {
          'running' => '任务仍在运行，如需停止请重新发起。',
          'stopping' => '任务正在停止，等待最终输出。',
          _ => '任务已结束，正在读取最终输出。',
        }),
        findsOneWidget,
      );
      expect(runtime.calls, hasLength(1));

      if (status == 'running') {
        // A new user gesture may request a stop after an authoritative running
        // baseline; reconnect itself must never replay the previous command.
        await tester.tap(find.text('停止子进程'));
        await tester.pumpAndSettle();
        expect(runtime.calls, hasLength(2));
        expect(find.text('停止请求已接受，等待任务结束。'), findsOneWidget);
      }
      runtime.feeds.single.add({
        'type': 'item',
        'value': {
          'type': 'status',
          'job': _job(status == 'completed' ? 'completed' : 'killed'),
        },
      });
      await tester.pumpAndSettle();
      expect(find.text(status == 'completed' ? '已完成' : '已停止'), findsOneWidget);
      expect(find.text('停止请求已接受，等待任务结束。'), findsNothing);
      expect(find.text('任务正在停止，等待最终输出。'), findsNothing);
      expect(find.text('任务已结束，正在读取最终输出。'), findsNothing);
    });
  }
}
