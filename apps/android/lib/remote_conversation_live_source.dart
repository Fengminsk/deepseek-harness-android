// 远程会话页的真实数据源：把 PC 门面接成 `RemoteConversationSource`。
//
// ## 依赖的门面方法
//
// | 方法 | 参数 | 用途 |
// |---|---|---|
// | `session.readWindow` | `{sessionId}` | 首屏与重连重建：`events` / `throughSeq` / `firstSeq` / `hasMore` |
// | `session.send` | `{sessionId, requestId, text, provider, model, selectModel:false, attachmentIds?}` | 提交一条消息；`attachmentIds` 是已在宿主登记的附件草稿 |
// | `session.command` | `{sessionId, line, attachmentIds}` | 在电脑上执行一条会话指令（以 `/` 开头），结果通常是 `{commandId, result:{kind, text}}`，未识别时为 null |
// | `session.ensure` | `{sessionId}` | `+` 弹层的指令目录与计划模式写操作之前恢复会话（幂等） |
// | `api.call` | `{namespace:'commands', method:'list', args:{agentId}}` | `+` 弹层的指令目录（与本地 `ComposerCommands` 同一份数据驱动菜单） |
// | `api.call` | `{namespace:'session', method:'projections', args:{request:{sessionId}}}` | 计划模式状态（`values.plan`）与 `asOfSeq` |
// | `api.subscribe` | `{namespace:'session', method:'control'}` | 会话控制流：`session.projections` 的实时增量（计划模式进出） |
// | `attachments.prepare` / `.release` | `{sessionId, id[, name, mediaType, bytes]}` | 附件草稿的上传准备与释放（`RemoteAttachmentSurface`，字节由宿主通过反向请求 `native.attachments.read` 分页拉取） |
// | `api.subscribe` | `{streamId, namespace:'session', method:'follow', args:{address}}` | 会话更新流（协议 §6.5、§7.3） |
// | `api.ack` / `api.unsubscribe` | 由 `AppApiStreams` 管理 | 窗口化回执与释放 |
// | `settings.describe` | `{}` | 仅当窗口里还没有模型投影时，取 `agent-default-model` 作为发送参数 |
// | `library.sessionRename` | `{sessionId, title}` | 重命名 |
// | `library.sessionArchive` | `{sessionId, archived:true}` | 归档会话 |
// | `interactions.list` | `{}` | 首屏与重连重建待处理审批/提问快照（按 `sessionId` 过滤） |
// | `interactions.reply` | `{id, version, response}` | 审批回 `allowed-once`/`rejected`；提问回 `{answers:[{id, selected, custom?}]}` |
// | `interactions.dismiss` | `{id, version}` | 计划审核的「请求修改」：不发送答案，请求继续等待决定 |
// | `api.call` | `{namespace:'session', method:'modelCatalog', args:{}}` | 会话模型目录，同时用于预判当前路由的可用性 |
// | `api.call` | `{namespace:'session', method:'selectModel', args:{request:{sessionId, provider, model, reasoningEffort?}}}` | 切换会话模型 |
// | `workspaceChanges.summary` / `.diff` / `.cancel` | `{owner, requestId, sessionId, seq[, index]}` | 「本次变更」页读取一次快照与其文件差异，离开页面时取消在途读取 |
//
// ## 模型路由可用性（发送前提示）
//
// 会话路由来自窗口里的 `model/selection` / `request/header` 投影。打开、重连与
// 切换模型后，数据源会读一次 `session.modelCatalog`，把当前路由的 provider 与
// 目录的 `failures[].id`、`routableProviders` 对比，用
// [RemoteConversationModelAvailability] 告诉页面这台电脑上这个服务商是否可用：
// 读取失败、或者静默缺席（没有配置凭据的服务商返回空模型列表，既不成组也不
// 报错）都算不可用。页面据此在发送前提示会自动改用电脑默认模型，而不是等发送
// 失败后才解释。
//
// 目录按「打开 / 重连」周期缓存：同一周期内路由变化（电脑上改了模型选择）复用
// 这次读取，只有打开与重连会重新读；切换模型用同一份目录重新判定。预读失败不会
// 变成页面错误，也从不阻塞发送——发送参数仍来自窗口投影。
//
// 本次变更的 seq 取会话窗口里最后一条 `workspace/changes` 事件的序号：宿主只为
// 这个序号保留快照，其它序号会回 `workspace-changes/unavailable`。快照只存在
// 宿主当前进程内，电脑重启后旧轮次读不到，页面因此把这种情况当作正常降级。
//
// ## 流式更新的来源
//
// 会话增量走 `session.follow`（快照 + 增量，协议 §7.3）；正在生成的助手回复走
// 宿主本来就推送的 `session.live` 通知——它的 `value` 已经是组装好的
// `{attemptId, revision, turn, step, content}`，与本地模式 `runtime.live` 完全
// 同形，因此页面不必重新实现助手流的组装。`session.status` / `session.error`
// 分别投影成运行状态与可见错误。
//
// 待处理交互走两条路：首屏/重连用一次 `interactions.list` 一元读，之后用
// `interactions.changed` 通知（协议 §7.3 的触发器型通知）整体替换。两条路都只
// 接受 `sessionId` 等于当前会话的请求，并按 `revision` 丢弃迟到的旧快照。
// 会话模型来自窗口里 `model/selection` / `request/header` 的投影；应用
// `selectModel` 后先用 `result.selected` 更新，模型选择事件落盘后由投影接替。
//
// `session.follow` 不可用时（`unsupported` / 方法表没有），宿主推送的
// `session.event` 通知仍然会被采用：页面按 `seq` 去重，所以两条路径同时到达也
// 不会出现重复消息。这条退路不是静默降级——发送能力是否可用只由
// `session.send` 决定，读取能力由 `session.readWindow` 决定。
//
// ## 重连（协议 §7.2）
//
// 连接掉线时 `AppApiStreams.setReady(false)` 会保留旧 `streamId` 并等待确认；
// 重新 `ready` 时先重读窗口与待处理交互，再把 `setReady(true)`，由它显式
// `api.unsubscribe` 旧流、用新 `streamId` 重新订阅。页面只看到一次整体替换的快照。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'api_streams.dart';
import 'attachment_surface.dart';
import 'remote_attachments.dart';
import 'remote_connection.dart';
import 'remote_conversation_source.dart';
import 'runtime.dart';
import 'runtime_transport.dart';
import 'session_model_projection.dart';
import 'workspace_changes.dart';

/// 生成一个线上标识用的 UUID v4 文本（小写、带连字符）。
///
/// 远程变更读取要求 `requestId` 是小写 UUID v4（宿主用正则校验），页面 owner
/// 也从这里生成：`remote-<uuid>`。`Random.secure()` 保证同一进程内不会重复；
/// [random] 只给测试注入确定性序列。
///
/// @param random 可选的随机源；缺省用加密安全随机源。
/// @returns 形如 `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` 的 36 字符小写文本。
String remoteUuidV4({Random? random}) {
  final source = random ?? _secureRandom;
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  // 版本位固定 4，变体位固定 10xx（RFC 4122 §4.4）。
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

final Random _secureRandom = Random.secure();

/// 会话数据源访问一条远程连接所需的只读面。
///
/// 阶段、失败原因与传输入口来自 [RemoteAttachmentConnection]（附件调用面也读
/// 同一份）；生产实现是 [RemoteControllerConnection]（套在
/// [RemoteConnectionController] 上）；测试可以给一个只实现这几个成员的假连接，
/// 因此数据源的单测不需要真实的 TLS 传输或设备表。
abstract interface class RemoteConversationConnection
    implements RemoteAttachmentConnection, Listenable {
  /// 宿主是否支持某个门面方法。
  bool supports(String method);

  /// 宿主是否声明了 `window-ack` 能力（协议 §6.4、§10.3）。
  ///
  /// 只有双方都声明时才切换成窗口化确认；宿主没有声明或尚未握手时必须为 false。
  bool get windowAck;

  /// 终止态下的重新连接。
  Future<void> reconnect();
}

/// 把 [RemoteConnectionController] 的公开面转成 [RemoteConversationConnection]。
///
/// 控制器仍由远程首页持有，这里只读它的阶段、方法表与传输，不改变连接生命周期。
class RemoteControllerConnection implements RemoteConversationConnection {
  /// 绑定连接控制器。
  RemoteControllerConnection(this.controller);

  /// 被读取的远程连接控制器。
  final RemoteConnectionController controller;

  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      controller.removeListener(listener);

  @override
  RemoteConnectionPhase get phase => controller.phase;

  @override
  String? get lastError => controller.lastError;

  @override
  bool supports(String method) => controller.supports(method);

  @override
  bool get windowAck => controller.host?.declares('window-ack') ?? false;

  @override
  RuntimeTransport? get transport => controller.transport;

  @override
  Future<void> reconnect() async {
    final device = controller.activeDevice;
    if (device != null) await controller.connect(device);
  }
}

/// 走 PC 门面的会话数据源。
///
/// [events] 是连接层的入站通知帧流（`{'method': String, 'params': Map}`），
/// 由调用方从 `RemoteConnectionController` 取得；本类只过滤自己关心的方法，
/// 不改写也不重放。
class RemoteConversationLiveSource extends RemoteConversationSource {
  /// 绑定连接、会话与入站帧流。
  ///
  /// [events] 是单订阅还是广播由连接层决定；本类只订阅一次，并在 [dispose]
  /// 时取消。构造后不会自行发请求，页面调用 [start] 才开始读首屏。
  RemoteConversationLiveSource({
    required this.connection,
    required this.sessionId,
    required Stream<Map<String, dynamic>> events,
    Random? random,
  }) : _random = random ?? Random() {
    _inbound = events.listen(_onInbound, onError: _onInboundError);
    connection.addListener(_onConnectionChanged);
    _follow = _streams
        .watch(
          remoteConversationFollowNamespace,
          remoteConversationFollowMethod,
          args: _followArgs(),
        )
        .listen(_onFollow, onError: _onFollowError);
  }

  /// 打开的会话标识。
  @override
  final String sessionId;

  /// 读取阶段、方法表与传输的连接；生命周期仍由调用方持有。
  final RemoteConversationConnection connection;

  final Random _random;
  late final AppApiStreams _streams = AppApiStreams(_request);
  final StreamController<RemoteConversationUpdate> _updates =
      StreamController<RemoteConversationUpdate>.broadcast(sync: true);
  final SessionModelProjection _modelProjection = SessionModelProjection();

  StreamSubscription<Map<String, dynamic>>? _inbound;
  StreamSubscription<ApiJson>? _follow;
  Future<void>? _started;
  Future<void>? _rebuilding;

  /// 最近一次已知的会话事件，只用于推导发送参数（模型路由）与定位变更快照。
  List<Json> _events = const [];

  /// 最近一次窗口读取的日志切点；变更快照的 seq 从它向下找。
  int _throughSeq = 0;

  /// 发送参数里的模型路由一次性缓存：窗口有了投影就不再读设置。
  ({String provider, String model, String? reasoningEffort})? _fallbackRoute;

  /// 当前会话的待处理交互，已按 `sessionId` 过滤。
  List<RemotePendingInteraction> _pendingInteractions =
      const <RemotePendingInteraction>[];

  /// 已应用交互快照的 `revision`；低于它的迟到快照丢弃。
  int _interactionsRevision = -1;

  /// 最近一次交互快照里的宿主错误，用来避免重复提示同一条消息。
  String? _interactionsError;

  /// `session.selectModel` 刚受理、但模型选择事件还没进窗口时的本地选择。
  ///
  /// 窗口重读与 `model/selection` 事件会清掉它，之后以投影为准。
  RemoteModelChoice? _selectedOverride;

  /// 最近一次推给页面的模型选择，用于去重。
  RemoteModelChoice? _lastModelChoice;

  /// 预读的模型目录：按「打开 / 重连」周期缓存，同一周期内复用同一次读取。
  ///
  /// null 表示本周期还没读过目录；读取失败时缓存一个结果为 null 的 future，
  /// 同一周期不会反复重试。
  Future<RemoteModelCatalog?>? _availabilityRead;

  /// 上一次做过可用性判定的路由；同一条路由不重复判定。
  RemoteModelChoice? _availabilityRoute;

  /// 可用性判定的代次：打开 / 重连会作废上一轮的迟到结果。
  int _availabilityGeneration = 0;

  /// 正在进行的可用性判定，用来合并同一时刻的重复请求。
  Future<void>? _availabilityCheck;

  bool _ready = false;
  bool _disposed = false;
  int _readGeneration = 0;

  @override
  RemoteConnectionPhase get phase => connection.phase;

  @override
  String? get lastError => connection.lastError;

  @override
  bool supports(String method) => connection.supports(method);

  @override
  Stream<RemoteConversationUpdate> get updates => _updates.stream;

  @override
  Future<void> start() => _started ??= _open();

  @override
  Future<void> reload() async {
    final generation = ++_readGeneration;
    await _readWindow(generation);
    if (_disposed || generation != _readGeneration) return;
    _streams.setWindowAck(connection.windowAck);
    _streams.setReady(connection.phase == RemoteConnectionPhase.ready);
  }

  @override
  Future<void> send(
    String text, {
    List<String> attachmentIds = const <String>[],
  }) async {
    final route = await _modelRoute();
    await _request(remoteConversationSendMethod, {
      'sessionId': sessionId,
      'requestId': _nextRequestId(),
      'text': text,
      'provider': route.provider,
      'model': route.model,
      if (route.reasoningEffort != null)
        'reasoningEffort': route.reasoningEffort,
      // 已存在的会话沿用电脑上的模型选择；这两个字段只在会话需要新建时生效。
      'selectModel': false,
      if (attachmentIds.isNotEmpty)
        'attachmentIds': List<String>.of(attachmentIds),
    });
  }

  @override
  Future<RemoteCommandResult> submitCommand(
    String line, {
    List<String> attachmentIds = const <String>[],
  }) async {
    final result = await _request(remoteConversationCommandMethod, {
      'sessionId': sessionId,
      'line': line,
      // 附件草稿已经由 `attachments.prepare` 在宿主登记；空数组是「这次没有
      // 附件」的显式声明（本地链路对 session.command 也是同样的字段形状）。
      'attachmentIds': List<String>.of(attachmentIds),
    });
    return _commandResultOf(result);
  }

  @override
  Future<Json> ensureSession() async {
    final result = await _request('session.ensure', {'sessionId': sessionId});
    if (result is! Json) {
      throw const RuntimeTransportFailure(
        code: 'gateway/internal',
        message: '电脑没有返回会话信息，请重新打开会话。',
      );
    }
    return result;
  }

  /// 门面请求的通用入口：`api.call` 的透传与 `ComposerCommandSurface` 等调用面
  /// 共用，失败翻译与在途请求归属都留在本类，页面只拿到可直接展示的文本。
  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) => _request(method, params);

  @override
  Future<Json?> readProjections() async {
    final result = await _request(remoteConversationApiCallMethod, {
      'namespace': remoteConversationPlanNamespace,
      'method': remoteConversationProjectionsMethod,
      'args': <String, dynamic>{
        'request': {'sessionId': sessionId},
      },
    });
    return result is Json ? result : null;
  }

  /// 会话控制流：与 `session.follow` 共用同一条连接的 `AppApiStreams`，因此回执
  /// 窗口、断线重建与旧流释放都沿用协议 §6.4/§7.2 的既有语义。
  @override
  Stream<Json> watchSessionControl() => _streams.watch(
    remoteConversationControlNamespace,
    remoteConversationControlMethod,
    args: const <String, dynamic>{},
  );

  /// 计划模式写入口；非成功结果转成可展示的 [StateError]，调用方保留输入。
  @override
  Future<void> submitPlan(bool enabled) async {
    final result = await _request(remoteConversationCommandMethod, {
      'sessionId': sessionId,
      'line': enabled ? '/plan' : '/plan off',
      'attachmentIds': const <String>[],
    });
    final outcome = _commandResultOf(result);
    if (!outcome.succeeded) throw StateError(outcome.displayText);
  }

  @override
  Future<RemoteInteractionReply> dismissInteraction(
    String id,
    int version,
  ) async {
    final result = await _request('interactions.dismiss', {
      'id': id,
      'version': version,
    });
    return _replyOf(result);
  }

  @override
  Future<void> rename(String title) async {
    await _request(remoteConversationRenameMethod, {
      'sessionId': sessionId,
      'title': title,
    });
  }

  @override
  Future<void> archive() async {
    await _request(remoteConversationArchiveMethod, {
      'sessionId': sessionId,
      'archived': true,
    });
  }

  @override
  Future<void> refreshInteractions() => _loadInteractions();

  @override
  Future<RemoteInteractionReply> replyApproval(
    String id,
    int version, {
    required bool allow,
  }) async {
    final result = await _request(remoteConversationInteractionsReplyMethod, {
      'id': id,
      'version': version,
      'response': allow ? 'allowed-once' : 'rejected',
    });
    return _replyOf(result);
  }

  @override
  Future<RemoteInteractionReply> answerQuestion(
    String id,
    int version,
    List<RemoteQuestionAnswer> answers,
  ) async {
    final result = await _request(remoteConversationInteractionsReplyMethod, {
      'id': id,
      'version': version,
      'response': <String, dynamic>{
        'answers': [for (final answer in answers) answer.toJson()],
      },
    });
    return _replyOf(result);
  }

  @override
  Future<RemoteModelCatalog> fetchModelCatalog() async {
    final result = await _request(remoteConversationApiCallMethod, {
      'namespace': remoteConversationModelNamespace,
      'method': remoteConversationModelCatalogMethod,
      'args': <String, dynamic>{},
    });
    return _catalogOf(result);
  }

  @override
  Future<void> selectModel(RemoteModelChoice choice) async {
    final result = await _request(remoteConversationApiCallMethod, {
      'namespace': remoteConversationModelNamespace,
      'method': remoteConversationSelectModelMethod,
      'args': <String, dynamic>{
        'request': <String, dynamic>{
          'sessionId': sessionId,
          ...choice.toJson(),
        },
      },
    });
    final selected = result is Json ? _choiceOf(result['selected']) : null;
    final applied = selected ?? choice;
    // 结果先落地：在模型选择事件进窗口之前，发送与页面都使用这次受理的选择。
    _selectedOverride = applied;
    _fallbackRoute = (
      provider: applied.provider,
      model: applied.model,
      reasoningEffort: applied.reasoningEffort,
    );
    // 新路由要重新判定可用性；目录仍用本周期预读的结果，不额外重读。
    _availabilityRoute = null;
    _emitModelSelection();
    await _checkModelAvailability();
  }

  @override
  Future<void> retry() => connection.reconnect();

  @override
  Future<RemoteModelChoice?> fetchDefaultModelRoute() async {
    try {
      final described = await _request('settings.describe');
      return _choiceOf(_defaultModelForm(described));
    } on RuntimeTransportFailure {
      // 设置读不到（宿主不支持或连接断开）时自动切换无从判断；调用方保留
      // 原有的凭据提示，不把这次失败升级成第二条错误。
      return null;
    }
  }

  @override
  RemoteWorkspaceChangesSource? createWorkspaceChangesSource() {
    if (!connection.supports(remoteWorkspaceChangesSummaryMethod) ||
        !connection.supports(remoteWorkspaceChangesDiffMethod)) {
      return null;
    }
    return RemoteWorkspaceChangesLiveSource(
      link: connection,
      session: sessionId,
      events: () => _events,
      latest: _latestSeq,
    );
  }

  /// 附件草稿的调用面：走同一条连接的 `attachments.prepare` / `.release`。
  ///
  /// 字节不随请求上行：宿主在 prepare 内用反向请求 `native.attachments.read`
  /// 向手机分页拉取（设计文档 §3.4）。连接就绪与否由调用面自己投影，因此未连接
  /// 时也能创建——页面据此渲染 rail 的「上传失败/重试」而不是隐藏入口。
  @override
  AttachmentCallSurface createAttachmentSurface() =>
      RemoteAttachmentSurface(connection: connection);

  /// 变更快照查找的起点：窗口切点与已收到的最后一条事件里较大的那个。
  int _latestSeq() {
    var latest = _throughSeq;
    for (final event in _events) {
      final seq = event['seq'];
      if (seq is int && seq > latest) latest = seq;
    }
    return latest;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    connection.removeListener(_onConnectionChanged);
    final inbound = _inbound;
    _inbound = null;
    if (inbound != null) unawaited(inbound.cancel());
    // 取消 follow 观察：传输仍然就绪时，AppApiStreams 会先显式 api.unsubscribe
    // 再收口，不会把旧 streamId 留在宿主上。
    final follow = _follow;
    _follow = null;
    if (follow != null) unawaited(follow.cancel());
    unawaited(_streams.close());
    unawaited(_updates.close());
    super.dispose();
  }

  // ------------------------------------------------------------------ 首屏

  Future<void> _open() async {
    _resetModelAvailability();
    await _readWindow(_readGeneration);
    if (_disposed) return;
    await _loadInteractions();
    if (_disposed) return;
    _ready = connection.phase == RemoteConnectionPhase.ready;
    // 协议 §6.4：双方都声明 window-ack 才切窗口模式；本类只跑远程链路，
    // 本地链路的观察层仍是逐条模式。
    _streams.setWindowAck(connection.windowAck);
    _streams.setReady(_ready);
    // 先让流与输入区就绪，再做一次模型目录预读：预读结果只影响发送前的提示，
    // 失败不升级成页面错误，也不阻塞发送。
    await _checkModelAvailability();
  }

  /// 连接阶段变化：离开 `ready` 先让流观察进入断开态；重新 `ready` 时按
  /// 协议 §7.2 先重读窗口、再重新订阅。
  void _onConnectionChanged() {
    if (_disposed) return;
    final ready = connection.phase == RemoteConnectionPhase.ready;
    if (ready != _ready) {
      _ready = ready;
      if (ready) {
        unawaited(_rebuild());
      } else {
        _streams.setReady(false);
      }
    }
    notifyListeners();
  }

  Future<void> _rebuild() {
    final rebuilding = _rebuilding;
    if (rebuilding != null) return rebuilding;
    late final Future<void> operation;
    operation = _rebuildNow().whenComplete(() {
      if (identical(_rebuilding, operation)) _rebuilding = null;
    });
    return _rebuilding = operation;
  }

  Future<void> _rebuildNow() async {
    final generation = ++_readGeneration;
    // 重连可能换了宿主进程或凭据：目录与路由判定都要从头来。
    _resetModelAvailability();
    await _readWindow(generation);
    if (_disposed || generation != _readGeneration) return;
    // 协议 §7.2：重新 ready 后除重读窗口外还要重读一次待处理交互，断线期间
    // 被丢掉的 interactions.changed 通知因此补齐。
    await _loadInteractions(generation);
    if (_disposed || generation != _readGeneration) return;
    _streams.setWindowAck(connection.windowAck);
    _streams.setReady(true);
    await _checkModelAvailability();
  }

  Future<void> _readWindow(int generation) async {
    try {
      final result = await _request(remoteConversationReadMethod, {
        'sessionId': sessionId,
      });
      if (_disposed || generation != _readGeneration) return;
      _applyWindow(_windowOf(result));
    } on Object catch (error) {
      if (_disposed || generation != _readGeneration) return;
      final failure = _failureOf(error);
      if (_isDisconnected(failure)) {
        // 阶段变化会触发重建；这里不再叠一条失败提示。
        return;
      }
      _emit(
        RemoteConversationFailure(
          _messageFor(failure, remoteConversationReadMethod),
          fatal: true,
        ),
      );
    }
  }

  void _applyWindow(RemoteConversationWindow window) {
    _events = List<Json>.of(window.events);
    _throughSeq = window.throughSeq;
    // 窗口是权威状态：重读后本地待生效的选择交给投影重建。
    _selectedOverride = null;
    _modelProjection.reconcile(_events);
    _emitModelSelection();
    _emit(RemoteConversationSnapshot(window));
  }

  // ------------------------------------------------------------ 待处理交互

  /// 一元读当前会话的待处理交互；首屏、重连与答复被拒绝后都会调用。
  ///
  /// 宿主没有把 `interactions.list` 登记进方法表（协议 §10.1）时跳过：入口在
  /// 页面上本来就不存在，不为此报错。
  Future<void> _loadInteractions([int? generation]) async {
    if (_disposed) return;
    final readGeneration = generation ?? _readGeneration;
    if (!connection.supports(remoteConversationInteractionsListMethod)) return;
    try {
      final result = await _request(remoteConversationInteractionsListMethod);
      if (_disposed || readGeneration != _readGeneration) return;
      _applyInteractionsSnapshot(result);
    } on Object catch (error) {
      if (_disposed || readGeneration != _readGeneration) return;
      final failure = _failureOf(error);
      if (_isDisconnected(failure) || failure.code == 'unsupported-method') {
        return;
      }
      _emit(RemoteConversationFailure(failure.message));
    }
  }

  /// 应用一次 `interactions.list` / `interactions.changed` 快照。
  ///
  /// `interactions.changed` 的 `params` 与 `interactions.list` 的 `result` 同形，
  /// 都不带外层字段；快照是全量替换，按 `revision` 丢弃迟到的旧帧。
  void _applyInteractionsSnapshot(Object? snapshot) {
    if (_disposed || snapshot is! Json) return;
    final revision = snapshot['revision'];
    if (revision is int) {
      if (revision < _interactionsRevision) return;
      _interactionsRevision = revision;
    }
    final raw = snapshot['requests'];
    if (raw is! List) return;
    final pending = <RemotePendingInteraction>[];
    for (final item in raw) {
      final request = _interactionOf(item);
      if (request == null || request.sessionId != sessionId) continue;
      pending.add(request);
    }
    final error = snapshot['error'];
    final errorText = error is String && error.trim().isNotEmpty
        ? error.trim()
        : null;
    if (errorText != null && errorText != _interactionsError) {
      _interactionsError = errorText;
      _emit(RemoteConversationFailure(errorText));
    } else if (errorText == null) {
      _interactionsError = null;
    }
    // 这个会话的待处理项没有变化时不推更新：另一会话的审批变化也会发快照，
    // 页面不该因此重建。
    if (_samePendingInteractions(pending)) return;
    _pendingInteractions = pending;
    _emit(RemoteConversationInteractions(pending));
  }

  bool _samePendingInteractions(List<RemotePendingInteraction> next) {
    if (next.length != _pendingInteractions.length) return false;
    for (var index = 0; index < next.length; index++) {
      final left = next[index];
      final right = _pendingInteractions[index];
      if (left.id != right.id ||
          left.version != right.version ||
          left.kind != right.kind) {
        return false;
      }
    }
    return true;
  }

  // ------------------------------------------------------------ 更新帧

  void _onInbound(Map<String, dynamic> frame) {
    if (_disposed) return;
    final method = frame['method'];
    final params = frame['params'];
    if (params is! Map<String, dynamic>) return;
    switch (method) {
      case 'api.stream':
        _streams.receive(params);
      case 'session.event':
        _onSessionEvent(params);
      case 'session.live':
        if (params['sessionId'] != sessionId) return;
        final value = params['value'];
        _emit(RemoteConversationLive(value is Json ? value : null));
      case 'session.status':
        if (params['sessionId'] != sessionId) return;
        final attached = params['attached'] != false;
        _emit(
          RemoteConversationRunning(attached && params['status'] == 'running'),
        );
      case 'session.error':
        if (params['sessionId'] != sessionId) return;
        final error = params['error'];
        _emit(
          RemoteConversationFailure(
            error is String && error.trim().isNotEmpty ? error : '会话出错了。',
          ),
        );
      // 触发器型通知（协议 §7.3）：`params` 就是一次完整快照，与
      // `interactions.list` 的 `result` 同形，不需要再读一次。
      case 'interactions.changed':
        _applyInteractionsSnapshot(params);
    }
  }

  /// `session.event` 是纯通知（协议 §7.3）：`session.follow` 正常时它与增量
  /// 重复，页面按 `seq` 去重；`session.follow` 不可用时它是唯一的增量来源。
  void _onSessionEvent(Map<String, dynamic> params) {
    if (params['sessionId'] != sessionId) return;
    final event = params['event'];
    if (event is! Json || event['seq'] is! int) return;
    final seq = event['seq'] as int;
    if (_events.any((known) => known['seq'] == seq)) return;
    _events = [..._events, event]..sort(_bySeq);
    _acceptModelEvent(event);
    _modelProjection.reconcile(_events);
    _emitModelSelection();
    _emit(RemoteConversationEvents([event]));
  }

  void _onInboundError(Object error) {
    if (_disposed) return;
    // 入站流本身出错意味着连接已经不可用；阶段机会给出可展示的原因。
    debugPrint('远程会话入站流中断：$error');
  }

  void _onFollow(ApiJson frame) {
    if (_disposed) return;
    // AppApiStreams 交付的是 `api.stream` 的 item 帧（协议 §6.1）：业务类型在
    // `value.type` 里，帧自己的 `type` 恒为 `item`。opening / disconnected / end
    // 由 AppApiStreams 的内部阶段管理，这里不处理。
    if (frame['type'] != 'item') return;
    final value = frame['value'];
    if (value is! Json) return;
    switch (value['type']) {
      case 'snapshot':
        final events = _eventsOfRecords(value['records']);
        if (events == null) return;
        final cursor = value['cursor'];
        _applyWindow(
          RemoteConversationWindow(
            events: events,
            throughSeq: cursor is int
                ? cursor
                : (events.isEmpty ? 0 : events.last['seq'] as int? ?? 0),
            firstSeq: events.isEmpty ? null : events.first['seq'] as int?,
            hasMore: value['hasMore'] == true,
          ),
        );
      case 'event':
        final event = value['event'];
        if (event is! Json || event['seq'] is! int) return;
        final seq = event['seq'] as int;
        if (_events.any((known) => known['seq'] == seq)) return;
        _events = [..._events, event]..sort(_bySeq);
        _acceptModelEvent(event);
        _modelProjection.reconcile(_events);
        _emitModelSelection();
        _emit(RemoteConversationEvents([event]));
      default:
        // assistant-stream 由 session.live 通知覆盖（见文件头注释）。
        break;
    }
  }

  void _onFollowError(Object error) {
    if (_disposed) return;
    final failure = _failureOf(error);
    // 取消与断线由阶段机负责；其余失败说明这条订阅开不起来，页面继续用
    // session.event 通知增量，并给出一条可见说明。
    if (_isDisconnected(failure) || failure.code == 'unsupported-method') {
      return;
    }
    _emit(RemoteConversationFailure(failure.message));
  }

  // ------------------------------------------------------------ 发送参数

  /// 发送消息必须带 `provider` / `model`（门面校验），与本地模式一样从窗口的
  /// 模型投影推导；刚应用过 `selectModel` 时用那次受理的结果。窗口里还没有选择
  /// 时读一次设置里的默认模型。
  Future<({String provider, String model, String? reasoningEffort})>
  _modelRoute() async {
    final applied = _selectedOverride;
    if (applied != null) {
      return (
        provider: applied.provider,
        model: applied.model,
        reasoningEffort: applied.reasoningEffort,
      );
    }
    final projected = _routeOf(_modelProjection.next);
    if (projected != null) return projected;
    final cached = _fallbackRoute;
    if (cached != null) return cached;
    final described = await _request('settings.describe');
    final route = _routeOf(_defaultModelForm(described));
    if (route == null) {
      throw const RuntimeTransportFailure(
        code: 'gateway/unavailable',
        message: '这台电脑还没有选择默认模型，暂时无法发送消息。',
      );
    }
    _fallbackRoute = route;
    return route;
  }

  /// `model/selection` 是会话日志里「选择已落盘」的事实，此后以投影为准。
  void _acceptModelEvent(Json event) {
    if (event['type'] == 'model/selection') _selectedOverride = null;
  }

  /// 当前模型选择：刚受理的本地选择优先，其次窗口投影。
  RemoteModelChoice? get _modelChoice =>
      _selectedOverride ?? _choiceOf(_modelProjection.next);

  /// 模型选择变化才推一条更新，避免每个事件都让页面 setState。
  void _emitModelSelection() {
    final choice = _modelChoice;
    if (choice == _lastModelChoice) return;
    _lastModelChoice = choice;
    _emit(RemoteConversationModel(choice));
    // 路由变化（电脑上改了选择、窗口重建）后重新判定可用性；同一条路由不会
    // 重复读目录，目录在本周期内复用。
    unawaited(_checkModelAvailability());
  }

  // -------------------------------------------------------- 模型路由可用性

  /// 作废上一轮的目录与判定：打开 / 重连时调用。
  void _resetModelAvailability() {
    _availabilityGeneration++;
    _availabilityRoute = null;
    _availabilityRead = null;
    // 上一轮的在途判定不再合并进这一轮；它的迟到结果由代次丢弃。
    _availabilityCheck = null;
  }

  /// 判定当前路由在电脑上是否可用，把不可用的服务商集合推给页面。
  ///
  /// 同一条路由只判定一次；并发的调用合并成同一次判定。目录读取失败时推空集合
  /// （页面不提示），发送不受影响。
  Future<void> _checkModelAvailability() {
    final pending = _availabilityCheck;
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _runModelAvailabilityCheck().whenComplete(() {
      if (!identical(_availabilityCheck, operation)) return;
      _availabilityCheck = null;
      // 判定期间路由又变了（例如刚切完模型又有新投影）：用同一份目录再判一次。
      if (!_disposed && _modelChoice != _availabilityRoute) {
        unawaited(_checkModelAvailability());
      }
    });
    return _availabilityCheck = operation;
  }

  Future<void> _runModelAvailabilityCheck() async {
    if (_disposed) return;
    final generation = _availabilityGeneration;
    final choice = _modelChoice;
    if (choice == null) {
      // 窗口里还没有路由：没有可对比的对象，清掉之前的判定。
      if (_availabilityRoute == null) return;
      _availabilityRoute = null;
      _emit(const RemoteConversationModelAvailability(<String>{}));
      return;
    }
    if (choice == _availabilityRoute) return;
    _availabilityRoute = choice;
    if (!connection.supports(remoteConversationApiCallMethod)) return;
    final catalog = await _readModelCatalogForAvailability();
    if (_disposed || generation != _availabilityGeneration) return;
    _emit(
      RemoteConversationModelAvailability(
        _unavailableProvidersOf(catalog, choice.provider),
      ),
    );
  }

  /// 本周期内的一次模型目录读取；读取失败也缓存成 null，避免反复重试。
  Future<RemoteModelCatalog?> _readModelCatalogForAvailability() =>
      _availabilityRead ??= fetchModelCatalog().then<RemoteModelCatalog?>(
        (catalog) => catalog,
        onError: (Object _) => null,
      );

  /// 当前路由的服务商在这台电脑上是否不可用，投影成页面对比的集合。
  ///
  /// 目录读取失败时返回空集合：没有依据就不提示，发送也不受影响。失败列表原样
  /// 保留；服务商不在 `routableProviders` 里时也加入——没有配置凭据的服务商在
  /// 目录里静默缺席，既不在失败列表、也不在任何分组里。
  static Set<String> _unavailableProvidersOf(
    RemoteModelCatalog? catalog,
    String provider,
  ) {
    if (catalog == null) return const <String>{};
    final unavailable = <String>{...catalog.failedProviders};
    if (!catalog.routableProviders.contains(provider)) {
      unavailable.add(provider);
    }
    return unavailable;
  }

  static RemoteModelChoice? _choiceOf(Object? value) {
    if (value is! Json) return null;
    final provider = value['provider'];
    final model = value['model'];
    if (provider is! String || provider.isEmpty) return null;
    if (model is! String || model.isEmpty) return null;
    final effort = value['reasoningEffort'];
    return RemoteModelChoice(
      provider: provider,
      model: model,
      reasoningEffort: effort is String && effort.isNotEmpty ? effort : null,
    );
  }

  static ({String provider, String model, String? reasoningEffort})? _routeOf(
    Json? value,
  ) {
    final provider = value?['provider'];
    final model = value?['model'];
    if (provider is! String || provider.isEmpty) return null;
    if (model is! String || model.isEmpty) return null;
    final effort = value?['reasoningEffort'];
    return (
      provider: provider,
      model: model,
      reasoningEffort: effort is String && effort.isNotEmpty ? effort : null,
    );
  }

  /// 与 `RuntimeController.refreshForms` 同一条规则：`agent-default-model`
  /// 表单的 `value` 是默认路由。
  static Json? _defaultModelForm(Object? described) {
    if (described is! List) return null;
    for (final form in described) {
      if (form is! Json || form['ns'] != 'agent-default-model') continue;
      final value = form['value'];
      if (value is Json) return value;
    }
    return null;
  }

  // ------------------------------------------------------------ 帧与请求

  Future<dynamic> _request(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) {
    final transport = connection.transport;
    if (transport == null) {
      return Future<dynamic>.error(
        const RuntimeTransportFailure(
          code: 'gateway/unavailable',
          message: '与电脑的连接已断开，正在重连…',
        ),
      );
    }
    return transport.request(method, params);
  }

  /// `session.follow` 的线上参数。
  ///
  /// 门面的方法签名是 `follow(request: SessionFollowRequest)`，所以 typert 网关要
  /// 的是 `args.request`（与 `index.mjs` 里 subagents 的 follow 同形）。`activate`
  /// 让宿主把会话保持在可继续执行的状态，与 Web 客户端的订阅一致；`assistantStream`
  /// 不请求，流式回复走宿主的 `session.live` 通知。
  Map<String, dynamic> _followArgs() => {
    'request': {
      'address': {'kind': 'session', 'sessionId': sessionId},
      'activate': true,
    },
  };

  String _nextRequestId() =>
      'app-${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 30)}';

  void _emit(RemoteConversationUpdate update) {
    if (_disposed || _updates.isClosed) return;
    _updates.add(update);
  }

  static RemoteConversationWindow _windowOf(Object? result) {
    if (result is! Json) {
      throw const RuntimeTransportFailure(
        code: 'gateway/internal',
        message: '电脑返回的会话窗口格式不正确。',
      );
    }
    final rawEvents = result['events'];
    final throughSeq = result['throughSeq'];
    if (rawEvents is! List || throughSeq is! int) {
      throw const RuntimeTransportFailure(
        code: 'gateway/internal',
        message: '电脑返回的会话窗口缺少 events 或 throughSeq。',
      );
    }
    final events = [
      for (final event in rawEvents)
        if (event is Json) event,
    ]..sort(_bySeq);
    final firstSeq = result['firstSeq'];
    return RemoteConversationWindow(
      events: events,
      throughSeq: throughSeq,
      firstSeq: firstSeq is int
          ? firstSeq
          : (events.isEmpty ? null : events.first['seq'] as int?),
      hasMore: result['hasMore'] == true,
    );
  }

  static List<Json>? _eventsOfRecords(Object? records) {
    if (records is! List) return null;
    final events = <Json>[];
    for (final record in records) {
      if (record is! Map) continue;
      final event = record['event'];
      if (event is Json && event['seq'] is int) events.add(event);
    }
    return events..sort(_bySeq);
  }

  static int _bySeq(Json left, Json right) =>
      (left['seq'] as int? ?? 0).compareTo(right['seq'] as int? ?? 0);

  // ------------------------------------------------------------ 线上字段投影

  static RemoteInteractionReply _replyOf(Object? result) => result is Json
      ? RemoteInteractionReply(
          accepted: result['accepted'] == true,
          requestStillPending: result['requestStillPending'] == true,
          message: _nonEmptyString(result['message']),
        )
      : const RemoteInteractionReply(
          accepted: false,
          requestStillPending: true,
          message: '电脑没有返回答复结果，请重试。',
        );

  /// 把一个 `interactions.list` / `interactions.changed` 的请求条目投影成页面
  /// 需要的字段；不认识的种类（例如协议里保留的 `plan`）不展示。
  static RemotePendingInteraction? _interactionOf(Object? raw) {
    if (raw is! Json) return null;
    final id = _nonEmptyString(raw['id']);
    final version = raw['version'];
    final sessionId = _nonEmptyString(raw['sessionId']);
    if (id == null || version is! int || sessionId == null) return null;
    final callId = _nonEmptyString(raw['callId']);
    switch (raw['kind']) {
      case 'approval':
        final toolCall = raw['toolCall'];
        return RemotePendingInteraction(
          id: id,
          version: version,
          sessionId: sessionId,
          kind: RemoteInteractionKind.approval,
          toolName: _nonEmptyString(raw['toolName']),
          summary: _toolSummary(toolCall is Json ? toolCall : null),
          reason: _nonEmptyString(raw['reason']),
          callId: callId,
        );
      case 'question':
        final questions = <RemoteQuestion>[];
        for (final item in raw['questions'] as List? ?? const <Object?>[]) {
          final question = _questionOf(item);
          if (question != null) questions.add(question);
        }
        return RemotePendingInteraction(
          id: id,
          version: version,
          sessionId: sessionId,
          kind: RemoteInteractionKind.question,
          callId: callId,
          questions: questions,
        );
      default:
        return null;
    }
  }

  static RemoteQuestion? _questionOf(Object? raw) {
    if (raw is! Json) return null;
    final id = _nonEmptyString(raw['id']);
    final text = raw['question'];
    if (id == null || text is! String || text.trim().isEmpty) return null;
    final options = <RemoteQuestionOption>[];
    for (final option in raw['options'] as List? ?? const <Object?>[]) {
      if (option is! Json) continue;
      final label = _nonEmptyString(option['label']);
      if (label == null) continue;
      options.add(
        RemoteQuestionOption(
          label: label,
          description: _nonEmptyString(option['description']),
        ),
      );
    }
    return RemoteQuestion(
      id: id,
      question: text,
      header: _nonEmptyString(raw['header']),
      detail: _nonEmptyString(raw['detail']),
      multiSelect: raw['multiSelect'] == true,
      options: options,
      intent: _intentOf(raw['intent']),
    );
  }

  /// 问题意图（`intent`）：计划审核等专属决策卡片的判据。
  ///
  /// 只在形状可用时保留成 JSON 对象；页面把它原样交给 `planReviewOf`，不在这里
  /// 解释 `approve` 或选项顺序。
  static Json? _intentOf(Object? value) {
    if (value is! Map) return null;
    final intent = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) return null;
      intent[key] = entry.value;
    }
    return intent.isEmpty ? null : intent;
  }

  /// 审批卡片的一行输入摘要：从 `toolCall.arguments`（JSON 文本）里取前几个
  /// 参数拼成单行；参数不是 JSON 对象时退回原文，没有参数时返回 null。
  static String? _toolSummary(Json? toolCall) {
    if (toolCall == null) return null;
    final arguments = toolCall['arguments'];
    if (arguments is! String || arguments.trim().isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(arguments);
    } on FormatException {
      return _oneLine(arguments);
    }
    if (decoded is! Map) return _oneLine(arguments);
    final parts = <String>[];
    for (final entry in decoded.entries) {
      if (parts.length >= 3) break;
      parts.add('${entry.key}: ${_shortArgument(entry.value)}');
    }
    if (parts.isEmpty) return null;
    return _oneLine(parts.join(' · '));
  }

  static String _shortArgument(Object? value) {
    final text = value is String ? value : jsonEncode(value);
    return text.length <= 80 ? text : '${text.substring(0, 77)}…';
  }

  static String _oneLine(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();

  static RemoteModelCatalog _catalogOf(Object? result) {
    if (result is! Json || result['groups'] is! List) {
      throw const RuntimeTransportFailure(
        code: 'gateway/internal',
        message: '电脑返回的模型目录格式不正确。',
      );
    }
    final groups = <RemoteModelGroup>[];
    for (final rawGroup in result['groups'] as List) {
      if (rawGroup is! Json) continue;
      final id = _nonEmptyString(rawGroup['id']);
      if (id == null) continue;
      final models = <RemoteModelInfo>[];
      for (final rawModel in rawGroup['models'] as List? ?? const <Object?>[]) {
        if (rawModel is! Json) continue;
        final modelId = _nonEmptyString(rawModel['id']);
        if (modelId == null) continue;
        models.add(
          RemoteModelInfo(
            id: modelId,
            name: _nonEmptyString(rawModel['name']) ?? modelId,
            reasoning: _reasoningOf(rawModel['reasoning']),
          ),
        );
      }
      groups.add(
        RemoteModelGroup(
          id: id,
          name: _nonEmptyString(rawGroup['name']) ?? id,
          models: models,
        ),
      );
    }
    final failures = <String>[];
    final failedProviders = <String>{};
    for (final rawFailure in result['failures'] as List? ?? const <Object?>[]) {
      if (rawFailure is! Json) continue;
      final id = _nonEmptyString(rawFailure['id']);
      if (id != null) failedProviders.add(id);
      final message = _nonEmptyString(rawFailure['message']);
      if (message == null) continue;
      final name = _nonEmptyString(rawFailure['name']);
      failures.add(name == null ? message : '$name：$message');
    }
    final routableProviders = <String>{};
    final rawRoutableProviders = result['routableProviders'];
    if (rawRoutableProviders is List) {
      for (final provider in rawRoutableProviders) {
        if (provider is String && provider.isNotEmpty) {
          routableProviders.add(provider);
        }
      }
    } else {
      // 旧宿主没有这个字段：目录只保留有模型的分组，所以非空分组的 id 就是可
      // 路由的服务商集合；空分组不能当成可用。
      for (final group in groups) {
        if (group.models.isNotEmpty) routableProviders.add(group.id);
      }
    }
    return RemoteModelCatalog(
      defaultChoice: _choiceOf(result['default']),
      groups: groups,
      failures: failures,
      failedProviders: failedProviders,
      routableProviders: routableProviders,
    );
  }

  /// 把 `session.command` 的返回值拍平成页面要用的结果。
  ///
  /// 正常形态是 `{commandId, result:{kind:'success'|'error', text?}}`；null 表示
  /// 电脑没有识别出这条指令（语法或名字不成立，什么都没执行）。也接受直接返回
  /// `{kind, text}` 的宿主，其它形态视为不完整应答，交给页面报错并保留草稿。
  static RemoteCommandResult _commandResultOf(Object? result) {
    if (result == null) return const RemoteCommandResult.unrecognized();
    if (result is! Json) {
      throw const RuntimeTransportFailure(
        code: 'gateway/internal',
        message: '电脑返回的指令结果格式不正确。',
      );
    }
    final commandId = _nonEmptyString(result['commandId']);
    final payload = result['result'] is Json
        ? result['result'] as Json
        : result;
    final kind = payload['kind'];
    final text = _nonEmptyString(payload['text']);
    if (kind == 'success') {
      return RemoteCommandResult.success(text: text, commandId: commandId);
    }
    if (kind == 'error') {
      return RemoteCommandResult(kind: RemoteCommandKind.error, text: text);
    }
    throw const RuntimeTransportFailure(
      code: 'gateway/internal',
      message: '电脑返回的指令结果格式不正确。',
    );
  }

  static RemoteReasoningInfo? _reasoningOf(Object? raw) {
    if (raw is! Json) return null;
    final efforts = <RemoteReasoningLevel>[];
    for (final effort in raw['efforts'] as List? ?? const <Object?>[]) {
      if (effort is! Json) continue;
      final id = _nonEmptyString(effort['id']);
      if (id == null) continue;
      efforts.add(
        RemoteReasoningLevel(id: id, name: _nonEmptyString(effort['name'])),
      );
    }
    final defaultEffort = _nonEmptyString(raw['defaultEffort']);
    if (efforts.isEmpty && defaultEffort == null) return null;
    return RemoteReasoningInfo(efforts: efforts, defaultEffort: defaultEffort);
  }

  static String? _nonEmptyString(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static RuntimeTransportFailure _failureOf(Object error) =>
      error is RuntimeTransportFailure
      ? error
      : RuntimeTransportFailure(code: 'gateway/internal', message: '$error');

  static bool _isDisconnected(RuntimeTransportFailure failure) =>
      failure.code == 'gateway/cancelled' ||
      failure.code == 'gateway/unavailable';

  static String _messageFor(RuntimeTransportFailure failure, String method) =>
      failure.code == 'unsupported-method'
      ? '这台电脑不支持「$method」。'
      : failure.message;
}

/// 「本次变更」页的真实数据源：把 PC 门面的 `workspaceChanges.*` 接成
/// [RemoteWorkspaceChangesSource]。
///
/// ## 快照定位
///
/// 宿主只为它发出的 `workspace/changes` 事件保留快照，所以正常路径是读会话窗口里
/// 最后一条 `workspace/changes` 事件、用它的 `seq` 调 `workspaceChanges.summary`。
/// 读窗口是权威来源：`resolveSnapshot` 每次都先用 `session.readWindow` 重新取一次，
/// 会话页缓存只在这条请求失败时兜底（例如刚发完消息、缓存还停在发送前）。
/// 窗口里没有这类事件时：本轮还在执行就回 [RemoteWorkspaceChangesPendingTurn]
/// （变更在轮次结束后才可读）；否则做至多
/// [remoteWorkspaceChangesFallbackScanSteps] 步的向下兜底扫描。非
/// `workspace/changes` 序号会得到 `workspace-changes/unavailable`，按正常降级
/// 继续下一步。
///
/// ## owner 与 requestId
///
/// owner 每个页面实例一个（`remote-<uuid v4>`，≤200 字符），同一页面的多次读取
/// 共用它；requestId 每次请求都新生成一个 UUID v4（宿主按正则校验，复用会被
/// 拒绝）。页面关闭或重新查找时先用 `workspaceChanges.cancel` 取消在途请求，
/// 从宿主侧释放并发名额；取消是尽力而为，失败不影响页面。
class RemoteWorkspaceChangesLiveSource implements RemoteWorkspaceChangesSource {
  /// 绑定连接、会话与窗口快照来源。
  ///
  /// [link] 是连接（读方法表与传输），[session] 是会话标识，[events] 给出当前
  /// 会话窗口事件（用于找 `workspace/changes` 事件），[latest] 给出查找起点；
  /// 后三者由远程会话数据源提供，本类只读。
  RemoteWorkspaceChangesLiveSource({
    required RemoteConversationConnection link,
    required String session,
    required List<Json> Function() events,
    required int Function() latest,
    Random? random,
  }) : _connection = link,
       _sessionId = session,
       _windowEvents = events,
       _latestSeq = latest,
       _random = random ?? _secureRandom,
       owner = 'remote-${remoteUuidV4(random: random)}';

  /// 这个页面实例的稳定 owner（≤200 字符）；同一页面的全部读取共用它。
  final String owner;

  final RemoteConversationConnection _connection;
  final String _sessionId;
  final List<Json> Function() _windowEvents;
  final int Function() _latestSeq;
  final Random _random;

  /// 在途请求的 requestId；取消后从集合里移除，重复取消是空操作。
  final Set<String> _inFlight = <String>{};

  /// 查找代次：页面重新查找后，旧的循环不再发请求、也不再返回结果。
  int _generation = 0;

  bool _disposed = false;

  @override
  Future<RemoteWorkspaceChangesResolution> resolveSnapshot({
    void Function(RemoteWorkspaceScanProgress progress)? onProgress,
  }) async {
    if (_disposed) return const RemoteWorkspaceChangesFailure('页面已关闭。');
    final generation = ++_generation;
    await cancelInFlight();
    // 以宿主的窗口为准重新读一次：会话页的缓存可能停在发送之前（本轮
    // `workspace/changes` 事件由 follow 增量补齐），而快照只按事件序号
    // 保留。读窗口失败时退回缓存，让「本轮未结束/没有变更」状态正常显示。
    var events = _windowEvents();
    var latest = _latestSeq();
    try {
      final result = await _request(remoteConversationReadMethod, {
        'sessionId': _sessionId,
      });
      if (_disposed || generation != _generation) {
        return const RemoteWorkspaceChangesFailure('读取已取消。');
      }
      final window = RemoteConversationLiveSource._windowOf(result);
      if (window.events.isNotEmpty) events = window.events;
      if (window.throughSeq > latest) latest = window.throughSeq;
    } on Object {
      // 窗口读不到时用会话页缓存继续：下面的状态机会给出可见原因。
    }
    // 宿主只为 `workspace/changes` 事件的序号保留快照，最后一条就是本轮答案；
    // 其它序号一律 unavailable，所以正常路径只读它一次，不做逐号扫描。
    int? announcement;
    for (final event in events.reversed) {
      if (event['type'] != 'workspace/changes') continue;
      final seq = event['seq'];
      if (seq is int && seq > 0) {
        announcement = seq;
        break;
      }
    }
    final candidates = <int>[];
    final seen = <int>{};
    void addCandidate(int seq) {
      if (seq <= 0 || candidates.length >= remoteWorkspaceChangesScanLimit) {
        return;
      }
      if (seen.add(seq)) candidates.add(seq);
    }

    if (announcement != null) addCandidate(announcement);
    if (candidates.isEmpty) {
      // 没有 workspace/changes 事件：这一轮可能还没结束，变更在轮次结束后才可读。
      if (_turnInProgress(events)) {
        return const RemoteWorkspaceChangesPendingTurn();
      }
      // 防御性兜底：窗口被截断或宿主行为变化时仍可能命中宿主的快照。
      // 只向前找几步，一次页面打开不会变成连续几十次请求。
      final firstFallback =
          latest - remoteWorkspaceChangesFallbackScanSteps + 1;
      for (var seq = latest; seq >= 1 && seq >= firstFallback; seq--) {
        addCandidate(seq);
      }
    }

    final limit = candidates.length;
    var scanned = 0;
    for (final seq in candidates) {
      if (_disposed || generation != _generation) {
        return const RemoteWorkspaceChangesFailure('读取已取消。');
      }
      onProgress?.call(
        RemoteWorkspaceScanProgress(
          attempt: scanned + 1,
          limit: limit,
          seq: seq,
        ),
      );
      final requestId = remoteUuidV4(random: _random);
      _inFlight.add(requestId);
      try {
        final raw = await _request(remoteWorkspaceChangesSummaryMethod, {
          'owner': owner,
          'requestId': requestId,
          'sessionId': _sessionId,
          'seq': seq,
        });
        scanned++;
        if (_disposed || generation != _generation) {
          return const RemoteWorkspaceChangesFailure('读取已取消。');
        }
        final envelope = _envelopeOf(raw);
        if (envelope.ok) {
          final summary = WorkspaceChangesSummary.parse(envelope.value);
          if (summary == null) {
            return const RemoteWorkspaceChangesFailure('电脑返回的变更摘要格式不正确。');
          }
          return RemoteWorkspaceChangesFound(seq: seq, summary: summary);
        }
        if (envelope.code == 'workspace-changes/unavailable') continue;
        return RemoteWorkspaceChangesFailure(
          _readFailureMessage(envelope.code, envelope.message),
        );
      } on RuntimeTransportFailure catch (failure) {
        scanned++;
        if (_disposed || generation != _generation) {
          return const RemoteWorkspaceChangesFailure('读取已取消。');
        }
        if (failure.code == 'workspace-changes/unavailable') continue;
        return RemoteWorkspaceChangesFailure(_transportFailureMessage(failure));
      } finally {
        _inFlight.remove(requestId);
      }
    }
    return RemoteWorkspaceChangesUnavailable(
      scanned: scanned,
      limit: limit,
      startSeq: latest,
      announced: announcement != null,
    );
  }

  @override
  Future<WorkspaceFileDiff> loadDiff(int seq, int index) async {
    if (_disposed) {
      throw const RuntimeTransportFailure(
        code: 'gateway/cancelled',
        message: '页面已关闭。',
      );
    }
    final requestId = remoteUuidV4(random: _random);
    _inFlight.add(requestId);
    try {
      final raw = await _request(remoteWorkspaceChangesDiffMethod, {
        'owner': owner,
        'requestId': requestId,
        'sessionId': _sessionId,
        'seq': seq,
        'index': index,
      });
      if (_disposed) {
        throw const RuntimeTransportFailure(
          code: 'gateway/cancelled',
          message: '页面已关闭。',
        );
      }
      final envelope = _envelopeOf(raw);
      final code = envelope.code ?? 'workspace-changes/read-failed';
      if (!envelope.ok) {
        throw RuntimeTransportFailure(
          code: code,
          message: _readFailureMessage(code, envelope.message),
        );
      }
      final diff = WorkspaceFileDiff.parse(envelope.value);
      if (diff == null) {
        throw const RuntimeTransportFailure(
          code: 'gateway/internal',
          message: '电脑返回的文件差异格式不正确。',
        );
      }
      return diff;
    } finally {
      _inFlight.remove(requestId);
    }
  }

  @override
  Future<void> cancelInFlight() async {
    final pending = _inFlight.toList();
    _inFlight.clear();
    if (pending.isEmpty) return;
    final transport = _connection.transport;
    if (transport == null) return;
    for (final requestId in pending) {
      try {
        await transport.request(remoteWorkspaceChangesCancelMethod, {
          'owner': owner,
          'requestId': requestId,
        });
      } on Object {
        // 取消是尽力而为：连接已断开或宿主已经收口时不再上报，页面本来也不展示
        // 这次读取的结果。
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    final pending = _inFlight.toList();
    _inFlight.clear();
    final transport = _connection.transport;
    if (transport == null) return;
    for (final requestId in pending) {
      unawaited(
        transport
            .request(remoteWorkspaceChangesCancelMethod, {
              'owner': owner,
              'requestId': requestId,
            })
            .then<void>((_) {}, onError: (Object _) {}),
      );
    }
  }

  Future<dynamic> _request(String method, Map<String, dynamic> params) {
    final transport = _connection.transport;
    if (transport == null) {
      return Future<dynamic>.error(
        const RuntimeTransportFailure(
          code: 'gateway/unavailable',
          message: '与电脑的连接已断开，正在重连…',
        ),
      );
    }
    return transport.request(method, params);
  }

  /// 把 `{ok, value}` / `{ok:false, error}` 信封拍平成页面要用的结果。
  static ({bool ok, Object? value, String? code, String? message}) _envelopeOf(
    Object? raw,
  ) {
    if (raw is Json) {
      if (raw['ok'] == true) {
        return (ok: true, value: raw['value'], code: null, message: null);
      }
      final error = raw['error'];
      if (error is Json) {
        final code = error['code'];
        final message = error['message'];
        return (
          ok: false,
          value: null,
          code: code is String && code.isNotEmpty ? code : 'gateway/internal',
          message: message is String && message.trim().isNotEmpty
              ? message.trim()
              : null,
        );
      }
    }
    return (ok: false, value: null, code: 'gateway/internal', message: null);
  }

  static String _readFailureMessage(String? code, String? message) {
    final mapped = switch (code) {
      'gateway/cancelled' => '读取已取消。',
      'gateway/unavailable' => '与电脑的连接已断开，请重新连接后再试。',
      'unsupported-method' => '这台电脑不支持查看本次变更。',
      'remote-access/denied' => '这台电脑拒绝读取本次变更。',
      'gateway/bad-request' => '读取变更的请求参数不正确。',
      'workspace-changes/timeout' => '电脑读取变更快照超时了，请重试。',
      'workspace-changes/busy' => '电脑上同时进行的变更读取太多，请稍后重试。',
      'workspace-changes/unavailable' => '这轮改动的内容已不可用。',
      'workspace-changes/read-failed' => '电脑没能读取这轮变更，请重试。',
      'workspace-changes/cleanup-timeout' => '电脑还在停止上一次读取，请稍后重试。',
      _ => null,
    };
    if (mapped != null) return mapped;
    final text = message?.trim();
    if (text != null && text.isNotEmpty) return text;
    return '电脑没能读取这次变更（${code ?? 'gateway/internal'}），请重试。';
  }

  static String _transportFailureMessage(RuntimeTransportFailure failure) =>
      switch (failure.code) {
        'gateway/cancelled' => '读取已取消。',
        'gateway/unavailable' => '与电脑的连接已断开，请重新连接后再试。',
        'unsupported-method' => '这台电脑不支持查看本次变更。',
        _ => failure.message,
      };

  /// 窗口里最后一轮是否还没结束：`turn/start` 之后没有对应的 `turn/end`。
  static bool _turnInProgress(List<Json> events) {
    var open = false;
    for (final event in events) {
      switch (event['type']) {
        case 'turn/start':
          open = true;
        case 'turn/end':
          open = false;
      }
    }
    return open;
  }
}
