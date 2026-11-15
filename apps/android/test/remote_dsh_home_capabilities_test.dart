// 远程首页新增入口：电脑文件、设置的能力门控，以及从会话页返回后刷新列表。
//
// 这里不连宿主、不拨号：首页数据源是替身，它同时实现文件与设置两个可选能力接口，
// 并把能力状态与应答交给 `support/remote_home_fakes.dart` 的替身。打开会话时页面会
// 构造真实会话数据源，但替身报告连接就绪、页面自建的连接控制器仍是空闲态，因此不会
// 发出请求。

import 'package:dsh_android/remote_dsh_conversation.dart';
import 'package:dsh_android/remote_dsh_live_source.dart';
import 'package:dsh_android/remote_dsh_page.dart';
import 'package:dsh_android/remote_dsh_settings_page.dart';
import 'package:dsh_android/remote_workspace_files_page.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'library_test.dart' show LibraryRuntime;
import 'support/remote_home_fakes.dart';

/// 首页假数据源：一台在线电脑、可配置的项目，外加文件/设置/模型目录能力。
class _HomeCapabilitySource
    implements
        RemoteDshDataSource,
        RemoteDshFilesSource,
        RemoteDshSettingsSource,
        RemoteDshModelCatalogSource {
  _HomeCapabilitySource({
    required this.projects,
    required this.files,
    required this.settings,
    required this.catalog,
  });

  /// 当前项目列表；测试可以在打开会话期间替换它，模拟电脑上的改名。
  List<RemoteDshProject> projects;

  /// 文件能力替身。
  final FakeRemoteFilesSource files;

  /// 设置能力替身。
  final FakeRemoteSettingsSource settings;

  /// 模型目录替身。
  final FakeRemoteModelCatalogSource catalog;

  int projectCalls = 0;

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
  Future<List<RemoteDshProject>> listProjects() async {
    projectCalls++;
    return projects;
  }

  @override
  RemoteDshCapability get filesCapability => files.filesCapability;

  @override
  Future<RemoteDshDirectoryPage> listDirectory({
    required String path,
    int offset = 0,
    String? version,
  }) => files.listDirectory(path: path, offset: offset, version: version);

  @override
  Future<RemoteDshFilePage> readFile({
    required String path,
    int offset = 0,
    String? version,
  }) => files.readFile(path: path, offset: offset, version: version);

  @override
  RemoteDshCapability get settingsCapability => settings.settingsCapability;

  @override
  Future<RemoteDshSettingsSnapshot> describeSettings() =>
      settings.describeSettings();

  @override
  Future<RemoteDshSettingsSnapshot> saveDefaultModel({
    required RemoteDshModelRoute route,
    required int revision,
  }) => settings.saveDefaultModel(route: route, revision: revision);

  @override
  Future<RemoteDshModelCatalog> describeModelCatalog() =>
      catalog.describeModelCatalog();
}

/// 只读首页假数据源：没有文件与设置能力。
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

/// 记录每次推入的路由名。
class _RouteLog extends NavigatorObserver {
  final List<String?> names = <String?>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    names.add(route.settings.name);
  }
}

/// 只有一个项目的首页夹具。
List<RemoteDshProject> _projects({String title = '只回复两个字'}) =>
    <RemoteDshProject>[
      RemoteDshProject(
        id: 'cwd:Pocket',
        deviceId: 'device-1',
        name: 'Pocket',
        sessions: <RemoteDshSession>[RemoteDshSession(id: 's-1', title: title)],
      ),
    ];

/// 一份可用的默认模型设置快照。
RemoteDshSettingsSnapshot _settingsSnapshot() => fakeSettingsSnapshot(
  sections: <RemoteDshSettingsSection>[fakeDefaultModelSection(revision: 3)],
);

_HomeCapabilitySource _source({
  required FakeRemoteFilesSource files,
  required FakeRemoteSettingsSource settings,
  List<RemoteDshProject>? projects,
}) => _HomeCapabilitySource(
  projects: projects ?? _projects(),
  files: files,
  settings: settings,
  catalog: FakeRemoteModelCatalogSource(fakeModelCatalog()),
);

Future<_RouteLog> _show(WidgetTester tester, RemoteDshDataSource source) async {
  final runtime = LibraryRuntime();
  addTearDown(runtime.dispose);
  final log = _RouteLog();
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      navigatorObservers: <NavigatorObserver>[log],
      home: RemoteDshPage(runtime: runtime, source: source),
    ),
  );
  await tester.pumpAndSettle();
  return log;
}

/// 点标题打开首页菜单。
Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.text('远程 DSH'));
  await tester.pumpAndSettle();
}

void main() {
  group('电脑文件入口', () {
    testWidgets('能力可用时打开带稳定目的地标识的文件页', (tester) async {
      final files = FakeRemoteFilesSource(
        directories: <String, List<RemoteDshDirectoryPage>>{
          '': <RemoteDshDirectoryPage>[
            fakeDirectoryPage(
              entries: <RemoteDshFileEntry>[fakeFileEntry('a.txt')],
            ),
          ],
        },
      );
      final source = _source(
        files: files,
        settings: FakeRemoteSettingsSource(
          describes: <RemoteDshSettingsSnapshot>[_settingsSnapshot()],
        ),
      );
      final log = await _show(tester, source);
      await _openMenu(tester);

      await tester.tap(find.text('电脑文件'));
      await tester.pumpAndSettle();

      expect(find.byType(RemoteWorkspaceFilesPage), findsOneWidget);
      expect(
        log.names,
        contains(
          destinationRouteName(RemoteWorkspaceFilesPage.routeDestination),
        ),
        reason: '全屏目的地必须走 openDestination',
      );
      expect(files.directoryCalls, isNotEmpty);
    });

    testWidgets('宿主明确不支持时入口置灰并展示原因', (tester) async {
      final files = FakeRemoteFilesSource(
        capability: const RemoteDshCapability.unavailable(
          '这台电脑声明不支持「workspace.files.list」。',
        ),
      );
      final source = _source(
        files: files,
        settings: FakeRemoteSettingsSource(
          describes: <RemoteDshSettingsSnapshot>[_settingsSnapshot()],
        ),
      );
      final log = await _show(tester, source);
      await _openMenu(tester);

      expect(find.text('这台电脑声明不支持「workspace.files.list」。'), findsOneWidget);

      await tester.tap(find.text('电脑文件'));
      await tester.pumpAndSettle();

      expect(find.byType(RemoteWorkspaceFilesPage), findsNothing);
      expect(
        log.names,
        isNot(
          contains(
            destinationRouteName(RemoteWorkspaceFilesPage.routeDestination),
          ),
        ),
      );
      expect(files.directoryCalls, isEmpty);
    });

    testWidgets('数据源不支持文件能力时给「暂未开放」提示', (tester) async {
      await _show(tester, _ReadOnlySource(_projects()));
      await _openMenu(tester);

      // 电脑文件与设置两个入口都还没接，行内说明因此出现两次。
      expect(find.text('当前数据源不支持这项能力'), findsNWidgets(2));
      await tester.tap(find.text('电脑文件'));
      await tester.pumpAndSettle();

      expect(find.textContaining('「电脑文件」暂未开放'), findsOneWidget);
      expect(find.byType(RemoteWorkspaceFilesPage), findsNothing);
    });
  });

  group('设置入口', () {
    testWidgets('能力可用时打开设置页并读取设置', (tester) async {
      final settings = FakeRemoteSettingsSource(
        describes: <RemoteDshSettingsSnapshot>[_settingsSnapshot()],
      );
      final source = _source(
        files: FakeRemoteFilesSource(),
        settings: settings,
      );
      final log = await _show(tester, source);
      await _openMenu(tester);

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();

      expect(find.byType(RemoteDshSettingsPage), findsOneWidget);
      expect(
        log.names,
        contains(destinationRouteName(RemoteDshSettingsPage.routeDestination)),
      );
      expect(settings.describeCalls, 1);
    });

    testWidgets('宿主没有声明设置能力时入口置灰并展示原因', (tester) async {
      final settings = FakeRemoteSettingsSource(
        capability: const RemoteDshCapability.notDeclared(
          '这台电脑没有声明「settings.describe」，暂时无法使用。',
        ),
        describes: <RemoteDshSettingsSnapshot>[_settingsSnapshot()],
      );
      final source = _source(
        files: FakeRemoteFilesSource(),
        settings: settings,
      );
      await _show(tester, source);
      await _openMenu(tester);

      expect(find.textContaining('没有声明「settings.describe」'), findsOneWidget);

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();

      expect(find.byType(RemoteDshSettingsPage), findsNothing);
      expect(settings.describeCalls, 0);
    });

    testWidgets('数据源不支持设置能力时给「暂未开放」提示', (tester) async {
      await _show(tester, _ReadOnlySource(_projects()));
      await _openMenu(tester);

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();

      expect(find.textContaining('「设置」暂未开放'), findsOneWidget);
      expect(find.byType(RemoteDshSettingsPage), findsNothing);
    });
  });

  group('会话返回刷新', () {
    testWidgets('从会话页返回后重读列表，显示电脑上的新标题', (tester) async {
      final source = _source(
        projects: _projects(title: '修复登录'),
        files: FakeRemoteFilesSource(),
        settings: FakeRemoteSettingsSource(
          describes: <RemoteDshSettingsSnapshot>[_settingsSnapshot()],
        ),
      );
      final log = await _show(tester, source);
      expect(source.projectCalls, 1);

      await tester.tap(
        find.byKey(const ValueKey<String>('remote-session-s-1')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RemoteDshConversationPage), findsOneWidget);
      expect(log.names, contains(destinationRouteName('remote-session:s-1')));

      // 会话页开着时电脑上改了标题：返回首页必须重读，而不是显示旧缓存。
      source.projects = _projects(title: '改名后的会话');
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      expect(source.projectCalls, greaterThanOrEqualTo(2));
      expect(find.text('改名后的会话'), findsOneWidget);
      expect(find.text('修复登录'), findsNothing);
    });
  });
}
