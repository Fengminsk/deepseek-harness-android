import 'dart:async';

import 'package:dsh_android/automations_data.dart';
import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

import 'automations_fixture.dart';

void main() {
  test(
    'title-only edits keep original target and exclude catalog metadata',
    () {
      final record = {
        ...taskFixture(),
        'kind': 'after',
        'afterSeconds': 25,
        'lastDelivery': {'messageId': 'receipt'},
      }..remove('everySeconds');
      final draft = AutomationDraft(record);
      draft.values['title'] = '新名称';
      expect(draft.request(), {
        'id': 'task-a',
        'sessionId': 'conversation-a',
        'expected': {
          'id': 'task-a',
          'kind': 'after',
          'title': '整理进度',
          'prompt': '检查任务进度并总结。',
          'scheduledAt': '2030-01-01T12:00:00.123Z',
          'afterSeconds': 25,
        },
        'title': '新名称',
      });
      expect(draft.values['time'], '12:00:00.123');
      expect(draft.values['zone'], 'UTC');
    },
  );

  test(
    'all timing variants retain original Host input names and precision',
    () {
      final draft = AutomationDraft(taskFixture());
      draft.values.addAll({
        'kind': 'weekly',
        'time': '09:15:30.123',
        'zone': 'Asia/Shanghai',
        'weekdays': '1,3,7',
      });
      expect(draft.request()['change'], {
        'kind': 'weekly',
        'weekly': {
          'time': '09:15:30.123',
          'time_zone': 'Asia/Shanghai',
          'weekdays': [1, 3, 7],
        },
      });
      draft.values['kind'] = 'daily';
      expect(draft.request()['change'], {
        'kind': 'daily',
        'daily': {'time': '09:15:30.123', 'time_zone': 'Asia/Shanghai'},
      });
      draft.values.addAll({'kind': 'cron', 'expression': '15 9 * * 1-5'});
      expect(draft.request()['change'], {
        'kind': 'cron',
        'cron': {'expression': '15 9 * * 1-5', 'time_zone': 'Asia/Shanghai'},
      });
      draft.values.addAll({'kind': 'at', 'date': '2030-03-31'});
      expect(draft.request()['change'], {
        'kind': 'at',
        'at': {
          'date': '2030-03-31',
          'time': '09:15:30.123',
          'time_zone': 'Asia/Shanghai',
        },
      });
      draft.values.addAll({'kind': 'every', 'seconds': '90'});
      expect(draft.request()['change'], {'kind': 'every', 'every_seconds': 90});
      draft.values['seconds'] = '59';
      expect(draft.request, throwsFormatException);
    },
  );

  test(
    'explicit rebase preserves edited fields and adopts other remote changes',
    () {
      final draft = AutomationDraft(taskFixture());
      draft.values['title'] = '我的名称';
      final newer = {
        ...taskFixture(),
        'title': 'Web 名称',
        'prompt': 'Web 指令',
        'everySeconds': 7200,
        'scheduledAt': '2030-01-01T13:00:00.123Z',
      };
      draft.rebase(newer);
      expect(draft.values['title'], '我的名称');
      expect(draft.values['prompt'], 'Web 指令');
      expect(draft.values['seconds'], '7200');
      expect(draft.request()['expected'], automationSnapshot(newer));
      expect(draft.request().containsKey('change'), isFalse);
      expect(draft.request().containsKey('prompt'), isFalse);
      draft.values['seconds'] = '180';
      draft.rebase({...newer, 'everySeconds': 14400});
      expect(draft.values['seconds'], '180');
      expect(draft.request()['change'], {
        'kind': 'every',
        'every_seconds': 180,
      });
    },
  );

  test(
    'newer catalog read wins and a later error keeps that acknowledged list',
    () async {
      final runtime = AutomationRuntime();
      final first = Completer<List<Json>>(), second = Completer<List<Json>>();
      var reads = 0;
      runtime.handler = (_, _) {
        reads++;
        if (reads == 1) return first.future;
        if (reads == 2) return second.future;
        throw StateError('offline');
      };
      final catalog = AutomationsController(runtime);
      final oldRead = catalog.refresh();
      final newRead = catalog.refresh();
      second.complete([taskFixture(title: '较新记录')]);
      await newRead;
      first.complete([taskFixture(title: '旧记录')]);
      await oldRead;
      expect(catalog.records.single['title'], '较新记录');
      await catalog.refresh();
      expect(catalog.error, contains('无法读取'));
      expect(catalog.records.single['title'], '较新记录');
      catalog.dispose();
      runtime.dispose();
    },
  );

  test(
    'Host changes and readiness refresh catalog without activating sessions',
    () async {
      final runtime = AutomationRuntime()..phase = 'starting';
      final catalog = AutomationsController(runtime)..start();
      expect(runtime.requests, isEmpty);
      runtime.connection(true);
      await Future<void>.delayed(Duration.zero);
      expect(runtime.requests.single.method, 'catalog');
      runtime.tasks = [taskFixture(title: 'Web 改动')];
      runtime.events.add({'event': 'schedule/changed', 'args': []});
      await Future<void>.delayed(Duration.zero);
      expect(catalog.records.single['title'], 'Web 改动');
      runtime.connection(false);
      runtime.connection(true);
      await Future<void>.delayed(Duration.zero);
      expect(runtime.requests.map((item) => item.method), [
        'catalog',
        'catalog',
        'catalog',
      ]);
      catalog.dispose();
      runtime.events.add({'event': 'schedule/changed'});
      expect(runtime.requests, hasLength(3));
      runtime.dispose();
    },
  );

  test('conflict request keeps original binding and performs authoritative refresh', () async {
    final runtime = AutomationRuntime();
    runtime.handler = (method, _) async => method == 'catalog'
        ? [taskFixture(title: 'Web 名称')]
        : {'id': 'task-a', 'updated': false, 'code': 'schedule_conflict'};
    final catalog = AutomationsController(runtime);
    await catalog.refresh();
    runtime.requests.clear();
    final draft = AutomationDraft(taskFixture())..values['title'] = '我的名称';
    final result = await catalog.update(draft.request());
    expect(result['code'], 'schedule_conflict');
    expect(draft.values['title'], '我的名称');
    expect(runtime.requests.first.method, 'update');
    expect(runtime.requests.first.args, {'request': draft.request()});
    expect(catalog.records.single['title'], 'Web 名称');
    catalog.dispose();
    runtime.dispose();
  });

  test('history paginates exclusive cursor, deduplicates and retains after failure', () async {
    final runtime = AutomationRuntime();
    final catalog = AutomationsController(runtime);
    var reads = 0;
    runtime.handler = (method, args) async {
      expect(method, 'history');
      expect(args['request']['sessionId'], 'conversation-a');
      expect(args['request']['limit'], 20);
      reads++;
      if (reads == 1) {
        return {
          'records': [
            {'messageId': 'm2', 'prompt': '原指令'},
          ],
          'nextBefore': 'm2',
          'retention': {'days': 30, 'records': 200},
        };
      }
      expect(args['request']['before'], 'm2');
      if (reads == 2) throw StateError('network');
      return {
        'records': [
          {'messageId': 'm2'},
          {'messageId': 'm1'},
        ],
        'earlierRecordsPruned': true,
        'retention': {'days': 30, 'records': 200},
      };
    };
    final history = AutomationHistory(catalog, taskFixture());
    await history.load();
    await history.load(before: 'm2');
    expect(history.error, isNotNull);
    expect(history.records.single['prompt'], '原指令');
    await history.retry();
    expect(history.records.map((row) => row['messageId']), ['m2', 'm1']);
    expect(history.page!['earlierRecordsPruned'], isTrue);
    history.dispose();
    catalog.dispose();
    runtime.dispose();
  });

  test(
    'history refresh supersedes old pagination and late disposal result',
    () async {
      final runtime = AutomationRuntime();
      final catalog = AutomationsController(runtime);
      final older = Completer<Json>(), fresh = Completer<Json>();
      var reads = 0;
      runtime.handler = (_, _) async => {'records': <Json>[]};
      final history = AutomationHistory(catalog, taskFixture());
      await history.load();
      runtime.handler = (_, _) => ++reads == 1 ? older.future : fresh.future;
      final pendingOld = history.load(before: 'old-cursor');
      final pendingNew = history.load();
      fresh.complete({
        'records': [
          {'messageId': 'new'},
        ],
      });
      await pendingNew;
      history.dispose();
      older.complete({
        'records': [
          {'messageId': 'old'},
        ],
      });
      await pendingOld;
      expect(history.records.single['messageId'], 'new');
      catalog.dispose();
      runtime.dispose();
    },
  );

  test('live history follows new receipt and service recovery, not every catalog read', () async {
    final runtime = AutomationRuntime();
    var historyReads = 0;
    runtime.handler = (method, _) async {
      if (method == 'catalog') return runtime.tasks;
      if (method == 'history') {
        historyReads++;
        return {'records': <Json>[]};
      }
      throw StateError(method);
    };
    final catalog = AutomationsController(runtime)..start();
    await Future<void>.delayed(Duration.zero);
    final history = AutomationHistory(catalog, taskFixture())..start();
    await Future<void>.delayed(Duration.zero);
    expect(historyReads, 1);
    await catalog.refresh();
    expect(historyReads, 1);
    runtime.tasks = [
      {
        ...taskFixture(),
        'lastDelivery': {'messageId': 'new-receipt'},
      },
    ];
    runtime.events.add({'event': 'schedule/changed'});
    await Future<void>.delayed(Duration.zero);
    expect(historyReads, 2);
    runtime.connection(false);
    runtime.connection(true);
    await Future<void>.delayed(Duration.zero);
    expect(historyReads, 3);
    history.dispose();
    catalog.dispose();
    runtime.dispose();
  });
}
