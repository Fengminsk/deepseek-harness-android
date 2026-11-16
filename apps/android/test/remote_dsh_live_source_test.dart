// 远程首页数据源的纯函数与 `library.*` 门面行为。
//
// 这里不连宿主、不拨号：`RemoteDshFacade` 只接收 `RuntimeTransport`，测试用一个
// 记录请求并注入应答的假传输提供 `library.catalog` / `library.sessionCreate` /
// `library.sessionArchive` 的结果，因此工作区选择、目录缓存与归档标题连接都可以
// 在没有 PC 的情况下验证；页面本身由 remote_dsh_home_page_test.dart 覆盖。

import 'dart:async';

import 'package:dsh_android/remote_dsh_live_source.dart';
import 'package:dsh_android/runtime_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录请求并按方法给出应答的传输替身。
///
/// 没有配置应答的方法返回空对象；应答工厂抛出的异常原样变成请求失败。
class _RecordingTransport implements RuntimeTransport {
  _RecordingTransport(this.answers);

  /// 每个方法的应答工厂。
  final Map<String, Object? Function(Map<String, dynamic> params)> answers;

  /// 按调用顺序记录的方法名与参数。
  final List<({String method, Map<String, dynamic> params})> requests =
      <({String method, Map<String, dynamic> params})>[];

  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);

  /// 某个方法的全部参数。
  List<Map<String, dynamic>> paramsOf(String method) => [
    for (final request in requests)
      if (request.method == method) request.params,
  ];

  /// 某个方法的调用次数。
  int countOf(String method) =>
      requests.where((request) => request.method == method).length;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) async {
    requests.add((method: method, params: Map<String, dynamic>.of(params)));
    final answer = answers[method];
    if (answer != null) return answer(params);
    return <String, dynamic>{};
  }

  @override
  void notify(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) {}

  @override
  void setRequestHandler(
    Future<dynamic> Function(String method, Map<String, dynamic> params)?
    handler,
  ) {}

  @override
  Future<void> close() async {}
}

/// 一份最小的 `library.catalog` 应答。
Map<String, dynamic> _catalog({
  List<Map<String, dynamic>>? workspaces,
  List<Map<String, dynamic>>? sessions,
  List<String> archived = const <String>[],
  String defaultDirectory = r'C:\work\pocket',
}) => <String, dynamic>{
  'workspaces':
      workspaces ??
      <Map<String, dynamic>>[
        <String, dynamic>{
          'workspaceId': 'w-pocket',
          'path': r'C:\work\pocket',
          'title': 'Pocket',
          'sessionIds': <String>[],
        },
        <String, dynamic>{
          'workspaceId': 'w-cars',
          'path': r'C:\work\cars',
          'title': '',
          'sessionIds': <String>[],
        },
      ],
  'sessions': sessions ?? <Map<String, dynamic>>[],
  'archivedSessionIds': archived,
  'pinnedSessionIds': <String>[],
  'defaultDirectory': defaultDirectory,
  'capabilities': <String, dynamic>{'crossWorkspaceMove': false},
};

/// 一条目录里的会话记录。
Map<String, dynamic> _session(
  String id,
  String title, {
  String cwd = r'C:\work\pocket',
}) => <String, dynamic>{
  'sessionId': id,
  'cwd': cwd,
  'projections': <String, dynamic>{
    'values': <String, dynamic>{'title': title},
  },
};

/// 一组工作区。
List<RemoteDshWorkspace> _workspaces() => const <RemoteDshWorkspace>[
  RemoteDshWorkspace(id: 'w-pocket', path: r'C:\work\pocket', title: 'Pocket'),
  RemoteDshWorkspace(id: 'w-cars', path: r'C:\work\cars'),
];

void main() {
  group('选择新会话的工作区', () {
    test('优先默认目录对应的工作区', () {
      expect(
        chooseRemoteDshWorkspace(_workspaces(), r'C:\work\cars')?.id,
        'w-cars',
      );
    });

    test('默认目录没有对应工作区时退回第一个', () {
      expect(
        chooseRemoteDshWorkspace(_workspaces(), r'C:\work\elsewhere')?.id,
        'w-pocket',
      );
      expect(chooseRemoteDshWorkspace(_workspaces())?.id, 'w-pocket');
    });

    test('路径分隔符与末尾分隔符不影响匹配', () {
      expect(
        chooseRemoteDshWorkspace(_workspaces(), r'C:/work/cars/')?.id,
        'w-cars',
        reason: '宿主给的默认目录与工作区路径可能用不同的分隔符拼接',
      );
    });

    test('没有任何工作区时返回 null', () {
      expect(
        chooseRemoteDshWorkspace(const <RemoteDshWorkspace>[], r'C:\work'),
        isNull,
      );
    });
  });

  group('解析 library.catalog', () {
    test('读出工作区、会话标题、归档集合与默认目录', () {
      final catalog = parseRemoteDshCatalog(
        _catalog(
          sessions: <Map<String, dynamic>>[
            _session('s-1', '修复登录'),
            _session('a-1', '旧任务'),
          ],
          archived: <String>['a-1'],
        ),
      );
      expect(catalog.workspaces, hasLength(2));
      expect(catalog.workspaces.first.name, 'Pocket');
      expect(catalog.workspaces.last.name, 'cars', reason: '工作区没有标题时取目录最后一段');
      expect(catalog.session('s-1')?.displayTitle, '修复登录');
      expect(catalog.archivedSessionIds, <String>['a-1']);
      expect(catalog.defaultDirectory, r'C:\work\pocket');
    });

    test('跳过缺标识的坏记录，不让一条脏数据挡住整页', () {
      final catalog = parseRemoteDshCatalog(
        _catalog(
          workspaces: <Map<String, dynamic>>[
            <String, dynamic>{'path': r'C:\no-id'},
            <String, dynamic>{
              'workspaceId': 'w-ok',
              'path': r'C:\work\ok',
              'title': 'OK',
              'sessionIds': <String>[],
            },
          ],
          sessions: <Map<String, dynamic>>[
            <String, dynamic>{'projections': <String, dynamic>{}},
            _session('s-ok', '可用会话'),
          ],
        ),
      );
      expect(catalog.workspaces.map((workspace) => workspace.id), <String>[
        'w-ok',
      ]);
      expect(catalog.sessions.map((session) => session.id), <String>['s-ok']);
    });

    test('顶层不是对象时抛可重试的读取失败', () {
      expect(
        () => parseRemoteDshCatalog(<dynamic>['not', 'a', 'map']),
        throwsA(
          isA<PlatformException>().having(
            (failure) => failure.code,
            'code',
            'remote/bad-response',
          ),
        ),
      );
    });
  });

  group('新建会话的门面调用', () {
    test('项目编辑入口只在指定工作区创建', () async {
      final transport = _RecordingTransport(
        <String, Object? Function(Map<String, dynamic>)>{
          'library.catalog': (_) => _catalog(),
          'library.sessionCreate': (_) => <String, dynamic>{
            'sessionId': 's-new',
          },
        },
      );
      final facade = RemoteDshFacade(transport);
      await facade.createSession(projectId: r'cwd:C:\work\cars');
      expect(
        transport.paramsOf('library.sessionCreate'),
        <Map<String, dynamic>>[
          <String, dynamic>{'workspaceId': 'w-cars'},
        ],
      );

      await expectLater(
        facade.createSession(projectId: r'cwd:C:\work\missing'),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'remote/project-unavailable',
          ),
        ),
      );
      expect(transport.countOf('library.sessionCreate'), 1);
    });

    test('默认目录的工作区新建会话，随后作废目录缓存', () async {
      final transport = _RecordingTransport(
        <String, Object? Function(Map<String, dynamic>)>{
          'library.catalog': (_) => _catalog(defaultDirectory: r'C:\work\cars'),
          'library.sessionCreate': (_) => <String, dynamic>{
            'sessionId': 's-new',
            'agentPreset': 'standard',
          },
        },
      );
      final facade = RemoteDshFacade(transport);

      expect((await facade.catalog()).workspaces, hasLength(2));
      expect((await facade.catalog()).workspaces, hasLength(2));
      expect(
        transport.countOf('library.catalog'),
        1,
        reason: '同一传输内缓存目录，避免每次新建都重读',
      );

      final created = await facade.createSession();
      expect(created.sessionId, 's-new');
      expect(created.projectName, 'cars');
      expect(
        transport.paramsOf('library.sessionCreate'),
        <Map<String, dynamic>>[
          <String, dynamic>{'workspaceId': 'w-cars'},
        ],
      );

      // 新建成功后目录缓存作废：下一次读取拿到包含新会话的目录。
      await facade.createSession();
      expect(transport.countOf('library.catalog'), 2);
    });

    test('电脑上没有任何项目时抛专用异常且不发写请求', () async {
      final transport = _RecordingTransport(
        <String, Object? Function(Map<String, dynamic>)>{
          'library.catalog': (_) =>
              _catalog(workspaces: <Map<String, dynamic>>[]),
        },
      );
      final facade = RemoteDshFacade(transport);
      await expectLater(
        facade.createSession(),
        throwsA(isA<RemoteDshNoWorkspaceException>()),
      );
      expect(transport.countOf('library.sessionCreate'), 0);
    });

    test('电脑拒绝新建时把宿主消息原样带出', () async {
      final transport = _RecordingTransport(
        <String, Object? Function(Map<String, dynamic>)>{
          'library.catalog': (_) => _catalog(),
          'library.sessionCreate': (_) => throw const RuntimeTransportFailure(
            code: 'workspace/session-active',
            message: '该项目正在执行任务，暂时不能新建会话。',
          ),
        },
      );
      final facade = RemoteDshFacade(transport);
      await expectLater(
        facade.createSession(),
        throwsA(
          isA<PlatformException>()
              .having(
                (failure) => failure.code,
                'code',
                'workspace/session-active',
              )
              .having(
                (failure) => failure.message,
                'message',
                '该项目正在执行任务，暂时不能新建会话。',
              ),
        ),
      );
    });

    test('新建应答缺少会话标识时视为坏响应', () async {
      final transport = _RecordingTransport(
        <String, Object? Function(Map<String, dynamic>)>{
          'library.catalog': (_) => _catalog(),
          'library.sessionCreate': (_) => <String, dynamic>{
            'agentPreset': 'standard',
          },
        },
      );
      final facade = RemoteDshFacade(transport);
      await expectLater(
        facade.createSession(),
        throwsA(
          isA<PlatformException>().having(
            (failure) => failure.code,
            'code',
            'remote/bad-response',
          ),
        ),
      );
    });

    test('宿主不支持的方法在错误里点名该方法', () async {
      final transport = _RecordingTransport(
        <String, Object? Function(Map<String, dynamic>)>{
          'library.catalog': (_) => throw const RuntimeTransportFailure(
            code: 'unsupported-method',
            message: 'unsupported',
          ),
        },
      );
      final facade = RemoteDshFacade(transport);
      await expectLater(
        facade.catalog(),
        throwsA(
          isA<PlatformException>()
              .having((failure) => failure.code, 'code', 'unsupported-method')
              .having(
                (failure) => failure.message,
                'message',
                contains('library.catalog'),
              ),
        ),
      );
    });
  });

  group('已归档会话的门面调用', () {
    test('按归档集合连接会话标题与项目名', () async {
      final transport = _RecordingTransport(
        <String, Object? Function(Map<String, dynamic>)>{
          'library.catalog': (_) => _catalog(
            sessions: <Map<String, dynamic>>[
              _session('a-1', '旧任务'),
              _session('a-2', '', cwd: r'C:\work\unknown'),
            ],
            archived: <String>['a-1', 'a-2', 'a-missing'],
          ),
        },
      );
      final facade = RemoteDshFacade(transport);
      final archived = await facade.listArchivedSessions();
      expect(archived.map((session) => session.id), <String>[
        'a-1',
        'a-2',
        'a-missing',
      ]);
      expect(archived[0].title, '旧任务');
      expect(archived[0].projectName, 'Pocket');
      expect(archived[1].title, '未命名会话', reason: '没有标题的归档会话用占位文案，仍可打开与恢复');
      expect(archived[1].projectName, 'unknown');
      expect(archived[2].title, '未命名会话', reason: '归档集合里可能有目录还没投影到的会话');
    });

    test('恢复走 archived:false 并作废目录缓存', () async {
      final transport = _RecordingTransport(
        <String, Object? Function(Map<String, dynamic>)>{
          'library.catalog': (_) => _catalog(
            sessions: <Map<String, dynamic>>[_session('a-1', '旧任务')],
            archived: <String>['a-1'],
          ),
          'library.sessionArchive': (_) => <String, dynamic>{
            'archivedSessionIds': <String>[],
          },
        },
      );
      final facade = RemoteDshFacade(transport);
      expect(await facade.listArchivedSessions(), hasLength(1));
      await facade.restoreSession('a-1');
      expect(
        transport.paramsOf('library.sessionArchive'),
        <Map<String, dynamic>>[
          <String, dynamic>{'sessionId': 'a-1', 'archived': false},
        ],
      );
      // 缓存已作废：再读目录会重新问电脑（恢复后的归档集合才是事实）。
      await facade.listArchivedSessions();
      expect(transport.countOf('library.catalog'), 2);
    });

    test('打开归档页时重读目录，不复用新建会话留下的缓存', () async {
      final transport = _RecordingTransport(
        <String, Object? Function(Map<String, dynamic>)>{
          'library.catalog': (_) => _catalog(
            sessions: <Map<String, dynamic>>[_session('a-1', '旧任务')],
            archived: <String>['a-1'],
          ),
        },
      );
      final facade = RemoteDshFacade(transport);
      await facade.catalog();
      await facade.listArchivedSessions();
      expect(
        transport.countOf('library.catalog'),
        2,
        reason: '归档集合可能在这台手机之外被改动，打开归档页必须问电脑',
      );
    });
  });
}
