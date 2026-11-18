// 远程 DSH 首页：连接一台电脑后，浏览那台电脑上的项目与会话。
//
// 页面结构对齐设计参照截图：自建浮动头部（菜单、标题加下拉箭头、搜索）、
// 设备胶囊条、「项目」分组与底部悬浮输入卡；项目列表滚到浮动头部下方。
//
// 头部的搜索按钮把头部原地切成一个搜索输入框：输入时按项目名与会话标题在本地
// 过滤，清空或关闭搜索后恢复完整列表。底部输入卡与会话页共用 `PocketComposer`
// 的三态：缩小时只有加号、占位「与 <设备名> 新对话」与发送圆钮；聚焦输入、键盘
// 弹起或有草稿时展开为「输入区 + 工具条」；点工具条上的推理按钮切换为「电脑默认
// 模型 + 默认强度」只读面板（数据来自 `settings.describe` 与模型目录，修改入口是
// 远程设置页）。首页没有会话，因此「+」弹层只说明「进入会话后可添加文件与指令」。
// 输入卡在连接就绪后可用，提交非空内容会在那台电脑上新建一个会话并打开它；新建
// 期间卡片右侧换成进度，失败保留草稿并给出电脑返回的原因。
// 「已归档任务」菜单项打开独立的全屏目的地（`RemoteDshArchivedPage`），在那里
// 可以查看并恢复电脑上已归档的会话。「电脑文件」与「设置」分别打开
// `RemoteWorkspaceFilesPage` 与 `RemoteDshSettingsPage`；从这些目的地返回后首页
// 重读一次列表，电脑上改过的标题、归档状态因此即时可见。
//
// 本页不直接发网络请求：数据来自 [RemoteDshDataSource]。调用方没有注入
// [RemoteConnectionController] 时本页自己创建一个，并用 [RemoteDshLiveSource]
// 读真实设备（本机已配对的电脑）与那台电脑上的项目、会话；只有显式给了
// [RemoteDshPage.source] 时数据才完全来自调用方。页面结构与排序逻辑对两种数据源
// 完全相同。写操作（新建会话）与已归档会话、电脑文件、电脑设置来自可选的能力
// 接口 [RemoteDshSessionCreator]、[RemoteDshArchiveSource]、[RemoteDshFilesSource]
// 与 [RemoteDshSettingsSource]：只读数据源没有实现时，对应入口给出可见的
// 「暂未开放」提示；实现了但电脑声明不可用时，入口置灰并展示原因（协议 §10.2）。
//
// 多台电脑：设备胶囊条列出本机全部已配对电脑，选中项说明当前连接的是哪台
// （名称来自握手时电脑自报的 `host.name`，见 [RemoteDeviceStore.markConnected]）；
// 点另一台会先干净关闭旧连接再连新的。冷启动自动连上次成功连接的那台（没有记录
// 时只在恰好一台的情况下自动连）；失败停在失败态并给出「重试 / 切换设备」，不会
// 静默退回旧电脑。菜单「管理 → 移除已配对电脑」只删本机记录与令牌，移除当前连接
// 的电脑前先断开。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_sidebar.dart';
import 'flclash/popup.dart';
import 'flclash/typography.dart';
import 'model_reasoning.dart';
import 'pocket_composer.dart';
import 'remote_connection.dart';
import 'remote_conversation_live_source.dart';
import 'remote_dsh_archived_page.dart';
import 'remote_dsh_conversation.dart';
import 'remote_device_store.dart' as paired;
import 'remote_dsh_live_source.dart';
import 'remote_home_cache.dart';
import 'remote_dsh_settings_page.dart';
import 'remote_dsh_widgets.dart';
import 'remote_notification_navigation.dart';
import 'remote_notifications.dart';
import 'remote_pairing_page.dart';
import 'remote_sync_service.dart';
import 'remote_terminal_page.dart';
import 'remote_workspace_files_page.dart';
import 'runtime.dart';
import 'ui.dart';

/// 首页与那台电脑之间的连接状态。
enum RemoteDshConnectionState {
  /// 还没有配对任何电脑。
  notConnected,

  /// 正在连接或握手，此时还没有可读的项目。
  connecting,

  /// 已连接，可以读取那台电脑上的项目与会话。
  connected,

  /// 连接终止（令牌失效、设备被撤销、版本不匹配等），需要用户重新连接或配对。
  failed,
}

/// 已配对电脑的在线状态，只影响胶囊条上的状态点。
enum RemoteDshDeviceState { online, connecting, offline }

/// 一台已配对的电脑，只承载展示字段。
class RemoteDshDevice {
  const RemoteDshDevice({
    required this.id,
    required this.label,
    this.state = RemoteDshDeviceState.online,
  });

  /// 设备标识，与 [RemoteDshProject.deviceId] 对应，也用于胶囊条的选中比较。
  final String id;

  /// 设备显示名，例如「公司笔记本」。
  final String label;

  /// 在线状态。
  final RemoteDshDeviceState state;
}

/// 那台电脑上的一个会话。
class RemoteDshSession {
  const RemoteDshSession({
    required this.id,
    required this.title,
    this.pendingCount = 0,
    this.updatedAt,
    this.running = false,
  });

  /// 会话标识。
  final String id;

  /// 会话标题。
  final String title;

  /// 等待你处理的项数（审批、提问等）；没有未处理项时为 0。
  final int pendingCount;

  /// 最近更新的 Unix 毫秒；电脑没有给出更新时间时为 null。
  final int? updatedAt;

  /// 宿主上这个会话是否正在执行（`sessions.list` 行的 `running`）。
  final bool running;
}

/// 那台电脑上的一个项目，展开后是它的会话。
class RemoteDshProject {
  const RemoteDshProject({
    required this.id,
    required this.deviceId,
    required this.name,
    this.sessions = const [],
  });

  /// 项目标识。
  final String id;

  /// 项目所属的设备，用于设备胶囊条的过滤。
  final String deviceId;

  /// 项目名，例如「CarsTool」。
  final String name;

  /// 项目内的会话；顺序由数据源给出，页面按排序方式重排。
  final List<RemoteDshSession> sessions;
}

/// 按 [query] 过滤项目与会话（大小写不敏感的包含匹配，已去掉首尾空白）。
///
/// 规则：
///
/// - 项目名匹配时保留整个项目（包括它的全部会话）；
/// - 否则只保留标题匹配的会话，项目内没有匹配会话时该项目整体隐藏；
/// - [query] 去掉空白后为空时原样返回 [projects]，也就是「清空搜索即恢复」。
///
/// 纯函数：不读数据源、不改原列表，因此排序方式与搜索可以各自独立测试。
List<RemoteDshProject> filterRemoteProjects(
  List<RemoteDshProject> projects,
  String query,
) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return projects;
  final filtered = <RemoteDshProject>[];
  for (final project in projects) {
    final projectMatches = project.name.toLowerCase().contains(needle);
    final sessions = projectMatches
        ? project.sessions
        : <RemoteDshSession>[
            for (final session in project.sessions)
              if (session.title.toLowerCase().contains(needle)) session,
          ];
    if (!projectMatches && sessions.isEmpty) continue;
    filtered.add(
      RemoteDshProject(
        id: project.id,
        deviceId: project.deviceId,
        name: project.name,
        sessions: sessions,
      ),
    );
  }
  return filtered;
}

/// 首页渲染一次所需的全部数据。
class RemoteDshView {
  const RemoteDshView({
    required this.connection,
    this.hostName,
    this.devices = const [],
    this.projects = const [],
  });

  /// 当前连接状态。
  final RemoteDshConnectionState connection;

  /// 当前连接中的电脑显示名；未连接时为 null。
  final String? hostName;

  /// 已配对的电脑；未连接时为空列表。
  final List<RemoteDshDevice> devices;

  /// 那台电脑上的项目；未连接时为空列表。
  final List<RemoteDshProject> projects;
}

/// 远程首页的数据来源。
///
/// 页面缺省用 [RemoteDshLiveSource]：它从 [RemoteConnectionController] 读本机已
/// 配对的电脑与那台电脑上的项目，因此页面本身不直接调用任何门面方法。调用方也可以
/// 传入自己的实现（例如 [RemoteDshPlaceholderSource] 或测试替身），页面结构与排序
/// 逻辑对任何数据源都相同。
abstract class RemoteDshDataSource {
  /// 当前连接状态。
  RemoteDshConnectionState get connection;

  /// 当前连接中的电脑显示名；未连接时为 null。
  String? get hostName;

  /// 已配对的电脑；未连接时为空列表。
  Future<List<RemoteDshDevice>> listDevices();

  /// 那台电脑上的项目与会话；未连接时为空列表。
  Future<List<RemoteDshProject>> listProjects();
}

/// 占位数据源：永远是「未连接」、两个列表都为空，不发网络请求。
class RemoteDshPlaceholderSource implements RemoteDshDataSource {
  const RemoteDshPlaceholderSource();

  @override
  RemoteDshConnectionState get connection =>
      RemoteDshConnectionState.notConnected;

  @override
  String? get hostName => null;

  @override
  Future<List<RemoteDshDevice>> listDevices() async => const [];

  @override
  Future<List<RemoteDshProject>> listProjects() async => const [];
}

/// 「项目」分组的排序方式，对应标题菜单里的三个排序项。
enum RemoteDshOrder {
  /// 优先级：项目内有待处理项的会话排在最前。
  priority,

  /// 按项目：保留电脑给出的项目与会话顺序。
  byProject,

  /// 按时间倒序：项目内按最近更新时间从新到旧。
  newest,
}

/// 远程 DSH 首页。
///
/// [runtime] 是 App 的运行时；[source] 与 [connection] 都可省略：
///
/// - 不给 [source] 时数据源是 [RemoteDshLiveSource]（[connection] 省略时本页
///   自己创建一个），设备胶囊条用真实设备列表，点设备会连接或切换电脑；
/// - 给 [source] 时以它为准，本页不读连接控制器的数据（只用它渲染失败原因）。
///
/// 注入的 [connection] 由调用方持有并 dispose；本页自己创建的那个在 [dispose]
/// 时释放，因此从侧栏直接进入本页也不会留下一条没关掉的连接。
class RemoteDshPage extends StatefulWidget {
  const RemoteDshPage({
    super.key,
    required this.runtime,
    this.source,
    this.connection,
    this.archivedSource,
    this.notificationLaunch,
    this.syncLifecycle,
    this.notificationPermission,
  });

  /// 本页作为全屏目的地的标识（见 [openDestination]）。
  ///
  /// 侧栏推入本页、以及本页内挂出的侧栏判断「是不是已经在这里」都用它；
  /// 两边必须一致，否则重复选择会再压入一层同样的页面。
  static const routeDestination = 'remote-dsh';

  /// 当前 App 的运行时。
  final RuntimeController runtime;

  /// 指定的数据源；省略时按 [connection] 决定。
  final RemoteDshDataSource? source;

  /// 远程连接控制器；省略时本页按 [runtime] 自己创建一个并负责释放。
  ///
  /// 无论哪种来源，页面都跟着它的阶段刷新，并允许点设备切换连接。
  final RemoteConnectionController? connection;

  /// 已归档任务页的数据来源；省略时若 [source] 自己实现了
  /// [RemoteDshArchiveSource] 就直接用它（实时数据源就是这样）。
  ///
  /// 只读的测试替身没有实现该接口时，「已归档任务」入口给出可见提示。
  final RemoteDshArchiveSource? archivedSource;

  /// 点击系统通知带来的待打开会话；null 表示普通进入。
  ///
  /// 页面在连接就绪、项目列表读完后只处理一次：会话在列表里就直接打开；不在列表
  /// （已归档/已删除/属于另一台电脑）或连接失败时留在远程首页，并用可见提示说明
  /// 原因，不把用户留在 loading。来源设备的限制见 [RemoteNotificationLaunch]。
  final RemoteNotificationLaunch? notificationLaunch;

  /// 后台同步服务的生命周期控制；为 null 时用 `dsh/runtime` 的默认通道。
  ///
  /// 首页持有远程连接控制器：连接 ready 时在前台启动主进程前台服务，连接
  /// failed/idle 或页面销毁时停止。App 退后台不停止，让 `session.follow` 与
  /// `remote.*` 通知在后台继续到达；只在测试/组合时注入假实现。
  final RemoteSyncLifecycle? syncLifecycle;

  /// Android 13+ 通知运行时权限请求入口；为 null 时走 `dsh/runtime` 默认实现。
  ///
  /// 连接 ready、启动后台同步服务时调用一次 `ensureRequested`：未授予则弹系统
  /// 权限框，已授予/拒绝过则不再重复打扰。测试可注入假实现。
  final RemoteNotificationPermission? notificationPermission;

  @override
  State<RemoteDshPage> createState() => _RemoteDshPageState();
}

/// 标题菜单里可选项。
enum _HomeMenuChoice {
  priority,
  byProject,
  newest,
  recentFirst,
  archived,
  files,
  removeDevice,
  addConnection,
  settings,
}

class _RemoteDshPageState extends State<RemoteDshPage>
    with WidgetsBindingObserver {
  /// 浮动头部的渲染对象，用来算出标题菜单的锚点。
  final _headerKey = GlobalKey();
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();

  /// 头部搜索输入框的控制器与焦点；只在搜索模式使用。
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  /// 是否把头部切成搜索输入框。
  bool _searching = false;

  /// 当前搜索词（已同步到 [_search]）；空串表示不过滤。
  String _searchQuery = '';

  /// 是否正在那台电脑上新建会话。
  bool _creating = false;

  /// 输入卡是否为空草稿；用来决定发送按钮是否出现，避免每次按键都重建整页。
  bool _draftEmpty = true;

  /// 底部输入卡的当前基础状态（picker 打开时实际状态由 [_pickerOpen] 决定）。
  ///
  /// 缩小态（[PocketComposerMode.browse]）只显示加号、占位文案与发送圆钮；聚焦、
  /// 键盘弹起或有草稿时展开为 [PocketComposerMode.composing]；点模型/推理按钮后
  /// 切换为只读的默认模型面板 [PocketComposerMode.picker]。
  PocketComposerMode _composerMode = PocketComposerMode.browse;

  /// 默认模型面板是否打开。
  ///
  /// 与 [_composerMode] 分开记一个粘滞标记：一旦用户点了推理按钮，picker 就
  /// 不会因为键盘收起、焦点变化或 metrics 抖动被折叠回 browse——只有显式退出
  /// （再点推理按钮、点列表、发送、打开别的页面）才清除。真机上键盘/IME 的
  /// 异步事件可能晚于点按到达，只看瞬时的 insets 会把刚打开的面板吃掉。
  bool _pickerOpen = false;

  /// 实际渲染用的输入卡状态：面板打开时恒为 picker。
  PocketComposerMode get _effectiveComposerMode =>
      _pickerOpen ? PocketComposerMode.picker : _composerMode;

  /// 记录一次状态切换（仅 debug 包输出，真机诊断用）+ 赋值。
  ///
  /// 真机上键盘与焦点事件是异步的，出问题时可以用
  /// `adb logcat -s flutter` 看到是哪条事件把卡片切走的。
  void _setComposerMode(PocketComposerMode next, String reason) {
    if (_composerMode == next) return;
    assert(() {
      debugPrint(
        '[remote-home-composer] $reason: '
        '${_composerMode.name} -> ${next.name}',
      );
      return true;
    }());
    _composerMode = next;
  }

  /// 上一次 metrics 事件里键盘是否真的可见；只有真正的 0→可见→0 才改状态。
  bool _keyboardVisible = false;

  /// 首页输入卡的默认模型数据：电脑设置快照与模型目录（只用于显示名/档位）。
  ///
  /// 首页没有会话，因此这里只读：默认模型来自 `settings.describe` 的
  /// `agent-default-model` 一节，模型目录来自 `session.modelCatalog`；修改入口是
  /// 远程设置页。两者都在第一次打开面板时读一次并缓存。
  RemoteDshSettingsSnapshot? _composerSettings;
  RemoteDshModelCatalog? _composerCatalog;
  bool _composerSettingsLoading = false;
  String? _composerSettingsError;
  bool _composerSettingsRetryable = false;

  /// 已归档任务页的数据来源；当前数据源不支持归档时为 null。
  RemoteDshArchiveSource? _archivedSource;

  /// 新建会话的能力；当前数据源是只读替身时为 null。
  RemoteDshSessionCreator? _creator;

  /// 电脑文件的数据来源；当前数据源不支持浏览文件时为 null。
  RemoteDshFilesSource? _filesSource;

  /// 电脑设置的数据来源；当前数据源不支持远程设置时为 null。
  RemoteDshSettingsSource? _settingsSource;

  /// 默认模型候选（模型目录）的来源；为 null 时设置页退回手动填写。
  RemoteDshModelCatalogSource? _catalogSource;

  /// 页面实际使用的连接控制器：注入的优先，未注入时由本页创建。
  ///
  /// 未注入也必须有一个：否则数据源会退回占位源，页面既读不到本机已配对的电脑，
  /// 也没有对象可以发起连接与配对。
  late final RemoteConnectionController _connection;

  /// [connection] 是否由本页创建；为 true 时由本页负责 [RemoteConnectionController.dispose]。
  bool _ownsConnection = false;

  /// 后台同步前台服务：首页连接生命周期驱动，App 退后台不停止。
  late final RemoteSyncLifecycle _syncLifecycle =
      widget.syncLifecycle ?? MethodChannelRemoteSyncLifecycle();

  /// 是否已经向平台请求启动后台同步；重复 start/stop 由 RemoteSyncLifecycle 幂等处理。
  bool _syncStarted = false;

  /// 通知权限请求：与后台同步一起在连接 ready 时触发一次。
  late final RemoteNotificationPermission _notificationPermission =
      widget.notificationPermission ??
      MethodChannelRemoteNotificationPermission();

  /// 数据源：显式 [RemoteDshPage.source] 优先，否则按 [_connection] 建实时源。
  RemoteDshDataSource _source = const RemoteDshPlaceholderSource();

  late RemoteDshView _view;
  final _recentByDevice = <String, List<RemoteDshProject>>{};

  /// 已经成功读到过项目列表的设备（含返回空列表的情况）。
  ///
  /// 用来区分「还没读」与「读到了，只是没有项目」：连接刚刚 ready 时
  /// `_recentByDevice` 里没有这台设备，不能立刻显示「还没有项目」空态；只有
  /// `listProjects` 成功返回后才把设备记进来，`_content` 才允许渲染空态。
  final _projectsLoadedFor = <String>{};

  /// 项目展开状态，key 为 `deviceId + '\u0000' + projectId`。
  ///
  /// 放在页面级而不是 `RemoteProjectGroup` 的局部 state 里：首页列表会因轮询、
  /// 搜索过滤、切换设备而重建/重排，局部 state 会跟着元素位置被重置，表现为
  /// 「折叠后刷新又全展开」。缺省视为展开；用户折叠后立即写回本地缓存。
  final _projectExpanded = <String, bool>{};
  final _homeCache = const RemoteHomeCache();
  late final Future<void> _cacheRestore;
  String? _selectedDeviceId;
  int _loadGeneration = 0;
  bool _deviceListLoaded = false;
  ({RemoteDshProject project, RemoteDshSession? session})?
  _pendingProjectAction;
  StreamSubscription<Map<String, dynamic>>? _homeEvents;
  Timer? _recentRefresh;

  /// 本页自己的 Scaffold，用来**原地**打开侧栏（不离开远程页面）。
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// 原地挂出与根对话页同一份侧栏。
  ///
  /// 侧栏里的「新对话 / 选择会话 / 后台任务 / 自动化任务」属于根页面，因此这些
  /// 动作先收起侧栏、回到根页面，再执行根页面注册的同一条动作；「关闭」只收起
  /// 侧栏，仍停在远程页。
  Widget _appSidebar() {
    final actions = appShellActions;
    void leave(VoidCallback action) {
      _scaffoldKey.currentState?.closeDrawer();
      Navigator.of(context).popUntil((route) => route.isFirst);
      action();
    }

    return ChatSidebar(
      runtime: widget.runtime,
      // 远程页没有选中的本地会话：「全部」语义下侧栏就应当没有当前项。
      currentSessionId: '',
      // 侧栏在远程页里原地挂出：高亮「远程 DSH」表明当前位置。
      remoteDshSelected: true,
      onClose: () => _scaffoldKey.currentState?.closeDrawer(),
      // 点左上角 App 图标回到 Pocket Harness 首页。
      onOpenHome: () {
        _scaffoldKey.currentState?.closeDrawer();
        Navigator.of(context).popUntil((route) => route.isFirst);
      },
      onNewChat: () {
        if (actions == null) return;
        leave(actions.newChat);
      },
      onSelectSession: (id) {
        if (actions == null) return;
        leave(() => actions.openSession(id));
      },
      onOpenTasks: () {
        if (actions == null) return;
        leave(actions.openTasks);
      },
      onOpenAutomations: () {
        if (actions == null) return;
        leave(actions.openAutomations);
      },
    );
  }

  /// 当前排序方式；默认按项目。
  RemoteDshOrder _order = RemoteDshOrder.byProject;

  /// 是否把最近有活动的项目排在前面。
  bool _recentFirst = true;

  /// 是否已经尝试过冷启动自动连接。
  ///
  /// 每个页面实例只自动连一次：连接失败、移除当前电脑、从会话页返回等后续刷新都
  /// 不再重新发起连接，避免「失败→重试→再失败」的自动重连风暴。用户随时可以点
  /// 设备胶囊或失败提示里的「重试 / 切换设备」。
  bool _autoConnectAttempted = false;

  /// 通知点击带来的待打开会话；处理一次后清空（见 [_resolvePendingLaunch]）。
  ///
  /// 只有成功打开、明确不存在（已归档/删除/属于别的电脑）或页面销毁时才清空：
  /// 连接失败会保留它，用户重试成功后仍应打开这条通知对应的会话。
  RemoteNotificationLaunch? _pendingLaunch;

  /// 上次已经就 pending 未打开给过提示的原因键；同一原因只弹一次。
  String? _pendingLaunchFailure;

  /// 本地运行时是否已经就绪。
  ///
  /// 远程连接读设备令牌走本机凭据服务（`credentials.read`），服务在 `runtime.ready`
  /// 之前会直接拒绝（「运行时正在启动」）。冷启动由通知拉起时本页会先于
  /// `runtime.start()` 完成而挂载，因此自动连接必须等这个标记为 true。
  bool _localRuntimeReady = false;

  /// 读取数据源失败时的中文说明。
  String? _error;

  /// 已展开的标题菜单路由；用它避免重复入栈。
  CommonPopupRoute<void>? _menuRoute;

  /// 上一次触发刷新的连接快照（阶段 + 宿主显示名）。
  ///
  /// 连接层对每条入站通知都会发一次变更，而流式回复期间 `session.live` 最多每 50 ms
  /// 一条；不判重就会在会话页盖住首页时以每秒几十次重读设备表与 `sessions.list`。
  ({RemoteConnectionPhase phase, String? hostName})? _loadedConnection;

  /// 上一次重建页面时可见的连接快照。
  ///
  /// 只有会改变画面的事实（阶段、宿主名、失败原因、设备表里的展示字段）才
  /// `setState`：入站通知本身不改变首页，不该让被会话页盖住的首页每来一条帧就重建
  /// 一次（60 fps 门禁；设备胶囊条不得因通知每帧重建）。
  ({
    RemoteConnectionPhase phase,
    String? hostName,
    String? lastError,
    String devices,
  })?
  _visibleConnection;

  @override
  void initState() {
    super.initState();
    final injected = widget.connection;
    if (injected == null) {
      _connection = RemoteConnectionController(
        store: paired.RemoteDeviceStore(runtime: widget.runtime),
      );
      _ownsConnection = true;
    } else {
      _connection = injected;
    }
    _source = _resolveSource();
    // 能力接口与只读数据源没有继承关系，因此逐个做类型测试；只读替身没有实现
    // 的入口由页面给出可见的「暂未开放」，不会静默失效。
    final source = _source;
    if (source case final RemoteDshArchiveSource archive) {
      _archivedSource = widget.archivedSource ?? archive;
    } else {
      _archivedSource = widget.archivedSource;
    }
    if (source case final RemoteDshSessionCreator creator) {
      _creator = creator;
    }
    // 文件与设置同样是可选能力接口：没有实现的数据源保留「暂未开放」入口，
    // 实现了但电脑声明不可用的由能力状态驱动置灰（协议 §10.2）。
    if (source case final RemoteDshFilesSource files) {
      _filesSource = files;
    }
    if (source case final RemoteDshSettingsSource settings) {
      _settingsSource = settings;
    }
    if (source case final RemoteDshModelCatalogSource catalog) {
      _catalogSource = catalog;
    }
    _connection.addListener(_onConnectionChanged);
    _syncRemoteForConnection();
    _homeEvents = _connection.events.listen(_onHomeEvent);
    widget.runtime.addListener(_onRuntimeChanged);
    WidgetsBinding.instance.addObserver(this);
    _composerFocus.addListener(_onComposerFocusChanged);
    _localRuntimeReady = widget.runtime.ready;
    _view = RemoteDshView(
      connection: _source.connection,
      hostName: _source.hostName,
    );
    _loadedConnection = (
      phase: _connection.phase,
      hostName: _connection.host?.name,
    );
    _visibleConnection = _connectionSnapshot();
    _pendingLaunch = widget.notificationLaunch;
    _cacheRestore = widget.source == null && widget.connection == null
        ? _restoreRecent()
        : Future<void>.value();
    unawaited(_load());
  }

  @override
  void dispose() {
    // 首页是远程连接的持有者：连接随页面一起消失时，后台同步服务也停止。
    _stopRemoteSync();
    _connection.removeListener(_onConnectionChanged);
    unawaited(_homeEvents?.cancel());
    _recentRefresh?.cancel();
    widget.runtime.removeListener(_onRuntimeChanged);
    WidgetsBinding.instance.removeObserver(this);
    _composerFocus.removeListener(_onComposerFocusChanged);
    if (_ownsConnection) _connection.dispose();
    _composer.dispose();
    _composerFocus.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// 按构造参数决定数据源：显式 [RemoteDshPage.source] 优先，其余用连接控制器
  /// 之上的实时数据源。
  RemoteDshDataSource _resolveSource() {
    final source = widget.source;
    if (source != null) return source;
    return RemoteDshLiveSource(controller: _connection);
  }

  /// 连接层状态变化时刷新首页。
  ///
  /// 分两步判重：
  ///
  /// - 画面要变（阶段、宿主名、失败原因、设备表展示字段）才 `setState`。入站通知
  ///   本身不改变首页，流式回复期间不应让被会话页盖住的首页每来一条帧就重建一次；
  /// - 只有阶段或宿主身份变化才重读设备与项目。连接层对每条通知都发一次变更，
  ///   逐条重读会让首页持续打 `runtime.info` + `sessions.list`。
  void _onConnectionChanged() {
    if (!mounted) return;
    // 后台同步跟着连接阶段走：ready 启动；failed/idle 停止；connecting/
    // reconnecting 保持运行，后台才有机会完成重连。
    _syncRemoteForConnection();
    final snapshot = _connectionSnapshot();
    if (_visibleConnection != snapshot) {
      _visibleConnection = snapshot;
      setState(() {
        _view = RemoteDshView(
          connection: _source.connection,
          hostName: _source.hostName,
          devices: _view.devices,
          projects: _view.projects,
        );
      });
    }
    final loaded = (phase: snapshot.phase, hostName: snapshot.hostName);
    if (_loadedConnection == loaded) return;
    _loadedConnection = loaded;
    unawaited(_load());
  }

  /// 按连接阶段启动/停止主进程后台同步服务。
  ///
  /// 只在首页仍挂载时调用；重复调用是幂等的。App 退到后台不会触发停止：前台
  /// 服务让主进程与 Dart isolate 存活，`session.follow` 和 `remote.*` 通知才能
  /// 在后台继续到达。
  void _syncRemoteForConnection() {
    if (!mounted) return;
    switch (_connection.phase) {
      case RemoteConnectionPhase.ready:
        _startRemoteSync();
      case RemoteConnectionPhase.failed:
      case RemoteConnectionPhase.idle:
        _stopRemoteSync();
      case RemoteConnectionPhase.connecting:
      case RemoteConnectionPhase.handshaking:
      case RemoteConnectionPhase.reconnecting:
      case RemoteConnectionPhase.lost:
        break;
    }
  }

  void _startRemoteSync() {
    if (_syncStarted) return;
    _syncStarted = true;
    unawaited(_syncLifecycle.start());
    // Android 13+ 首次 ready 时申请一次通知权限；拒绝后实现内部不再自动弹。
    unawaited(_notificationPermission.ensureRequested());
  }

  void _stopRemoteSync() {
    if (!_syncStarted) return;
    _syncStarted = false;
    unawaited(_syncLifecycle.stop());
  }

  /// Refresh recents only for catalog changes, not for the token-by-token live stream.
  void _onHomeEvent(Map<String, dynamic> event) {
    if (!mounted || _source.connection != RemoteDshConnectionState.connected) {
      return;
    }
    final method = event['method'];
    if (method != 'sessions.changed' &&
        method != 'session.changed' &&
        method != 'remote.sessionChanged') {
      return;
    }
    _recentRefresh?.cancel();
    _recentRefresh = Timer(const Duration(milliseconds: 300), () {
      if (mounted && _source.connection == RemoteDshConnectionState.connected) {
        unawaited(_load());
      }
    });
  }

  /// 会影响首页画面的连接快照；[devices] 是设备表展示字段的拼接。
  ///
  /// 设备条数与字段都很少（个位数设备），这里只拼一个小字符串，比每帧重建整棵
  /// 首页子树便宜得多。
  ({
    RemoteConnectionPhase phase,
    String? hostName,
    String? lastError,
    String devices,
  })
  _connectionSnapshot() => (
    phase: _connection.phase,
    hostName: _connection.host?.name,
    lastError: _connection.lastError,
    devices: [
      for (final device in _connection.devices)
        '${device.id}|${device.label}|${device.hostName ?? ''}'
            '|${device.lastSeenAt?.millisecondsSinceEpoch ?? ''}',
    ].join(','),
  );

  /// 本地运行时（`runtime.start()`）就绪状态变化。
  ///
  /// 冷启动由系统通知拉起时本页会先于运行时就绪而挂载；设备令牌只能在本机凭据服务
  /// 就绪后读取（否则 `credentials.read` 被拒绝为「运行时正在启动」），因此
  /// [_maybeAutoConnect] 在运行时就绪前不发起连接，就绪后在这里补一次 [_load]
  /// 完成自动连接与通知深链的后续步骤。
  void _onRuntimeChanged() {
    if (!mounted || _localRuntimeReady == widget.runtime.ready) return;
    _localRuntimeReady = widget.runtime.ready;
    if (!_localRuntimeReady) return;
    unawaited(_load());
  }

  /// 读取设备与项目；失败时保留「未连接」状态并给出可重试的说明。
  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      final devices = await _source.listDevices();
      if (!mounted || generation != _loadGeneration) return;
      if (widget.source == null && widget.connection == null) {
        _deviceListLoaded = true;
        final pairedIds = devices.map((device) => device.id).toSet();
        _recentByDevice.removeWhere((id, _) => !pairedIds.contains(id));
        _projectsLoadedFor.removeWhere((id) => !pairedIds.contains(id));
        _projectExpanded.removeWhere(
          (key, _) => !pairedIds.contains(_projectExpansionDeviceId(key)),
        );
      }
      setState(() {
        _view = RemoteDshView(
          connection: _source.connection,
          hostName: _source.hostName,
          devices: devices,
          projects: _view.projects,
        );
      });
      _maybeAutoConnect();
      // 这次读取针对的设备：优先当前选中的胶囊，其次活动连接，最后是设备表
      // 第一台（注入数据源的测试与只读替身没有连接控制器，仍能判断首屏加载）。
      final contentDeviceId = _selectedDeviceId ??
          _connection.activeDevice?.id ??
          (devices.isEmpty ? null : devices.first.id);
      final projects = await _source.listProjects();
      if (!mounted || generation != _loadGeneration) return;
      if (_source.connection == RemoteDshConnectionState.connected) {
        final deviceId = _connection.activeDevice?.id;
        if (deviceId != null) _recentByDevice[deviceId] = projects;
        for (final id in projects.map((project) => project.deviceId).toSet()) {
          _recentByDevice[id] = projects
              .where((project) => project.deviceId == id)
              .toList();
        }
        if (widget.source == null && widget.connection == null) {
          unawaited(_persistRecent());
        }
      }
      setState(() {
        _error = null;
        // 读取成功（含空列表）：这台设备之后可以显示真正的空态，而不是转圈。
        if (contentDeviceId != null) _projectsLoadedFor.add(contentDeviceId);
        for (final project in projects) {
          _projectsLoadedFor.add(project.deviceId);
        }
        _view = RemoteDshView(
          connection: _source.connection,
          hostName: _source.hostName,
          devices: devices,
          projects: projects,
        );
      });
      _resolvePendingLaunch();
      _resolveProjectAction();
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      // 门面失败一律是 PlatformException，message 已是可直接展示的中文。
      final detail = error is PlatformException ? error.message : '$error';
      setState(() {
        _error = detail == null || detail.trim().isEmpty ? '请检查连接后重试。' : detail;
      });
      _notifyPendingLaunchFailure('load:$detail', '通知里的会话没能打开：读取会话列表失败。');
    }
  }

  Future<void> _restoreRecent() async {
    final saved = await _homeCache.read();
    if (!mounted || saved.isEmpty) return;
    setState(() {
      for (final entry in saved.projects.entries) {
        if (!_deviceListLoaded ||
            _view.devices.any((device) => device.id == entry.key)) {
          _recentByDevice.putIfAbsent(entry.key, () => entry.value);
        }
      }
      for (final entry in saved.expanded.entries) {
        _projectExpanded.putIfAbsent(entry.key, () => entry.value);
      }
    });
  }

  Future<void> _persistRecent() async {
    await _cacheRestore;
    await _homeCache.write(_recentByDevice, expanded: _projectExpanded);
  }

  /// 通知深链：连接就绪后按会话标识打开会话；打不开时留在首页并给出可见原因。
  ///
  /// 设备归属无法从通知判断（协议 §8.2/§8.3 不带 deviceId），因此只等首页既有的
  /// 自动连接（上次成功连接的电脑优先；没有记录时恰好一台才连），不为了猜测切换
  /// 电脑。
  ///
  /// pending 的生命周期按要求收敛为：**成功打开**、**明确不存在**（已归档/删除/
  /// 属于别的电脑）或**页面销毁**时才清空；连接失败、本地运行时就绪前、读取失败都
  /// 保留，用户重试成功后仍会打开这条通知对应的会话。失败原因用 SnackBar 提示一次
  /// （同一原因不重复弹），首页既有失败态/空态与「重试 / 切换设备」入口同时可见。
  void _resolvePendingLaunch() {
    final launch = _pendingLaunch;
    if (launch == null) return;
    switch (_view.connection) {
      case RemoteDshConnectionState.connected:
        _pendingLaunch = null;
        _pendingLaunchFailure = null;
        final located = _locateSession(launch.sessionId);
        if (located == null) {
          // 已归档、已删除或属于另一台电脑：留在远程首页，用户可以从列表继续找。
          _notice('会话已归档或不在该电脑上。');
          return;
        }
        _openSession(located.project, located.session);
      case RemoteDshConnectionState.connecting:
        // 自动化/用户重试已经开始连接：清掉上一次的失败提示，等 ready 后再消费。
        _pendingLaunchFailure = null;
        if (_connection.phase == RemoteConnectionPhase.lost) {
          _notifyPendingLaunchFailure('lost', '通知里的会话没能打开：与电脑的连接已断开，可以重试。');
        }
      case RemoteDshConnectionState.failed:
        // 连接失败保留 pending：用户点「重试」连上后仍应打开通知里的会话。
        _notifyPendingLaunchFailure(
          'failed:${_connection.lastErrorCode}:${_connection.lastError}',
          '通知里的会话没能打开：连接电脑失败，可以重试。',
        );
      case RemoteDshConnectionState.notConnected:
        // 本地运行时未就绪：设备令牌在本机凭据服务里，服务就绪前连接会被拒绝。
        // 这里什么都不做，[_onRuntimeChanged] 会在就绪后重试自动连接；
        // 运行时不就绪或启动失败时给一次可见提示。
        if (!widget.runtime.ready) {
          if (!_localRuntimeReady && widget.runtime.phase == 'failed') {
            _notifyPendingLaunchFailure(
              'runtime-failed',
              '通知里的会话没能打开：本地服务启动失败。',
            );
          }
          return;
        }
        if (_error != null) {
          _notifyPendingLaunchFailure(
            'devices:$_error',
            '通知里的会话没能打开：读取本机已配对电脑失败。',
          );
          return;
        }
        if (_connection.devices.isEmpty) {
          _notifyPendingLaunchFailure('no-devices', '通知里的会话没能打开：本机还没有配对电脑。');
          return;
        }
        if (_connection.lastConnectedDevice == null) {
          // 多台电脑且没有「上次连接」记录：不猜测设备，等用户自己选一台。
          _notifyPendingLaunchFailure('no-target', '无法确定通知来自哪台电脑，请先在上方选择一台电脑。');
        }
    }
  }

  /// 给「通知里的会话还没打开」的可见提示；同一原因只弹一次，避免刷新时刷屏。
  void _notifyPendingLaunchFailure(String key, String message) {
    if (_pendingLaunch == null || _pendingLaunchFailure == key) return;
    _pendingLaunchFailure = key;
    _notice(message);
  }

  /// 本地运行时未就绪时不允许发起远程连接（设备令牌要经本机凭据服务读取）。
  ///
  /// 用户主动发起的连接（设备胶囊、失败页「重试」、「添加连接」）在服务启动期间
  /// 给出可见提示而不是让连接层报「凭据服务拒绝了这次操作」。
  bool _canStartRemoteConnection() {
    if (widget.runtime.ready) return true;
    _notice('本地服务还在启动，请稍后再连接。');
    return false;
  }

  /// 冷启动自动连接：优先上次成功连接的电脑；否则只在恰好一台已配对电脑时连它。
  ///
  /// 超过一台且没有「上次连接」记录时不做猜测（v1 一次只连一台，协议 §11），由
  /// 用户点设备胶囊选择。每个页面实例只尝试一次：失败后停在失败态并给出「重试 /
  /// 切换设备」，后续刷新（移除电脑、从会话页返回）不会再次自动连接。
  ///
  /// 本地运行时未就绪时不发起连接、也不消耗这一次尝试：设备令牌要经本机凭据服务
  /// 读取，服务就绪前连接必然失败（见 [_onRuntimeChanged]）。
  void _maybeAutoConnect() {
    if (_autoConnectAttempted || !widget.runtime.ready) return;
    _autoConnectAttempted = true;
    if (_connection.phase != RemoteConnectionPhase.idle) return;
    final devices = _connection.devices;
    if (devices.isEmpty) return;
    final target =
        _connection.lastConnectedDevice ??
        (devices.length == 1 ? devices.single : null);
    if (target == null) return;
    unawaited(_connection.connect(target));
  }

  /// 提示某个入口还没有接入，避免点按后没有任何反馈。
  void _unavailable(String feature, {String? detail}) {
    _notice(detail == null ? '「$feature」暂未开放。' : '「$feature」暂未开放：$detail');
  }

  /// 显示一条可见的短提示；错误、结果与未接入入口都用它。
  void _notice(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 头部搜索按钮：把头部原地切成搜索输入框。
  void _openSearch() {
    if (_searching) return;
    _exitComposerPanel(keepKeyboard: false);
    setState(() => _searching = true);
  }

  /// 关闭搜索并恢复完整列表：清掉输入词、收起键盘、头部切回标题。
  void _closeSearch() {
    if (!_searching) return;
    _search.clear();
    _searchFocus.unfocus();
    setState(() {
      _searching = false;
      _searchQuery = '';
    });
  }

  /// 清空搜索词但保持搜索模式；清空即恢复完整列表。
  void _clearSearch() {
    if (_search.text.isEmpty) return;
    _search.clear();
    setState(() => _searchQuery = '');
    _searchFocus.requestFocus();
  }

  /// 输入时立即过滤；原样保留输入词，由 [filterRemoteProjects] 统一去掉空白。
  void _onSearchChanged(String value) {
    if (value == _searchQuery) return;
    setState(() => _searchQuery = value);
  }

  /// 草稿从空变成非空（或反过来）时重建一次，决定发送按钮是否出现，并在有草稿
  /// 时保持输入卡展开（即使输入框没拿到焦点，例如程序写入草稿）。
  void _onComposerChanged(String value) {
    final empty = value.trim().isEmpty;
    if (empty == _draftEmpty) {
      if (!empty &&
          !_pickerOpen &&
          _composerMode == PocketComposerMode.browse) {
        setState(() => _setComposerMode(PocketComposerMode.composing, '草稿'));
      }
      return;
    }
    setState(() {
      _draftEmpty = empty;
      if (!empty &&
          !_pickerOpen &&
          _composerMode == PocketComposerMode.browse) {
        _setComposerMode(PocketComposerMode.composing, '草稿');
      }
    });
  }

  // ------------------------------------------------------------ 输入卡三态

  /// 聚焦输入框即展开输入卡；失焦时只有「纯浏览」才缩回缩小态。
  ///
  /// 面板打开期间忽略焦点事件：面板是粘滞的，不能因为 IME 收起带来的焦点变化
  /// 把卡片折叠回 browse。
  void _onComposerFocusChanged() {
    if (!mounted || _pickerOpen) return;
    if (_composerFocus.hasFocus) {
      if (_composerMode == PocketComposerMode.browse) {
        setState(() => _setComposerMode(PocketComposerMode.composing, '聚焦'));
      }
      return;
    }
    if (_draftEmpty && _composerMode == PocketComposerMode.composing) {
      setState(() => _setComposerMode(PocketComposerMode.browse, '失焦'));
    }
  }

  /// 键盘显隐后同步输入卡状态，语义与远程会话页一致。
  ///
  /// 只有真正的显隐切换才改状态（聚焦时 Android 会先派发「键盘仍不可见」的
  /// metrics，误判会让卡片刚展开就缩回并解焦）；面板打开期间完全不改状态——
  /// 键盘被 IME 收起也不折叠 picker；输入态按草稿决定是否缩回；收起键盘不解焦，
  /// 点卡片可立刻把键盘唤回来。
  void _syncComposerWithKeyboard() {
    if (!mounted) return;
    final visible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final wasVisible = _keyboardVisible;
    _keyboardVisible = visible;
    if (visible == wasVisible) return;
    if (_pickerOpen) return;
    if (visible) {
      if (_composerMode == PocketComposerMode.browse) {
        setState(() => _setComposerMode(PocketComposerMode.composing, '键盘弹起'));
      }
      return;
    }
    if (!_draftEmpty) return;
    setState(() => _setComposerMode(PocketComposerMode.browse, '键盘收起'));
  }

  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncComposerWithKeyboard();
    });
  }

  /// 把焦点交给输入框，并在下一帧补一次输入法显示。
  ///
  /// 与远程会话页同一套处理：真机上输入框已聚焦但 IME 被系统藏起时，再点一次
  /// 不会自动弹键盘，显式 `TextInput.show` 才能让一次点击就进入输入。
  void _requestComposerFocus() {
    if (!_composerFocus.hasFocus) _composerFocus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_composerFocus.hasFocus) return;
      unawaited(_showComposerInput());
    });
  }

  Future<void> _showComposerInput() async {
    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    } on Object {
      // 没有活动输入连接（或测试环境没有通道）时忽略：展开与焦点不依赖它。
    }
  }

  /// 打开/收起默认模型面板（picker）。
  ///
  /// 面板是粘滞的：`_pickerOpen` 一旦置位，键盘收起、焦点变化、metrics 抖动都
  /// 不会把它折叠回 browse；只有显式退出（再点推理按钮、点列表、发送、打开别的
  /// 页面）才清除。打开时不再主动 requestFocus/TextInput.show——用户是在键盘
  /// 弹起、工具条可见时点的按钮，无需再扰动 IME；万一 IME 被系统收起，面板也
  /// 仍然可见（滑杆/模型行不依赖键盘 insets）。
  void _toggleComposerPanel() {
    if (_pickerOpen) {
      _exitComposerPanel();
      return;
    }
    setState(() {
      _pickerOpen = true;
      _setComposerMode(PocketComposerMode.picker, '打开面板');
    });
    if (_composerSettings == null && !_composerSettingsLoading) {
      unawaited(_loadComposerSettings());
    }
  }

  /// 收起默认模型面板。
  ///
  /// [keepKeyboard] 为 true（点推理按钮、发送）时回展开态并把焦点/键盘还给输入
  /// 框；为 false（点列表、打开别的页面）时按键盘与草稿决定：键盘收起且无草稿
  /// 就缩回缩小态，否则回到展开态但不主动唤起键盘。
  void _exitComposerPanel({bool keepKeyboard = true}) {
    if (!_pickerOpen) return;
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final expand = keepKeyboard || keyboardVisible || !_draftEmpty;
    setState(() {
      _pickerOpen = false;
      _setComposerMode(
        expand ? PocketComposerMode.composing : PocketComposerMode.browse,
        keepKeyboard ? '关闭面板' : '关闭面板(不唤键盘)',
      );
    });
    if (keepKeyboard) {
      _requestComposerFocus();
    } else if (!expand && _composerFocus.hasFocus) {
      _composerFocus.unfocus();
    }
  }

  /// 读一次电脑设置（默认模型）与模型目录；目录读取失败只影响显示名，不报错。
  Future<void> _loadComposerSettings() async {
    if (_composerSettingsLoading) return;
    final settings = _settingsSource;
    setState(() {
      _composerSettingsLoading = true;
      _composerSettingsError = null;
      _composerSettingsRetryable = false;
    });
    if (settings == null) {
      setState(() {
        _composerSettingsLoading = false;
        _composerSettingsError = '当前数据源不支持读取电脑设置。';
      });
      return;
    }
    final capability = settings.settingsCapability;
    if (!capability.isAvailable) {
      setState(() {
        _composerSettingsLoading = false;
        _composerSettingsError =
            '「设置」不可用：${capability.reason ?? '这台电脑没有声明该能力。'}';
      });
      return;
    }
    try {
      final snapshot = await settings.describeSettings();
      RemoteDshModelCatalog? catalog;
      final catalogSource = _catalogSource;
      if (catalogSource != null) {
        try {
          catalog = await catalogSource.describeModelCatalog();
        } on Object {
          // 目录只用来把 provider/model 换成显示名与档位；读取失败时回退到路由
          // 原文，面板仍然可用。
        }
      }
      if (!mounted) return;
      setState(() {
        _composerSettings = snapshot;
        _composerCatalog = catalog;
        _composerSettingsLoading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _composerSettingsError = error is PlatformException
            ? (error.message ?? '读取电脑设置失败，请稍后重试。')
            : '读取电脑设置失败：$error';
        _composerSettingsRetryable = true;
        _composerSettingsLoading = false;
      });
    }
  }

  /// 首页默认模型面板的数据：电脑默认模型 + 声明强度（只读）。
  PocketReasoningPanel _composerReasoningPanel() {
    final settings = _composerSettings;
    final route = settings?.defaultModelSection?.defaultModelRoute;
    final model = _composerModelOf(route);
    final reasoning = model?.reasoning;
    final efforts = reasoning?.efforts ?? const <RemoteDshReasoningLevel>[];
    final selected = route?.reasoningEffort ?? reasoning?.defaultEffort;
    final effort = route?.reasoningEffort;
    final capability = _settingsSource?.settingsCapability;
    final canOpenSettings =
        _settingsSource != null && (capability?.isAvailable ?? false);
    return PocketReasoningPanel(
      modelLabel: route == null ? '未设置默认模型' : (model?.name ?? route.label),
      effortLabel: effort == null ? '默认强度' : reasoningEffortLabel(effort),
      stops: <PocketReasoningStop>[
        for (final level in efforts)
          PocketReasoningStop(
            id: level.id,
            label: reasoningEffortLabel(level.id, fallback: level.name),
          ),
      ],
      selectedId: selected,
      // 只读：没有 onSelected，滑杆只回显电脑上的默认强度。
      loading: _composerSettingsLoading,
      error: _composerSettingsError,
      onOpenModels: canOpenSettings ? _openComposerSettings : null,
      onRetry: _composerSettingsRetryable
          ? () => unawaited(_loadComposerSettings())
          : null,
      hint: canOpenSettings ? '默认模型与强度由电脑设置决定，可在「设置」中修改' : '默认模型与强度由电脑设置决定',
    );
  }

  /// 模型目录里按默认路由找到模型声明；目录缺失或找不到时为 null。
  RemoteDshModel? _composerModelOf(RemoteDshModelRoute? route) {
    final catalog = _composerCatalog;
    if (catalog == null || route == null) return null;
    for (final group in catalog.groups) {
      if (group.id != route.provider) continue;
      for (final model in group.models) {
        if (model.id == route.model) return model;
      }
    }
    return null;
  }

  /// 面板第一行/说明里的修改入口：退出面板并打开远程设置页。
  Future<void> _openComposerSettings() async {
    _exitComposerPanel(keepKeyboard: false);
    await _openSettings();
  }

  /// 首页的「+」：打开与「添加与指令」同款弹层，说明首页没有会话、进入会话后可用。
  void _openComposerAddSheet() {
    _exitComposerPanel(keepKeyboard: false);
    _composerFocus.unfocus();
    unawaited(
      showRemoteCommandsSheet(
        context,
        builder: (_) => const _ComposerAddHint(),
      ),
    );
  }

  /// 发送草稿：先收起面板，再走既有新建会话流程。
  void _submitComposerDraft() {
    _exitComposerPanel(keepKeyboard: false);
    unawaited(_createSession());
  }

  /// 标题菜单的锚点：头部去掉左右两个 48dp 按钮后的中间段，坐标取导航器本地坐标。
  Rect? _titleAnchor() {
    final box = _headerKey.currentContext?.findRenderObject();
    final navigator = Navigator.maybeOf(context)?.context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    if (navigator is! RenderBox || !navigator.attached || !navigator.hasSize) {
      return null;
    }
    final rect = box.localToGlobal(Offset.zero, ancestor: navigator) & box.size;
    final title = Rect.fromLTRB(
      rect.left + 48,
      rect.top,
      rect.right - 48,
      rect.bottom,
    );
    // 极窄视口下中间段可能被按钮吃掉，退回整个头部，菜单依旧贴着头部展开。
    return title.width > 0 ? title : rect;
  }

  /// 构造一个可选能力入口的菜单行。
  ///
  /// - 数据源没有实现对应能力接口：入口保留可点，点了给出「暂未开放」的可见提示；
  /// - 实现了但电脑声明不可用（或还没握手、方法表里没有声明）：入口置灰，原因写在
  ///   行内说明里——不允许「能点但没用」（协议 §10.2）；
  /// - 可用：正常点开目的地。
  CommonPopupMenuItem _capabilityMenuItem({
    required String label,
    required IconData glyph,
    required bool implemented,
    required RemoteDshCapability? capability,
    required _HomeMenuChoice choice,
    required ValueChanged<_HomeMenuChoice> onChosen,
    String? section,
  }) {
    if (!implemented) {
      return CommonPopupMenuItem(
        label: label,
        glyph: glyph,
        section: section,
        description: '当前数据源不支持这项能力',
        onPressed: () => onChosen(choice),
      );
    }
    final state = capability;
    if (state == null || !state.isAvailable) {
      return CommonPopupMenuItem(
        label: label,
        glyph: glyph,
        section: section,
        description: state?.reason ?? '这台电脑没有声明这项能力。',
        onPressed: null,
      );
    }
    return CommonPopupMenuItem(
      label: label,
      glyph: glyph,
      section: section,
      onPressed: () => onChosen(choice),
    );
  }

  /// 展开标题菜单：排序项只切换本地状态，未接入的项给出可见提示。
  Future<void> _showHomeMenu() async {
    if (_menuRoute != null) return;
    _exitComposerPanel(keepKeyboard: false);
    final anchor = _titleAnchor();
    if (anchor == null) return;
    final navigator = Navigator.of(context);
    _HomeMenuChoice? chosen;
    final route = CommonPopupRoute<void>(
      anchorOf: () => anchor,
      placement: PopupPlacement.overAnchorEnd,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      builder: (context) => CommonPopupMenu(
        // 菜单共九行加两段小标题，默认 7.5 行的上限会把它截成可滚动，
        // 这里放宽到全部可见；屏幕实在放不下时弹层自己再裁到可用高度。
        maxVisibleItems: 11,
        items: [
          CommonPopupMenuItem(
            label: '优先级',
            glyph: Icons.notifications_outlined,
            checked: _order == RemoteDshOrder.priority,
            onPressed: () => chosen = _HomeMenuChoice.priority,
          ),
          CommonPopupMenuItem(
            label: '按项目',
            glyph: Icons.folder_outlined,
            checked: _order == RemoteDshOrder.byProject,
            onPressed: () => chosen = _HomeMenuChoice.byProject,
          ),
          CommonPopupMenuItem(
            label: '按时间倒序排列',
            glyph: Icons.history_rounded,
            checked: _order == RemoteDshOrder.newest,
            onPressed: () => chosen = _HomeMenuChoice.newest,
          ),
          CommonPopupMenuItem(
            label: '优先显示「最近」',
            glyph: Icons.schedule_rounded,
            checked: _recentFirst,
            onPressed: () => chosen = _HomeMenuChoice.recentFirst,
          ),
          CommonPopupMenuItem(
            label: '已归档任务',
            glyph: Icons.archive_outlined,
            section: '管理',
            onPressed: () => chosen = _HomeMenuChoice.archived,
          ),
          _capabilityMenuItem(
            label: '电脑文件',
            glyph: Icons.computer_rounded,
            section: '管理',
            implemented: _filesSource != null,
            capability: _filesSource?.filesCapability,
            choice: _HomeMenuChoice.files,
            onChosen: (choice) => chosen = choice,
          ),
          CommonPopupMenuItem(
            label: '移除已配对电脑',
            glyph: Icons.delete_outline_rounded,
            section: '管理',
            danger: true,
            description: _connection.devices.isEmpty
                ? '本机还没有已配对电脑'
                : '只删除这台手机上的配对记录与令牌',
            onPressed: _connection.devices.isEmpty
                ? null
                : () => chosen = _HomeMenuChoice.removeDevice,
          ),
          CommonPopupMenuItem(
            label: '添加连接',
            glyph: Icons.add_link_rounded,
            onPressed: () => chosen = _HomeMenuChoice.addConnection,
          ),
          _capabilityMenuItem(
            label: '设置',
            glyph: Icons.settings_outlined,
            implemented: _settingsSource != null,
            capability: _settingsSource?.settingsCapability,
            choice: _HomeMenuChoice.settings,
            onChosen: (choice) => chosen = choice,
          ),
        ],
      ),
    );
    _menuRoute = route;
    try {
      await navigator.push<void>(route);
      await route.completed;
    } finally {
      if (identical(_menuRoute, route)) _menuRoute = null;
    }
    final picked = chosen;
    if (!mounted || picked == null) return;
    _applyHomeMenu(picked);
  }

  void _applyHomeMenu(_HomeMenuChoice choice) {
    switch (choice) {
      case _HomeMenuChoice.priority:
        setState(() => _order = RemoteDshOrder.priority);
      case _HomeMenuChoice.byProject:
        setState(() => _order = RemoteDshOrder.byProject);
      case _HomeMenuChoice.newest:
        setState(() => _order = RemoteDshOrder.newest);
      case _HomeMenuChoice.recentFirst:
        setState(() => _recentFirst = !_recentFirst);
      case _HomeMenuChoice.archived:
        unawaited(_openArchived());
      case _HomeMenuChoice.files:
        unawaited(_openFiles());
      case _HomeMenuChoice.removeDevice:
        unawaited(_openDeviceManager());
      case _HomeMenuChoice.addConnection:
        unawaited(_addConnection());
      case _HomeMenuChoice.settings:
        unawaited(_openSettings());
    }
  }

  /// 点设备胶囊：null 是所有已配对电脑的最近项目与会话。
  ///
  /// 点已经连上（或正在连）的那台不会重复连接；点另一台走 [RemoteConnectionController.switchTo]，
  /// 由连接层先关闭旧连接再连新的（协议 §11）。失败态下点当前设备等于重试。
  void _selectDevice(String? id) {
    setState(() => _selectedDeviceId = id);
    if (id != _pendingProjectAction?.project.deviceId) {
      _pendingProjectAction = null;
    }
    if (id == null) return;
    final device = _pairedDevice(id);
    if (device == null) return;
    final active = _connection.activeDevice;
    if (active?.id == id && _connection.phase != RemoteConnectionPhase.failed) {
      return;
    }
    if (!_canStartRemoteConnection()) return;
    unawaited(_connection.switchTo(device));
  }

  /// 按设备标识找到已配对电脑的记录；找不到时返回 null。
  ///
  /// 返回的是存储层的 [paired.RemoteDevice]（含 CA 与端点），与胶囊条用的展示模型
  /// [RemoteDevice] 不是同一个类。
  paired.RemoteDevice? _pairedDevice(String id) {
    for (final device in _connection.devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  /// 胶囊条上显示的电脑名。
  ///
  /// 数据源给出的 label 在就绪时已经是宿主自报的名字，但离线设备是配对时上报的手机
  /// 名（[paired.RemoteDevice.label] 的约定），不能当电脑名展示。这里以存储层的
  /// 电脑名为准：从没连接过的电脑还没有名字，退回地址。
  String _computerNameOf(RemoteDshDevice device, paired.RemoteDevice? record) {
    if (record == null) return device.label;
    final name = record.hostName?.trim() ?? '';
    if (name.isNotEmpty) return name;
    if (device.state == RemoteDshDeviceState.online) {
      // 就绪时数据源已用宿主名替换 label（电脑名可能还没来得及回写存储层）。
      return device.label;
    }
    return record.host;
  }

  /// 当前连接（或最近一次连接的）电脑显示名；没有电脑时为 null。
  String? _activeComputerName(RemoteDshView view) {
    final activeId = _connection.activeDevice?.id;
    if (activeId != null) {
      for (final device in view.devices) {
        if (device.id == activeId) {
          return _computerNameOf(device, _pairedDevice(activeId));
        }
      }
      final record = _pairedDevice(activeId);
      if (record != null) return record.displayName;
    }
    final hostName = view.hostName?.trim() ?? '';
    return hostName.isEmpty ? null : hostName;
  }

  /// 终止态下的「重新连接」：重连当前设备；没有当前设备时回到「添加连接」。
  void _retryConnection() {
    final device = _connection.activeDevice;
    if (device == null) {
      unawaited(_addConnection());
      return;
    }
    if (!_canStartRemoteConnection()) return;
    unawaited(_connection.connect(device));
  }

  /// 弹层里当前那台电脑的状态说明；失败/连接中不能一概写成「当前连接」。
  String get _currentDeviceSheetLabel {
    if (_connection.activeDevice == null) return '当前连接';
    return switch (_connection.phase) {
      RemoteConnectionPhase.failed => '连接失败',
      RemoteConnectionPhase.connecting ||
      RemoteConnectionPhase.handshaking ||
      RemoteConnectionPhase.reconnecting ||
      RemoteConnectionPhase.lost => '正在连接',
      RemoteConnectionPhase.idle || RemoteConnectionPhase.ready => '当前连接',
    };
  }

  /// 失败态下的「切换设备」：列出已配对电脑，选一台走 [paired.RemoteDeviceStore]
  /// 的切换。没有其它电脑可切换时入口退化成「添加连接」（见 [_content]），不会
  /// 打开一个只有一行的弹层。
  Future<void> _showSwitchDeviceSheet() async {
    final devices = _connection.devices;
    if (devices.isEmpty) {
      await _addConnection();
      return;
    }
    final target = await showModalBottomSheet<paired.RemoteDevice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: .4),
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (sheetContext) => _RemoteDeviceSheet(
        key: const ValueKey('remote-switch-device-sheet'),
        title: '切换设备',
        message: '选择要连接的电脑。切换会先断开当前连接，失败时留在失败页并可重试。',
        children: [
          for (final device in devices)
            _RemoteDeviceSheetRow(
              key: ValueKey('remote-switch-device-${device.id}'),
              record: device,
              active: _connection.activeDevice?.id == device.id,
              activeLabel: _currentDeviceSheetLabel,
              onPressed: () => Navigator.of(sheetContext).pop(device),
            ),
        ],
      ),
    );
    if (!mounted || target == null) return;
    final active = _connection.activeDevice;
    if (active?.id == target.id &&
        _connection.phase != RemoteConnectionPhase.failed) {
      return;
    }
    if (!_canStartRemoteConnection()) return;
    unawaited(_connection.switchTo(target));
  }

  /// 「管理」菜单里的「移除已配对电脑」：选择一台，二次确认后只删本机记录与令牌。
  ///
  /// 不调用宿主撤销接口：电脑上的授权记录还在，只是这台手机不再持有它的令牌。移除
  /// 当前连接的电脑时先断开，保证阶段机与界面立刻回到「未连接」。
  Future<void> _openDeviceManager() async {
    final devices = _connection.devices;
    if (devices.isEmpty) {
      _notice('本机还没有已配对电脑。');
      return;
    }
    final target = await showModalBottomSheet<paired.RemoteDevice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: .4),
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (sheetContext) => _RemoteDeviceSheet(
        key: const ValueKey('remote-manage-device-sheet'),
        title: '管理已配对电脑',
        message:
            '选择要从这台手机移除的电脑。只删除本机的配对记录与设备令牌；'
            '电脑上的授权记录不会自动撤销。',
        children: [
          for (final device in devices)
            _RemoteDeviceSheetRow(
              key: ValueKey('remote-manage-device-${device.id}'),
              record: device,
              active: _connection.activeDevice?.id == device.id,
              activeLabel: _currentDeviceSheetLabel,
              trailingLabel: '移除',
              onPressed: () => Navigator.of(sheetContext).pop(device),
            ),
        ],
      ),
    );
    if (!mounted || target == null) return;
    final name = target.displayName;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('移除已配对电脑'),
        content: Text(
          '移除「$name」？这台手机上会删除它的配对记录与设备令牌，'
          '电脑上的授权记录不会自动撤销。之后想再用这台电脑需要重新配对。',
        ),
        actions: [
          TextButton(
            key: const ValueKey('remote-remove-cancel'),
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('remote-remove-confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _removeDevice(target);
  }

  /// 从本机删除一台已配对电脑：当前连接的先断开，再删令牌与记录，最后重读设备表。
  Future<void> _removeDevice(paired.RemoteDevice device) async {
    final name = device.displayName;
    if (_connection.activeDevice?.id == device.id) {
      // 先断开：移除后阶段机回到 idle，界面与「没有当前电脑」保持一致。
      await _connection.disconnect();
      if (!mounted) return;
    }
    try {
      await _connection.store.remove(device.id);
    } on Object catch (error) {
      if (!mounted) return;
      _notice('移除「$name」失败：${_failureMessage(error)}');
      // 删除令牌可能已经成功、偏好没写成功：重读让界面显示真实剩余状态。
      await _load();
      return;
    }
    if (!mounted) return;
    _recentByDevice.remove(device.id);
    if (widget.source == null && widget.connection == null) {
      unawaited(_persistRecent());
    }
    await _load();
    if (!mounted) return;
    _notice('已从这台手机移除「$name」');
  }

  /// 把存储层/格式类失败转成可直接展示的中文原因。
  static String _failureMessage(Object error) {
    if (error is paired.RemoteDeviceStoreException) return error.message;
    if (error is FormatException) return error.message;
    return '$error';
  }

  /// 打开一个会话。
  ///
  /// 每个会话是独立的全屏目的地（标识 `remote-session:<id>`），推入统一走
  /// [openDestination]，因此同一会话在栈上不会叠第二层。数据源在 builder 里创建：
  /// 万一目的地已经在栈顶而没有推入，也不会留下一条没人释放的订阅。
  void _openSession(RemoteDshProject project, RemoteDshSession session) {
    unawaited(
      _openSessionById(
        sessionId: session.id,
        title: session.title,
        projectName: project.name,
      ),
    );
  }

  /// A cached row can be chosen before its computer reconnects.
  void _activateProjectItem(
    RemoteDshProject project, [
    RemoteDshSession? session,
  ]) {
    if (_source.connection == RemoteDshConnectionState.connected &&
        (widget.source != null ||
            _connection.activeDevice?.id == project.deviceId)) {
      if (session == null) {
        unawaited(_createSession(project: project));
      } else {
        _openSession(project, session);
      }
      return;
    }
    final device = _pairedDevice(project.deviceId);
    if (device == null || !_canStartRemoteConnection()) return;
    _pendingProjectAction = (project: project, session: session);
    _selectDevice(project.deviceId);
  }

  void _resolveProjectAction() {
    final pending = _pendingProjectAction;
    if (pending == null ||
        _source.connection != RemoteDshConnectionState.connected ||
        _connection.activeDevice?.id != pending.project.deviceId) {
      return;
    }
    _pendingProjectAction = null;
    RemoteDshProject? current;
    for (final project in _view.projects) {
      if (project.id == pending.project.id &&
          project.deviceId == pending.project.deviceId) {
        current = project;
        break;
      }
    }
    if (current == null) {
      _notice('这个项目已不在电脑上，请刷新后重试。');
      return;
    }
    final pendingSession = pending.session;
    if (pendingSession == null) {
      unawaited(_createSession(project: current));
      return;
    }
    for (final session in current.sessions) {
      if (session.id == pendingSession.id) {
        _openSession(current, session);
        return;
      }
    }
    _notice('这个会话已不在电脑上，请刷新后重试。');
  }

  /// 按会话标识打开会话页；首页会话行、新建会话与已归档会话都走这里。
  ///
  /// 三条入口共用同一个目的地标识、同一份实时数据源与同一套副标题规则，因此
  /// 新建或恢复来的会话与会话行里的会话在栈上不会各开一种页面。会话页的「终端」
  /// 入口拿到的是首页持有的这条连接（[RemoteControllerTerminalConnection]），
  /// 不新建第二条连接。会话页返回后重读一次列表：电脑上的标题可能被改名、会话也
  /// 可能被归档，首页不能继续显示旧结果。
  Future<void> _openSessionById({
    required String sessionId,
    required String title,
    required String projectName,
  }) async {
    final deviceName = _conversationDeviceName();
    await openDestination<String>(
      context,
      destination: RemoteDshConversationPage.destinationFor(sessionId),
      dragBack: false,
      builder: (_) => RemoteDshConversationPage(
        source: RemoteConversationLiveSource(
          connection: RemoteControllerConnection(_connection),
          sessionId: sessionId,
          events: _connection.events,
        ),
        deviceName: deviceName,
        projectName: projectName,
        title: title,
        terminalConnection: RemoteControllerTerminalConnection(_connection),
      ),
    );
    if (!mounted) return;
    unawaited(_load());
  }

  /// 在刷新后的项目列表里找刚新建的会话；电脑还没把它列出来时为 null。
  ({RemoteDshProject project, RemoteDshSession session})? _locateSession(
    String id,
  ) {
    for (final project in _view.projects) {
      for (final session in project.sessions) {
        if (session.id == id) return (project: project, session: session);
      }
    }
    return null;
  }

  /// 提交输入卡内容：在那台电脑上新建一个会话，刷新项目列表并打开它。
  ///
  /// 文本只用于触发新建：会话页由自己的数据源读取，本页不预填内容。新建期间
  /// 输入卡不可用并显示「正在新建会话」；失败保留原有草稿，并用可见提示给出
  /// 电脑返回的原因。
  Future<void> _createSession({RemoteDshProject? project}) async {
    if (_creating) return;
    _exitComposerPanel(keepKeyboard: false);
    final draft = _composer.text.trim();
    if (project == null && draft.isEmpty) return;
    final creator = _creator;
    if (creator == null) {
      _unavailable('新建会话', detail: '当前数据源不支持在电脑上新建会话。');
      return;
    }
    setState(() => _creating = true);
    try {
      final created = await creator.createSession(projectId: project?.id);
      if (!mounted) return;
      if (project == null) {
        _composer.clear();
        setState(() => _draftEmpty = true);
        _composerFocus.unfocus();
      }
      // 先刷新项目列表：新会话通常已经在 sessions.list 里，于是能拿到电脑投影的
      // 标题与项目名；读取失败也不挡打开，退回工作区名与占位标题。
      await _load();
      if (!mounted) return;
      final located = _locateSession(created.sessionId);
      if (located != null) {
        _openSession(located.project, located.session);
      } else {
        unawaited(
          _openSessionById(
            sessionId: created.sessionId,
            title: '未命名会话',
            projectName: created.projectName,
          ),
        );
      }
    } on RemoteDshNoWorkspaceException {
      if (mounted) _notice('这台电脑上还没有项目');
    } on PlatformException catch (failure) {
      if (!mounted) return;
      final message = failure.message?.trim();
      _notice(message == null || message.isEmpty ? '新建会话失败，请稍后重试。' : message);
    } catch (error) {
      if (mounted) _notice('新建会话失败：$error');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  /// 打开已归档任务页。
  ///
  /// 独立的全屏目的地（标识见 [RemoteDshArchivedPage.routeDestination]），推入
  /// 同样走 [openDestination]：重复选择只会收起菜单，不会叠第二层。页面返回后重读
  /// 一次列表：用户可能在归档页里恢复过会话，首页的缓存不能继续显示旧结果。
  Future<void> _openArchived() async {
    _exitComposerPanel(keepKeyboard: false);
    final source = _archivedSource;
    if (source == null) {
      _unavailable('已归档任务', detail: '当前数据源不支持读取已归档会话。');
      return;
    }
    await openDestination<void>(
      context,
      destination: RemoteDshArchivedPage.routeDestination,
      dragBack: false,
      builder: (_) =>
          RemoteDshArchivedPage(source: source, onOpen: _openArchivedSession),
    );
    if (!mounted) return;
    unawaited(_load());
  }

  /// 从已归档任务页打开一个会话：走与首页会话行完全相同的打开路径。
  void _openArchivedSession(RemoteDshArchivedSession session) {
    unawaited(
      _openSessionById(
        sessionId: session.id,
        title: session.title,
        projectName: session.projectName.trim().isEmpty
            ? '未指定项目'
            : session.projectName,
      ),
    );
  }

  /// 打开电脑文件页。
  ///
  /// 独立的全屏目的地（标识见 [RemoteWorkspaceFilesPage.routeDestination]），推入
  /// 走 [openDestination]，重复选择不会叠第二层。能力在打开前再判一次：菜单行
  /// 已经按能力置灰，这里保留兜底，避免重新连接后能力变化时打开一个不可用页面。
  Future<void> _openFiles() async {
    _exitComposerPanel(keepKeyboard: false);
    final source = _filesSource;
    if (source == null) {
      _unavailable('电脑文件', detail: '当前数据源不支持浏览电脑上的文件。');
      return;
    }
    final capability = source.filesCapability;
    if (!capability.isAvailable) {
      _notice('「电脑文件」不可用：${capability.reason ?? '这台电脑没有声明该能力。'}');
      return;
    }
    await openDestination<void>(
      context,
      destination: RemoteWorkspaceFilesPage.routeDestination,
      dragBack: false,
      builder: (_) => RemoteWorkspaceFilesPage(source: source),
    );
  }

  /// 打开电脑设置页。
  ///
  /// 同样按 [RemoteDshSettingsPage.routeDestination] 作为稳定目的地标识；返回后
  /// 重读列表（设置里改默认模型不影响会话列表，但电脑上的其它变化可能已经发生）。
  Future<void> _openSettings() async {
    final source = _settingsSource;
    if (source == null) {
      _unavailable('设置', detail: '当前数据源不支持读取电脑设置。');
      return;
    }
    final capability = source.settingsCapability;
    if (!capability.isAvailable) {
      _notice('「设置」不可用：${capability.reason ?? '这台电脑没有声明该能力。'}');
      return;
    }
    await openDestination<void>(
      context,
      destination: RemoteDshSettingsPage.routeDestination,
      dragBack: false,
      builder: (_) =>
          RemoteDshSettingsPage(source: source, catalogSource: _catalogSource),
    );
    if (!mounted) return;
    // 设置页里可能改过默认模型：输入卡面板的缓存作废，下次打开重新读取。
    setState(() {
      _composerSettings = null;
      _composerCatalog = null;
      _composerSettingsError = null;
    });
    unawaited(_load());
  }

  /// 会话页副标题里的电脑名：当前连接的那台，没有时退回「这台电脑」。
  String _conversationDeviceName() {
    final name = _composerDeviceLabel(_view).trim();
    if (name.isNotEmpty) return name;
    return '这台电脑';
  }

  /// 打开配对页；配对成功时刷新设备列表并连上刚配好的电脑。
  ///
  /// 配对页返回 null 表示用户自己返回：设备表与连接都没有变化，这里什么都不做，
  /// 也不提示失败。配对页只负责把设备存进本机，连接由本页发起，因此成功与失败的
  /// 反馈各自留在自己的页面上。
  Future<void> _addConnection() async {
    final device = await Navigator.of(context).push<paired.RemoteDevice>(
      PocketRoute(builder: (_) => RemotePairingPage(store: _connection.store)),
    );
    if (!mounted || device == null) return;
    // 配对已经把设备写进本机存储：先重读设备表让胶囊条出现这台电脑，再连上它。
    // 读取失败由 [_load] 收进页面的可重试提示，连接仍然尝试；本机运行时未就绪时
    // 连接层读不到设备令牌（[_canStartRemoteConnection] 会先给可见提示）。
    await _load();
    if (!mounted) return;
    if (!_canStartRemoteConnection()) return;
    unawaited(_connection.connect(device));
  }

  /// 设备胶囊条的数据：多台已配对电脑的名称与状态点。
  ///
  /// 名称以存储层的电脑名为准（[_computerNameOf]）；数据源只提供状态与顺序。
  List<RemoteDevice> _railDevices(RemoteDshView view) => [
    for (final device in view.devices)
      RemoteDevice(
        id: device.id,
        label: _computerNameOf(device, _pairedDevice(device.id)),
        icon: Icons.computer_rounded,
        status: switch (device.state) {
          RemoteDshDeviceState.online => RemoteDeviceStatus.online,
          RemoteDshDeviceState.connecting => RemoteDeviceStatus.connecting,
          RemoteDshDeviceState.offline => RemoteDeviceStatus.offline,
        },
      ),
  ];

  /// 输入卡里的目标电脑名：当前连接的那台；未连接时为空。
  String _composerDeviceLabel(RemoteDshView view) =>
      _activeComputerName(view) ?? '';

  /// 输入卡的占位文案。
  ///
  /// 连接后是「与 <设备名> 新对话」；未连接与新建期间各自说明当前状态。原来卡片
  /// 下方那行「进入会话后可添加附件与指令…」的说明已并入占位文案与「+」弹层，
  /// 卡片外没有额外说明行，保持悬浮感。
  String _composerPlaceholder(RemoteDshView view, {required bool connected}) {
    if (_creating) return '正在电脑上新建会话…';
    if (!connected) return '先连接一台电脑';
    final device = _composerDeviceLabel(view).trim();
    return device.isEmpty ? '与这台电脑新对话' : '与 $device 新对话';
  }

  /// 按当前排序方式重排项目与会话。
  ///
  /// v1 一次只连一台电脑（协议 §11），项目列表就是当前这台电脑的全部项目；会话只
  /// 在项目内重排；[_recentFirst] 决定项目之间是否按最近活动排序。
  List<RemoteDshProject> _orderedProjects(List<RemoteDshProject> projects) {
    final ordered = [
      for (final project in projects)
        RemoteDshProject(
          id: project.id,
          deviceId: project.deviceId,
          name: project.name,
          sessions: _orderedSessions(project.sessions),
        ),
    ];
    if (_recentFirst) {
      ordered.sort((a, b) => _lastActivity(b).compareTo(_lastActivity(a)));
    }
    return ordered;
  }

  /// 项目内排序；用原始下标兜底，让保持顺序的排序结果稳定。
  List<RemoteDshSession> _orderedSessions(List<RemoteDshSession> sessions) {
    // 只有「优先级」改变会话之间的先后，其余两种由时间比较与原始下标决定。
    int rank(RemoteDshSession session) =>
        _order == RemoteDshOrder.priority && session.pendingCount > 0 ? 0 : 1;
    final indexed = [
      for (var index = 0; index < sessions.length; index++)
        (index: index, session: sessions[index]),
    ];
    indexed.sort((a, b) {
      final byRank = rank(a.session).compareTo(rank(b.session));
      if (byRank != 0) return byRank;
      if (_order == RemoteDshOrder.newest) {
        final byTime = (b.session.updatedAt ?? 0).compareTo(
          a.session.updatedAt ?? 0,
        );
        if (byTime != 0) return byTime;
      }
      return a.index - b.index;
    });
    return [for (final entry in indexed) entry.session];
  }

  /// 项目最近的活动时间；没有任何更新时间时为 0。
  int _lastActivity(RemoteDshProject project) => project.sessions.fold(
    0,
    (latest, session) => math.max(latest, session.updatedAt ?? 0),
  );

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final colors = Theme.of(context).colorScheme;
    final background = colors.brightness == Brightness.light
        ? Colors.white
        : colors.surface;
    final view = _view;
    final connected = view.connection == RemoteDshConnectionState.connected;
    return PopScope(
      // 搜索模式先收起搜索，再考虑离开页面：系统返回键不会直接关掉整个远程页。
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _searching) _closeSearch();
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: _appSidebar(),
        body: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: background),
            Listener(
              key: const ValueKey('remote-home-content'),
              onPointerDown: _effectiveComposerMode == PocketComposerMode.picker
                  ? (_) => _exitComposerPanel(keepKeyboard: false)
                  : null,
              child: _content(view),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: safe.top + 142,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        background,
                        background,
                        background.withValues(alpha: 0),
                      ],
                      stops: const [0, .75, 1],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: safe.top + 10,
              left: 18,
              right: 18,
              child: _searching
                  ? _RemoteSearchHeader(
                      controller: _search,
                      focusNode: _searchFocus,
                      onClose: _closeSearch,
                      onChanged: _onSearchChanged,
                      onClear: _clearSearch,
                    )
                  : RemoteHomeHeader(
                      key: _headerKey,
                      title: '远程 DSH',
                      // 三横线是本 App 的菜单：在原地打开侧栏，不离开远程页。
                      onMenu: () {
                        final scaffold = _scaffoldKey.currentState;
                        if (scaffold == null) {
                          _unavailable('菜单', detail: '侧栏还没有准备好，请稍后再试。');
                          return;
                        }
                        scaffold.openDrawer();
                      },
                      onTitle: _showHomeMenu,
                      onSearch: _openSearch,
                      menuLabel: '打开菜单',
                      searchLabel: '搜索会话',
                    ),
            ),
            Positioned(
              top: safe.top + 86,
              left: 0,
              right: 0,
              child: RemoteDeviceRail(
                devices: _railDevices(view),
                // 选中态就是当前连接的那台电脑：v1 一次只连一台，「全部」只
                // 在没有当前连接时选中。点已连接的胶囊不会重复连接。
                selectedId: _selectedDeviceId,
                onSelected: _selectDevice,
                padding: const EdgeInsets.symmetric(horizontal: 18),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: safe.bottom,
              child: RemoteComposer(
                floating: true,
                mode: _effectiveComposerMode,
                deviceLabel: _composerDeviceLabel(view),
                placeholder: _composerPlaceholder(view, connected: connected),
                controller: _composer,
                focusNode: _composerFocus,
                enabled: connected && !_creating,
                hasDraft: !_draftEmpty,
                sending: _creating,
                onChanged: _onComposerChanged,
                onSubmitted: (_) => _submitComposerDraft(),
                onAdd: _openComposerAddSheet,
                onReasoning: _toggleComposerPanel,
                reasoning: _effectiveComposerMode == PocketComposerMode.picker
                    ? _composerReasoningPanel()
                    : null,
                onSend: _submitComposerDraft,
                sendKey: const ValueKey('remote-home-send'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 内容区：读取失败、四种连接状态与项目列表。
  ///
  /// 未连接分两种：本机没有任何已配对电脑（先配对）与已配对但当前没有连接
  /// （点胶囊选一台，或还没连接过）。失败态给出当前这台电脑的错误、重试与切换
  /// 设备的入口；切换失败不会静默退回旧电脑（旧连接在切换时已经关闭）。
  Widget _content(RemoteDshView view) {
    final error = _error;
    final hasRecent = _visibleRecent().isNotEmpty;
    if (error != null && !hasRecent) {
      return PocketEmpty(
        child: _RemoteNotice(
          icon: Icons.cloud_off_rounded,
          title: '读取远程电脑失败',
          message: error,
          actionLabel: '重试',
          onAction: _load,
        ),
      );
    }
    // 连接已建立、这台设备的项目列表还没返回：先转圈，不能抢先显示「还没有项目」。
    if (_awaitingFirstProjects) {
      return PocketEmpty(
        child: _RemoteLoading(
          key: const ValueKey('remote-projects-loading'),
          title: '正在获取电脑上的项目…',
          message: '连接已建立，正在读取那台电脑上的项目与会话。',
        ),
      );
    }
    if (hasRecent) return _projects(view);
    final name = _activeComputerName(view);
    return switch (view.connection) {
      // 两个空态各自返回完整的 PocketEmpty：不要再套一层（滚动视口里不能再放一个
      // 依赖有限高度的滚动视口）。
      RemoteDshConnectionState.notConnected =>
        view.devices.isEmpty ? _pairFirstNotice() : _disconnectedNotice(),
      RemoteDshConnectionState.connecting => PocketEmpty(
        child: _RemoteLoading(
          key: const ValueKey('remote-connecting'),
          title: name == null ? '正在连接电脑' : '正在连接「$name」',
          message: '连接完成后，这里会显示那台电脑上的项目与会话。',
        ),
      ),
      RemoteDshConnectionState.connected => _projects(view),
      // 终止态：传输已经停止重连，只有用户动作能恢复。原因直接用连接层的
      // message（协议 §9.4 已经是可直接展示的中文）；切换失败也停在这里，
      // 指向的是那台连不上的电脑，而不是退回旧电脑。
      RemoteDshConnectionState.failed => PocketEmpty(
        child: _RemoteNotice(
          icon: Icons.link_off_rounded,
          title: name == null ? '没能连接到这台电脑' : '没能连接到「$name」',
          message: _connection.lastError ?? '请检查手机与电脑是否在同一网络，然后重新连接。',
          actionLabel: '重试',
          onAction: _retryConnection,
          secondaryActionLabel: view.devices.length > 1 ? '切换设备' : '添加连接',
          onSecondaryAction: view.devices.length > 1
              ? () => unawaited(_showSwitchDeviceSheet())
              : () => unawaited(_addConnection()),
        ),
      ),
    };
  }

  /// 本机还没有任何已配对电脑时的空态：先配对。
  Widget _pairFirstNotice() => PocketEmpty(
    child: _RemoteNotice(
      icon: Icons.devices_other_rounded,
      title: '还没有连接任何电脑',
      message: '在一台电脑上启动远程宿主，再用配对码把这台手机连上去。连接后可以在这里查看那台电脑上的项目和会话。',
      actionLabel: '添加连接',
      onAction: () => unawaited(_addConnection()),
    ),
  );

  /// 已配对电脑但当前没有连接时的空态：区分「从未连接过」与「以前连过」。
  Widget _disconnectedNotice() => PocketEmpty(
    child: _RemoteNotice(
      icon: Icons.devices_other_rounded,
      title: _connection.lastConnectedDevice == null
          ? '还没有连接过任何一台电脑'
          : '当前没有连接电脑',
      message: _connection.lastConnectedDevice == null
          ? '点上方电脑胶囊选择一台开始连接；第一台电脑会在连接成功后记住，之后打开 App 会自动连它。'
          : '点上方电脑胶囊选择要连接的电脑。',
      actionLabel: '添加连接',
      onAction: () => unawaited(_addConnection()),
    ),
  );

  /// 已连接时的「项目」分组；没有项目时给出独立的空状态。
  ///
  /// 搜索词非空时先按 [filterRemoteProjects] 过滤；过滤后没有结果给出
  /// 「没有匹配的会话」，与「这台电脑上还没有项目」区分开。
  Widget _projects(RemoteDshView view) {
    final query = _searchQuery.trim();
    final visible = _visibleRecent();
    final projects = filterRemoteProjects(_orderedProjects(visible), query);
    if (projects.isEmpty) {
      if (query.isNotEmpty) {
        return PocketEmpty(
          child: _RemoteNotice(
            icon: Icons.search_off_rounded,
            title: '没有匹配的会话',
            message: '没有项目和会话匹配「$query」。可以换个关键词，或清除搜索。',
            actionLabel: '清除搜索',
            onAction: _clearSearch,
          ),
        );
      }
      return PocketEmpty(
        child: _RemoteNotice(
          icon: Icons.folder_off_outlined,
          title: '这台电脑上还没有项目',
          message: '在电脑上创建项目后，它的会话会显示在这里。',
        ),
      );
    }
    return ListView(
      key: const ValueKey('remote-project-list'),
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top + 150,
        bottom: MediaQuery.paddingOf(context).bottom + 112,
      ),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        if (view.connection != RemoteDshConnectionState.connected)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              switch (view.connection) {
                RemoteDshConnectionState.connecting =>
                  '正在连接「${_activeComputerName(view) ?? '电脑'}」 · 显示上次同步的内容',
                RemoteDshConnectionState.failed => '连接未恢复 · 显示上次同步的内容',
                _ => '尚未连接 · 显示上次同步的内容',
              },
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
            '项目',
            style: AppTextStyle.subheadline.of(context, emphasized: true),
          ),
        ),
        for (final project in projects)
          Padding(
            // 外层也要稳定 key：列表刷新/重排时 Flutter 按位置匹配元素，外层没有
            // key 会让内层项目组被当成新元素，展开状态随之丢失。
            key: ValueKey(
              'remote-project-shell-${project.deviceId}-${project.id}',
            ),
            padding: EdgeInsets.symmetric(
              horizontal: 18,
              vertical: _isProjectExpanded(project) ? 4 : 2,
            ),
            child: RemoteProjectGroup(
              key: ValueKey('remote-project-${project.deviceId}-${project.id}'),
              name: project.name,
              plain: true,
              expanded: _isProjectExpanded(project),
              onExpandedChanged: (expanded) =>
                  _setProjectExpanded(project, expanded),
              deviceLabel: _selectedDeviceId == null && view.devices.length > 1
                  ? _deviceName(view, project.deviceId)
                  : null,
              showCreate: true,
              onCreate: () => _activateProjectItem(project),
              children: [
                for (final session in project.sessions)
                  RemoteSessionRow(
                    key: ValueKey(
                      'remote-session-${project.deviceId}-${session.id}',
                    ),
                    title: session.title,
                    running: session.running,
                    plain: true,
                    trailingCount: session.pendingCount,
                    onTap: () => _activateProjectItem(project, session),
                  ),
              ],
            ),
          ),
        if (projects.any((project) => project.sessions.isNotEmpty)) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
            child: Text(
              '最近会话',
              style: AppTextStyle.subheadline.of(context, emphasized: true),
            ),
          ),
          for (final item in _recentSessions(projects).take(20))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: RemoteSessionRow(
                key: ValueKey(
                  'remote-recent-${item.project.deviceId}-${item.session.id}',
                ),
                title: item.session.title,
                running: item.session.running,
                plain: true,
                plainInset: 2,
                contextLabel:
                    _selectedDeviceId == null && view.devices.length > 1
                    ? '${item.project.name} · ${_deviceName(view, item.project.deviceId)}'
                    : null,
                onTap: () => _activateProjectItem(item.project, item.session),
              ),
            ),
        ],
      ],
    );
  }

  List<RemoteDshProject> _visibleRecent() {
    final selected = _selectedDeviceId;
    if (selected != null) return _recentByDevice[selected] ?? const [];
    return [for (final projects in _recentByDevice.values) ...projects];
  }

  /// 项目展开状态的 map key：设备标识与项目标识之间用 NUL 分隔，避免拼接歧义。
  String _projectExpansionKey(RemoteDshProject project) =>
      '${project.deviceId}\u0000${project.id}';

  /// 从 [_projectExpansionKey] 的 key 里取回设备标识。
  String _projectExpansionDeviceId(String key) {
    final separator = key.indexOf('\u0000');
    return separator < 0 ? key : key.substring(0, separator);
  }

  /// 项目当前是否展开；没有记忆时默认展开。
  bool _isProjectExpanded(RemoteDshProject project) =>
      _projectExpanded[_projectExpansionKey(project)] ?? true;

  /// 记录一次用户折叠/展开，并写回本地缓存（下次启动仍记得）。
  void _setProjectExpanded(RemoteDshProject project, bool expanded) {
    setState(() {
      _projectExpanded[_projectExpansionKey(project)] = expanded;
    });
    // 注入数据源的测试/替身没有真实本地缓存通道：只保留页面内状态。
    if (widget.source == null && widget.connection == null) {
      unawaited(_persistRecent());
    }
  }

  /// 当前内容区对应的设备：选中的胶囊、活动连接，最后是设备表第一台。
  ///
  /// 注入数据源的测试与只读替身没有连接控制器（`activeDevice` 为空），仍要能判断
  /// 「第一次读取还没有返回」。
  String? get _contentDeviceId {
    final selected = _selectedDeviceId;
    if (selected != null) return selected;
    final active = _connection.activeDevice?.id;
    if (active != null) return active;
    return _view.devices.isEmpty ? null : _view.devices.first.id;
  }

  /// 是否在等待这台设备的首次项目列表；为 true 时内容区显示转圈而不是空态。
  ///
  /// 只有 `listProjects` 成功返回（含空列表）后才把设备记进 [_projectsLoadedFor]；
  /// 失败由 [_error] 走错误态，断开/未连接时连接状态本身决定空态，不显示转圈。
  bool get _awaitingFirstProjects {
    if (_source.connection != RemoteDshConnectionState.connected) return false;
    if (_error != null) return false;
    final deviceId = _contentDeviceId;
    if (deviceId == null) return false;
    if (_projectsLoadedFor.contains(deviceId)) return false;
    if (_recentByDevice[deviceId]?.isNotEmpty ?? false) return false;
    return true;
  }

  String _deviceName(RemoteDshView view, String id) {
    for (final device in view.devices) {
      if (device.id == id) return device.label;
    }
    return id;
  }

  List<({RemoteDshProject project, RemoteDshSession session})> _recentSessions(
    List<RemoteDshProject> projects,
  ) {
    final rows = [
      for (final project in projects)
        for (final session in project.sessions)
          (project: project, session: session),
    ];
    rows.sort(
      (a, b) => (b.session.updatedAt ?? 0).compareTo(a.session.updatedAt ?? 0),
    );
    return rows;
  }
}

/// 头部搜索模式：关闭按钮加一个输入框，高度与 [RemoteHomeHeader] 一致。
///
/// 输入即过滤，没有「搜索」提交按钮；清空输入框即恢复完整列表。关闭按钮只收起
/// 搜索（系统返回键走同一段逻辑），不离开远程首页。
class _RemoteSearchHeader extends StatelessWidget {
  const _RemoteSearchHeader({
    required this.controller,
    required this.focusNode,
    required this.onClose,
    required this.onChanged,
    required this.onClear,
  });

  /// 搜索输入框的控制器，由页面持有。
  final TextEditingController controller;

  /// 搜索输入框的焦点节点，由页面持有。
  final FocusNode focusNode;

  /// 关闭搜索并恢复完整列表。
  final VoidCallback onClose;

  /// 输入变化回调。
  final ValueChanged<String> onChanged;

  /// 清空输入词（保持搜索模式）。
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          GlassButton(
            key: const ValueKey('remote-home-search-close'),
            icon: Icons.arrow_back_rounded,
            label: '关闭搜索',
            onPressed: onClose,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: const ValueKey('remote-home-search-field'),
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
              textInputAction: TextInputAction.search,
              style: AppTextStyle.subheadline.of(context),
              onChanged: onChanged,
              decoration: InputDecoration(
                hintText: '搜索项目和会话',
                hintMaxLines: 1,
                filled: true,
                fillColor: colors.surfaceContainerLow,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: AppRadius.full,
                  borderSide: BorderSide.none,
                ),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: colors.onSurfaceVariant,
                ),
                suffixIcon: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) => value.text.isEmpty
                      ? const SizedBox.shrink()
                      : IconButton(
                          key: const ValueKey('remote-home-search-clear'),
                          tooltip: '清空搜索',
                          icon: const Icon(Icons.close_rounded, size: 20),
                          onPressed: onClear,
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 空状态与读取失败共用的居中提示：图标、标题、说明与可选动作。
///
/// 最多两个动作：失败态用第二个动作给出「切换设备 / 添加连接」的可恢复路径。
/// 文字按当前字号缩放换行，因此放大字体时仍能完整读到。
/// 正在连接/首次读取数据时的转圈提示。
///
/// 与 [_RemoteNotice] 同一版式，但以 [CircularProgressIndicator] 明确表示还在等
/// 电脑返回数据；真正的空态只在读取成功且结果为空后出现。
class _RemoteLoading extends StatelessWidget {
  const _RemoteLoading({super.key, required this.title, required this.message});

  /// 提示标题，例如「正在获取电脑上的项目…」。
  final String title;

  /// 一段说明，不写营销语。
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: colors.primary,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: AppTextStyle.title3.of(context, emphasized: true),
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: AppTextStyle.footnote
              .of(context)
              .copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _RemoteNotice extends StatelessWidget {
  const _RemoteNotice({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
  });

  /// 顶部图标，取自当前主题的前景色。
  final IconData icon;

  /// 提示标题。
  final String title;

  /// 一段说明，不写营销语。
  final String message;

  /// 动作按钮文案；为空时不显示按钮。
  final String? actionLabel;

  /// 动作回调；为空时按钮同样不显示。
  final VoidCallback? onAction;

  /// 第二个动作的文案（次要样式）；为空时不显示。
  final String? secondaryActionLabel;

  /// 第二个动作的回调；为空时不显示。
  final VoidCallback? onSecondaryAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final actionLabel = this.actionLabel;
    final onAction = this.onAction;
    final secondaryActionLabel = this.secondaryActionLabel;
    final onSecondaryAction = this.onSecondaryAction;
    final secondary = secondaryActionLabel != null && onSecondaryAction != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 40, color: colors.onSurfaceVariant),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: AppTextStyle.title3.of(context, emphasized: true),
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: AppTextStyle.footnote
              .of(context)
              .copyWith(color: colors.onSurfaceVariant),
        ),
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(height: 20),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PocketButton(onPressed: onAction, child: Text(actionLabel)),
              if (secondary) ...[
                const SizedBox(width: 8),
                PocketButton.tonal(
                  onPressed: onSecondaryAction,
                  child: Text(secondaryActionLabel),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

/// 设备选择弹层的底部面板：标题、说明与若干设备行。
///
/// 只做展示：选中的设备由设备行的点击回调查询方决定，面板本身不读连接状态。
class _RemoteDeviceSheet extends StatelessWidget {
  const _RemoteDeviceSheet({
    super.key,
    required this.title,
    required this.message,
    required this.children,
  });

  /// 弹层标题。
  final String title;

  /// 标题下的一段说明。
  final String message;

  /// 设备行。
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  title,
                  style: AppTextStyle.title3.of(context, emphasized: true),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                style: AppTextStyle.footnote
                    .of(context)
                    .copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(children: children),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 设备选择弹层里的一台电脑：名称、地址、当前连接标记与可选行尾动作。
class _RemoteDeviceSheetRow extends StatelessWidget {
  const _RemoteDeviceSheetRow({
    super.key,
    required this.record,
    required this.active,
    required this.onPressed,
    this.trailingLabel,
    this.activeLabel = '当前连接',
  });

  /// 已配对电脑记录。
  final paired.RemoteDevice record;

  /// 是否当前连接的那台。
  final bool active;

  /// 行尾动作文案；为空时只显示状态/地址。
  final String? trailingLabel;

  /// 当前连接那台的状态说明。
  final String activeLabel;

  /// 点按回调（行与行尾动作共用）。
  final VoidCallback onPressed;

  /// 状态/地址行尾的信任模式标记；直连电脑不加标记。
  ///
  /// 只做展示：连接逻辑读的是设备记录里的 `systemTrust`，不看这段文字。
  String get _trustLabel => record.systemTrust ? ' · HTTPS 反代' : '';

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final trailingLabel = this.trailingLabel;
    return PocketTile(
      title: Text(
        record.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${active ? activeLabel : record.host}$_trustLabel',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      leading: const Icon(Icons.computer_rounded),
      trailing: trailingLabel == null
          ? (active
                ? Icon(Icons.check_rounded, color: colors.primary, size: 20)
                : null)
          : TextButton(
              onPressed: onPressed,
              style: TextButton.styleFrom(foregroundColor: colors.error),
              child: Text(trailingLabel),
            ),
      onTap: onPressed,
    );
  }
}

/// 首页「+」弹层的内容：说明首页没有会话、这些能力进入会话后可用。
///
/// 复用会话页「添加与指令」弹层的同一套外壳（[showRemoteCommandsSheet]），因此
/// 标题、关闭按钮与玻璃表面都一致；这里只换正文。
class _ComposerAddHint extends StatelessWidget {
  const _ComposerAddHint();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PocketSection(
      children: [
        const PocketTile(
          contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          leading: Icon(Icons.info_outline_rounded),
          title: Text('进入会话后可添加文件与指令'),
          subtitle: Text('在会话页的输入区里用「+」添加附件、执行会话指令、进入方案模式或切换权限预设。'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
          child: Text(
            '现在可以直接在下面的输入框里说点什么，发送后会在电脑上新建会话并打开它。',
            style: AppTextStyle.footnote
                .of(context)
                .copyWith(color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
