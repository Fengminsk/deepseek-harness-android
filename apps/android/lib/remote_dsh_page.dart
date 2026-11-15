// 远程 DSH 首页：连接一台电脑后，浏览那台电脑上的项目与会话。
//
// 页面结构对齐设计参照截图：自建浮动头部（菜单、标题加下拉箭头、搜索）、
// 设备胶囊条、「项目」分组与底部输入条；布局沿用 PocketScaffold 的风格
// （全高滚动视口、内容让出头部、玻璃或实心表面）。
//
// 头部的搜索按钮把头部原地切成一个搜索输入框：输入时按项目名与会话标题在本地
// 过滤，清空或关闭搜索后恢复完整列表。输入条在连接就绪后可用，提交非空内容会在
// 那台电脑上新建一个会话并打开它；新建期间输入条不可用并显示「正在新建会话」。
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

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_sidebar.dart';
import 'flclash/daylight.dart';
import 'flclash/popup.dart';
import 'flclash/typography.dart';
import 'remote_connection.dart';
import 'remote_conversation_live_source.dart';
import 'remote_dsh_archived_page.dart';
import 'remote_dsh_conversation.dart';
import 'remote_device_store.dart' as paired;
import 'remote_dsh_live_source.dart';
import 'remote_dsh_settings_page.dart';
import 'remote_dsh_widgets.dart';
import 'remote_pairing_page.dart';
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
  });

  /// 会话标识。
  final String id;

  /// 会话标题。
  final String title;

  /// 等待你处理的项数（审批、提问等）；没有未处理项时为 0。
  final int pendingCount;

  /// 最近更新的 Unix 毫秒；电脑没有给出更新时间时为 null。
  final int? updatedAt;
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
  addConnection,
  settings,
}

class _RemoteDshPageState extends State<RemoteDshPage> {
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

  /// 输入条是否为空草稿；用来决定发送按钮是否出现，避免每次按键都重建整页。
  bool _draftEmpty = true;

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

  /// 滚动期间让首页背景暂停流动，与 PocketScaffold 的做法一致。
  final _suspendBackdrop = ValueNotifier<bool>(false);

  /// 页面实际使用的连接控制器：注入的优先，未注入时由本页创建。
  ///
  /// 未注入也必须有一个：否则数据源会退回占位源，页面既读不到本机已配对的电脑，
  /// 也没有对象可以发起连接与配对。
  late final RemoteConnectionController _connection;

  /// [connection] 是否由本页创建；为 true 时由本页负责 [RemoteConnectionController.dispose]。
  bool _ownsConnection = false;

  /// 数据源：显式 [RemoteDshPage.source] 优先，否则按 [_connection] 建实时源。
  RemoteDshDataSource _source = const RemoteDshPlaceholderSource();

  late RemoteDshView _view;

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
  bool _recentFirst = false;

  /// 当前选中的设备；null 表示选中「全部」。
  String? _deviceId;

  /// 读取数据源失败时的中文说明。
  String? _error;

  /// 已展开的标题菜单路由；用它避免重复入栈。
  CommonPopupRoute<void>? _menuRoute;

  /// 上一次触发刷新的连接快照（阶段 + 宿主显示名）。
  ///
  /// 连接层对每条入站通知都会发一次变更，而流式回复期间 `session.live` 最多每 50 ms
  /// 一条；不判重就会在会话页盖住首页时以每秒几十次重读设备表与 `sessions.list`。
  ({RemoteConnectionPhase phase, String? hostName})? _loadedConnection;

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
    _view = RemoteDshView(
      connection: _source.connection,
      hostName: _source.hostName,
    );
    _loadedConnection = (
      phase: _connection.phase,
      hostName: _connection.host?.name,
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _connection.removeListener(_onConnectionChanged);
    if (_ownsConnection) _connection.dispose();
    _composer.dispose();
    _composerFocus.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _suspendBackdrop.dispose();
    super.dispose();
  }

  /// 按构造参数决定数据源：显式 [RemoteDshPage.source] 优先，其余用连接控制器
  /// 之上的实时数据源。
  RemoteDshDataSource _resolveSource() {
    final source = widget.source;
    if (source != null) return source;
    return RemoteDshLiveSource(controller: _connection);
  }

  /// 连接阶段变化时刷新：先把空态切到新阶段，再重读设备与项目。
  ///
  /// 只有阶段或宿主身份变化才重读：连接层对每条通知都发一次变更，逐条重读会让
  /// 流式回复期间首页持续打 `runtime.info` + `sessions.list`。
  void _onConnectionChanged() {
    if (!mounted) return;
    setState(() {
      _view = RemoteDshView(
        connection: _source.connection,
        hostName: _source.hostName,
        devices: _view.devices,
        projects: _view.projects,
      );
    });
    final snapshot = (
      phase: _connection.phase,
      hostName: _connection.host?.name,
    );
    if (_loadedConnection == snapshot) return;
    _loadedConnection = snapshot;
    unawaited(_load());
  }

  /// 读取设备与项目；失败时保留「未连接」状态并给出可重试的说明。
  Future<void> _load() async {
    try {
      final devices = await _source.listDevices();
      _autoConnect();
      final projects = await _source.listProjects();
      if (!mounted) return;
      setState(() {
        _error = null;
        // 选中的设备可能已经不在这台电脑上，回落到「全部」。
        if (_deviceId != null &&
            !devices.any((device) => device.id == _deviceId)) {
          _deviceId = null;
        }
        _view = RemoteDshView(
          connection: _source.connection,
          hostName: _source.hostName,
          devices: devices,
          projects: projects,
        );
      });
    } catch (error) {
      if (!mounted) return;
      // 门面失败一律是 PlatformException，message 已是可直接展示的中文。
      final detail = error is PlatformException ? error.message : '$error';
      setState(() {
        _error = detail == null || detail.trim().isEmpty ? '请检查连接后重试。' : detail;
      });
    }
  }

  /// 只有一台已配对电脑且当前空闲时自动连上。
  ///
  /// 打开远程页的预期是直接看到那台电脑的项目，而不是先点一次设备胶囊。多台时
  /// 不自动选择（v1 一次只连一台，协议 §11）；失败态也不自动重试，避免重启风暴。
  void _autoConnect() {
    if (_connection.phase != RemoteConnectionPhase.idle) return;
    if (_connection.devices.length != 1) return;
    unawaited(_connection.connect(_connection.devices.single));
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

  /// 草稿从空变成非空（或反过来）时重建一次，决定发送按钮是否出现。
  void _onComposerChanged(String value) {
    final empty = value.trim().isEmpty;
    if (empty == _draftEmpty) return;
    setState(() => _draftEmpty = empty);
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
        // 菜单共八行加两段小标题，默认 7.5 行的上限会把它截成可滚动，
        // 这里放宽到全部可见；屏幕实在放不下时弹层自己再裁到可用高度。
        maxVisibleItems: 10,
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
      case _HomeMenuChoice.addConnection:
        unawaited(_addConnection());
      case _HomeMenuChoice.settings:
        unawaited(_openSettings());
    }
  }

  void _selectDevice(String? id) {
    if (id == _deviceId) return;
    setState(() => _deviceId = id);
    // 「全部」只是清掉项目过滤（v1 就是当前这台电脑的全部项目），不触发连接。
    if (id == null) return;
    final device = _pairedDevice(id);
    if (device == null) return;
    // 点已连接的设备不会重连；点另一台会先干净断开旧连接（协议 §11）。
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

  /// 终止态下的「重新连接」：重连当前设备；没有当前设备时回到「添加连接」。
  void _retryConnection() {
    final device = _connection.activeDevice;
    if (device == null) {
      unawaited(_addConnection());
      return;
    }
    unawaited(_connection.connect(device));
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

  /// 提交输入条内容：在那台电脑上新建一个会话，刷新项目列表并打开它。
  ///
  /// 文本只用于触发新建：会话页由自己的数据源读取，本页不预填内容。新建期间
  /// 输入条不可用并显示「正在新建会话」；失败保留原有草稿，并用可见提示给出
  /// 电脑返回的原因。
  Future<void> _createSession() async {
    if (_creating) return;
    final draft = _composer.text.trim();
    if (draft.isEmpty) return;
    final creator = _creator;
    if (creator == null) {
      _unavailable('新建会话', detail: '当前数据源不支持在电脑上新建会话。');
      return;
    }
    setState(() => _creating = true);
    try {
      final created = await creator.createSession();
      if (!mounted) return;
      _composer.clear();
      setState(() => _draftEmpty = true);
      _composerFocus.unfocus();
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
    unawaited(_load());
  }

  /// 会话页副标题里的设备名：选中的设备优先，其次当前电脑的显示名。
  String _conversationDeviceName() {
    final selected = _composerDeviceLabel(_view).trim();
    if (selected.isNotEmpty) return selected;
    return _connection.activeDevice?.label ?? '这台电脑';
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
    // 读取失败由 [_load] 收进页面的可重试提示，连接仍然尝试。
    await _load();
    if (!mounted) return;
    unawaited(_connection.connect(device));
  }

  List<RemoteDevice> _railDevices(RemoteDshView view) => [
    for (final device in view.devices)
      RemoteDevice(
        id: device.id,
        label: device.label,
        icon: Icons.computer_rounded,
        status: switch (device.state) {
          RemoteDshDeviceState.online => RemoteDeviceStatus.online,
          RemoteDshDeviceState.connecting => RemoteDeviceStatus.connecting,
          RemoteDshDeviceState.offline => RemoteDeviceStatus.offline,
        },
      ),
  ];

  /// 输入条里的目标设备名：优先取选中的设备，其次取当前电脑的显示名。
  String _composerDeviceLabel(RemoteDshView view) {
    final selected = _deviceId;
    if (selected != null) {
      for (final device in view.devices) {
        if (device.id == selected) return device.label;
      }
    }
    return view.hostName ?? '';
  }

  /// 按当前排序方式重排项目与会话。
  ///
  /// 会话只在项目内重排；[_recentFirst] 决定项目之间是否按最近活动排序。
  List<RemoteDshProject> _orderedProjects(RemoteDshView view) {
    final visible = _deviceId == null
        ? view.projects
        : [
            for (final project in view.projects)
              if (project.deviceId == _deviceId) project,
          ];
    final ordered = [
      for (final project in visible)
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
    final glass = LiquidGlassScope.of(context);
    final safe = MediaQuery.paddingOf(context);
    final view = _view;
    final connected = view.connection == RemoteDshConnectionState.connected;
    final canSubmit = connected && !_creating && !_draftEmpty;
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
            if (glass)
              Positioned.fill(
                child: DaylightBackdrop(suspendMotion: _suspendBackdrop),
              ),
            NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollStartNotification) {
                  _suspendBackdrop.value = true;
                } else if (notification is ScrollEndNotification) {
                  _suspendBackdrop.value = false;
                }
                return false;
              },
              child: Padding(
                padding: EdgeInsets.only(top: safe.top),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
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
                    const SizedBox(height: 10),
                    RemoteDeviceRail(
                      devices: _railDevices(view),
                      selectedId: _deviceId,
                      onSelected: _selectDevice,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                    ),
                    const SizedBox(height: 14),
                    Expanded(child: _content(view)),
                    Padding(
                      padding: EdgeInsets.fromLTRB(16, 10, 16, safe.bottom + 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: RemoteComposer(
                              deviceLabel: _composerDeviceLabel(view),
                              controller: _composer,
                              focusNode: _composerFocus,
                              enabled: connected && !_creating,
                              placeholder: _creating
                                  ? '正在电脑上新建会话…'
                                  : (connected ? null : '先连接一台电脑'),
                              onChanged: _onComposerChanged,
                              onAdd: () => _unavailable('添加内容'),
                              onApproval: () => _unavailable('审批策略'),
                              onModel: () => _unavailable('选择模型'),
                              onSubmitted: (_) => unawaited(_createSession()),
                            ),
                          ),
                          // 输入条提交=在电脑上新建会话；与会话页一样，有草稿时
                          // 才出现发送按钮，新建期间换成忙碌态。
                          if (_creating || !_draftEmpty) ...[
                            const SizedBox(width: 8),
                            GlassButton(
                              key: const ValueKey('remote-home-send'),
                              icon: _creating
                                  ? Icons.hourglass_top_rounded
                                  : Icons.arrow_upward_rounded,
                              label: _creating ? '正在新建会话' : '新建会话',
                              solid: true,
                              onPressed: canSubmit
                                  ? () => unawaited(_createSession())
                                  : null,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 内容区：读取失败、四种连接状态与项目列表。
  Widget _content(RemoteDshView view) {
    final error = _error;
    if (error != null) {
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
    return switch (view.connection) {
      RemoteDshConnectionState.notConnected => PocketEmpty(
        child: _RemoteNotice(
          icon: Icons.devices_other_rounded,
          title: '还没有连接任何电脑',
          message: '在一台电脑上启动远程宿主，再用配对码把这台手机连上去。连接后可以在这里查看那台电脑上的项目和会话。',
          actionLabel: '添加连接',
          onAction: () => unawaited(_addConnection()),
        ),
      ),
      RemoteDshConnectionState.connecting => const PocketEmpty(
        child: _RemoteNotice(
          icon: Icons.hourglass_top_rounded,
          title: '正在连接电脑',
          message: '连接完成后，这里会显示那台电脑上的项目与会话。',
        ),
      ),
      RemoteDshConnectionState.connected => _projects(view),
      // 终止态：传输已经停止重连，只有用户动作能恢复。原因直接用连接层的
      // message（协议 §9.4 已经是可直接展示的中文）。
      RemoteDshConnectionState.failed => PocketEmpty(
        child: _RemoteNotice(
          icon: Icons.link_off_rounded,
          title: '没能连接到这台电脑',
          message: _connection.lastError ?? '请检查手机与电脑是否在同一网络，然后重新连接。',
          actionLabel: '重新连接',
          onAction: _retryConnection,
        ),
      ),
    };
  }

  /// 已连接时的「项目」分组；没有项目时给出独立的空状态。
  ///
  /// 搜索词非空时先按 [filterRemoteProjects] 过滤；过滤后没有结果给出
  /// 「没有匹配的会话」，与「这台电脑上还没有项目」区分开。
  Widget _projects(RemoteDshView view) {
    final query = _searchQuery.trim();
    final projects = filterRemoteProjects(_orderedProjects(view), query);
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
          message: _deviceId == null
              ? '在电脑上创建项目后，它的会话会显示在这里。'
              : '选中的设备上还没有项目，点「全部」可以查看其它设备。',
        ),
      );
    }
    final colors = Theme.of(context).colorScheme;
    return ListView(
      key: const ValueKey('remote-project-list'),
      padding: const EdgeInsets.only(bottom: 24),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        const RemoteSectionLabel('项目'),
        for (final project in projects)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: RemoteProjectGroup(
              key: ValueKey('remote-project-${project.id}'),
              name: project.name,
              trailing: project.sessions.isEmpty
                  ? null
                  : Text(
                      '${project.sessions.length}',
                      maxLines: 1,
                      style: AppTextStyle.footnote
                          .of(context)
                          .copyWith(color: colors.onSurfaceVariant),
                    ),
              children: [
                for (final session in project.sessions)
                  RemoteSessionRow(
                    key: ValueKey('remote-session-${session.id}'),
                    title: session.title,
                    trailingCount: session.pendingCount,
                    onTap: () => _openSession(project, session),
                  ),
              ],
            ),
          ),
      ],
    );
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
/// 文字按当前字号缩放换行，因此放大字体时仍能完整读到。
class _RemoteNotice extends StatelessWidget {
  const _RemoteNotice({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
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

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final actionLabel = this.actionLabel;
    final onAction = this.onAction;
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
          PocketButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ],
    );
  }
}
