// 远程首页：头部搜索过滤、输入条新建会话、已归档任务入口。
//
// 这些测试不连宿主、不拨号：首页数据源是下面的假实现，它同时提供本文件要验证的
// 两个可选能力（新建会话、已归档会话）。打开会话时页面会构造真实会话数据源，
// 但假数据源报告连接就绪、页面自建的连接控制器仍是空闲态，因此不会发出请求。

import 'dart:async';

import 'package:dsh_android/remote_dsh_archived_page.dart';
import 'package:dsh_android/remote_dsh_conversation.dart';
import 'package:dsh_android/remote_dsh_live_source.dart';
import 'package:dsh_android/remote_dsh_page.dart';
import 'package:dsh_android/remote_dsh_widgets.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'library_test.dart' show LibraryRuntime;

/// 首页假数据源：一台在线电脑、可配置的项目与会话，以及新建/归档能力。
class _HomeSource
    implements
        RemoteDshDataSource,
        RemoteDshSessionCreator,
        RemoteDshArchiveSource {
  _HomeSource({
    required this.projects,
    this.projectsAfterCreate,
    this.archived = const <RemoteDshArchivedSession>[],
    this.createGate,
    this.createError,
  });

  /// 当前项目列表。
  List<RemoteDshProject> projects;

  /// 新建会话后 [listProjects] 返回的列表；为 null 时不变。
  final List<RemoteDshProject>? projectsAfterCreate;

  /// 已归档会话。
  List<RemoteDshArchivedSession> archived;

  /// 新建会话的等待门；用来观察「新建中」的忙碌态。
  final Completer<void>? createGate;

  /// 新建会话抛出的失败。
  Object? createError;

  int createCalls = 0;
  int archivedCalls = 0;
  final List<String> restored = <String>[];

  @override
  RemoteDshConnectionState get connection => RemoteDshConnectionState.connected;

  @override
  String? get hostName => '客厅的电脑';

  @override
  Future<List<RemoteDshDevice>> listDevices() async => const <RemoteDshDevice>[
    RemoteDshDevice(
      id: 'device-1',
      label: '客厅的电脑',
      state: RemoteDshDeviceState.online,
    ),
  ];

  @override
  Future<List<RemoteDshProject>> listProjects() async => projects;

  @override
  Future<RemoteDshCreatedSession> createSession() async {
    createCalls++;
    final gate = createGate;
    if (gate != null) await gate.future;
    final error = createError;
    if (error != null) throw error;
    final after = projectsAfterCreate;
    if (after != null) projects = after;
    return const RemoteDshCreatedSession(
      sessionId: 's-new',
      projectName: 'Pocket',
    );
  }

  @override
  Future<List<RemoteDshArchivedSession>> listArchivedSessions() async {
    archivedCalls++;
    return List<RemoteDshArchivedSession>.of(archived);
  }

  @override
  Future<void> restoreSession(String sessionId) async {
    restored.add(sessionId);
    archived = <RemoteDshArchivedSession>[
      for (final session in archived)
        if (session.id != sessionId) session,
    ];
  }
}

/// 只读首页假数据源：没有新建会话与归档能力。
class _ReadOnlySource implements RemoteDshDataSource {
  _ReadOnlySource(this.projects);

  final List<RemoteDshProject> projects;

  @override
  RemoteDshConnectionState get connection => RemoteDshConnectionState.connected;

  @override
  String? get hostName => '客厅的电脑';

  @override
  Future<List<RemoteDshDevice>> listDevices() async =>
      const <RemoteDshDevice>[];

  @override
  Future<List<RemoteDshProject>> listProjects() async => projects;
}

/// 还未连上电脑的首页假数据源：输入条应整体不可用并说明先连接。
class _OfflineSource implements RemoteDshDataSource {
  @override
  RemoteDshConnectionState get connection =>
      RemoteDshConnectionState.notConnected;

  @override
  String? get hostName => null;

  @override
  Future<List<RemoteDshDevice>> listDevices() async =>
      const <RemoteDshDevice>[];

  @override
  Future<List<RemoteDshProject>> listProjects() async =>
      const <RemoteDshProject>[];
}

/// 记录每次推入的路由名。
class _RouteLog extends NavigatorObserver {
  final List<String?> names = <String?>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    names.add(route.settings.name);
  }
}

/// 会话行与项目的最小夹具。
List<RemoteDshProject> _projects() => const <RemoteDshProject>[
  RemoteDshProject(
    id: 'cwd:Pocket',
    deviceId: 'device-1',
    name: 'Pocket',
    sessions: <RemoteDshSession>[
      RemoteDshSession(id: 's-1', title: '修复登录'),
      RemoteDshSession(id: 's-2', title: '构建失败'),
    ],
  ),
  RemoteDshProject(
    id: 'cwd:CarsTool',
    deviceId: 'device-1',
    name: 'CarsTool',
    sessions: <RemoteDshSession>[RemoteDshSession(id: 's-3', title: '调整雷达')],
  ),
];

/// 首页上的会话行查找器。
Finder _sessionRow(String id) => find.byKey(ValueKey('remote-session-$id'));

/// 输入条里的文本框。
Finder _composerField() => find.descendant(
  of: find.byKey(const ValueKey('remote-composer')),
  matching: find.byType(TextField),
);

Future<_RouteLog> _show(
  WidgetTester tester,
  RemoteDshDataSource source, {
  RemoteDshArchiveSource? archivedSource,
}) async {
  final runtime = LibraryRuntime();
  addTearDown(runtime.dispose);
  final log = _RouteLog();
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      navigatorObservers: <NavigatorObserver>[log],
      home: RemoteDshPage(
        runtime: runtime,
        source: source,
        archivedSource: archivedSource,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return log;
}

Future<void> _openSearch(WidgetTester tester) async {
  await tester.tap(find.byTooltip('搜索会话'));
  await tester.pumpAndSettle();
}

Future<void> _enterSearch(WidgetTester tester, String query) async {
  await tester.enterText(
    find.byKey(const ValueKey('remote-home-search-field')),
    query,
  );
  await tester.pump();
}

void main() {
  group('头部搜索', () {
    testWidgets('按会话标题过滤，大小写不敏感的包含匹配', (tester) async {
      await _show(tester, _HomeSource(projects: _projects()));
      await _openSearch(tester);

      expect(
        find.byKey(const ValueKey('remote-home-search-field')),
        findsOneWidget,
      );
      await _enterSearch(tester, '构建');

      expect(_sessionRow('s-2'), findsOneWidget, reason: '标题匹配的会话保留');
      expect(_sessionRow('s-1'), findsNothing, reason: '其余会话被过滤');
      expect(_sessionRow('s-3'), findsNothing, reason: '没有匹配会话的项目隐藏');
      expect(find.text('Pocket'), findsOneWidget, reason: '保留会话所属项目');

      await _enterSearch(tester, 'cars');
      expect(find.text('CarsTool'), findsOneWidget);
      expect(_sessionRow('s-3'), findsOneWidget);
      expect(find.text('Pocket'), findsNothing, reason: '已忽略大小写');

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('没有匹配时给出「没有匹配的会话」空态', (tester) async {
      await _show(tester, _HomeSource(projects: _projects()));
      await _openSearch(tester);
      await _enterSearch(tester, '不存在的关键词');

      expect(find.text('没有匹配的会话'), findsOneWidget);
      expect(_sessionRow('s-1'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('清空输入恢复完整列表，关闭搜索回到标题头', (tester) async {
      await _show(tester, _HomeSource(projects: _projects()));
      await _openSearch(tester);
      await _enterSearch(tester, '构建');
      expect(_sessionRow('s-1'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('remote-home-search-clear')));
      await tester.pumpAndSettle();
      expect(_sessionRow('s-1'), findsOneWidget);
      expect(_sessionRow('s-3'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('remote-home-search-field')),
        findsOneWidget,
        reason: '清空只恢复列表，保持搜索模式',
      );

      await _enterSearch(tester, '构建');
      await tester.tap(find.byKey(const ValueKey('remote-home-search-close')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('remote-home-search-field')),
        findsNothing,
      );
      expect(find.text('远程 DSH'), findsOneWidget);
      expect(_sessionRow('s-1'), findsOneWidget, reason: '关闭搜索恢复完整列表');

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('系统返回键先收起搜索，不离开远程首页', (tester) async {
      await _show(tester, _HomeSource(projects: _projects()));
      await _openSearch(tester);
      await _enterSearch(tester, '构建');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('remote-home-search-field')),
        findsNothing,
        reason: '返回键应只关闭搜索',
      );
      expect(find.text('远程 DSH'), findsOneWidget, reason: '远程首页仍在栈上');
      expect(_sessionRow('s-1'), findsOneWidget, reason: '关闭搜索恢复完整列表');

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  });

  group('输入条新建会话', () {
    testWidgets('提交草稿在电脑上新建会话并打开它', (tester) async {
      final projects = _projects();
      final source = _HomeSource(
        projects: projects,
        projectsAfterCreate: <RemoteDshProject>[
          RemoteDshProject(
            id: 'cwd:Pocket',
            deviceId: 'device-1',
            name: 'Pocket',
            sessions: <RemoteDshSession>[
              ...projects.first.sessions,
              const RemoteDshSession(id: 's-new', title: '新建的会话'),
            ],
          ),
          projects.last,
        ],
      );
      final log = await _show(tester, source);

      await tester.enterText(_composerField(), '  新建一个会话  ');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('remote-home-send')),
        findsOneWidget,
        reason: '有草稿时才出现发送按钮',
      );

      await tester.tap(find.byKey(const ValueKey('remote-home-send')));
      await tester.pumpAndSettle();

      expect(source.createCalls, 1);
      expect(log.names, contains(destinationRouteName('remote-session:s-new')));
      expect(find.byType(RemoteDshConversationPage), findsOneWidget);
      expect(
        find.text('新建的会话'),
        findsOneWidget,
        reason: '刷新后的列表里有新会话时用电脑投影的标题打开',
      );
      final composer = tester.widget<RemoteComposer>(
        find.byType(RemoteComposer).first,
      );
      expect(composer.controller?.text, isEmpty, reason: '新建受理后清空草稿');

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('新建期间显示忙碌态并禁止重复提交', (tester) async {
      final gate = Completer<void>();
      final source = _HomeSource(projects: _projects(), createGate: gate);
      final log = await _show(tester, source);

      await tester.enterText(_composerField(), '排队新建');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('remote-home-send')));
      await tester.pump();

      final composer = tester.widget<RemoteComposer>(
        find.byType(RemoteComposer).first,
      );
      expect(composer.enabled, isFalse, reason: '新建期间输入条不可用');
      expect(
        tester
            .widget<GlassButton>(find.byKey(const ValueKey('remote-home-send')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('remote-home-send')));
      await tester.pump();
      expect(source.createCalls, 1, reason: '忙碌期间再点不会重复新建');

      gate.complete();
      await tester.pumpAndSettle();
      expect(source.createCalls, 1);
      expect(log.names, contains(destinationRouteName('remote-session:s-new')));

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('电脑上还没有项目时给出可见提示', (tester) async {
      final source = _HomeSource(
        projects: _projects(),
        createError: const RemoteDshNoWorkspaceException(),
      );
      final log = await _show(tester, source);

      await tester.enterText(_composerField(), '随便说点什么');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('remote-home-send')));
      await tester.pumpAndSettle();

      expect(find.text('这台电脑上还没有项目'), findsOneWidget);
      expect(find.byType(RemoteDshConversationPage), findsNothing);
      expect(
        log.names,
        isNot(contains(destinationRouteName('remote-session:s-new'))),
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('新建失败时把电脑返回的消息显示成提示', (tester) async {
      final source = _HomeSource(
        projects: _projects(),
        createError: PlatformException(
          code: 'workspace/session-active',
          message: '该项目正在执行任务，暂时不能新建会话。',
        ),
      );
      await _show(tester, source);

      await tester.enterText(_composerField(), '再开一个');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('remote-home-send')));
      await tester.pumpAndSettle();

      expect(find.text('该项目正在执行任务，暂时不能新建会话。'), findsOneWidget);
      final composer = tester.widget<RemoteComposer>(
        find.byType(RemoteComposer).first,
      );
      expect(composer.controller?.text, '再开一个', reason: '失败时保留草稿，用户可以直接重试');

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('只读数据源提交时给出「暂未开放」而不是静默失效', (tester) async {
      await _show(tester, _ReadOnlySource(_projects()));

      await tester.enterText(_composerField(), '能新建吗');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('remote-home-send')));
      await tester.pumpAndSettle();

      expect(find.textContaining('「新建会话」暂未开放'), findsOneWidget);
      expect(find.byType(RemoteDshConversationPage), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  });

  group('已归档任务入口', () {
    testWidgets('菜单项打开带稳定目的地标识的归档页', (tester) async {
      final source = _HomeSource(
        projects: _projects(),
        archived: const <RemoteDshArchivedSession>[
          RemoteDshArchivedSession(
            id: 'a-1',
            title: '旧任务',
            projectName: 'Pocket',
          ),
        ],
      );
      final log = await _show(tester, source);

      await tester.tap(find.text('远程 DSH'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已归档任务'));
      await tester.pumpAndSettle();

      expect(
        log.names,
        contains(destinationRouteName(RemoteDshArchivedPage.routeDestination)),
        reason: '归档页是独立的全屏目的地，必须走 openDestination',
      );
      expect(find.byType(RemoteDshArchivedPage), findsOneWidget);
      expect(find.text('旧任务'), findsOneWidget);
      expect(source.archivedCalls, 1);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('归档页点会话走与首页相同的会话目的地', (tester) async {
      final source = _HomeSource(
        projects: _projects(),
        archived: const <RemoteDshArchivedSession>[
          RemoteDshArchivedSession(
            id: 'a-1',
            title: '旧任务',
            projectName: 'Pocket',
          ),
        ],
      );
      final log = await _show(tester, source);

      await tester.tap(find.text('远程 DSH'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已归档任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('remote-archived-a-1')));
      await tester.pumpAndSettle();

      expect(log.names, contains(destinationRouteName('remote-session:a-1')));
      expect(find.byType(RemoteDshConversationPage), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('数据源不支持归档时菜单项给出可见提示', (tester) async {
      await _show(tester, _ReadOnlySource(_projects()));

      await tester.tap(find.text('远程 DSH'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已归档任务'));
      await tester.pumpAndSettle();

      expect(find.byType(RemoteDshArchivedPage), findsNothing);
      expect(find.textContaining('「已归档任务」暂未开放'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  });

  group('输入条会话外能力说明', () {
    /// 输入条里某个按钮的 IconButton 控件；按钮不可点时 `onPressed` 为 null。
    IconButton circleButton(WidgetTester tester, String tooltip) =>
        tester.widget<IconButton>(
          find.ancestor(
            of: find.byTooltip(tooltip),
            matching: find.byType(IconButton),
          ),
        );

    testWidgets('已连接时加号、权限与模型置灰，并说明进入会话后可用', (tester) async {
      await _show(tester, _HomeSource(projects: _projects()));

      expect(
        find.byKey(const ValueKey('remote-composer-hint')),
        findsOneWidget,
      );
      expect(
        find.text('进入会话后可添加附件与指令、切换权限预设与选择模型'),
        findsOneWidget,
        reason: '会话外的不可用能力统一给可操作说明',
      );

      for (final tooltip in ['添加与指令', '权限预设', '选择模型']) {
        expect(
          circleButton(tester, tooltip).onPressed,
          isNull,
          reason: '$tooltip 在首页没有数据源，必须置灰',
        );
      }

      // 不再是「能点但没用」的入口：点按不弹「暂未开放」提示，也不跳页。
      for (final tooltip in ['添加与指令', '权限预设', '选择模型']) {
        await tester.tap(find.byTooltip(tooltip), warnIfMissed: false);
      }
      await tester.pumpAndSettle();
      expect(find.textContaining('暂未开放'), findsNothing);
      expect(find.textContaining('添加内容'), findsNothing);
      expect(find.byType(RemoteDshConversationPage), findsNothing);

      // 语音入口已删除（§4.4 语音不做），不能留死按钮。
      expect(find.byTooltip('语音输入'), findsNothing);
      expect(find.byIcon(Icons.mic_rounded), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('未连接时输入条整体不可用并说明先连接', (tester) async {
      await _show(tester, _OfflineSource());

      final composer = tester.widget<RemoteComposer>(
        find.byType(RemoteComposer).first,
      );
      expect(composer.enabled, isFalse);
      expect(find.text('连接后可输入消息并新建会话'), findsOneWidget, reason: '未连接时说明连接的作用');
      for (final tooltip in ['添加与指令', '权限预设', '选择模型']) {
        expect(
          circleButton(tester, tooltip).onPressed,
          isNull,
          reason: '$tooltip 在未连接时不可点',
        );
      }

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  });

  group('搜索过滤', () {
    test('空查询原样返回列表', () {
      final projects = _projects();
      expect(filterRemoteProjects(projects, '   '), same(projects));
    });

    test('项目名匹配时保留该项目的全部会话', () {
      final filtered = filterRemoteProjects(_projects(), 'pocket');
      expect(filtered, hasLength(1));
      expect(filtered.single.name, 'Pocket');
      expect(filtered.single.sessions, hasLength(2));
    });

    test('只保留标题匹配的会话，项目按标题匹配时也不整组保留', () {
      final filtered = filterRemoteProjects(_projects(), '雷达');
      expect(filtered, hasLength(1));
      expect(filtered.single.name, 'CarsTool');
      expect(filtered.single.sessions.map((session) => session.title), <String>[
        '调整雷达',
      ]);
    });
  });
}
