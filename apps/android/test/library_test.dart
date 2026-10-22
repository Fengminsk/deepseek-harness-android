import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/library.dart';
import 'package:dsh_android/library_data.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Json copy(Json value) => jsonDecode(jsonEncode(value)) as Json;

Json summary(String id, String title, {String cwd = '/private/work'}) => {
  'sessionId': id,
  'updatedAt': 1792505774889,
  'running': false,
  'blank': false,
  'cwd': cwd,
  'projections': {
    'values': {'title': title},
  },
};

class LibraryRuntime extends RuntimeController {
  LibraryRuntime() {
    phase = 'ready';
    catalog = copy(catalog);
  }

  Json catalog = {
    'workspaces': [
      {
        'workspaceId': 'w1',
        'path': '/private/work',
        'title': '项目一',
        'sessionIds': ['s1', 's2'],
        'createdAt': 1,
        'updatedAt': 2,
      },
      {
        'workspaceId': 'w2',
        'path': '/private/other',
        'title': '项目二',
        'sessionIds': ['s3'],
        'createdAt': 1,
        'updatedAt': 2,
      },
    ],
    'sessions': [
      summary('s1', '原始标题'),
      summary('s2', '第二会话'),
      summary('s3', '另一工作区会话', cwd: '/private/other'),
      summary('a1', '已归档任务'),
      {...summary('child1', '子 Agent 会话'), 'origin': 'subagent'},
    ],
    'archivedSessionIds': ['a1'],
    'pinnedSessionIds': ['s1'],
    'defaultDirectory': '/private/work',
    'capabilities': {'crossWorkspaceMove': false},
  };
  final calls = <(String, Json)>[];
  final watches = <(String, String)>[];
  final streams = <String, List<StreamController<Json>>>{};
  final handlers = <String, Future<dynamic> Function(Json)>{};
  int get reads => sent('catalog').length;
  List<(String, Json)> sent(String name) =>
      calls.where((call) => call.$1 == 'library.$name').toList();
  Json row(String id) => (catalog['sessions'] as List).cast<Json>().firstWhere(
    (row) => row['sessionId'] == id,
  );

  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) {
    watches.add((namespace, method));
    late final StreamController<Json> stream;
    stream = StreamController<Json>(
      onListen: () => scheduleMicrotask(
        () => stream.add({
          'type': 'item',
          'value': {'type': 'baseline'},
        }),
      ),
    );
    streams.putIfAbsent(namespace, () => []).add(stream);
    return stream.stream;
  }

  void emit(String name, Json frame) => streams[name]!.last.add(frame);

  void changeConnection(String value, {String? epoch}) {
    phase = value;
    if (epoch != null) taskState = {'epoch': epoch};
    notifyListeners();
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method, Map.of(params)));
    if (handlers[method] case final handler?) return handler(params);
    switch (method) {
      case 'library.catalog':
        return copy(catalog);
      case 'library.sessionCreate':
        return {'sessionId': 'service-selected-id'};
      case 'library.sessionFork':
        return {'sessionId': 'service-fork-id'};
      case 'library.directoryCreate':
        return {'path': '${params['path']}/${params['name']}'};
      case 'library.workspaceCreate':
        final workspace = {
          'workspaceId': 'registered',
          'path': params['path'],
          'title': '新工作区',
          'sessionIds': <String>[],
        };
        (catalog['workspaces'] as List).add(workspace);
        return {'workspace': workspace, 'created': true};
      case 'library.workspaceRename':
        final workspace = (catalog['workspaces'] as List)
            .cast<Json>()
            .firstWhere((row) => row['workspaceId'] == params['workspaceId']);
        workspace['title'] = params['title'];
        return {'workspace': copy(workspace)};
      case 'library.sessionRename':
        row(params['sessionId'])['projections']['values']['title'] =
            params['title'];
        return {'title': params['title'], 'seq': 8};
      case 'library.sessionPin':
        final ids = catalog['pinnedSessionIds'] as List;
        ids.remove(params['sessionId']);
        if (params['pinned'] == true) ids.add(params['sessionId']);
        return {
          'pinnedSessionIds': [...ids],
        };
      case 'library.sessionArchive':
        final ids = catalog['archivedSessionIds'] as List;
        ids.remove(params['sessionId']);
        if (params['archived'] == true) ids.add(params['sessionId']);
        return {
          'archivedSessionIds': [...ids],
        };
      case 'library.sessionReorder':
        return {
          'workspace': {
            'workspaceId': params['workspaceId'],
            'sessionIds': ['s2', 's1'],
          },
        };
      case 'library.workspaceReorder':
        return {
          'workspaceIds': ['w2', 'w1'],
        };
      default:
        throw StateError('Unexpected call $method');
    }
  }
}

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pumpAndSettle();
}

Future<void> prepare(WidgetTester tester, LibraryRuntime runtime) async {
  tester.view.physicalSize = const Size(1000, 2200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  runtime.library.start();
  await settle(tester);
  expect(runtime.library.synchronized, isTrue);
}

Future<void> show(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(
    MaterialApp(theme: pocketTheme(Brightness.light), home: page),
  );
  await settle(tester);
}

Finder key(String value) => find.byKey(ValueKey(value));

Future<void> tap(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      350,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await settle(tester);
}

Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('catalog lists preserve original titles and do not read logs', (
    tester,
  ) async {
    final runtime = LibraryRuntime();
    await prepare(tester, runtime);
    await show(tester, LibraryPage(runtime: runtime));
    expect(find.text('项目一'), findsOneWidget);
    expect(runtime.watches, [('workspace', 'follow'), ('session', 'control')]);
    await tap(tester, find.text('近期'));
    expect(find.text('原始标题'), findsOneWidget);
    expect(find.text('子 Agent 会话'), findsNothing);
    expect(find.text('已归档任务'), findsNothing);
    expect(find.text('s1'), findsNothing);
    expect(
      tester.widget<PocketRow>(key('library-session-s1')).subtitle,
      contains('项目一'),
    );
    await tap(tester, find.text('置顶'));
    expect(key('library-session-s1'), findsOneWidget);
    expect(key('library-session-s2'), findsNothing);
    await tap(tester, find.text('已归档').first);
    expect(find.text('已归档任务'), findsOneWidget);
    expect(runtime.calls.every((call) => call.$1 == 'library.catalog'), isTrue);
    await close(tester);
  });

  testWidgets(
    'new session propagates the service selected identity through routes',
    (tester) async {
      final runtime = LibraryRuntime();
      await prepare(tester, runtime);
      String? opened;
      await show(
        tester,
        Builder(
          builder: (context) {
            return PocketButton(
              onPressed: () async => opened = await Navigator.push<String>(
                context,
                PocketRoute<String>(
                  builder: (_) => LibraryPage(runtime: runtime),
                ),
              ),
              child: const Text('管理入口'),
            );
          },
        ),
      );
      await tap(tester, find.text('管理入口'));
      await tap(tester, key('workspace-w1'));
      await tap(tester, key('workspace-new-session'));
      expect(opened, 'service-selected-id');
      expect(runtime.sent('sessionCreate').single.$2, {'workspaceId': 'w1'});
      expect(find.text('管理入口'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets('fork uses the original completed prefix and returned identity', (
    tester,
  ) async {
    final runtime = LibraryRuntime();
    await prepare(tester, runtime);
    String? opened;
    await show(
      tester,
      Builder(
        builder: (context) {
          return PocketButton(
            onPressed: () async => opened = await Navigator.push<String>(
              context,
              PocketRoute<String>(
                builder: (_) => LibrarySessionPage(
                  library: runtime.library,
                  sessionId: 's1',
                ),
              ),
            ),
            child: const Text('会话入口'),
          );
        },
      ),
    );
    await tap(tester, find.text('会话入口'));
    await tap(tester, key('session-fork'));
    expect(opened, 'service-fork-id');
    expect(runtime.sent('sessionFork').single.$2, {'sessionId': 's1'});
    await close(tester);
  });

  testWidgets(
    'active archive requires a second explicit decision and can restore',
    (tester) async {
      final runtime = LibraryRuntime();
      runtime.handlers['library.sessionArchive'] = (params) async {
        if (params['archived'] == true && params['stopActivity'] != true) {
          throw PlatformException(
            code: 'workspace/session-active',
            details: {
              'details': {
                'sessionId': 's1',
                'activity': [
                  {'kind': 'turn'},
                  {
                    'kind': 'job',
                    'items': [
                      {'id': 'job1', 'label': '下载依赖'},
                    ],
                  },
                ],
              },
            },
          );
        }
        final ids = catalogIds(runtime, 'archivedSessionIds');
        ids.remove('s1');
        if (params['archived'] == true) ids.add('s1');
        return {
          'archivedSessionIds': [...ids],
        };
      };
      await prepare(tester, runtime);
      await show(
        tester,
        LibrarySessionPage(library: runtime.library, sessionId: 's1'),
      );
      await tap(tester, key('session-archive'));
      expect(runtime.sent('sessionArchive'), hasLength(1));
      expect(runtime.sent('sessionArchive').first.$2['stopActivity'], isFalse);
      expect(find.text('正在执行的会话回合'), findsOneWidget);
      expect(find.text('后台作业'), findsOneWidget);
      await settle(tester);
      expect(runtime.sent('sessionArchive'), hasLength(1));
      await tap(tester, key('confirm-stop-and-archive'));
      expect(runtime.sent('sessionArchive').last.$2, {
        'sessionId': 's1',
        'archived': true,
        'stopActivity': true,
      });
      expect(runtime.library.archivedSessionIds, contains('s1'));
      await tap(tester, key('session-archive'));
      expect(runtime.sent('sessionArchive').last.$2, {
        'sessionId': 's1',
        'archived': false,
        'stopActivity': false,
      });
      expect(runtime.library.archivedSessionIds, isNot(contains('s1')));
      await close(tester);
    },
  );

  testWidgets(
    'directory creation and registration are separate confirmed steps',
    (tester) async {
      final runtime = LibraryRuntime();
      await prepare(tester, runtime);
      await show(tester, LibraryCreateWorkspacePage(library: runtime.library));
      await tester.enterText(key('workspace-directory-name'), '../escape');
      await tap(tester, key('create-workspace-directory'));
      expect(runtime.sent('directoryCreate'), isEmpty);
      expect(find.textContaining('只填写单层文件夹名'), findsOneWidget);
      await tester.enterText(key('workspace-directory-name'), 'notes');
      await tap(tester, key('create-workspace-directory'));
      expect(runtime.sent('directoryCreate').single.$2, {
        'path': '/private/work',
        'name': 'notes',
      });
      expect(runtime.sent('workspaceCreate'), isEmpty);
      expect(runtime.library.workspaceDraft.directory, '/private/work/notes');
      await tap(tester, key('register-workspace'));
      expect(runtime.sent('workspaceCreate').single.$2, {
        'path': '/private/work/notes',
      });
      expect(
        runtime.library.workspaceDraft.registered?['workspaceId'],
        'registered',
      );
      expect(runtime.sent('directoryCreate'), hasLength(1));
      await close(tester);
    },
  );

  testWidgets(
    'default directory registration does not create another directory',
    (tester) async {
      final runtime = LibraryRuntime();
      await prepare(tester, runtime);
      await show(tester, LibraryCreateWorkspacePage(library: runtime.library));
      await tap(tester, find.text('登记默认目录'));
      await tap(tester, key('register-workspace'));
      expect(runtime.sent('directoryCreate'), isEmpty);
      expect(runtime.sent('workspaceCreate').single.$2, {
        'path': '/private/work',
      });
      await close(tester);
    },
  );

  testWidgets(
    'unknown mkdir survives reopening with its draft and cannot replay',
    (tester) async {
      final runtime = LibraryRuntime();
      runtime.handlers['library.directoryCreate'] = (_) async =>
          throw TimeoutException('reply lost');
      await prepare(tester, runtime);
      await show(tester, LibraryCreateWorkspacePage(library: runtime.library));
      await tester.enterText(key('workspace-directory-name'), 'retained');
      await tap(tester, key('create-workspace-directory'));
      expect(runtime.library.actions['directory-create']?.state, 'unconfirmed');
      await close(tester);
      await show(tester, LibraryCreateWorkspacePage(library: runtime.library));
      expect(
        tester
            .widget<TextField>(key('workspace-directory-name'))
            .controller!
            .text,
        'retained',
      );
      expect(
        tester
            .widget<PocketButton>(key('create-workspace-directory'))
            .onPressed,
        isNull,
      );
      await runtime.library.refresh(reconnect: true);
      await settle(tester);
      expect(runtime.sent('directoryCreate'), hasLength(1));
      expect(runtime.sent('workspaceCreate'), isEmpty);
      await close(tester);
    },
  );

  testWidgets(
    'registration failure retains confirmed mkdir and uncertain receipt',
    (tester) async {
      final runtime = LibraryRuntime();
      runtime.handlers['library.workspaceCreate'] = (_) async =>
          throw PlatformException(code: 'workspace/invalid-path');
      await prepare(tester, runtime);
      await show(tester, LibraryCreateWorkspacePage(library: runtime.library));
      await tester.enterText(key('workspace-directory-name'), 'kept');
      await tap(tester, key('create-workspace-directory'));
      await tap(tester, key('register-workspace'));
      expect(
        runtime.library.actions['workspace-register']?.state,
        'unconfirmed',
      );
      expect(runtime.library.workspaceDraft.directory, '/private/work/kept');
      expect(
        tester.widget<PocketButton>(key('register-workspace')).onPressed,
        isNull,
      );
      expect(runtime.sent('directoryCreate'), hasLength(1));
      await close(tester);
    },
  );

  testWidgets(
    'partial creation keeps created identity and blocks duplicate creation',
    (tester) async {
      final runtime = LibraryRuntime();
      runtime.handlers['library.sessionCreate'] = (_) async =>
          throw PlatformException(
            code: 'session/workspace-attach-failed',
            details: {
              'details': {'sessionId': 'already-created', 'workspaceId': 'w1'},
            },
          );
      await prepare(tester, runtime);
      await show(
        tester,
        LibraryWorkspacePage(library: runtime.library, workspaceId: 'w1'),
      );
      await tap(tester, key('workspace-new-session'));
      expect(runtime.library.actions['session-create:w1']?.state, 'partial');
      expect(find.text('打开已创建的会话'), findsOneWidget);
      expect(
        tester.widget<PocketButton>(key('workspace-new-session')).onPressed,
        isNull,
      );
      await runtime.library.refresh();
      expect(runtime.sent('sessionCreate'), hasLength(1));
      await close(tester);
    },
  );

  testWidgets(
    'rename retains failed draft and requires reviewing a concurrent title',
    (tester) async {
      final runtime = LibraryRuntime();
      runtime.handlers['library.sessionRename'] = (_) async =>
          throw PlatformException(code: 'session/title-invalid');
      await prepare(tester, runtime);
      await show(tester, LibraryRenamePage(library: runtime.library, id: 's1'));
      await tester.enterText(key('library-title'), '我的草稿');
      await tap(tester, key('save-library-title'));
      expect(runtime.library.actions['session-rename:s1']?.state, 'rejected');
      expect(
        tester.widget<TextField>(key('library-title')).controller!.text,
        '我的草稿',
      );
      expect(
        tester.widget<PocketButton>(key('save-library-title')).onPressed,
        isNotNull,
      );
      runtime.row('s1')['projections']['values']['title'] = 'Web 的新名称';
      runtime.emit('session', {
        'type': 'item',
        'value': {'type': 'projection', 'key': 'title', 'sessionId': 's1'},
      });
      await settle(tester);
      expect(find.text('名称已在其他入口改变，草稿保留'), findsOneWidget);
      expect(
        tester.widget<PocketButton>(key('save-library-title')).onPressed,
        isNull,
      );
      await tap(tester, find.text('以当前名称为依据，保留草稿'));
      runtime.handlers.remove('library.sessionRename');
      await tap(tester, key('save-library-title'));
      expect(runtime.sent('sessionRename').last.$2, {
        'sessionId': 's1',
        'title': '我的草稿',
      });
      expect(
        runtime.library.session('s1')?['projections']['values']['title'],
        '我的草稿',
      );
      await close(tester);
    },
  );

  testWidgets(
    'ordering exposes only siblings and sends original anchor fields',
    (tester) async {
      final runtime = LibraryRuntime();
      await prepare(tester, runtime);
      await show(
        tester,
        LibraryOrderPage(
          library: runtime.library,
          workspaceId: 'w1',
          sessionId: 's1',
        ),
      );
      expect(key('order-before-s2'), findsOneWidget);
      expect(key('order-before-s3'), findsNothing);
      await tap(tester, key('order-before-s2'));
      await tap(tester, key('save-library-order'));
      expect(runtime.sent('sessionReorder').single.$2, {
        'workspaceId': 'w1',
        'sessionId': 's1',
        'beforeSessionId': 's2',
      });
      await close(tester);
      await show(
        tester,
        LibraryOrderPage(library: runtime.library, workspaceId: 'w1'),
      );
      await tap(tester, key('order-before-w2'));
      await tap(tester, key('save-library-order'));
      expect(runtime.sent('workspaceReorder').single.$2, {
        'workspaceId': 'w1',
        'beforeWorkspaceId': 'w2',
      });
      await close(tester);
    },
  );

  testWidgets(
    'a disconnected stream disables writes and reopens closed observations',
    (tester) async {
      final runtime = LibraryRuntime();
      await prepare(tester, runtime);
      await show(
        tester,
        LibraryWorkspacePage(library: runtime.library, workspaceId: 'w1'),
      );
      runtime.emit('workspace', {'type': 'end'});
      await settle(tester);
      expect(runtime.library.synchronized, isFalse);
      expect(find.textContaining('未同步'), findsOneWidget);
      expect(
        tester.widget<PocketButton>(key('workspace-new-session')).onPressed,
        isNull,
      );
      await runtime.library.refresh(reconnect: true);
      await settle(tester);
      expect(runtime.library.synchronized, isTrue);
      expect(runtime.watches, hasLength(4));
      expect(runtime.sent('sessionCreate'), isEmpty);
      await close(tester);
    },
  );

  testWidgets('stale catalog cannot overwrite a newer authoritative read', (
    tester,
  ) async {
    final runtime = LibraryRuntime();
    await prepare(tester, runtime);
    final old = Completer<Json>();
    final before = copy(runtime.catalog);
    runtime.handlers['library.catalog'] = (_) => old.future;
    final oldRead = runtime.library.refresh();
    expect(runtime.library.canWrite, isFalse);
    runtime.handlers.remove('library.catalog');
    runtime.row('s1')['projections']['values']['title'] = '确认的新名称';
    await runtime.library.refresh();
    old.complete(before);
    await oldRead;
    expect(librarySessionTitle(runtime.library.session('s1')!), '确认的新名称');
    expect(runtime.library.synchronized, isTrue);
    await settle(tester);
  });

  testWidgets(
    'unknown fork and old connection receipts never resend or fabricate IDs',
    (tester) async {
      final runtime = LibraryRuntime();
      await prepare(tester, runtime);
      final pending = Completer<Json>();
      runtime.handlers['library.sessionFork'] = (_) => pending.future;
      final action = runtime.library.mutate('fork:s1', 'sessionFork', {
        'sessionId': 's1',
      });
      runtime.changeConnection('failed');
      runtime.changeConnection('ready', epoch: 'replacement');
      await settle(tester);
      pending.complete({'sessionId': 'old-connection-id'});
      expect(await action, isNull);
      expect(runtime.library.actions['fork:s1']?.state, 'unconfirmed');
      expect(runtime.library.actions['fork:s1']?.result, isEmpty);
      await show(
        tester,
        LibrarySessionPage(library: runtime.library, sessionId: 's1'),
      );
      expect(
        tester.widget<PocketButton>(key('session-fork')).onPressed,
        isNull,
      );
      await runtime.library.refresh(reconnect: true);
      await close(tester);
      await show(
        tester,
        LibrarySessionPage(library: runtime.library, sessionId: 's1'),
      );
      expect(runtime.sent('sessionFork'), hasLength(1));
      expect(
        tester.widget<PocketButton>(key('session-fork')).onPressed,
        isNull,
      );
      await close(tester);
    },
  );

  testWidgets(
    'definite validation refusals allow correction but missing receipts do not',
    (tester) async {
      final runtime = LibraryRuntime();
      await prepare(tester, runtime);
      for (final code in [
        'session/fork-unavailable',
        'session/migration-required',
        'workspace/not-found',
        'gateway/arguments-invalid',
        'directory-picker/create-failed',
        'agent-preset/conflict',
      ]) {
        runtime.handlers['library.sessionFork'] = (_) async =>
            throw PlatformException(code: code);
        await runtime.library.mutate('failure:$code', 'sessionFork', {
          'sessionId': 's1',
        });
        expect(
          runtime.library.actions['failure:$code']?.state,
          'rejected',
          reason: code,
        );
        expect(runtime.library.allowed('failure:$code'), isTrue);
      }
      runtime.handlers['library.sessionFork'] = (_) async =>
          <String, dynamic>{};
      await runtime.library.mutate('missing', 'sessionFork', {
        'sessionId': 's1',
      });
      expect(runtime.library.actions['missing']?.state, 'unconfirmed');
      expect(runtime.library.allowed('missing'), isFalse);
      await settle(tester);
    },
  );

  testWidgets(
    'created fork with failed title keeps child ID and blocks retry',
    (tester) async {
      final runtime = LibraryRuntime();
      await prepare(tester, runtime);
      runtime.handlers['library.sessionFork'] = (_) async =>
          throw PlatformException(
            code: 'session/fork-title-failed',
            details: {
              'sessionId': 'created-child',
              'cause': 'session/title-invalid',
            },
          );
      expect(
        await runtime.library.mutate('fork:s1:7', 'sessionFork', {
          'sessionId': 's1',
          'atSeq': 7,
          'increaseTitle': true,
        }),
        isNull,
      );
      final action = runtime.library.actions['fork:s1:7'];
      expect(action?.state, 'partial');
      expect(action?.result['sessionId'], 'created-child');
      expect(action?.message, contains('created-child'));
      expect(runtime.library.allowed('fork:s1:7'), isFalse);
      expect(runtime.sent('sessionFork'), hasLength(1));
      await settle(tester);
    },
  );

  testWidgets(
    'routine runtime updates and token projections do not reread the catalog',
    (tester) async {
      final runtime = LibraryRuntime();
      await prepare(tester, runtime);
      final reads = runtime.reads;
      runtime.useModelSelection(provider: 'test', model: 'test');
      runtime.emit('session', {
        'type': 'item',
        'value': {'type': 'projection', 'key': 'messages', 'sessionId': 's1'},
      });
      await settle(tester);
      expect(runtime.reads, reads);
      runtime.sessions = [];
      runtime.useModelSelection(provider: 'test', model: 'test2');
      await settle(tester);
      expect(runtime.reads, reads + 1);
    },
  );

  testWidgets(
    'observed changes block writes during debounce and refresh until a fresh catalog arrives',
    (tester) async {
      final runtime = LibraryRuntime();
      await prepare(tester, runtime);
      final fresh = Completer<Json>();
      runtime.handlers['library.catalog'] = (_) => fresh.future;
      runtime.emit('workspace', {
        'type': 'item',
        'value': {'type': 'upsert'},
      });
      await tester.pump();
      expect(runtime.library.canWrite, isFalse);
      await runtime.library.mutate('create', 'sessionCreate', {
        'workspaceId': 'w1',
      });
      expect(runtime.sent('sessionCreate'), isEmpty);
      await tester.pump(const Duration(milliseconds: 150));
      expect(runtime.library.loading, isTrue);
      expect(runtime.library.canWrite, isFalse);
      fresh.complete(copy(runtime.catalog));
      await settle(tester);
      expect(runtime.library.canWrite, isTrue);
    },
  );

  testWidgets(
    'read failure preserves old rows but withdraws synchronization until explicit recovery',
    (tester) async {
      final runtime = LibraryRuntime();
      await prepare(tester, runtime);
      runtime.handlers['library.catalog'] = (_) async =>
          throw PlatformException(code: 'unavailable');
      await runtime.library.refresh();
      expect(runtime.library.synchronized, isFalse);
      expect(runtime.library.readError, contains('unavailable'));
      expect(runtime.library.workspace('w1')?['title'], '项目一');
      expect(runtime.library.allowed('fork:s1'), isFalse);
      runtime.handlers.remove('library.catalog');
      await runtime.library.refresh();
      expect(runtime.library.synchronized, isTrue);
      expect(runtime.library.readError, isNull);
      await settle(tester);
    },
  );

  testWidgets('phone layout preserves the editable name after a failed save', (
    tester,
  ) async {
    final runtime = LibraryRuntime();
    runtime.handlers['library.workspaceRename'] = (_) async =>
        throw PlatformException(code: 'gateway/internal');
    await prepare(tester, runtime);
    tester.view.physicalSize = const Size(390, 844);
    await show(
      tester,
      LibraryRenamePage(library: runtime.library, id: 'w1', workspace: true),
    );
    await tester.enterText(key('library-title'), '保留这段工作区名称');
    await tap(tester, key('save-library-title'));
    expect(tester.takeException(), isNull);
    await close(tester);
    await show(
      tester,
      LibraryRenamePage(library: runtime.library, id: 'w1', workspace: true),
    );
    expect(
      tester.widget<TextField>(key('library-title')).controller!.text,
      '保留这段工作区名称',
    );
    expect(
      tester.widget<PocketButton>(key('save-library-title')).onPressed,
      isNull,
    );
    await close(tester);
  });
}

List<dynamic> catalogIds(LibraryRuntime runtime, String key) =>
    runtime.catalog[key] as List;
