/// 远程 DSH 首页的真实数据源：把 [RemoteConnectionController] 的连接与 PC 门面
/// 方法投影成首页要的设备、项目与会话，并承载首页的写操作（新建会话）与
/// 已归档任务页的读取/恢复。
///
/// ## 依赖的门面方法
///
/// | 方法 | 参数 | 用到的返回字段 |
/// |---|---|---|
/// | `runtime.info` | `{}` | 只做连通性探测：`node`、`platform`、`arch`、`workspace`、`profile`，本类不读具体值 |
/// | `sessions.list` | `{}` | 数组；每项 `header.id`（会话标识）、`title`（可空，已投影的标题）、`cwd`（可选，项目目录）、`updatedAt`（Unix 毫秒，可选）、`pinned`（可选） |
/// | `library.catalog` | `{}` | `workspaces[].workspaceId` / `path` / `title`、`sessions[].sessionId` / `cwd` / `projections.values.title`、`archivedSessionIds`、`defaultDirectory` |
/// | `library.sessionCreate` | `{workspaceId}` | `sessionId`（新建会话的标识，用于打开会话） |
/// | `library.sessionArchive` | `{sessionId, archived:false}` | 只等受理；恢复后重读 `library.catalog` |
/// | `workspace.files.list` | `{path, offset?, version?}` | `root`、`path`、`version`、`entries[]`（`name` / `path` / `kind` / `modifiedAt` / `bytes` / `blockedReason`）、`offset`、`nextOffset`、`truncated` |
/// | `workspace.files.read` | `{path, offset?, version?}` | `root`、`path`、`version`、`bytes`、`offset`、`nextOffset`、`eof`、`text`；非文本文件回 `_pocket_error` |
/// | `settings.describe` | `{}` | 数组；每项 `ns`、`revision`、`schema`、`value`（已脱敏）、`secrets[]` |
/// | `settings.mutate` | `{ns, ops, revision}` | 成功后回整份 `settings.describe`；版本冲突回 `SETTINGS_CONFLICT` 的 `_pocket_error` |
/// | `api.call` | `{namespace:'session', method:'modelCatalog', args:{}}` | `groups[].id` / `name`、`groups[].models[].id` / `name` / `reasoning`、`failures[]` |
///
/// `sessions.list` 在 PC 侧就是门面里的 `library.sidebar()`（`runtime/index.mjs`）：
/// 已过滤掉归档会话与子 Agent 会话，置顶项排在最前，每项在原始会话记录上追加
/// `header` / `title` / `pinned` / `archived`。这里按 `cwd` 把会话归组成「项目」，
/// 没有 `cwd` 的会话落到「未指定项目」。
///
/// `library.catalog` 只在需要时读（新会话选工作区、已归档任务页），并缓存在
/// [RemoteDshFacade] 里；新建会话与恢复归档后作废缓存，下一次读取拿到电脑上的
/// 新状态。首页的项目列表仍走 `sessions.list`，两条读取互不替代。
///
/// ## 不抛异常的前提
///
/// 未连接、握手中、重连中、终止态都返回空列表：连接状态由
/// [RemoteDshDataSource.connection] 报给页面，页面据此显示空态，不需要异常。
/// 只有「已连接但电脑返回了无法解释的结果」才抛 `PlatformException`，这时页面会
/// 显示带「重试」的读取失败提示。写操作（新建会话、恢复归档）失败一律抛
/// `PlatformException`，`message` 是可直接展示的中文，由发出动作的页面提示。
///
/// ## 设备来自哪里
///
/// 设备列表不来自 PC，而是本机的 [RemoteDeviceStore]（已配对电脑）；因此未连接时
/// 也能显示胶囊条。v1 一次只连一台（协议 §11），除当前连接外其余设备都是
/// 「已配对但未连接」。
library;

import 'package:flutter/services.dart';

import 'configuration_edits.dart';
import 'configuration_fields_schema.dart';
import 'configuration_presentation.dart';
import 'remote_connection.dart';
import 'remote_device_store.dart';
import 'remote_dsh_archived_page.dart';
import 'remote_dsh_page.dart';
import 'remote_transport.dart';
import 'runtime_transport.dart';

/// 连通性探测用的门面方法。
const String remoteProbeMethod = 'runtime.info';

/// 读取项目与会话用的门面方法。
const String remoteSessionsListMethod = 'sessions.list';

/// 读取工作区、会话标题与归档集合用的门面方法。
const String remoteCatalogMethod = 'library.catalog';

/// 新建会话用的门面方法。
const String remoteSessionCreateMethod = 'library.sessionCreate';

/// 归档/恢复会话用的门面方法。
const String remoteSessionArchiveMethod = 'library.sessionArchive';

/// 读电脑上工作区目录用的门面方法。
const String remoteWorkspaceFilesListMethod = 'workspace.files.list';

/// 读电脑上文件内容用的门面方法。
const String remoteWorkspaceFilesReadMethod = 'workspace.files.read';

/// 读电脑设置目录用的门面方法。
const String remoteSettingsDescribeMethod = 'settings.describe';

/// 写电脑设置用的门面方法。
const String remoteSettingsMutateMethod = 'settings.mutate';

/// 读电脑模型目录的路由（`api.call` 的 `session.modelCatalog`）。
const String remoteApiCallMethod = 'api.call';

/// 电脑设置里默认模型路由所在的命名空间。
const String remoteDefaultModelNamespace = 'agent-default-model';

/// 没有 `cwd` 的会话归入的项目标识。
const String _unscopedProjectKey = 'remote:unscoped';

/// 没有 `cwd` 的会话归入的项目名。
const String _unscopedProjectName = '未指定项目';

/// 会话没有标题时显示的占位文案（与 `library_data.dart` 的既有文案一致）。
const String _untitledSession = '未命名会话';

/// 电脑上没有任何工作区，无法为新会话选择落点。
///
/// 首页把它显示成可见提示「这台电脑上还没有项目」，而不是网络错误。
class RemoteDshNoWorkspaceException implements Exception {
  const RemoteDshNoWorkspaceException();

  /// 可直接展示的中文说明。
  String get message => '这台电脑上还没有项目';

  @override
  String toString() => message;
}

/// `library.catalog` 里的一个工作区（首页的「项目」来源之一）。
class RemoteDshWorkspace {
  const RemoteDshWorkspace({required this.id, this.path = '', this.title = ''});

  /// 工作区标识，用于 `library.sessionCreate`。
  final String id;

  /// 工作区目录（绝对路径）；电脑没有给出时为空字符串。
  final String path;

  /// 工作区标题；电脑没有给出时为空字符串。
  final String title;

  /// 项目显示名：工作区标题优先，没有标题时取目录最后一段。
  String get name {
    final title = this.title.trim();
    if (title.isNotEmpty) return title;
    final fromPath = remoteDshProjectName(path);
    return fromPath.isEmpty ? _unscopedProjectName : fromPath;
  }
}

/// `library.catalog` 里的一个会话。
class RemoteDshCatalogSession {
  const RemoteDshCatalogSession({
    required this.id,
    this.cwd = '',
    this.title = '',
    this.running = false,
  });

  /// 会话标识。
  final String id;

  /// 会话所属目录；电脑没有给出时为空字符串。
  final String cwd;

  /// 会话标题；没有标题时为空字符串。
  final String title;

  /// 目录行是否带 `running: true`；多数 `library.catalog` 应答不带这个字段。
  final bool running;

  /// 展示用标题：没有标题时退回占位文案。
  String get displayTitle =>
      title.trim().isEmpty ? _untitledSession : title.trim();
}

/// 首页写操作需要的 `library.catalog` 快照。
class RemoteDshCatalog {
  const RemoteDshCatalog({
    this.workspaces = const <RemoteDshWorkspace>[],
    this.sessions = const <RemoteDshCatalogSession>[],
    this.archivedSessionIds = const <String>[],
    this.defaultDirectory,
  });

  /// 电脑上的工作区（按电脑给出的顺序）。
  final List<RemoteDshWorkspace> workspaces;

  /// 电脑上的会话（已排除子 Agent 会话）。
  final List<RemoteDshCatalogSession> sessions;

  /// 已归档会话的标识（按电脑给出的顺序）。
  final List<String> archivedSessionIds;

  /// 电脑的默认目录；新会话优先落在这个目录对应的工作区。
  final String? defaultDirectory;

  /// 按标识找会话；不存在时为 null。
  RemoteDshCatalogSession? session(String id) {
    for (final session in sessions) {
      if (session.id == id) return session;
    }
    return null;
  }

  /// 按目录找会话所属的工作区；没有对应工作区时为 null。
  RemoteDshWorkspace? workspaceForPath(String path) {
    if (path.trim().isEmpty) return null;
    for (final workspace in workspaces) {
      if (_sameRemoteDirectory(workspace.path, path)) return workspace;
    }
    return null;
  }
}

/// 新建会话后首页需要的信息。
class RemoteDshCreatedSession {
  const RemoteDshCreatedSession({
    required this.sessionId,
    required this.projectName,
  });

  /// 新建会话的标识，用于打开会话页。
  final String sessionId;

  /// 新会话落点工作区的项目显示名，用于会话页副标题的降级展示。
  final String projectName;
}

/// 把 `library.catalog` 的原始 JSON 解析成 [RemoteDshCatalog]。
///
/// 顶层不是对象时抛 `PlatformException`：这是「已连接但电脑返回了无法解释的
/// 结果」，页面应显示可重试的读取失败。列表里的单条坏数据跳过，不让一条脏记录
/// 挡住整页（工作区标识是唯一必需的字段，其余缺失按空值处理）。
///
/// 解析本身不发请求，可以脱离连接单独测试。
RemoteDshCatalog parseRemoteDshCatalog(Object? raw) {
  if (raw is! Map) {
    throw PlatformException(
      code: 'remote/bad-response',
      message: '电脑返回的作品目录不是对象，无法读取项目。',
    );
  }
  final workspaces = <RemoteDshWorkspace>[];
  final rawWorkspaces = raw['workspaces'];
  if (rawWorkspaces is List) {
    for (final entry in rawWorkspaces) {
      if (entry is! Map) continue;
      final id = entry['workspaceId'];
      if (id is! String || id.trim().isEmpty) continue;
      workspaces.add(
        RemoteDshWorkspace(
          id: id,
          path: _stringOf(entry['path']),
          title: _stringOf(entry['title']),
        ),
      );
    }
  }
  final sessions = <RemoteDshCatalogSession>[];
  final rawSessions = raw['sessions'];
  if (rawSessions is List) {
    for (final entry in rawSessions) {
      if (entry is! Map) continue;
      final id = entry['sessionId'];
      if (id is! String || id.trim().isEmpty) continue;
      sessions.add(
        RemoteDshCatalogSession(
          id: id,
          cwd: _stringOf(entry['cwd']),
          title: _sessionTitleOf(entry),
          running: entry['running'] == true,
        ),
      );
    }
  }
  final archived = <String>[];
  final rawArchived = raw['archivedSessionIds'];
  if (rawArchived is List) {
    for (final id in rawArchived) {
      if (id is String && id.trim().isNotEmpty) archived.add(id);
    }
  }
  final directory = raw['defaultDirectory'];
  return RemoteDshCatalog(
    workspaces: workspaces,
    sessions: sessions,
    archivedSessionIds: archived,
    defaultDirectory: directory is String && directory.trim().isNotEmpty
        ? directory.trim()
        : null,
  );
}

/// 新会话落点的选择规则：优先 `defaultDirectory` 对应的工作区，否则第一个。
///
/// 没有任何工作区时返回 null，由调用方给出「这台电脑上还没有项目」。选择本身是
/// 纯函数，不读连接、不发请求。
RemoteDshWorkspace? chooseRemoteDshWorkspace(
  List<RemoteDshWorkspace> workspaces, [
  String? defaultDirectory,
]) {
  if (workspaces.isEmpty) return null;
  final directory = defaultDirectory?.trim() ?? '';
  if (directory.isNotEmpty) {
    for (final workspace in workspaces) {
      if (_sameRemoteDirectory(workspace.path, directory)) return workspace;
    }
  }
  return workspaces.first;
}

/// 目录路径对应的项目名：取最后一段，Windows 与 POSIX 分隔符都认。
///
/// 路径没有可用片段时返回空字符串（调用方决定占位文案）。
String remoteDshProjectName(String path) {
  final segments = path.split(RegExp(r'[\\/]'));
  for (var index = segments.length - 1; index >= 0; index--) {
    final segment = segments[index].trim();
    if (segment.isNotEmpty) return segment;
  }
  return '';
}

/// 两个目录路径是否指向同一个目录。
///
/// 比较前去掉首尾空白与末尾分隔符，并把 `\` 与 `/` 视为等价：宿主给的
/// `defaultDirectory` 与工作区 `path` 来自同一次读取，但两侧的拼接方式可能不同。
bool _sameRemoteDirectory(String left, String right) {
  final a = left.trim();
  final b = right.trim();
  if (a == b) return true;
  return _normalizedDirectory(a) == _normalizedDirectory(b);
}

String _normalizedDirectory(String path) {
  var value = path.replaceAll('\\', '/');
  while (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

String _stringOf(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : '';

String _sessionTitleOf(Map<dynamic, dynamic> row) {
  final title = row['title'];
  if (title is String && title.trim().isNotEmpty) return title.trim();
  final projections = row['projections'];
  if (projections is Map) {
    final values = projections['values'];
    if (values is Map) {
      final projected = values['title'];
      if (projected is String && projected.trim().isNotEmpty) {
        return projected.trim();
      }
    }
  }
  return '';
}

/// 首页写操作面：在电脑上新建一个会话。
///
/// 只读数据源不需要实现它；首页拿到未实现的数据源时，输入条提交给出可见的
/// 「暂未开放」提示，而不是假装创建成功。
abstract interface class RemoteDshSessionCreator {
  /// 在默认目录（或第一个）工作区里新建会话。
  ///
  /// 没有任何工作区时抛 [RemoteDshNoWorkspaceException]；其它失败抛
  /// `PlatformException`，`message` 可直接展示。
  Future<RemoteDshCreatedSession> createSession({String? projectId});
}

// ---------------------------------------------------------------------------
// 能力判定（协议 §10.2）
// ---------------------------------------------------------------------------

/// 远程入口的三种能力状态。
///
/// 页面不能把「宿主不支持」和「还没拿到方法表」混成同一个灰按钮：前者置灰时说明
/// 电脑明确拒绝，后者只说明现在还判断不了（未连接或宿主版本较旧）。
enum RemoteDshCapabilityState {
  /// 宿主在 `methods` 里声明了全部主方法，入口可用。
  available,

  /// 宿主用 `unsupported` 明确覆盖了某个主方法，入口置灰并给出原因。
  unavailable,

  /// 宿主方法表里没有声明某个主方法：视同不可用，但不记成永久不支持。
  notDeclared,
}

/// 一个入口的能力判定结果；[reason] 是可直接展示的中文原因。
class RemoteDshCapability {
  /// 全部主方法都声明可用。
  const RemoteDshCapability.available()
    : state = RemoteDshCapabilityState.available,
      reason = null;

  /// 宿主明确不支持；[reason] 说明被拒绝的方法。
  const RemoteDshCapability.unavailable(String this.reason)
    : state = RemoteDshCapabilityState.unavailable;

  /// 方法表里没有该能力；[reason] 说明缺的是哪个方法。
  const RemoteDshCapability.notDeclared(String this.reason)
    : state = RemoteDshCapabilityState.notDeclared;

  /// 判定结果。
  final RemoteDshCapabilityState state;

  /// 可直接展示的中文原因；可用时为 null。
  final String? reason;

  /// 入口是否可以点开。
  bool get isAvailable => state == RemoteDshCapabilityState.available;
}

/// 按宿主握手的 `methods` / `unsupported` 判定一组主方法是否全部可用。
///
/// 协议 §10.1 规定 `unsupported` 优先于 `methods`；方法表只来自本次握手，因此这里
/// 只做即时判定，不缓存（[RemoteConnectionController.supports] 的语义相同，但这里
/// 需要区分「明确不支持」与「没有声明」两种可见状态）。
///
/// [host] 为 null 表示还没握手成功：返回 [RemoteDshCapabilityState.notDeclared]，
/// 页面据此说明「先连接电脑」而不是「电脑不支持」。
RemoteDshCapability remoteDshCapabilityOf(
  RemoteHostInfo? host,
  List<String> methods,
) {
  if (host == null) {
    return const RemoteDshCapability.notDeclared('还没有和电脑完成握手，无法确认这项能力。');
  }
  for (final method in methods) {
    for (final pattern in host.unsupported) {
      if (_matchesRemoteMethod(pattern, method)) {
        return RemoteDshCapability.unavailable('这台电脑声明不支持「$method」。');
      }
    }
  }
  for (final method in methods) {
    if (!host.supports(method)) {
      return RemoteDshCapability.notDeclared('这台电脑没有声明「$method」，暂时无法使用。');
    }
  }
  return const RemoteDshCapability.available();
}

/// 协议 §10.1 的 `methods` 条目匹配：精确名，或 `.*` 结尾的前缀。
bool _matchesRemoteMethod(String pattern, String method) =>
    pattern.endsWith('.*')
    ? method.startsWith(pattern.substring(0, pattern.length - 1))
    : pattern == method;

// ---------------------------------------------------------------------------
// 电脑文件（workspace.files.*，只读）
// ---------------------------------------------------------------------------

/// `workspace.files.list` 里一项的类型。
enum RemoteDshFileKind { directory, file, link, other }

/// 电脑上的一个文件或目录。
class RemoteDshFileEntry {
  const RemoteDshFileEntry({
    required this.name,
    required this.path,
    required this.kind,
    this.modifiedAt,
    this.bytes,
    this.blockedReason,
  });

  /// 显示名（不含目录路径）。
  final String name;

  /// 相对工作区根目录的路径，也是读目录/读文件时的 `path`；无法表达时为 ''。
  final String path;

  /// 项目类型。
  final RemoteDshFileKind kind;

  /// 最近修改的 Unix 毫秒；电脑没给时为 null。
  final int? modifiedAt;

  /// 文件字节数；目录或电脑没给时为 null。
  final int? bytes;

  /// 不能打开的原因码（`symlink`、`not-regular-file`、`unsupported-name` 等）。
  final String? blockedReason;

  /// 是否为目录。
  bool get isDirectory => kind == RemoteDshFileKind.directory;

  /// 是否可以在页面上打开：只有普通文件与目录，且路径可表达。
  bool get openable =>
      blockedReason == null &&
      path.isNotEmpty &&
      (kind == RemoteDshFileKind.file || kind == RemoteDshFileKind.directory);
}

/// 一页目录内容（`workspace.files.list` 的结果）。
class RemoteDshDirectoryPage {
  const RemoteDshDirectoryPage({
    required this.root,
    required this.path,
    required this.version,
    required this.entries,
    required this.offset,
    this.nextOffset,
    this.truncated = false,
    this.listedEntries,
  });

  /// 工作区根目录的绝对路径（只用于展示）。
  final String root;

  /// 本页读取的相对路径；'' 表示根目录。
  final String path;

  /// 目录版本；续页必须原样带回。
  final String version;

  /// 本页项目。
  final List<RemoteDshFileEntry> entries;

  /// 本页起始位置。
  final int offset;

  /// 下一页的位置；null 表示目录已经读完。
  final int? nextOffset;

  /// 目录项目数达到读取预算，列表不完整。
  final bool truncated;

  /// 目录里的项目总数（电脑扫描到的，可能大于已列出数量）。
  final int? listedEntries;
}

/// 一页文件文本（`workspace.files.read` 的结果）。
class RemoteDshFilePage {
  const RemoteDshFilePage({
    required this.root,
    required this.path,
    required this.version,
    required this.bytes,
    required this.offset,
    required this.nextOffset,
    required this.eof,
    required this.text,
  });

  /// 工作区根目录的绝对路径（只用于展示）。
  final String root;

  /// 相对路径。
  final String path;

  /// 文件版本；续页必须原样带回。
  final String version;

  /// 文件总字节数。
  final int bytes;

  /// 本页起始字节位置。
  final int offset;

  /// 下一页的起始字节位置。
  final int nextOffset;

  /// 是否已到文件末尾。
  final bool eof;

  /// 本页 UTF-8 文本。
  final String text;

  /// 是否还有下一段可加载。
  bool get hasMore => !eof;
}

RemoteDshFileKind _remoteFileKindOf(Object? value) => switch (value) {
  'directory' => RemoteDshFileKind.directory,
  'file' => RemoteDshFileKind.file,
  'link' => RemoteDshFileKind.link,
  _ => RemoteDshFileKind.other,
};

/// 把 `workspace.files.list` 的结果解析成 [RemoteDshDirectoryPage]。
///
/// 顶层字段不完整时抛 `PlatformException`（已连接但电脑返回了无法解释的结果）；
/// 列表里的坏条目跳过，不让一条脏数据挡住整页。
RemoteDshDirectoryPage parseRemoteDshDirectoryPage(Object? raw) {
  if (raw is! Map) {
    throw PlatformException(
      code: 'remote/bad-response',
      message: '电脑返回的目录内容不是对象，无法显示文件列表。',
    );
  }
  final root = _stringOf(raw['root']);
  final path = raw['path'];
  final version = _stringOf(raw['version']);
  final offset = raw['offset'];
  final entries = raw['entries'];
  if (root.isEmpty ||
      path is! String ||
      version.isEmpty ||
      offset is! int ||
      offset < 0 ||
      entries is! List) {
    throw PlatformException(
      code: 'remote/bad-response',
      message: '电脑返回的目录内容不完整，请刷新后重试。',
    );
  }
  final parsed = <RemoteDshFileEntry>[];
  for (final entry in entries) {
    if (entry is! Map) continue;
    final name = _stringOf(entry['name']);
    if (name.isEmpty) continue;
    final kind = _remoteFileKindOf(entry['kind']);
    final blocked = _stringOf(entry['blockedReason']);
    final entryPath = _stringOf(entry['path']);
    final openableKind =
        kind == RemoteDshFileKind.file || kind == RemoteDshFileKind.directory;
    parsed.add(
      RemoteDshFileEntry(
        name: name,
        path: entryPath,
        kind: kind,
        modifiedAt: entry['modifiedAt'] is num
            ? (entry['modifiedAt'] as num).toInt()
            : null,
        bytes: entry['bytes'] is num ? (entry['bytes'] as num).toInt() : null,
        blockedReason: blocked.isNotEmpty
            ? blocked
            : entryPath.isEmpty || !openableKind
            ? kind == RemoteDshFileKind.link
                  ? 'symlink'
                  : 'not-regular-file'
            : null,
      ),
    );
  }
  final nextOffset = raw['nextOffset'];
  final listedEntries = raw['listedEntries'];
  return RemoteDshDirectoryPage(
    root: root,
    path: path,
    version: version,
    entries: parsed,
    offset: offset,
    nextOffset: nextOffset is int && nextOffset > offset ? nextOffset : null,
    truncated: raw['truncated'] == true,
    listedEntries: listedEntries is int && listedEntries >= 0
        ? listedEntries
        : null,
  );
}

/// 把 `workspace.files.read` 的结果解析成 [RemoteDshFilePage]。
///
/// 非文本文件不会走到这里：宿主用 `_pocket_error` 拒绝，传输层已经把它抛成
/// 带中文 `message` 的 `PlatformException`。
RemoteDshFilePage parseRemoteDshFilePage(Object? raw) {
  if (raw is! Map) {
    throw PlatformException(
      code: 'remote/bad-response',
      message: '电脑返回的文件内容不是对象，无法显示文件。',
    );
  }
  final root = _stringOf(raw['root']);
  final path = _stringOf(raw['path']);
  final version = _stringOf(raw['version']);
  final bytes = raw['bytes'];
  final offset = raw['offset'];
  final nextOffset = raw['nextOffset'];
  final text = raw['text'];
  final eof = raw['eof'];
  if (root.isEmpty ||
      path.isEmpty ||
      version.isEmpty ||
      bytes is! int ||
      bytes < 0 ||
      offset is! int ||
      offset < 0 ||
      nextOffset is! int ||
      nextOffset < offset ||
      nextOffset > bytes ||
      text is! String ||
      eof is! bool) {
    throw PlatformException(
      code: 'remote/bad-response',
      message: '电脑返回的文件内容不完整，请重新打开文件。',
    );
  }
  return RemoteDshFilePage(
    root: root,
    path: path,
    version: version,
    bytes: bytes,
    offset: offset,
    nextOffset: nextOffset,
    eof: eof,
    text: text,
  );
}

/// 电脑文件能力（`workspace.files.list` 与 `workspace.files.read`，只读）。
///
/// 只读数据源不需要实现它；首页拿到未实现的数据源时，「电脑文件」入口给出可见的
/// 「暂未开放」提示，而不是打开一个空页面。实现了它的数据源还要给出能力状态：
/// 不可用时首页入口置灰并展示 [RemoteDshCapability.reason]。
abstract interface class RemoteDshFilesSource {
  /// 这台电脑是否支持浏览文件（协议 §10.2）。
  RemoteDshCapability get filesCapability;

  /// 读一页目录；[version] 是上一页返回的目录版本，续页必须原样带回。
  Future<RemoteDshDirectoryPage> listDirectory({
    required String path,
    int offset = 0,
    String? version,
  });

  /// 读一页文件文本；[version] 是上一页返回的文件版本，续页必须原样带回。
  Future<RemoteDshFilePage> readFile({
    required String path,
    int offset = 0,
    String? version,
  });
}

// ---------------------------------------------------------------------------
// 电脑设置（settings.describe / settings.mutate）
// ---------------------------------------------------------------------------

/// 设置页只读行的类型，决定图标与值的展示方式。
enum RemoteDshSettingFieldKind {
  boolean,
  choice,
  text,
  number,
  secret,
  structured,
}

/// 设置页的一行：一个普通字段或一个凭据槽位。
class RemoteDshSettingField {
  const RemoteDshSettingField({
    required this.path,
    required this.label,
    required this.value,
    required this.kind,
    this.configured = false,
  });

  /// 字段路径（相对该节根）。
  final List<String> path;

  /// 展示标题；没有本地文案时是字段名。
  final String label;

  /// 可直接展示的值；凭据槽位只显示是否已配置。
  final String value;

  /// 字段类型。
  final RemoteDshSettingFieldKind kind;

  /// 凭据槽位是否已配置（只有 [RemoteDshSettingFieldKind.secret] 有意义）。
  final bool configured;
}

/// `settings.describe` 里的一节（一个插件命名空间的设置）。
class RemoteDshSettingsSection {
  const RemoteDshSettingsSection({
    required this.ns,
    required this.title,
    required this.revision,
    this.fields = const [],
    this.value = const {},
  });

  /// 命名空间，例如 `agent-default-model`。
  final String ns;

  /// 展示标题。
  final String title;

  /// 读取时的设置版本；写回时必须原样带回。
  final int revision;

  /// 已可读的普通字段。
  final List<RemoteDshSettingField> fields;

  /// 已脱敏的当前值；默认模型路由从这里取。
  final Map<String, dynamic> value;

  /// 是否为默认模型路由那一节。
  bool get isDefaultModel => ns == remoteDefaultModelNamespace;

  /// 默认模型路由；不是这一节或字段缺失时为 null。
  RemoteDshModelRoute? get defaultModelRoute {
    if (!isDefaultModel) return null;
    final provider = _stringOf(value['provider']);
    final model = _stringOf(value['model']);
    if (provider.isEmpty || model.isEmpty) return null;
    final effort = _stringOf(value['reasoningEffort']);
    return RemoteDshModelRoute(
      provider: provider,
      model: model,
      reasoningEffort: effort.isEmpty ? null : effort,
    );
  }
}

/// 一次 `settings.describe` 读到的完整设置目录。
class RemoteDshSettingsSnapshot {
  const RemoteDshSettingsSnapshot({
    this.sections = const [],
    this.writable = true,
  });

  /// 电脑上的设置节，顺序沿用电脑给出的顺序。
  final List<RemoteDshSettingsSection> sections;

  /// 电脑是否接受写入；false 时页面只读。
  final bool writable;

  /// 按命名空间找一节；不存在时为 null。
  RemoteDshSettingsSection? section(String ns) {
    for (final section in sections) {
      if (section.ns == ns) return section;
    }
    return null;
  }

  /// 默认模型路由那一节；电脑没有提供时为 null。
  RemoteDshSettingsSection? get defaultModelSection =>
      section(remoteDefaultModelNamespace);
}

/// 默认模型的 provider / model / 可选推理强度。
class RemoteDshModelRoute {
  const RemoteDshModelRoute({
    required this.provider,
    required this.model,
    this.reasoningEffort,
  });

  /// 模型提供方路由（例如 `deepseek-account`）。
  final String provider;

  /// 提供方自己的模型 id（例如 `deepseek-flash`）。
  final String model;

  /// 推理强度；null 表示不指定（使用提供方默认值）。
  final String? reasoningEffort;

  /// 展示用的 `provider/model`。
  String get label => '$provider/$model';

  @override
  bool operator ==(Object other) =>
      other is RemoteDshModelRoute &&
      other.provider == provider &&
      other.model == model &&
      other.reasoningEffort == reasoningEffort;

  @override
  int get hashCode => Object.hash(provider, model, reasoningEffort);

  @override
  String toString() => label;
}

/// 远程设置节标题：电脑没有给出 `title` 时的本地兜底。
///
/// 只列远程宿主 profile 常见的命名空间；未知插件保留命名空间原名，避免猜错。
String remoteDshSettingsTitle(String ns) => switch (ns) {
  remoteDefaultModelNamespace => '默认模型',
  'agent-loop' => 'Agent 执行',
  'llm-deepseek' => 'DeepSeek API 密钥接入',
  'llm-deepseek-account' => 'DeepSeek 账号模型接入',
  'llm-pi-ai' => '兼容模型服务',
  'subagent' => '子 Agent',
  'subagent-model-selection-settings' => '子 Agent 模型选择',
  'web' ||
  'web-search-deepseek' ||
  'web-deepseek-api' ||
  'web-search-exa' ||
  'web-fetch-http' ||
  'tool-web' => '联网工具',
  'tool-fs' => 'Agent 文件工具',
  'tool-fs-search' => 'Agent 文件搜索',
  'tool-ask-user' => 'Agent 提问工具',
  'session-log-deepseek' => '会话日志上传',
  'ui-theme' => 'Web 主题与字体',
  _ => ns,
};

/// 把 `settings.describe` 的结果解析成 [RemoteDshSettingsSnapshot]。
///
/// 接受两种顶层形态：数组（门面实际返回）与 `{writable, namespaces:[...]}`
/// （设置服务自己的描述对象）。单节字段缺失时跳过该节，不让一条坏数据挡住整页。
RemoteDshSettingsSnapshot parseRemoteDshSettings(Object? raw) {
  bool writable = true;
  Object? rows = raw;
  if (raw is Map) {
    writable = raw['writable'] != false;
    rows = raw['namespaces'];
  }
  if (rows is! List) {
    throw PlatformException(
      code: 'remote/bad-response',
      message: '电脑返回的设置目录不是列表，无法显示设置。',
    );
  }
  final sections = <RemoteDshSettingsSection>[];
  for (final row in rows) {
    if (row is! Map) continue;
    final ns = _stringOf(row['ns']);
    final revision = row['revision'];
    final schema = row['schema'];
    if (ns.isEmpty || revision is! int || revision < 0 || schema is! Map) {
      continue;
    }
    final rawValue = row['value'];
    final value = rawValue is Map
        ? Map<String, dynamic>.from(rawValue)
        : const <String, dynamic>{};
    final title = _stringOf(row['title']);
    sections.add(
      RemoteDshSettingsSection(
        ns: ns,
        title: title.isEmpty ? remoteDshSettingsTitle(ns) : title,
        revision: revision,
        fields: _settingsFieldsOf(ns, schema, value, row['secrets']),
        value: value,
      ),
    );
  }
  return RemoteDshSettingsSnapshot(sections: sections, writable: writable);
}

/// 从一节设置的 schema 与已脱敏值里提出现实可展示的字段。
///
/// 只看该节对象的第一层：标量字段（文本、数字、开关、枚举）逐行展示；嵌套对象
/// 折叠成一行摘要；凭据槽位只显示是否已配置，绝不显示值（`settings.describe`
/// 在电脑侧已经脱敏，这里再按 `secrets` 标注一遍）。
List<RemoteDshSettingField> _settingsFieldsOf(
  String ns,
  Map<dynamic, dynamic> schemaJson,
  Map<String, dynamic> value,
  Object? rawSecrets,
) {
  final schema = ConfigurationSchema(Map<String, dynamic>.from(schemaJson));
  final configured = <String>{};
  if (rawSecrets is List) {
    for (final secret in rawSecrets) {
      if (secret is! Map || secret['set'] != true) continue;
      final path = secret['path'];
      if (path is List) {
        final label = path.whereType<String>().join('.');
        if (label.isNotEmpty) configured.add(label);
      }
    }
  }
  final presentation = ConfigurationPresentation(ns);
  final dict = schema.root['dict'];
  if (dict is! Map) return const <RemoteDshSettingField>[];
  final fields = <RemoteDshSettingField>[];
  for (final entry in dict.entries) {
    final path = <String>['${entry.key}'];
    final node = schema.resolve(entry.value);
    if (node.isEmpty) continue;
    final field = ConfigurationFieldSchema(schema, node);
    final label = presentation.title(path, field);
    final current = configurationValueAt(value, path);
    if (field.secret) {
      final set = configured.contains(path.join('.'));
      fields.add(
        RemoteDshSettingField(
          path: path,
          label: label,
          value: set ? '已配置（不显示）' : '未配置',
          kind: RemoteDshSettingFieldKind.secret,
          configured: set,
        ),
      );
      continue;
    }
    final kind = field.booleanChoice
        ? RemoteDshSettingFieldKind.boolean
        : field.enumType
        ? RemoteDshSettingFieldKind.choice
        : switch (field.type) {
            'string' => RemoteDshSettingFieldKind.text,
            'number' => RemoteDshSettingFieldKind.number,
            _ => RemoteDshSettingFieldKind.structured,
          };
    fields.add(
      RemoteDshSettingField(
        path: path,
        label: label,
        value: _settingsFieldValue(path, kind, current, presentation),
        kind: kind,
      ),
    );
  }
  return fields;
}

String _settingsFieldValue(
  List<String> path,
  RemoteDshSettingFieldKind kind,
  dynamic current,
  ConfigurationPresentation presentation,
) {
  if (!configurationHasValue(current) || current == null) {
    return '未设置（使用默认值）';
  }
  switch (kind) {
    case RemoteDshSettingFieldKind.boolean:
      return current == true ? '已开启' : '已关闭';
    case RemoteDshSettingFieldKind.choice:
      return presentation.option(path, current);
    case RemoteDshSettingFieldKind.text:
      final text = '$current';
      return text.contains('\n') || text.length > 80
          ? '${text.length} 个字符'
          : text;
    case RemoteDshSettingFieldKind.number:
      return '$current';
    case RemoteDshSettingFieldKind.structured:
      return configurationStructureSummary(current);
    case RemoteDshSettingFieldKind.secret:
      return '';
  }
}

/// 电脑设置能力（`settings.describe` / `settings.mutate`）。
abstract interface class RemoteDshSettingsSource {
  /// 这台电脑是否支持远程查看/修改设置（协议 §10.2）。
  RemoteDshCapability get settingsCapability;

  /// 读取整份设置目录（`settings.describe`，电脑侧已脱敏）。
  Future<RemoteDshSettingsSnapshot> describeSettings();

  /// 写回默认模型路由（`settings.mutate` 的 `agent-default-model` 一节）。
  ///
  /// [revision] 是读取时那一节的版本；版本冲突抛
  /// `PlatformException(code: 'SETTINGS_CONFLICT')`（协议 §9.2 的
  /// `settings/conflict`），页面据此重读并提示重试。
  Future<RemoteDshSettingsSnapshot> saveDefaultModel({
    required RemoteDshModelRoute route,
    required int revision,
  });
}

/// 可选的模型目录来源：设置页用它把默认模型的 provider/model 变成可选项。
///
/// 只读数据源不需要实现它；没有实现时设置页仍允许手动填写路由。
abstract interface class RemoteDshModelCatalogSource {
  /// 读取电脑的模型目录（`api.call` 的 `session.modelCatalog`）。
  Future<RemoteDshModelCatalog> describeModelCatalog();
}

// ---------------------------------------------------------------------------
// 模型目录（api.call session.modelCatalog）
// ---------------------------------------------------------------------------

/// 电脑可用的模型目录。
class RemoteDshModelCatalog {
  const RemoteDshModelCatalog({
    this.groups = const [],
    this.failures = const [],
  });

  /// 按提供方分组的模型。
  final List<RemoteDshModelGroup> groups;

  /// 读取目录时失败的提供方说明；可直接展示。
  final List<String> failures;

  /// 目录里有没有任何可选模型。
  bool get isEmpty => groups.every((group) => group.models.isEmpty);
}

/// 模型目录里的一个提供方分组。
class RemoteDshModelGroup {
  const RemoteDshModelGroup({
    required this.id,
    required this.name,
    this.models = const [],
  });

  /// 提供方路由 id（写进 `provider`）。
  final String id;

  /// 展示名。
  final String name;

  /// 该提供方的模型。
  final List<RemoteDshModel> models;
}

/// 模型目录里的一个模型。
class RemoteDshModel {
  const RemoteDshModel({required this.id, required this.name, this.reasoning});

  /// 模型 id（写进 `model`）。
  final String id;

  /// 展示名。
  final String name;

  /// 该模型声明的推理强度；没有声明时为 null。
  final RemoteDshModelReasoning? reasoning;
}

/// 一个模型声明的推理强度档位。
class RemoteDshModelReasoning {
  const RemoteDshModelReasoning({this.efforts = const [], this.defaultEffort});

  /// 可选档位。
  final List<RemoteDshReasoningLevel> efforts;

  /// 模型的默认档位；没有时为 null。
  final String? defaultEffort;
}

/// 一个推理强度档位。
class RemoteDshReasoningLevel {
  const RemoteDshReasoningLevel({required this.id, this.name});

  /// 档位 id（写进 `reasoningEffort`）。
  final String id;

  /// 展示名；电脑没给时为 null。
  final String? name;
}

/// 把 `session.modelCatalog` 的结果解析成 [RemoteDshModelCatalog]。
///
/// 目录格式不对时抛 `PlatformException`；单个坏分组/坏模型跳过。空目录是有效
/// 结果（电脑上还没有登录账号或配置服务商），由页面给出空态。
RemoteDshModelCatalog parseRemoteDshModelCatalog(Object? raw) {
  if (raw is! Map || raw['groups'] is! List) {
    throw PlatformException(
      code: 'remote/bad-response',
      message: '电脑返回的模型目录格式不正确。',
    );
  }
  final groups = <RemoteDshModelGroup>[];
  for (final rawGroup in raw['groups'] as List) {
    if (rawGroup is! Map) continue;
    final id = _stringOf(rawGroup['id']);
    if (id.isEmpty) continue;
    final models = <RemoteDshModel>[];
    for (final rawModel in rawGroup['models'] as List? ?? const <Object?>[]) {
      if (rawModel is! Map) continue;
      final modelId = _stringOf(rawModel['id']);
      if (modelId.isEmpty) continue;
      final name = _stringOf(rawModel['name']);
      models.add(
        RemoteDshModel(
          id: modelId,
          name: name.isEmpty ? modelId : name,
          reasoning: _remoteReasoningOf(rawModel['reasoning']),
        ),
      );
    }
    final name = _stringOf(rawGroup['name']);
    groups.add(
      RemoteDshModelGroup(
        id: id,
        name: name.isEmpty ? id : name,
        models: models,
      ),
    );
  }
  final failures = <String>[];
  for (final rawFailure in raw['failures'] as List? ?? const <Object?>[]) {
    if (rawFailure is! Map) continue;
    final message = _stringOf(rawFailure['message']);
    if (message.isEmpty) continue;
    final name = _stringOf(rawFailure['name']);
    failures.add(name.isEmpty ? message : '$name：$message');
  }
  return RemoteDshModelCatalog(groups: groups, failures: failures);
}

RemoteDshModelReasoning? _remoteReasoningOf(Object? raw) {
  if (raw is! Map) return null;
  final efforts = <RemoteDshReasoningLevel>[];
  for (final rawEffort in raw['efforts'] as List? ?? const <Object?>[]) {
    if (rawEffort is! Map) continue;
    final id = _stringOf(rawEffort['id']);
    if (id.isEmpty) continue;
    final name = _stringOf(rawEffort['name']);
    efforts.add(
      RemoteDshReasoningLevel(id: id, name: name.isEmpty ? null : name),
    );
  }
  final defaultEffort = _stringOf(raw['defaultEffort']);
  if (efforts.isEmpty && defaultEffort.isEmpty) return null;
  return RemoteDshModelReasoning(
    efforts: efforts,
    defaultEffort: defaultEffort.isEmpty ? null : defaultEffort,
  );
}

/// 一台电脑上 `library.*` 读写的门面。
///
/// 与连接层解耦：构造时只拿 [RuntimeTransport]，因此可以脱离
/// [RemoteConnectionController] 单独测试；[RemoteDshLiveSource] 在每条传输上建
/// 一个实例，传输换代时整实例替换，缓存也随之失效。
class RemoteDshFacade {
  /// 绑定一条已就绪的传输。
  RemoteDshFacade(this.transport);

  /// 发请求用的传输。
  final RuntimeTransport transport;

  RemoteDshCatalog? _catalogCache;

  /// 读取 `library.catalog`；同一传输内缓存，写操作后作废。
  ///
  /// [refresh] 为 true 时跳过缓存重读：已归档任务页每次都问电脑，因为归档集合
  /// 可能在这台手机之外被改动。
  Future<RemoteDshCatalog> catalog({bool refresh = false}) async {
    final cached = _catalogCache;
    if (cached != null && !refresh) return cached;
    final catalog = parseRemoteDshCatalog(await _request(remoteCatalogMethod));
    _catalogCache = catalog;
    return catalog;
  }

  /// 在默认目录（或第一个）工作区里新建会话。
  ///
  /// 先读 [catalog] 选工作区，再调 `library.sessionCreate`，成功后作废缓存：下一次
  /// 读取会拿到包含新会话的目录。返回的标识用于打开会话页。
  Future<RemoteDshCreatedSession> createSession({String? projectId}) async {
    final catalog = await this.catalog();
    final projectPath = projectId?.startsWith('cwd:') == true
        ? projectId!.substring(4)
        : null;
    final workspace = projectId == null
        ? chooseRemoteDshWorkspace(catalog.workspaces, catalog.defaultDirectory)
        : projectPath == null
        ? null
        : catalog.workspaceForPath(projectPath);
    if (projectId != null && workspace == null) {
      throw PlatformException(
        code: 'remote/project-unavailable',
        message: '这个项目在电脑上已不可用，请刷新项目列表后重试。',
      );
    }
    if (workspace == null) throw const RemoteDshNoWorkspaceException();
    final created = await _request(remoteSessionCreateMethod, {
      'workspaceId': workspace.id,
    });
    _catalogCache = null;
    final sessionId = created is Map ? created['sessionId'] : null;
    if (sessionId is! String || sessionId.trim().isEmpty) {
      throw PlatformException(
        code: 'remote/bad-response',
        message: '电脑没有返回新会话的标识，无法打开新建的会话。',
      );
    }
    return RemoteDshCreatedSession(
      sessionId: sessionId,
      projectName: workspace.name,
    );
  }

  /// 读取已归档会话：`archivedSessionIds` 与 `sessions` 的标题按标识连接。
  ///
  /// 每次都重读目录：归档可能是在电脑上（Web 或桌面 App）发起的，缓存会显示
  /// 已经不该出现的旧行。新建会话与恢复归档仍走 [catalog] 的缓存/作废规则。
  Future<List<RemoteDshArchivedSession>> listArchivedSessions() async {
    final catalog = await this.catalog(refresh: true);
    return [
      for (final id in catalog.archivedSessionIds)
        _archivedSessionOf(catalog, id),
    ];
  }

  /// 恢复一个已归档会话（`library.sessionArchive` 的 `archived: false`）。
  Future<void> restoreSession(String sessionId) async {
    await _request(remoteSessionArchiveMethod, {
      'sessionId': sessionId,
      'archived': false,
    });
    _catalogCache = null;
  }

  RemoteDshArchivedSession _archivedSessionOf(
    RemoteDshCatalog catalog,
    String id,
  ) {
    final session = catalog.session(id);
    if (session == null) {
      // 归档集合里可能出现电脑还没投影标题的会话；标识本身仍可打开与恢复。
      return RemoteDshArchivedSession(id: id, title: _untitledSession);
    }
    final workspace = catalog.workspaceForPath(session.cwd);
    final project = workspace?.name ?? remoteDshProjectName(session.cwd);
    return RemoteDshArchivedSession(
      id: id,
      title: session.displayTitle,
      projectName: project,
    );
  }

  /// 读取一页目录（`workspace.files.list`）。
  Future<RemoteDshDirectoryPage> listDirectory({
    required String path,
    int offset = 0,
    String? version,
  }) async => parseRemoteDshDirectoryPage(
    await _request(remoteWorkspaceFilesListMethod, {
      'path': path,
      'offset': offset,
      'version': ?version,
    }),
  );

  /// 读取一页文件文本（`workspace.files.read`）。
  ///
  /// 非文本文件由电脑用 `_pocket_error` 拒绝，这里原样抛 `PlatformException`，
  /// 页面按错误码给出「不是文本文件」的说明。
  Future<RemoteDshFilePage> readFile({
    required String path,
    int offset = 0,
    String? version,
  }) async => parseRemoteDshFilePage(
    await _request(remoteWorkspaceFilesReadMethod, {
      'path': path,
      'offset': offset,
      'version': ?version,
    }),
  );

  /// 读取整份设置目录（`settings.describe`，电脑侧已脱敏）。
  Future<RemoteDshSettingsSnapshot> describeSettings() async =>
      parseRemoteDshSettings(await _request(remoteSettingsDescribeMethod));

  /// 写回默认模型路由，并返回电脑回写的整份设置。
  ///
  /// 只发 `agent-default-model` 一节的三个字段；推理强度为空时用 `unset` 移除
  /// profile 里的旧值（与 `DefaultModelPage` 的保存语义一致）。版本冲突由电脑以
  /// `SETTINGS_CONFLICT` 拒绝，页面据此重读并提示重试。
  Future<RemoteDshSettingsSnapshot> saveDefaultModel({
    required RemoteDshModelRoute route,
    required int revision,
  }) async {
    final effort = route.reasoningEffort?.trim();
    final ops = <Map<String, dynamic>>[
      {
        'op': 'set',
        'path': <String>['provider'],
        'value': route.provider,
      },
      {
        'op': 'set',
        'path': <String>['model'],
        'value': route.model,
      },
      if (effort == null || effort.isEmpty)
        {
          'op': 'unset',
          'path': <String>['reasoningEffort'],
        }
      else
        {
          'op': 'set',
          'path': <String>['reasoningEffort'],
          'value': effort,
        },
    ];
    return parseRemoteDshSettings(
      await _request(remoteSettingsMutateMethod, {
        'ns': remoteDefaultModelNamespace,
        'ops': ops,
        'revision': revision,
      }),
    );
  }

  /// 读取电脑的模型目录（`api.call` 的 `session.modelCatalog`）。
  Future<RemoteDshModelCatalog> describeModelCatalog() async =>
      parseRemoteDshModelCatalog(
        await _request(remoteApiCallMethod, {
          'namespace': 'session',
          'method': 'modelCatalog',
          'args': const <String, dynamic>{},
        }),
      );

  /// 发一次门面请求，把 [RuntimeTransportFailure] 统一成可展示的
  /// `PlatformException`；不支持的方法给出点名该方法的说明。
  Future<dynamic> _request(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) async {
    try {
      return await transport.request(method, params);
    } on RuntimeTransportFailure catch (failure) {
      if (failure.code == 'unsupported-method') {
        throw PlatformException(
          code: failure.code,
          message: '当前连接的电脑不支持「$method」。',
          details: failure.details?.toString(),
        );
      }
      throw PlatformException(
        code: failure.code,
        message: failure.message,
        details: failure.details?.toString(),
      );
    }
  }
}

/// 远程首页的真实数据源。
///
/// 构造后不自行发起任何读取：页面调用 [listDevices] / [listProjects] 时才读本机
/// 设备表与 PC 门面。本类不持有监听、不需要 dispose。
class RemoteDshLiveSource
    implements
        RemoteDshDataSource,
        RemoteDshSessionCreator,
        RemoteDshArchiveSource,
        RemoteDshFilesSource,
        RemoteDshSettingsSource,
        RemoteDshModelCatalogSource {
  /// 绑定连接控制器。
  ///
  /// [controller] 既提供设备表，也提供当前连接的传输与方法表。
  RemoteDshLiveSource({required this.controller});

  /// 远程连接控制器。
  final RemoteConnectionController controller;

  /// 上一次做过连通性探测的传输实例。
  ///
  /// 握手成功只说明传输层连上了；`runtime.info` 能应答才说明门面真的在跑，所以
  /// 每条传输先探一次。传输实例在重连期间保持不变，因此重连不会重复探测。
  RuntimeTransport? _probedTransport;

  /// 当前传输上的 `library.*` 门面；传输换代时整实例替换，缓存随之失效。
  RemoteDshFacade? _facade;
  RuntimeTransport? _facadeTransport;

  @override
  RemoteDshConnectionState get connection {
    switch (controller.phase) {
      case RemoteConnectionPhase.idle:
        return RemoteDshConnectionState.notConnected;
      case RemoteConnectionPhase.failed:
        return RemoteDshConnectionState.failed;
      case RemoteConnectionPhase.ready:
        return RemoteDshConnectionState.connected;
      case RemoteConnectionPhase.connecting:
      case RemoteConnectionPhase.handshaking:
      case RemoteConnectionPhase.reconnecting:
      case RemoteConnectionPhase.lost:
        return RemoteDshConnectionState.connecting;
    }
  }

  /// 当前连接的电脑显示名；未握手或已断开时为 null。
  @override
  String? get hostName => controller.host?.name;

  @override
  Future<List<RemoteDshDevice>> listDevices() async {
    try {
      await controller.loadDevices();
    } on RemoteDeviceStoreException catch (failure) {
      // 「偏好通道不存在」等于本机还没有设备表这项能力：配对写入同样不可用，
      // 因此「没有任何已配对电脑」是事实，按空列表展示并给出「添加连接」空态。
      // 其它失败（数据损坏、版本不认识、超时）不降级，交给页面显示可重试的错误。
      if (failure.code != 'remote/preferences-unavailable') {
        throw PlatformException(
          code: failure.code,
          message: failure.message,
          details: failure.details?.toString(),
        );
      }
    }
    final activeId = controller.activeDevice?.id;
    final phase = controller.phase;
    // 设备表里的 label 是配对时上报的**手机**显示名（`protocol.hello` 的
    // `deviceLabel` 同值），拿来当电脑名会显示成手机型号。握手完成后用宿主的
    // `host.name` 作为这台电脑的显示名；未连接时仍用本机保存的别名。
    final hostName = controller.host?.name;
    final showHostName =
        phase == RemoteConnectionPhase.ready &&
        hostName != null &&
        hostName.trim().isNotEmpty;
    return <RemoteDshDevice>[
      for (final device in controller.devices)
        RemoteDshDevice(
          id: device.id,
          label: showHostName && device.id == activeId
              ? hostName
              : device.label,
          state: _deviceState(device.id, activeId, phase),
        ),
    ];
  }

  @override
  Future<List<RemoteDshProject>> listProjects() async {
    final device = controller.activeDevice;
    if (device == null) return const <RemoteDshProject>[];
    if (controller.phase != RemoteConnectionPhase.ready) {
      return const <RemoteDshProject>[];
    }
    final transport = controller.transport;
    if (transport == null) return const <RemoteDshProject>[];
    try {
      await _probe(transport);
      final result = await transport.request(remoteSessionsListMethod);
      if (result is! List) {
        throw PlatformException(
          code: 'remote/bad-response',
          message: '电脑返回的会话列表不是数组，无法显示项目。',
          details: '${result.runtimeType}',
        );
      }
      return _projectsFrom(result, device.id);
    } on RuntimeTransportFailure catch (failure) {
      switch (failure.code) {
        case 'gateway/cancelled':
        case 'gateway/unavailable':
          // 读取过程中连接断了或还没就绪：空列表即可，阶段变化会把页面切到
          // 「正在连接」，不需要再叠一条读取失败提示。
          return const <RemoteDshProject>[];
        case 'unsupported-method':
          throw PlatformException(
            code: failure.code,
            message: '当前连接的电脑不支持「$remoteSessionsListMethod」。',
            details: failure.details?.toString(),
          );
        default:
          throw PlatformException(
            code: failure.code,
            message: failure.message,
            details: failure.details?.toString(),
          );
      }
    }
  }

  /// 在默认目录（或第一个）工作区里新建会话。
  @override
  Future<RemoteDshCreatedSession> createSession({String? projectId}) async =>
      (await _liveFacade()).createSession(projectId: projectId);

  /// 读取那台电脑上已归档的会话。
  @override
  Future<List<RemoteDshArchivedSession>> listArchivedSessions() async =>
      (await _liveFacade()).listArchivedSessions();

  /// 恢复那台电脑上一个已归档的会话。
  @override
  Future<void> restoreSession(String sessionId) async =>
      (await _liveFacade()).restoreSession(sessionId);

  /// 这台电脑是否支持浏览文件（协议 §10.2）。
  @override
  RemoteDshCapability get filesCapability =>
      remoteDshCapabilityOf(controller.host, const <String>[
        remoteWorkspaceFilesListMethod,
        remoteWorkspaceFilesReadMethod,
      ]);

  /// 这台电脑是否支持远程设置（协议 §10.2）。
  @override
  RemoteDshCapability get settingsCapability => remoteDshCapabilityOf(
    controller.host,
    const <String>[remoteSettingsDescribeMethod, remoteSettingsMutateMethod],
  );

  /// 读一页电脑上的目录。
  @override
  Future<RemoteDshDirectoryPage> listDirectory({
    required String path,
    int offset = 0,
    String? version,
  }) async => (await _liveFacade()).listDirectory(
    path: path,
    offset: offset,
    version: version,
  );

  /// 读一页电脑上的文本文件。
  @override
  Future<RemoteDshFilePage> readFile({
    required String path,
    int offset = 0,
    String? version,
  }) async => (await _liveFacade()).readFile(
    path: path,
    offset: offset,
    version: version,
  );

  /// 读取电脑上的整份设置目录。
  @override
  Future<RemoteDshSettingsSnapshot> describeSettings() async =>
      (await _liveFacade()).describeSettings();

  /// 写回电脑上的默认模型路由。
  @override
  Future<RemoteDshSettingsSnapshot> saveDefaultModel({
    required RemoteDshModelRoute route,
    required int revision,
  }) async =>
      (await _liveFacade()).saveDefaultModel(route: route, revision: revision);

  /// 读取电脑上的模型目录（设置页用来提供默认模型候选）。
  @override
  Future<RemoteDshModelCatalog> describeModelCatalog() async =>
      (await _liveFacade()).describeModelCatalog();

  /// 取当前传输上的门面；未就绪时给出可展示的连接失败。
  Future<RemoteDshFacade> _liveFacade() async {
    final transport = controller.transport;
    if (controller.phase != RemoteConnectionPhase.ready || transport == null) {
      throw PlatformException(
        code: 'gateway/unavailable',
        message: '与电脑的连接已断开，正在重连…',
      );
    }
    final facade = _facade;
    if (identical(_facadeTransport, transport) && facade != null) return facade;
    _facadeTransport = transport;
    return _facade = RemoteDshFacade(transport);
  }

  /// 连通性探测：每条传输只调一次 `runtime.info`。
  ///
  /// 它返回 `{node, platform, arch, uid?, workspace, profile}`，本类不读具体值，
  /// 只确认门面在应答。宿主没有把该方法登记进方法表时同样记为「已探测」：缺这条
  /// 探测不影响接下来读会话列表，也不该让每次刷新都多打一次无效请求。其它失败按
  /// `RuntimeTransportFailure` 抛给 [listProjects] 归类：断线时页面保持空列表。
  Future<void> _probe(RuntimeTransport transport) async {
    if (identical(_probedTransport, transport)) return;
    try {
      await transport.request(remoteProbeMethod);
    } on RuntimeTransportFailure catch (failure) {
      if (failure.code != 'unsupported-method') rethrow;
    }
    _probedTransport = transport;
  }

  /// 设备胶囊条上的状态。
  ///
  /// v1 只有一条连接（协议 §11），因此除当前设备外都只能是「已配对、未连接」。
  RemoteDshDeviceState _deviceState(
    String id,
    String? activeId,
    RemoteConnectionPhase phase,
  ) {
    if (id != activeId) return RemoteDshDeviceState.offline;
    switch (phase) {
      case RemoteConnectionPhase.ready:
        return RemoteDshDeviceState.online;
      case RemoteConnectionPhase.connecting:
      case RemoteConnectionPhase.handshaking:
      case RemoteConnectionPhase.reconnecting:
      case RemoteConnectionPhase.lost:
        return RemoteDshDeviceState.connecting;
      case RemoteConnectionPhase.idle:
      case RemoteConnectionPhase.failed:
        return RemoteDshDeviceState.offline;
    }
  }

  /// 把 `sessions.list` 的数组按 `cwd` 归组成项目。
  ///
  /// 项目顺序沿用电脑给出的顺序（置顶会话在最前，因此置顶会话所属项目也更靠前）；
  /// 会话顺序原样保留，页面按自己的排序方式重排。
  List<RemoteDshProject> _projectsFrom(List<dynamic> rows, String deviceId) {
    final grouped = <String, List<RemoteDshSession>>{};
    for (final raw in rows) {
      if (raw is! Map) continue;
      final id = _sessionId(raw);
      if (id == null) continue;
      final key = _sessionCwd(raw) ?? _unscopedProjectKey;
      grouped
          .putIfAbsent(key, () => <RemoteDshSession>[])
          .add(
            RemoteDshSession(
              id: id,
              title: _sessionTitle(raw),
              // sessions.list 不返回待处理项数量；审批计数要再调 interactions.list，
              // 本轮不接，页面因此不会把任何会话排进「优先级」。
              pendingCount: 0,
              updatedAt: _sessionUpdatedAt(raw),
              // 宿主 `session.list` 行携带 running:true 表示该会话正在执行；缺失按
              // 未运行处理。字符串 "true" 不算，避免把投影里的其它字段误读成状态。
              running: _sessionRunning(raw),
            ),
          );
    }
    return <RemoteDshProject>[
      for (final entry in grouped.entries)
        RemoteDshProject(
          id: entry.key == _unscopedProjectKey
              ? _unscopedProjectKey
              : 'cwd:${entry.key}',
          deviceId: deviceId,
          name: _projectName(entry.key),
          sessions: entry.value,
        ),
    ];
  }

  static String? _sessionId(Map<dynamic, dynamic> row) {
    final header = row['header'];
    if (header is Map) {
      final id = header['id'];
      if (id is String && id.isNotEmpty) return id;
    }
    final id = row['sessionId'];
    return id is String && id.isNotEmpty ? id : null;
  }

  /// 会话是否正在工作：优先顶层 `running`，兼容放在 `header` 里的行形状。
  static bool _sessionRunning(Map<dynamic, dynamic> row) {
    if (row['running'] == true) return true;
    final header = row['header'];
    return header is Map && header['running'] == true;
  }

  static String _sessionTitle(Map<dynamic, dynamic> row) {
    final title = row['title'];
    if (title is String && title.trim().isNotEmpty) return title;
    // `sessions.list` 已经把投影标题提到顶层，但原始会话记录里的投影仍在；
    // 两处都缺时用占位文案，与既有会话列表保持一致。
    final projections = row['projections'];
    if (projections is Map) {
      final values = projections['values'];
      if (values is Map) {
        final projected = values['title'];
        if (projected is String && projected.trim().isNotEmpty) {
          return projected;
        }
      }
    }
    return _untitledSession;
  }

  static String? _sessionCwd(Map<dynamic, dynamic> row) {
    final cwd = row['cwd'];
    if (cwd is String && cwd.trim().isNotEmpty) return cwd;
    final header = row['header'];
    if (header is Map) {
      final nested = header['cwd'];
      if (nested is String && nested.trim().isNotEmpty) return nested;
    }
    return null;
  }

  static int? _sessionUpdatedAt(Map<dynamic, dynamic> row) {
    final value = row['updatedAt'];
    return value is num ? value.toInt() : null;
  }

  /// 项目名取目录的最后一段；Windows 与 POSIX 的分隔符都要认。
  static String _projectName(String key) {
    if (key == _unscopedProjectKey) return _unscopedProjectName;
    final name = remoteDshProjectName(key);
    return name.isEmpty ? key : name;
  }
}
