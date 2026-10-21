import 'package:dsh_android/session_search_data.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/session_search_runtime.dart';

void main() {
  late SessionSearchTestRuntime runtime;
  late SessionSearchController state;
  setUp(() {
    runtime = SessionSearchTestRuntime();
    state = SessionSearchController(runtime);
  });
  tearDown(() {
    state.dispose();
    runtime.dispose();
  });

  test(
    'typing is local; submitting searches original messages and reads catalog',
    () async {
      state.setQuery('  Shell  ');
      expect(runtime.calls, isEmpty);
      runtime.response = sessionSearchResponse('执行过 Shell');
      await state.search();
      expect(runtime.calls.map((call) => call.method), [
        'api.call',
        'library.catalog',
      ]);
      expect(runtime.calls.first.params, {
        'namespace': 'session',
        'method': 'search',
        'args': {
          'request': {'query': 'Shell'},
        },
      });
      expect(state.phase, SessionSearchPhase.complete);
      expect(state.submittedQuery, 'Shell');
      expect(state.title('first'), '手机里的本地助手');
      expect(state.items.single.snippet, '执行过 Shell');
      expect(state.canOpen('first'), isTrue);
      expect(state.canOpen('child'), isFalse);
    },
  );

  test(
    'query accepts 500 UTF16 units and rejects longer or NUL before calling',
    () async {
      for (final text in ['', ' ', 'a' * 501, '😀' * 251, 'a\u0000b']) {
        state.setQuery(text);
        await state.search();
        expect(runtime.calls, isEmpty);
        expect(state.error, isNotNull);
      }
      state.setQuery('😀' * 250);
      expect(state.canSearch, isTrue);
      await state.search();
      expect(runtime.calls.length, 2);
    },
  );

  test('same query cannot duplicate an outstanding request', () async {
    runtime.deferSearch = true;
    state.setQuery('Shell');
    final work = state.search();
    await state.search();
    expect(runtime.pending.length, 1);
    runtime.pending.single.complete(sessionSearchResponse('done'));
    await work;
  });

  test(
    'query edit retires prior reads and permits a new explicit submission',
    () async {
      runtime.deferSearch = true;
      state.setQuery('old');
      final old = state.search();
      state.setQuery('new');
      final next = state.search();
      runtime.pending[1].complete(sessionSearchResponse('new result'));
      await next;
      runtime.pending[0].complete(sessionSearchResponse('old result'));
      await old;
      expect(state.items.single.snippet, 'new result');
      expect(state.submittedQuery, 'new');
    },
  );

  test(
    'clearing query removes old results and ignores a late failed receipt',
    () async {
      runtime.deferSearch = true;
      state.setQuery('old');
      final old = state.search();
      state.setQuery('');
      runtime.pending.single.completeError(PlatformException(code: 'late'));
      await old;
      expect(state.phase, SessionSearchPhase.idle);
      expect(state.items, isEmpty);
      expect(state.error, isNull);
    },
  );

  for (final boundary in ['disconnect', 'ready generation', 'epoch']) {
    test(
      '$boundary retires reads without replaying and preserves query',
      () async {
        runtime.deferSearch = true;
        state.setQuery('保留我的搜索');
        final old = state.search();
        if (boundary == 'epoch') {
          runtime.changeEpoch();
        } else {
          runtime.changeConnection(ready: boundary != 'disconnect');
        }
        runtime.pending.single.complete(sessionSearchResponse('stale'));
        await old;
        expect(state.query, '保留我的搜索');
        expect(state.items, isEmpty);
        expect(state.phase, SessionSearchPhase.idle);
        if (!runtime.ready) runtime.changeConnection();
        expect(runtime.pending.length, 1);
        expect(state.canSearch, isTrue);
        final retry = state.search();
        runtime.pending.last.complete(sessionSearchResponse('fresh'));
        await retry;
        expect(state.items.single.snippet, 'fresh');
      },
    );
  }

  test(
    'catalog receipt from prior connection cannot restore search results',
    () async {
      runtime.deferCatalog = true;
      runtime.response = sessionSearchResponse('old');
      state.setQuery('test');
      final old = state.search();
      runtime.changeConnection();
      runtime.catalogRead!.complete(runtime.catalog);
      await old;
      expect(state.items, isEmpty);
      expect(state.canOpen('first'), isFalse);
    },
  );

  test('offline submit does not access any API', () async {
    runtime.changeConnection(ready: false);
    state.setQuery('test');
    await state.search();
    expect(runtime.calls, isEmpty);
    expect(state.error, contains('连接'));
  });

  test(
    'missing catalog keeps matching content but cannot open unknown session',
    () async {
      runtime.catalogFailure = PlatformException(code: 'catalog/offline');
      runtime.response = sessionSearchResponse('并不是会话标题', id: 'missing');
      state.setQuery('内容');
      await state.search();
      expect(state.phase, SessionSearchPhase.complete);
      expect(state.items.single.snippet, '并不是会话标题');
      expect(state.title('missing'), '会话信息未读取');
      expect(state.catalogError, isNotNull);
      expect(state.canOpen('missing'), isFalse);
    },
  );

  test('archived and untitled catalog sessions remain selectable', () async {
    (runtime.catalog['sessions'] as List).add({'sessionId': 'untitled'});
    runtime.response = {
      'items': [
        {'sessionId': 'archived', 'snippet': '旧的正文'},
        {'sessionId': 'untitled', 'snippet': '无标题正文'},
      ],
      'hasMore': false,
    };
    state.setQuery('正文');
    await state.search();
    expect(state.archived('archived'), isTrue);
    expect(state.canOpen('archived'), isTrue);
    expect(state.title('untitled'), '未命名会话');
    expect(state.hasTitle('untitled'), isFalse);
    expect(state.canOpen('untitled'), isTrue);
  });

  test(
    'server limit is displayed as more matches without an invented cursor',
    () async {
      runtime.response = {
        'items': [
          for (var i = 0; i < 20; i++) {'sessionId': 's$i', 'snippet': '摘要$i'},
        ],
        'hasMore': true,
      };
      state.setQuery('摘要');
      await state.search();
      expect(state.items.length, 20);
      expect(state.hasMore, isTrue);
      expect(runtime.calls.length, 2);
    },
  );

  test(
    'malformed and oversized results fail visibly instead of claiming empty',
    () async {
      for (final response in [
        {'items': [], 'hasMore': 'false'},
        {
          'items': [
            {'sessionId': 'first', 'snippet': 1},
          ],
          'hasMore': false,
        },
        {
          'items': [
            for (var i = 0; i < 21; i++) {'sessionId': 's$i', 'snippet': ''},
          ],
          'hasMore': false,
        },
        {
          'items': [
            for (var i = 0; i < 2; i++) {'sessionId': 'same', 'snippet': ''},
          ],
          'hasMore': false,
        },
      ]) {
        runtime.response = response;
        state.setQuery('query');
        await state.search();
        expect(state.phase, SessionSearchPhase.failed);
        expect(state.items, isEmpty);
        expect(state.error, isNotNull);
      }
    },
  );

  test(
    'unavailable service is recoverable and does not fabricate results',
    () async {
      runtime.searchFailure = PlatformException(
        code: 'SESSION_QUERY_SEARCH_DISABLED',
      );
      state.setQuery('word');
      await state.search();
      expect(state.phase, SessionSearchPhase.failed);
      expect(state.error, '当前服务未开启正文搜索');
      runtime.searchFailure = null;
      await state.search();
      expect(state.phase, SessionSearchPhase.complete);
      expect(state.items, isEmpty);
    },
  );

  test('disposed controller cannot publish late responses', () async {
    final other = SessionSearchController(runtime, initialQuery: 'late');
    runtime.deferSearch = true;
    var updates = 0;
    other.addListener(() => updates++);
    final work = other.search();
    other.dispose();
    runtime.pending.single.complete(sessionSearchResponse('late'));
    await work;
    runtime.changeConnection();
    expect(updates, 1);
  });
}
