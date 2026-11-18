// 远程首页：头部搜索过滤、输入条新建会话、已归档任务入口、多台电脑管理与切换。
//
// 连接类用例不拨号：传输替身由测试推进阶段，本机设备表走 mock 的偏好通道。数据源类
// 用例用下面的假实现；打开会话时页面会构造真实会话数据源，但假数据源报告连接就绪、
// 页面自建的连接控制器仍是空闲态，因此不会发出请求。

import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/pocket_composer.dart';
import 'package:dsh_android/remote_connection.dart';
import 'package:dsh_android/remote_device_store.dart' as paired;
import 'package:dsh_android/remote_dsh_archived_page.dart';
import 'package:dsh_android/remote_dsh_conversation.dart';
import 'package:dsh_android/remote_dsh_live_source.dart';
import 'package:dsh_android/remote_dsh_page.dart';
import 'package:dsh_android/remote_dsh_widgets.dart';
import 'package:dsh_android/remote_notification_navigation.dart';
import 'package:dsh_android/remote_notifications.dart';
import 'package:dsh_android/remote_pairing.dart';
import 'package:dsh_android/remote_sync_service.dart';
import 'package:dsh_android/remote_transport.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'library_test.dart' show LibraryRuntime;
import 'support/remote_tls_fixture.dart';

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
    this.projectsGate,
    this.devices = const <RemoteDshDevice>[
      RemoteDshDevice(
        id: 'device-1',
        label: '客厅的电脑',
        state: RemoteDshDeviceState.online,
      ),
    ],
  });

  /// 当前项目列表。
  List<RemoteDshProject> projects;

  /// 新建会话后 [listProjects] 返回的列表；为 null 时不变。
  final List<RemoteDshProject>? projectsAfterCreate;

  /// 已归档会话。
  List<RemoteDshArchivedSession> archived;

  /// 新建会话的等待门；用来观察「新建中」的忙碌态。
  final Completer<void>? createGate;

  /// 首次 `listProjects` 的等待门；用来观察首屏转圈。
  final Completer<void>? projectsGate;

  /// 新建会话抛出的失败。
  Object? createError;
  final List<RemoteDshDevice> devices;

  int createCalls = 0;
  String? lastCreatedProjectId;
  int archivedCalls = 0;
  final List<String> restored = <String>[];

  @override
  RemoteDshConnectionState get connection => RemoteDshConnectionState.connected;

  @override
  String? get hostName => '客厅的电脑';

  @override
  Future<List<RemoteDshDevice>> listDevices() async => devices;

  @override
  Future<List<RemoteDshProject>> listProjects() async {
    final gate = projectsGate;
    if (gate != null) await gate.future;
    return projects;
  }

  @override
  Future<RemoteDshCreatedSession> createSession({String? projectId}) async {
    createCalls++;
    lastCreatedProjectId = projectId;
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

/// 连接中的假数据源：没有可用的缓存与项目，内容区应当转圈而不是空态。
class _ConnectingSource implements RemoteDshDataSource {
  @override
  RemoteDshConnectionState get connection =>
      RemoteDshConnectionState.connecting;

  @override
  String? get hostName => '新电脑';

  @override
  Future<List<RemoteDshDevice>> listDevices() async =>
      const <RemoteDshDevice>[
        RemoteDshDevice(
          id: 'device-new',
          label: '新电脑',
          state: RemoteDshDeviceState.connecting,
        ),
      ];

  @override
  Future<List<RemoteDshProject>> listProjects() async =>
      const <RemoteDshProject>[];
}

/// 记录通知权限请求次数的假实现。
class _FakeNotificationPermission implements RemoteNotificationPermission {
  int requests = 0;

  @override
  Future<void> ensureRequested() async {
    requests++;
  }
}

/// 记录后台同步 start/stop 次数的假实现。
class _FakeSyncLifecycle implements RemoteSyncLifecycle {
  int starts = 0;
  int stops = 0;

  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

/// 记录每次推入的路由名。
class _RouteLog extends NavigatorObserver {
  final List<String?> names = <String?>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    names.add(route.settings.name);
  }
}

/// 多设备用例的传输替身：不拨号，阶段由测试推进；门面请求返回可用的最小应答。
class _HomeFakeLink implements RemoteTransportLink {
  final StreamController<Map<String, dynamic>> _inbound =
      StreamController<Map<String, dynamic>>(sync: true);
  final Completer<RemoteHostInfo> _handshake = Completer<RemoteHostInfo>();

  /// 收到过的门面请求方法名。
  final List<String> requests = <String>[];

  /// `sessions.list` 返回的会话行；默认空列表（多数用例不关心项目列表）。
  List<Map<String, dynamic>> sessions = const <Map<String, dynamic>>[];

  RemoteHostInfo? _host;
  String _phase = 'connecting';
  bool _closed = false;

  @override
  Stream<Map<String, dynamic>> get events => _inbound.stream;

  @override
  Future<RemoteHostInfo> get handshake => _handshake.future;

  @override
  RemoteHostInfo? get host => _host;

  @override
  String get phase => _phase;

  @override
  bool get isClosed => _closed;

  /// 事件流上是否还有订阅者。
  bool get hasListener => _inbound.hasListener;

  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) async {
    requests.add(method);
    switch (method) {
      case 'runtime.info':
        return <String, dynamic>{'node': 'v24', 'platform': 'win32'};
      case 'sessions.list':
        return sessions;
      case 'session.readWindow':
        // 通知深链用例会真的打开会话页：给一个合法空窗口，让它停在空态而不是错误态。
        return <String, dynamic>{'events': <dynamic>[], 'throughSeq': 0};
      default:
        return null;
    }
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
  Future<void> close() async {
    _closed = true;
    if (!_inbound.isClosed) await _inbound.close();
  }

  /// 握手成功：推 `remote.status.ready` 并兑现握手，但不代表宿主可用。
  void handshakeSucceeded(RemoteHostInfo info) {
    _host = info;
    _phase = 'ready';
    emit('remote.status', <String, dynamic>{'phase': 'ready'});
    if (!_handshake.isCompleted) _handshake.complete(info);
  }

  void emit(String method, [Map<String, dynamic> params = const {}]) {
    if (_inbound.isClosed) return;
    _inbound.add(<String, dynamic>{'method': method, 'params': params});
  }

  void lost(String code, String message) {
    _phase = 'lost';
    emit('remote.status', <String, dynamic>{
      'phase': 'lost',
      'error': <String, dynamic>{'code': code, 'message': message},
    });
  }
}

/// 每次建连返回一条新的 [_HomeFakeLink]，记录端点顺序。
class _HomeLinkFactory {
  final List<_HomeFakeLink> links = <_HomeFakeLink>[];
  final List<String> endpoints = <String>[];

  /// 每次创建新连接时，上一条连接是否已经关闭。
  final List<bool> previousClosedOnCreate = <bool>[];

  _HomeFakeLink call({
    required String endpoint,
    required String token,
    required String pinnedCaPem,
    required bool systemTrust,
    required String deviceLabel,
    required String appVersion,
    required List<String> capabilities,
  }) {
    if (links.isNotEmpty) previousClosedOnCreate.add(links.last.isClosed);
    final link = _HomeFakeLink();
    links.add(link);
    endpoints.add(endpoint);
    return link;
  }
}

/// 内存令牌保管口：测试不碰 Keystore。
class _HomeVault implements paired.RemoteDeviceTokenVault {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String tokenRef) async => values.remove(tokenRef);

  @override
  Future<bool> isConfigured(String tokenRef) async =>
      values.containsKey(tokenRef);

  @override
  Future<String> read(String tokenRef) async {
    final value = values[tokenRef];
    if (value == null) {
      throw const paired.RemoteDeviceStoreException(
        'remote/credential-read',
        '本机密钥库里没有这台电脑的设备令牌，请重新配对。',
      );
    }
    return value;
  }

  @override
  Future<void> write(String tokenRef, String token) async {
    values[tokenRef] = token;
  }
}

/// 首页连接用例的装配：mock 偏好通道 + 注入式连接控制器 + 可推进的传输替身。
class _HomeConnectionHarness {
  _HomeConnectionHarness({
    required List<paired.RemoteDevice> devices,
    String? lastConnectedDeviceId,
  }) {
    preferences = jsonEncode(<String, dynamic>{
      'version': paired.remoteDeviceStoreVersion,
      'devices': <Map<String, dynamic>>[
        for (final device in devices) device.toJson(),
      ],
      paired.remoteLastConnectedDeviceKey: ?lastConnectedDeviceId,
    });
    messenger.setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case paired.remoteDevicesReadMethod:
          return preferences;
        case paired.remoteDevicesSaveMethod:
          preferences = call.arguments as String;
          saveCalls++;
          return null;
        default:
          throw MissingPluginException('未模拟的偏好方法 ${call.method}');
      }
    });
    store = paired.RemoteDeviceStore(channel: _channel, tokens: vault);
    controller = RemoteConnectionController(
      store: store,
      createTransport: factory.call,
    );
  }

  static const MethodChannel _channel = MethodChannel(
    'test/remote_home_devices',
  );
  static final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 每台设备固定的测试令牌（43 字符 base64url）。
  static const String token = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq';

  final _HomeVault vault = _HomeVault();
  final _HomeLinkFactory factory = _HomeLinkFactory();

  late final paired.RemoteDeviceStore store;
  late final RemoteConnectionController controller;

  /// 偏好原文。
  String? preferences;

  /// 偏好写入次数。
  int saveCalls = 0;

  /// 读回偏好 JSON。
  Map<String, dynamic> decode() =>
      jsonDecode(preferences ?? '{}') as Map<String, dynamic>;

  /// 登记设备令牌（默认给用例里的每台设备写入同一个测试令牌）。
  void authorize(List<paired.RemoteDevice> devices) {
    for (final device in devices) {
      vault.values[device.tokenRef] = token;
    }
  }

  void dispose() {
    controller.dispose();
    messenger.setMockMethodCallHandler(_channel, null);
  }
}

/// 两台电脑的固定标识与地址。
const String _livingRoomId = '0123456789abcdef0123456789abcdef';
const String _studyId = 'fedcba9876543210fedcba9876543210';
const String _neverConnectedId = 'aaaabbbbccccddddeeeeffff00001111';

paired.RemoteDevice _pairedDevice({
  required String id,
  required String host,
  String label = 'Pixel 8',
  String? hostName,
  DateTime? createdAt,
  DateTime? lastSeenAt,
}) => paired.RemoteDevice(
  id: id,
  label: label,
  host: host,
  port: 4777,
  instanceId: caCertificateFingerprint(pairingCaPem),
  caPem: pairingCaPem,
  createdAt: createdAt ?? DateTime.utc(2026, 11, 15, 6),
  lastSeenAt: lastSeenAt,
  hostName: hostName,
);

/// 客厅那台（测试默认的上次连接设备）。
paired.RemoteDevice _livingRoom({bool connectedBefore = true}) => _pairedDevice(
  id: _livingRoomId,
  host: '192.168.5.140',
  hostName: connectedBefore ? '客厅的电脑' : null,
  createdAt: DateTime.utc(2026, 11, 15, 6),
);

/// 书房那台。
paired.RemoteDevice _study({bool connectedBefore = true}) => _pairedDevice(
  id: _studyId,
  host: '192.168.5.141',
  hostName: connectedBefore ? '书房的笔记本' : null,
  createdAt: DateTime.utc(2026, 11, 15, 7),
);

RemoteHostInfo _hostInfo(String name) => RemoteHostInfo(
  protocolVersion: 1,
  name: name,
  platform: 'win32',
  home: r'C:\Users\colin\DSH',
  methods: const <String>['session.send', 'runtime.info', 'sessions.list'],
  unsupported: const <String>[],
  capabilities: const <String>['window-ack'],
);

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
Finder _sessionRow(String id) =>
    find.byKey(ValueKey('remote-session-device-1-$id'));

/// 项目折叠动画是否已经收到「只显示项目头」。
///
/// AnimatedSize 的展开态 child 是会话列表、折叠态是零高 SizedBox；动画期间
/// child 已经是目标状态，只是高度在过渡，因此可以立即断言。
bool _projectCollapsed(WidgetTester tester, String deviceProjectKey) {
  final size = tester.widget<AnimatedSize>(
    find
        .descendant(
          of: find.byKey(ValueKey('remote-project-$deviceProjectKey')),
          matching: find.byType(AnimatedSize),
        )
        .first,
  );
  final child = size.child;
  return child is SizedBox && child.height == 0;
}

/// 输入卡里的文本框。
Finder _composerField() => find.byKey(PocketComposer.inputKey);

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

/// 推进到界面稳定；连接中的转圈是无限动画，`pumpAndSettle` 会等不到停止而
/// 超时，因此给 settle 一个有界时间，超时后按固定帧收尾（不改变测试断言）。
Future<void> _settle(WidgetTester tester) async {
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
  } on FlutterError {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 只挂载首页、不等待首帧静止：用于观察一直转圈的首屏加载态。
///
/// `pumpAndSettle` 会等所有动画停止，而 [CircularProgressIndicator] 一直转，
/// 因此这类用例只推进两帧看加载态，数据返回后再 `pumpAndSettle`。
Future<void> _showRaw(
  WidgetTester tester,
  RemoteDshDataSource source,
) async {
  final runtime = LibraryRuntime();
  addTearDown(runtime.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: RemoteDshPage(runtime: runtime, source: source),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _openSearch(WidgetTester tester) async {
  await tester.tap(find.byTooltip('搜索会话'));
  await tester.pumpAndSettle();
}

/// 用注入的连接控制器打开首页（数据源是真实实时源）。
///
/// [launch] 模拟「从系统通知点击进来」的待打开会话；[observer] 记录推入的目的地，
/// 用来断言通知深链打开的是会话页而不是别的页面。[runtime] 给冷启动用例注入一个
/// 尚未就绪的本机运行时（缺省是已就绪的 [LibraryRuntime]）。
Future<void> _showConnection(
  WidgetTester tester,
  _HomeConnectionHarness harness, {
  NavigatorObserver? observer,
  RemoteNotificationLaunch? launch,
  LibraryRuntime? runtime,
  RemoteSyncLifecycle? syncLifecycle,
  RemoteNotificationPermission? notificationPermission,
}) async {
  final controller = runtime ?? LibraryRuntime();
  if (runtime == null) addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      navigatorObservers: <NavigatorObserver>[?observer],
      home: RemoteDshPage(
        runtime: controller,
        connection: harness.controller,
        notificationLaunch: launch,
        syncLifecycle: syncLifecycle,
        notificationPermission: notificationPermission,
      ),
    ),
  );
  await _settle(tester);
}

/// 让第 [index] 条连接完成握手并进入宿主就绪态。
void _completeHandshake(
  _HomeConnectionHarness harness,
  int index,
  String hostName,
) {
  final link = harness.factory.links[index];
  link.handshakeSucceeded(_hostInfo(hostName));
  link.emit('runtime.status', <String, dynamic>{'phase': 'ready'});
}

/// 让连接层的异步清理在 widget 测试里真正跑完。
///
/// [RemoteConnectionController] 关闭旧连接时会 `await StreamSubscription.cancel()`：
/// 这个 future 要真实事件循环回合才兑现，`tester.pump`（fake async）不会推进它。
/// 这里用 [WidgetTester.runAsync] 提供真实回合，反复到链路推进到位后再渲染。
Future<void> _flushConnection(
  WidgetTester tester, {
  bool Function()? until,
}) async {
  for (var turn = 0; turn < 16; turn++) {
    if (until != null && until()) break;
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  await _settle(tester);
}

/// 设备胶囊（按名称找）。
RemoteDeviceChip _chip(WidgetTester tester, String label) =>
    tester.widget<RemoteDeviceChip>(
      find.ancestor(
        of: find.text(label),
        matching: find.byType(RemoteDeviceChip),
      ),
    );

/// 打开首页标题菜单。
Future<void> _openHomeMenu(WidgetTester tester) async {
  await tester.tap(find.text('远程 DSH'));
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
  group('连接与首次数据加载态', () {
    Finder projectLoading() => find.byKey(
      const ValueKey('remote-projects-loading'),
    );

    testWidgets('连接后等待项目返回时显示转圈而不是空态', (tester) async {
      final gate = Completer<void>();
      await _showRaw(
        tester,
        _HomeSource(projects: _projects(), projectsGate: gate),
      );
      expect(projectLoading(), findsOneWidget);
      expect(find.text('正在获取电脑上的项目…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(find.text('这台电脑上还没有项目'), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(projectLoading(), findsNothing);
      expect(find.text('Pocket'), findsOneWidget);
      expect(find.text('这台电脑上还没有项目'), findsNothing);
    });

    testWidgets('项目列表成功返回空列表后才显示空态', (tester) async {
      final gate = Completer<void>();
      await _showRaw(
        tester,
        _HomeSource(projects: const <RemoteDshProject>[], projectsGate: gate),
      );
      expect(projectLoading(), findsOneWidget);
      expect(find.text('这台电脑上还没有项目'), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(projectLoading(), findsNothing);
      expect(find.text('这台电脑上还没有项目'), findsOneWidget);
    });

    testWidgets('切换到尚未加载的设备时重新显示转圈', (tester) async {
      final source = _HomeSource(
        projects: _projects(),
        devices: const <RemoteDshDevice>[
          RemoteDshDevice(
            id: 'device-1',
            label: '客厅的电脑',
            state: RemoteDshDeviceState.online,
          ),
          RemoteDshDevice(
            id: 'device-2',
            label: '书房的笔记本',
            state: RemoteDshDeviceState.offline,
          ),
        ],
      );
      await _show(tester, source);
      expect(find.text('Pocket'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byType(RemoteDeviceRail),
          matching: find.text('书房的笔记本'),
        ),
      );
      await tester.pump();
      expect(projectLoading(), findsOneWidget);
      expect(find.text('这台电脑上还没有项目'), findsNothing);
      expect(find.text('Pocket'), findsNothing);
    });

    testWidgets('连接中显示转圈提示而不是沙漏空态', (tester) async {
      await _showRaw(tester, _ConnectingSource());
      expect(find.byKey(const ValueKey('remote-connecting')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(find.text('正在连接「新电脑」'), findsOneWidget);
      expect(find.byIcon(Icons.hourglass_top_rounded), findsNothing);
    });
  });

  group('会话运行状态与项目折叠', () {
    testWidgets('running 会话标题前显示绿点，非 running 不显示', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: Scaffold(
            body: Column(
              children: <Widget>[
                RemoteSessionRow(title: '正在工作', running: true, plain: true),
                RemoteSessionRow(title: '空闲', plain: true),
              ],
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('remote-running-dot')),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == '正在工作',
        ),
        findsOneWidget,
      );
      expect(find.text('空闲'), findsOneWidget);
    });

    testWidgets('sessions.list 的 running 行在首页点亮绿点', (tester) async {
      final livingRoom = _livingRoom();
      final harness = _HomeConnectionHarness(
        devices: <paired.RemoteDevice>[livingRoom],
        lastConnectedDeviceId: _livingRoomId,
      );
      addTearDown(harness.dispose);
      harness.authorize(<paired.RemoteDevice>[livingRoom]);
      await _showConnection(tester, harness);
      harness.factory.links.single.sessions = <Map<String, dynamic>>[
        <String, dynamic>{
          'header': <String, dynamic>{
            'id': 's-running',
            'cwd': r'C:\Users\colin\Pocket',
          },
          'title': '运行中的会话',
          'running': true,
        },
        <String, dynamic>{
          'header': <String, dynamic>{
            'id': 's-idle',
            'cwd': r'C:\Users\colin\Pocket',
          },
          'title': '空闲会话',
        },
      ];
      _completeHandshake(harness, 0, '客厅的电脑');
      await _flushConnection(tester);

      expect(find.text('运行中的会话'), findsWidgets);
      expect(find.byKey(const ValueKey('remote-running-dot')), findsWidgets);
    });

    testWidgets('折叠项目后经过搜索过滤重建，仍然保持折叠', (tester) async {
      await _show(tester, _HomeSource(projects: _projects()));
      expect(_sessionRow('s-1'), findsOneWidget);

      await tester.tap(find.text('Pocket'));
      await tester.pumpAndSettle();
      expect(_projectCollapsed(tester, 'device-1-cwd:Pocket'), isTrue);

      await _openSearch(tester);
      await _enterSearch(tester, 'Cars');
      await tester.pump();
      expect(find.text('CarsTool'), findsOneWidget);
      await _enterSearch(tester, '');
      await tester.pumpAndSettle();

      expect(find.text('Pocket'), findsOneWidget);
      expect(
        _projectCollapsed(tester, 'device-1-cwd:Pocket'),
        isTrue,
        reason: '列表重建后折叠状态不能丢',
      );
    });

    testWidgets('切换设备再切回「全部」后，折叠状态仍然保持', (tester) async {
      final source = _HomeSource(
        projects: <RemoteDshProject>[
          ..._projects(),
          const RemoteDshProject(
            id: 'cwd:Study',
            deviceId: 'device-2',
            name: 'Study',
            sessions: <RemoteDshSession>[
              RemoteDshSession(id: 's-study', title: '书房会话'),
            ],
          ),
        ],
        devices: const <RemoteDshDevice>[
          RemoteDshDevice(
            id: 'device-1',
            label: '客厅的电脑',
            state: RemoteDshDeviceState.online,
          ),
          RemoteDshDevice(
            id: 'device-2',
            label: '书房的笔记本',
            state: RemoteDshDeviceState.offline,
          ),
        ],
      );
      await _show(tester, source);
      await tester.tap(find.text('Pocket'));
      await tester.pumpAndSettle();
      expect(_projectCollapsed(tester, 'device-1-cwd:Pocket'), isTrue);

      await tester.tap(
        find.descendant(
          of: find.byType(RemoteDeviceRail),
          matching: find.text('书房的笔记本'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();

      expect(find.text('Pocket'), findsOneWidget);
      expect(find.text('Study'), findsOneWidget);
      expect(
        _projectCollapsed(tester, 'device-1-cwd:Pocket'),
        isTrue,
        reason: '切换设备后折叠状态不能丢',
      );
    });

    testWidgets('折叠态项目头和外层间距明显收紧，展开态保持可读', (tester) async {
      final group = find.byKey(
        const ValueKey('remote-project-device-1-cwd:Pocket'),
      );
      await _show(tester, _HomeSource(projects: _projects()));
      final expandedSize = tester.getSize(group);
      expect(
        find.descendant(
          of: group,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Padding &&
                widget.padding == const EdgeInsets.fromLTRB(2, 16, 2, 10),
          ),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Pocket'));
      await tester.pumpAndSettle();
      final collapsedSize = tester.getSize(group);
      expect(
        expandedSize.height - collapsedSize.height,
        greaterThanOrEqualTo(60),
        reason: '折叠后项目组高度应明显下降',
      );
      expect(collapsedSize.height, greaterThanOrEqualTo(40));
      expect(
        find.descendant(
          of: group,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Padding &&
                widget.padding == const EdgeInsets.fromLTRB(2, 10, 2, 8),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: group,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Padding &&
                widget.padding ==
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
          ),
        ),
        findsOneWidget,
        reason: '折叠项目的外层垂直间距从 4 收紧到 2',
      );
    });
  });

  group('后台同步服务生命周期', () {
    Future<_HomeConnectionHarness> harnessFor() async {
      final livingRoom = _livingRoom();
      final harness = _HomeConnectionHarness(
        devices: <paired.RemoteDevice>[livingRoom],
        lastConnectedDeviceId: _livingRoomId,
      );
      addTearDown(harness.dispose);
      harness.authorize(<paired.RemoteDevice>[livingRoom]);
      return harness;
    }

    testWidgets('连接 ready 启动后台同步，退后台不停止，销毁时停止', (tester) async {
      final sync = _FakeSyncLifecycle();
      final harness = await harnessFor();
      await _showConnection(tester, harness, syncLifecycle: sync);
      expect(sync.starts, 0, reason: '连接尚未就绪时不启动');

      _completeHandshake(harness, 0, '客厅的电脑');
      await _flushConnection(tester);
      expect(sync.starts, 1);

      // 合法生命周期路径：resumed → inactive → hidden → paused，再逐级恢复。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(sync.stops, 0, reason: '退后台不停止后台同步');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(sync.stops, 0);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(sync.stops, 1);
    });

    testWidgets('连接 ready 时申请一次通知权限', (tester) async {
      final sync = _FakeSyncLifecycle();
      final permission = _FakeNotificationPermission();
      final harness = await harnessFor();
      await _showConnection(
        tester,
        harness,
        syncLifecycle: sync,
        notificationPermission: permission,
      );
      expect(permission.requests, 0, reason: '连接尚未就绪时不申请');

      _completeHandshake(harness, 0, '客厅的电脑');
      await _flushConnection(tester);
      expect(permission.requests, 1);
    });
    testWidgets('连接 failed 时停止后台同步', (tester) async {
      final sync = _FakeSyncLifecycle();
      final harness = await harnessFor();
      await _showConnection(tester, harness, syncLifecycle: sync);
      _completeHandshake(harness, 0, '客厅的电脑');
      await _flushConnection(tester);
      expect(sync.starts, 1);

      harness.factory.links.first.lost('remote/tls', '连接已断开');
      await _flushConnection(
        tester,
        until: () => harness.controller.phase == RemoteConnectionPhase.failed,
      );
      expect(sync.stops, 1);
    });

    testWidgets('用户断开连接回到 idle 时停止后台同步', (tester) async {
      final sync = _FakeSyncLifecycle();
      final harness = await harnessFor();
      await _showConnection(tester, harness, syncLifecycle: sync);
      _completeHandshake(harness, 0, '客厅的电脑');
      await _flushConnection(tester);
      expect(sync.starts, 1);

      unawaited(harness.controller.disconnect());
      await _flushConnection(
        tester,
        until: () => harness.controller.phase == RemoteConnectionPhase.idle,
      );
      expect(sync.stops, 1);
    });
    testWidgets('MethodChannelRemoteSyncLifecycle 调用 native 并保持幂等', (
      tester,
    ) async {
      const channel = MethodChannel('remote-sync-lifecycle-home-test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final lifecycle = MethodChannelRemoteSyncLifecycle(channel: channel);
      await lifecycle.start();
      await lifecycle.start();
      await lifecycle.stop();
      await lifecycle.stop();
      expect(calls, <String>['remote.sync.start', 'remote.sync.stop']);
    });
  });

  group('最近项目与会话', () {
    testWidgets('全部显示两台电脑，设备页签只显示对应电脑', (tester) async {
      final source = _HomeSource(
        projects: <RemoteDshProject>[
          ..._projects(),
          const RemoteDshProject(
            id: 'cwd:Study',
            deviceId: 'device-2',
            name: 'Study',
            sessions: <RemoteDshSession>[
              RemoteDshSession(id: 's-study', title: '书房会话'),
            ],
          ),
        ],
        devices: const <RemoteDshDevice>[
          RemoteDshDevice(
            id: 'device-1',
            label: '客厅的电脑',
            state: RemoteDshDeviceState.online,
          ),
          RemoteDshDevice(
            id: 'device-2',
            label: '书房的笔记本',
            state: RemoteDshDeviceState.offline,
          ),
        ],
      );
      await _show(tester, source);
      expect(find.text('Pocket'), findsOneWidget);
      expect(find.text('Study'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('最近会话'),
        350,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('remote-project-list')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('最近会话'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byType(RemoteDeviceRail),
          matching: find.text('书房的笔记本'),
        ),
      );
      await tester.pumpAndSettle();
      expect(_chip(tester, '书房的笔记本').selected, isTrue);
      expect(find.text('Study'), findsOneWidget);
      expect(find.text('Pocket'), findsNothing);

      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      expect(_chip(tester, '全部').selected, isTrue);
      expect(find.text('Pocket'), findsOneWidget);
      expect(find.text('Study'), findsOneWidget);
    });

    testWidgets('项目行折叠渐隐，右侧编辑在项目中新建会话', (tester) async {
      final source = _HomeSource(projects: _projects());
      await _show(tester, source);
      final group = find.byKey(
        const ValueKey('remote-project-device-1-cwd:Pocket'),
      );
      final expandedHeight = tester.getSize(group).height;
      expect(_sessionRow('s-1'), findsOneWidget);
      await tester.tap(find.text('Pocket'));
      await tester.pump();
      expect(_projectCollapsed(tester, 'device-1-cwd:Pocket'), isTrue);
      await tester.pumpAndSettle();
      expect(tester.getSize(group).height, lessThan(expandedHeight));

      await tester.tap(find.byTooltip('在Pocket中新建会话'));
      await tester.pump();
      expect(source.createCalls, 1);
      expect(source.lastCreatedProjectId, 'cwd:Pocket');
    });
  });

  group('头部搜索', () {
    testWidgets('按会话标题过滤，大小写不敏感的包含匹配', (tester) async {
      await _show(tester, _HomeSource(projects: _projects()));
      expect(
        tester.widget<TextField>(_composerField()).textAlign,
        TextAlign.start,
      );
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
      expect(composer.enabled, isFalse, reason: '新建期间输入卡不可用');
      expect(composer.sending, isTrue, reason: '新建期间右侧圆钮换成进度');
      expect(
        find.byKey(const ValueKey('remote-home-send')),
        findsNothing,
        reason: '忙碌时不存在可再次点按的发送圆钮',
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pump();
      expect(source.createCalls, 1, reason: '忙碌时不存在可再次点按的发送圆钮');

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

  group('输入卡三态', () {
    /// 首页输入卡当前状态（受控组件，状态由页面持有）。
    PocketComposerMode modeOf(WidgetTester tester) =>
        tester.widget<RemoteComposer>(find.byType(RemoteComposer).first).mode;

    testWidgets('缩小态是悬浮单行卡：加号、占位与置灰发送，没有权限/推理按钮', (tester) async {
      await _show(tester, _HomeSource(projects: _projects()));

      expect(find.byKey(PocketComposer.cardKey), findsOneWidget);
      expect(find.text('与 客厅的电脑 新对话'), findsOneWidget);
      expect(find.byTooltip('添加与指令'), findsOneWidget);
      expect(find.byKey(const ValueKey('remote-home-send')), findsNothing);
      // 首页没有权限入口；推理按钮只在展开态出现。
      expect(find.byTooltip('权限预设'), findsNothing);
      expect(find.byTooltip('推理强度'), findsNothing);
      // 旧的说明行已并入占位文案/+ 弹层，卡片外不再多一行。
      expect(find.byKey(const ValueKey('remote-composer-hint')), findsNothing);
      expect(modeOf(tester), PocketComposerMode.browse);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('点输入卡一次即展开并进入输入，工具条按钮紧凑可用', (tester) async {
      await _show(tester, _HomeSource(projects: _projects()));

      await tester.tap(find.byKey(PocketComposer.inputKey));
      await tester.pumpAndSettle();

      expect(modeOf(tester), PocketComposerMode.composing);
      expect(find.byTooltip('添加与指令'), findsOneWidget);
      expect(find.byTooltip('推理强度'), findsOneWidget);
      // 首页没有 session、没有权限入口：工具条不画权限按钮（避免死按钮）。
      expect(find.byTooltip('权限预设'), findsNothing);
      // 工具条动作按钮是小图标（40dp 热区），没有 44dp 大圆底。
      expect(tester.getSize(find.byTooltip('推理强度')), const Size(40, 40));

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('「+」弹层说明进入会话后可添加文件与指令', (tester) async {
      await _show(tester, _HomeSource(projects: _projects()));

      await tester.tap(find.byKey(PocketComposer.inputKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加与指令'));
      await tester.pumpAndSettle();

      expect(find.text('添加与指令'), findsOneWidget, reason: '弹层标题与按钮同名');
      expect(find.text('进入会话后可添加文件与指令'), findsOneWidget);
      expect(find.textContaining('添加附件、执行会话指令'), findsOneWidget);

      await tester.tap(find.byTooltip('关闭添加菜单'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('未连接时输入卡整体不可用并提示先连接', (tester) async {
      await _show(tester, _OfflineSource());

      final composer = tester.widget<RemoteComposer>(
        find.byType(RemoteComposer).first,
      );
      expect(composer.enabled, isFalse);
      expect(find.text('先连接一台电脑'), findsOneWidget);
      final add = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('添加与指令'),
          matching: find.byType(IconButton),
        ),
      );
      expect(add.onPressed, isNull, reason: '未连接时加号不可点');

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('键盘收起后纯浏览缩回缩小态，有草稿保持展开', (tester) async {
      addTearDown(tester.view.resetViewInsets);
      await _show(tester, _HomeSource(projects: _projects()));

      await tester.tap(find.byKey(PocketComposer.inputKey));
      await tester.pumpAndSettle();
      expect(modeOf(tester), PocketComposerMode.composing);

      tester.view.viewInsets = const FakeViewPadding(bottom: 600);
      await tester.pumpAndSettle();
      expect(modeOf(tester), PocketComposerMode.composing);

      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(
        modeOf(tester),
        PocketComposerMode.browse,
        reason: '键盘收起且无草稿回到缩小态',
      );

      await tester.enterText(find.byKey(PocketComposer.inputKey), '写了一半');
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 600);
      await tester.pumpAndSettle();
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(
        modeOf(tester),
        PocketComposerMode.composing,
        reason: '有草稿时键盘收起仍保持展开',
      );

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

  group('多台电脑管理与切换', () {
    /// 建一台客厅电脑、一台书房电脑、一台从未连接过的电脑。
    Future<_HomeConnectionHarness> harnessWith({
      bool studyConnectedBefore = true,
      bool neverConnected = true,
      String? lastConnectedDeviceId = _livingRoomId,
    }) async {
      final livingRoom = _livingRoom();
      final study = _study(connectedBefore: studyConnectedBefore);
      final never = _pairedDevice(
        id: _neverConnectedId,
        host: '192.168.5.142',
        createdAt: DateTime.utc(2026, 11, 15, 8),
      );
      final devices = <paired.RemoteDevice>[
        livingRoom,
        study,
        if (neverConnected) never,
      ];
      final harness = _HomeConnectionHarness(
        devices: devices,
        lastConnectedDeviceId: lastConnectedDeviceId,
      );
      addTearDown(harness.dispose);
      harness.authorize(devices);
      return harness;
    }

    testWidgets('胶囊条显示多台电脑的名称、当前所连与离线状态点', (tester) async {
      final harness = await harnessWith();
      await _showConnection(tester, harness);

      // 超过一台设备也自动连「上次成功连接」的那台，而不是最近配对的。
      expect(harness.factory.links, hasLength(1));
      expect(
        harness.factory.endpoints.single,
        _livingRoom().appEndpoint.toString(),
        reason: '上次连接的是客厅那台',
      );
      expect(
        find.byKey(const ValueKey('remote-home-connection-summary')),
        findsNothing,
      );
      expect(find.text('正在连接「客厅的电脑」'), findsOneWidget);

      _completeHandshake(harness, 0, '客厅的电脑');
      await _flushConnection(tester);

      expect(_chip(tester, '客厅的电脑').selected, isFalse);
      expect(_chip(tester, '全部').selected, isTrue);
      expect(
        _chip(tester, '客厅的电脑').status,
        RemoteDeviceStatus.online,
        reason: '当前连接用实心在线点标出',
      );
      expect(_chip(tester, '书房的笔记本').selected, isFalse);
      expect(_chip(tester, '书房的笔记本').status, RemoteDeviceStatus.offline);
      expect(
        _chip(tester, '192.168.5.142').status,
        RemoteDeviceStatus.offline,
        reason: '从未连接过的电脑还没有电脑名，用地址占位',
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('点另一台电脑触发切换：旧连接先关闭，再连新电脑', (tester) async {
      final harness = await harnessWith();
      await _showConnection(tester, harness);
      _completeHandshake(harness, 0, '客厅的电脑');
      await _flushConnection(tester);

      await tester.tap(find.text('书房的笔记本'));
      await _flushConnection(
        tester,
        until: () => harness.factory.links.length == 2,
      );

      expect(harness.factory.links, hasLength(2));
      expect(harness.factory.previousClosedOnCreate, <bool>[
        true,
      ], reason: '先关旧的再建新的');
      expect(harness.factory.links.first.isClosed, isTrue);
      expect(harness.factory.links.first.hasListener, isFalse);
      expect(harness.factory.endpoints.last, _study().appEndpoint.toString());
      expect(harness.controller.activeDevice?.id, _studyId);
      expect(harness.controller.phase, RemoteConnectionPhase.connecting);
      expect(find.text('正在连接「书房的笔记本」'), findsOneWidget);

      _completeHandshake(harness, 1, '书房的笔记本');
      await _flushConnection(tester);

      expect(_chip(tester, '书房的笔记本').selected, isTrue);
      expect(_chip(tester, '客厅的电脑').status, RemoteDeviceStatus.offline);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('点当前已连接的电脑不会重复连接', (tester) async {
      final harness = await harnessWith();
      await _showConnection(tester, harness);
      _completeHandshake(harness, 0, '客厅的电脑');
      await _flushConnection(tester);

      await tester.tap(find.text('客厅的电脑'));
      await tester.pumpAndSettle();

      expect(harness.factory.links, hasLength(1), reason: '已连接就不要再拨一次');
      expect(harness.factory.links.single.isClosed, isFalse);
      expect(harness.controller.phase, RemoteConnectionPhase.ready);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('上次连接的电脑不可达：显示该电脑的错误与「切换设备」入口', (tester) async {
      final harness = await harnessWith();
      await _showConnection(tester, harness);
      _completeHandshake(harness, 0, '客厅的电脑');
      await _flushConnection(tester);

      harness.factory.links.first.lost('remote/tls', '无法验证电脑的 TLS 证书：证书指纹不匹配。');
      await _flushConnection(
        tester,
        until: () => harness.factory.links.first.isClosed,
      );

      // 失败页指向那台连不上的电脑，而不是静默回到可用的旧状态。
      expect(find.text('没能连接到「客厅的电脑」'), findsWidgets);
      expect(find.text('无法验证电脑的 TLS 证书：证书指纹不匹配。'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('切换设备'), findsOneWidget);
      expect(harness.factory.links.first.isClosed, isTrue);

      await tester.tap(find.text('切换设备'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('remote-switch-device-sheet')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('remote-switch-device-$_studyId')),
      );
      await _flushConnection(
        tester,
        until: () => harness.factory.links.length == 2,
      );

      expect(harness.factory.links, hasLength(2));
      expect(harness.controller.activeDevice?.id, _studyId);
      _completeHandshake(harness, 1, '书房的笔记本');
      await _flushConnection(tester);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('已配对但从未连接：不自动连接，文案与「没有电脑」区分', (tester) async {
      final livingRoom = _livingRoom(connectedBefore: false);
      final study = _study(connectedBefore: false);
      final harness = _HomeConnectionHarness(
        devices: <paired.RemoteDevice>[livingRoom, study],
      );
      addTearDown(harness.dispose);
      harness.authorize(<paired.RemoteDevice>[livingRoom, study]);
      await _showConnection(tester, harness);

      expect(harness.factory.links, isEmpty, reason: '没有上次连接记录时不猜要连哪台');
      expect(find.text('还没有连接过任何一台电脑'), findsOneWidget);
      expect(find.text('还没有连接任何电脑'), findsNothing, reason: '与完全没配对区分');
      // 从未连接过的电脑还不知道电脑名：胶囊退回地址。
      expect(_chip(tester, '192.168.5.140').label, '192.168.5.140');
      expect(_chip(tester, '192.168.5.141').status, RemoteDeviceStatus.offline);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('没有已配对电脑：空态与「移除已配对电脑」入口置灰', (tester) async {
      final harness = _HomeConnectionHarness(
        devices: const <paired.RemoteDevice>[],
      );
      addTearDown(harness.dispose);
      await _showConnection(tester, harness);

      expect(find.text('还没有连接任何电脑'), findsOneWidget);
      expect(harness.factory.links, isEmpty);

      await _openHomeMenu(tester);
      expect(find.text('移除已配对电脑'), findsOneWidget);
      expect(find.text('本机还没有已配对电脑'), findsOneWidget);

      await tester.tap(find.text('移除已配对电脑'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('remote-manage-device-sheet')),
        findsNothing,
        reason: '没有设备时入口不可点，不会弹出空的管理弹层',
      );
      // 收起可能还开着的菜单，再拆页面。
      await tester.tapAt(const Offset(4, 300));
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('移除当前连接的电脑：先断开、删本机记录，设备条立即收敛', (tester) async {
      final harness = await harnessWith(neverConnected: false);
      await _showConnection(tester, harness);
      _completeHandshake(harness, 0, '客厅的电脑');
      await _flushConnection(tester);
      expect(harness.factory.links, hasLength(1));

      await _openHomeMenu(tester);
      await tester.tap(find.text('移除已配对电脑'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('remote-manage-device-sheet')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('remote-manage-device-$_livingRoomId')),
      );
      await tester.pumpAndSettle();
      expect(find.text('移除已配对电脑'), findsWidgets, reason: '先弹二次确认');
      await tester.tap(find.byKey(const ValueKey('remote-remove-confirm')));
      await _flushConnection(
        tester,
        until: () =>
            harness.controller.phase == RemoteConnectionPhase.idle &&
            harness.vault.values.length == 1,
      );

      // 先断开当前连接：旧传输关闭、阶段回 idle。
      expect(harness.factory.links.single.isClosed, isTrue);
      expect(harness.controller.phase, RemoteConnectionPhase.idle);
      expect(harness.controller.activeDevice, isNull);
      expect(find.text('客厅的电脑'), findsNothing);

      // 只删本机记录与令牌（偏好原文里只剩书房那台，且不再记着上次连接）。
      final stored = harness.decode();
      final storedDevices = (stored['devices'] as List)
          .cast<Map<String, dynamic>>();
      expect(storedDevices.map((row) => row['id']), <String>[_studyId]);
      expect(stored.containsKey(paired.remoteLastConnectedDeviceKey), isFalse);
      expect(harness.vault.values.keys, <String>['remote-device/$_studyId']);

      // 自动连接不会因为「少了一台」再发起：每个页面实例只自动连一次。
      expect(harness.factory.links, hasLength(1));
      expect(find.textContaining('已从这台手机移除'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('入站通知不触发首页重读（60fps：胶囊条不随通知重建）', (tester) async {
      final harness = await harnessWith();
      await _showConnection(tester, harness);
      _completeHandshake(harness, 0, '客厅的电脑');
      await _flushConnection(tester);

      final requestsBefore = List<String>.of(
        harness.factory.links.single.requests,
      );
      final savesBefore = harness.saveCalls;
      for (var index = 0; index < 3; index++) {
        harness.factory.links.single.emit('session.event', <String, dynamic>{
          'sessionId': 's-$index',
        });
      }
      await tester.pumpAndSettle();

      expect(
        harness.factory.links.single.requests,
        requestsBefore,
        reason: '入站通知不改变首页，不应重读设备表与 sessions.list',
      );
      expect(harness.saveCalls, savesBefore, reason: '通知不触发设备表回写');

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  });

  group('通知点击深链', () {
    RemoteNotificationLaunch launch(String sessionId) =>
        RemoteNotificationLaunch(
          sessionId: sessionId,
          kind: RemoteNotificationKind.taskCompleted,
          tag: 'turn:3',
        );

    Future<_HomeConnectionHarness> harnessFor(
      List<paired.RemoteDevice> devices, {
      String? lastConnectedDeviceId,
    }) async {
      final harness = _HomeConnectionHarness(
        devices: devices,
        lastConnectedDeviceId: lastConnectedDeviceId,
      );
      addTearDown(harness.dispose);
      harness.authorize(devices);
      return harness;
    }

    /// 电脑上的会话行；`sessions.list` 的既有投影形状。
    List<Map<String, dynamic>> sessionRows(List<String> ids) =>
        <Map<String, dynamic>>[
          for (final id in ids)
            <String, dynamic>{
              'header': <String, dynamic>{
                'id': id,
                'cwd': r'C:\Users\colin\Pocket',
              },
              'title': '会话 $id',
            },
        ];

    testWidgets('连接就绪后按 sessionId 打开通知里的远程会话', (tester) async {
      final harness = await harnessFor(<paired.RemoteDevice>[
        _livingRoom(),
      ], lastConnectedDeviceId: _livingRoomId);
      final log = _RouteLog();
      await _showConnection(
        tester,
        harness,
        observer: log,
        launch: launch('s-2'),
      );
      harness.factory.links.single.sessions = sessionRows(<String>[
        's-1',
        's-2',
      ]);

      expect(
        find.byType(RemoteDshConversationPage),
        findsNothing,
        reason: '连接就绪前不能打开一个没有数据源的会话页',
      );
      expect(find.text('正在连接「客厅的电脑」'), findsOneWidget);

      _completeHandshake(harness, 0, '客厅的电脑');
      await _flushConnection(tester);

      expect(
        log.names,
        contains(destinationRouteName('remote-session:s-2')),
        reason: '就绪后打开通知里的会话，而不是只停在远程首页',
      );
      expect(find.byType(RemoteDshConversationPage), findsOneWidget);
      expect(find.text('会话 s-2'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('会话已归档或不在该电脑上：留在首页并给出可见提示', (tester) async {
      final harness = await harnessFor(<paired.RemoteDevice>[
        _livingRoom(),
      ], lastConnectedDeviceId: _livingRoomId);
      final log = _RouteLog();
      await _showConnection(
        tester,
        harness,
        observer: log,
        launch: launch('s-gone'),
      );
      harness.factory.links.single.sessions = sessionRows(<String>['s-1']);

      _completeHandshake(harness, 0, '客厅的电脑');
      await _flushConnection(tester);

      expect(find.byType(RemoteDshConversationPage), findsNothing);
      expect(
        log.names,
        isNot(contains(destinationRouteName('remote-session:s-gone'))),
      );
      expect(find.text('会话已归档或不在该电脑上。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('remote-session-$_livingRoomId-s-1')),
        findsOneWidget,
        reason: '首页项目列表保持可用，用户可以从列表继续找',
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('连接失败：停在首页既有失败态并说明会话没打开', (tester) async {
      final harness = await harnessFor(<paired.RemoteDevice>[
        _livingRoom(),
      ], lastConnectedDeviceId: _livingRoomId);
      await _showConnection(tester, harness, launch: launch('s-1'));
      final link = harness.factory.links.single;
      link.lost('auth-failed', '连接被拒绝：设备令牌无效。请在电脑上重新配对这台手机。');
      await _flushConnection(tester, until: () => link.isClosed);

      expect(find.text('没能连接到「客厅的电脑」'), findsWidgets);
      expect(find.text('重试'), findsOneWidget);
      expect(find.textContaining('通知里的会话没能打开'), findsOneWidget);
      expect(find.byType(RemoteDshConversationPage), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('本机还没有已配对电脑：首页空态 + 可见提示', (tester) async {
      final harness = await harnessFor(const <paired.RemoteDevice>[]);
      await _showConnection(tester, harness, launch: launch('s-1'));

      expect(find.text('还没有连接任何电脑'), findsOneWidget);
      expect(find.textContaining('本机还没有配对电脑'), findsOneWidget);
      expect(harness.factory.links, isEmpty);
      expect(find.byType(RemoteDshConversationPage), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('多台电脑且没有上次连接记录：不猜测设备，提示先选择电脑', (tester) async {
      final harness = await harnessFor(<paired.RemoteDevice>[
        _livingRoom(connectedBefore: false),
        _study(connectedBefore: false),
      ]);
      await _showConnection(tester, harness, launch: launch('s-1'));

      expect(harness.factory.links, isEmpty, reason: '无法判断通知来源设备时不自动切换/连接任何一台');
      expect(find.textContaining('无法确定通知来自哪台电脑'), findsOneWidget);
      expect(find.byType(RemoteDshConversationPage), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('本地运行时未就绪时不抢跑连接，就绪后自动连接并打开 pending 会话', (tester) async {
      final harness = await harnessFor(<paired.RemoteDevice>[
        _livingRoom(),
      ], lastConnectedDeviceId: _livingRoomId);
      // 冷启动由通知拉起：页面先挂载，runtime.start() 还没完成。
      final runtime = LibraryRuntime()..phase = 'starting';
      addTearDown(runtime.dispose);
      final log = _RouteLog();
      await _showConnection(
        tester,
        harness,
        runtime: runtime,
        observer: log,
        launch: launch('s-2'),
      );

      expect(
        harness.factory.links,
        isEmpty,
        reason: '本机凭据服务未就绪时读不到设备令牌，连接会被拒绝；必须等 runtime ready',
      );
      expect(find.byType(RemoteDshConversationPage), findsNothing);

      // 本机运行时就绪：远程页监听 runtime 变化后补一次自动连接。
      runtime.changeConnection('ready');
      await _flushConnection(
        tester,
        until: () => harness.factory.links.isNotEmpty,
      );
      expect(harness.factory.links, hasLength(1));
      harness.factory.links.single.sessions = sessionRows(<String>[
        's-1',
        's-2',
      ]);
      _completeHandshake(harness, 0, '客厅的电脑');
      await _flushConnection(tester);

      expect(
        log.names,
        contains(destinationRouteName('remote-session:s-2')),
        reason: 'runtime ready → 连接 ready 后应打开通知里的会话',
      );
      expect(find.byType(RemoteDshConversationPage), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('连接失败不清空 pending，重试成功后打开通知里的会话', (tester) async {
      final harness = await harnessFor(<paired.RemoteDevice>[
        _livingRoom(),
      ], lastConnectedDeviceId: _livingRoomId);
      final log = _RouteLog();
      await _showConnection(
        tester,
        harness,
        observer: log,
        launch: launch('s-2'),
      );
      final first = harness.factory.links.single;
      first.lost('auth-failed', '连接被拒绝：设备令牌无效。请在电脑上重新配对这台手机。');
      await _flushConnection(tester, until: () => first.isClosed);

      expect(find.byType(RemoteDshConversationPage), findsNothing);
      expect(find.textContaining('通知里的会话没能打开'), findsOneWidget);

      // 用户点「重试」：第一次失败不能把 pending 消费掉。
      await tester.tap(find.text('重试'));
      await _flushConnection(
        tester,
        until: () => harness.factory.links.length == 2,
      );
      harness.factory.links[1].sessions = sessionRows(<String>['s-1', 's-2']);
      _completeHandshake(harness, 1, '客厅的电脑');
      await _flushConnection(tester);

      expect(
        log.names,
        contains(destinationRouteName('remote-session:s-2')),
        reason: '失败只提示、不丢弃 pending；重试连上后仍要打开通知里的会话',
      );
      expect(find.byType(RemoteDshConversationPage), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('pending 会话只消费一次，返回首页刷新不会重复打开', (tester) async {
      final harness = await harnessFor(<paired.RemoteDevice>[
        _livingRoom(),
      ], lastConnectedDeviceId: _livingRoomId);
      final log = _RouteLog();
      await _showConnection(
        tester,
        harness,
        observer: log,
        launch: launch('s-2'),
      );
      harness.factory.links.single.sessions = sessionRows(<String>[
        's-1',
        's-2',
      ]);
      _completeHandshake(harness, 0, '客厅的电脑');
      await _flushConnection(tester);

      final route = destinationRouteName('remote-session:s-2');
      expect(log.names.where((name) => name == route), hasLength(1));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await _flushConnection(tester);

      expect(find.byType(RemoteDshConversationPage), findsNothing);
      expect(
        log.names.where((name) => name == route),
        hasLength(1),
        reason: '返回首页会重读列表；pending 已消费，不应再次打开同一会话',
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  });
}
