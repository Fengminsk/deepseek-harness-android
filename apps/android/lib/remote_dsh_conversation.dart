// 远程 DSH 的会话页：头部（返回、标题与副标题、编辑与省略号胶囊）、消息区与
// 底部输入区。
//
// 页面只依赖 [RemoteConversationSource]：首屏由数据源用 `session.readWindow`
// 读回，发送走 `session.send`，增量与流式回复从数据源的更新流进来。消息用既有
// 内核的数据形态直接渲染：窗口事件交给 [ChatProjection]，正文与流式回复交给
// [ChatTimeline]（内部是 `ChatMessage` / `ChatContent`），本文件不复制一份对话
// 内核的投影或渲染逻辑，也不含任何样例消息。
//
// 待处理的审批与提问替代底部输入卡：审批卡显示原因、命令与「允许一次 / 拒绝」，
// 也可填写补充指令（先拒绝当前调用，再作为新消息发送）；提问卡片按
// `multiSelect` 渲染选项（可补自定义文字），每个问题都有答复后「提交」才可用。答复走数据源的
// [RemoteConversationSource.replyApproval] / [RemoteConversationSource.answerQuestion]，
// 页面不拼线上 `response` 字段。
//
// 输入区是一张悬浮输入卡（共享组件 `pocket_composer.dart`），三态由页面持有：
// 浏览时是一行缩小卡（加号、占位文案、盾牌与发送圆钮）；输入框获得焦点、键盘
// 弹起或草稿非空时向上展开成「输入区 + 工具条一行」；点工具条上的推理按钮后
// 输入区换成「当前模型 + 推理强度滑杆」面板，再点推理按钮或点聊天区收起。面板
// 档位来自 `session.modelCatalog` 里当前模型声明的强度，切换走既有
// `selectModel`；没有档位时只显示模型名。面板不依赖键盘 insets：用户按返回键
// 收起键盘时面板保持可见，输入态则在没有草稿时缩回浏览态、有草稿时保持展开；
// 缩小态点整张卡都会聚焦输入框并请求输入法显示。权限预设与当前模型的回显行
// 只属于展开的输入上下文：缩小态只留一行悬浮卡及其上方的会话读数，不显示它们。
//
// 模型入口在输入区：上方回显当前 `provider/model`，点按与推理面板第一行都打开
// 底部模型弹层（模型目录来自 `api.call` 的 `session.modelCatalog`），应用后数据源
// 推新的选择。发送因凭据类错误失败时，页面先尝试一次自动恢复：读电脑上的默认
// 模型（`settings.describe`），与当前路由不同就切过去并重发一次；成功或两次都
// 失败都在输入区上方留下常驻说明，自动恢复不了时保留一条直接指向模型选择的
// 可操作提示。
//
// 数据源把电脑模型目录的读取失败服务商（例如缺少 API Key）推给页面：当前路由的
// provider 命中时，发送前就有一条常驻提示说明发送会自动改用电脑默认模型，动作
// 直接打开模型选择。路由换到可用的服务商、目录刷新后不再命中，或一次发送成功
// 之后，提示不再出现；提示本身不参与发送，也不会阻塞输入。
//
// 输入以 `/` 开头时是电脑上的会话指令，不是消息：输入区上方说明这一行会在电脑上
// 执行，提交走 `session.command`，结果（成功 / 失败 / 电脑没有识别出这条指令）
// 作为常驻结果条展示。成功清空草稿，失败保留草稿可直接修改重试；以 `/` 开头的行
// 永远不会落到 `session.send`。输入不补全；「+」弹层则复用本地那套数据驱动菜单
// （`ComposerCommands` + `remote_commands.dart` 的远程调用面），目录来自电脑上的
// `commands.list`：文件、模型与计划模式在手机上就地处理，其它宿主指令作为
// `session.command` 执行，导出与技能本轮置灰并写明原因。
//
// 方案模式：输入区上方的 `ChatPlanDock` 由 `RemoteGoalPlanController`
// （`remote_goal_plan.dart`）驱动，状态读 `session.projections` 的 `values.plan`，
// 实时增量来自 `session.control` 的 `plan` 投影，写入口是 `session.command` 的
// `/plan` 与 `/plan off`。未连接时条不显示；状态读失败时给可重试说明；写失败
// 保留输入草稿并常驻提示（与本地同语义）。计划审核卡片来自既有 `interactions.*`
// 的提问对象：`intent.kind == 'plan-review'` 时复用 `planReviewOf` 与
// `planReviewPreview` 渲染标题/摘要，「批准计划」回 `intent.approve` 选项，
// 「请求修改」走 `interactions.dismiss`，计划原文可推入既有
// `ChatPlanDocumentPage` 单独阅读。
//
// 附件：本页持有一个 `AttachmentDrafts`，调用面来自数据源的
// `createAttachmentSurface()`（远程实现走 `wss` 门面 + 反向请求分页拉取字节）。
// 「+」弹层的「文件」项触发系统文件选择器，选中后立即在电脑上准备；输入区上方的
// `PocketAttachmentRail` 展示上传中 / 失败 / 重试 / 移除。发送与指令提交都带上
// 准备好的 `attachmentIds`，受理后才回收草稿，失败保留（与本地 `main.dart` 同序）。
//
// 头部省略号菜单提供「本次变更」「终端」与「归档会话」：前两者各自推入独立的全屏
// 目的地——[RemoteWorkspaceDiffPage] 的数据源由会话数据源按次创建并交给该页持有，
// [RemoteSessionTerminalPage] 复用调用方传入的那台电脑的连接面；「归档会话」确认后
// 写 `library.sessionArchive` 并带着可见结果返回首页。
//
// 权限预设：输入条的盾牌与输入区上方的当前预设回显打开真实预设列表
// （`RemotePermissionController`，目录来自 `permissionPresets.catalog`，当前值来自
// `session.projections` 的 `values.permissions`）；`danger-full-access` / `auto`
// 复用本地权限页的二次确认，切换写 `/permission <值>` 后重读投影。电脑没有启用
// 权限预设时入口置灰并写明原因；目录读取失败只在弹层内报错并可重试，不缓存成
// 永久不支持。一次性审批卡片（允许一次 / 拒绝）保持不变：预设只影响新请求，不会
// 自动通过已挂起的审批。
//
// 会话洞察：输入区上方是待办卡片（收起一行摘要「任务 + 各状态计数」，展开为清单，
// 展开状态由页面持有并在本次会话内保留）。独立的悬浮统计胶囊显示步数、缓存命中、
// 上下文占用；左右滑动收纳到屏幕边缘为上下文球，点球展开，点长条打开详情弹层。
// 两块读数都来自 [RemoteSessionInsights]：只有数据源推来新的洞察时才变化，页面不轮询。
//
// 连接阶段来自传入的数据源（它投影 `RemoteConnectionController.phase`）：
// 连接中 / 就绪 / 失败三态分别给出连接提示、正常会话与带 `lastError` 的失败条；
// 失败条上的「重新连接」重连同一台电脑，不新建连接。宿主不支持某个门面方法时
// （协议 §10.2）这里的模型入口、重命名、本次变更、终端与归档都按三态置灰并写明
// 原因，而不是让按钮静默失效。
//
// 外观沿用 App 的既有约定：颜色只从 Theme 取（含纯黑变体），玻璃开关看
// [LiquidGlassScope]，减少动态效果看 `MediaQuery.disableAnimations`，字号走
// [AppTextStyle]，两者都会跟随系统与 App 设置。

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

import 'approvals_draft.dart';
import 'attachment_surface.dart';
import 'attachments.dart';
import 'image_preview.dart';
import 'chat_messages.dart';
import 'chat_plan.dart';
import 'chat_projection.dart';
import 'composer_commands.dart';
import 'design/color.dart';
import 'design/popup.dart';
import 'design/typography.dart';
import 'model_reasoning.dart';
import 'pocket_composer.dart';
import 'remote_attachments.dart';
import 'remote_commands.dart';
import 'remote_connection.dart';
import 'remote_conversation_cache.dart';
import 'remote_conversation_live_source.dart';
import 'remote_conversation_source.dart';
import 'remote_dsh_widgets.dart';
import 'remote_goal_plan.dart';
import 'remote_permissions.dart';
import 'remote_session_insights.dart';
import 'remote_stats_bar.dart';
import 'remote_terminal_page.dart';
import 'remote_todo_card.dart';
import 'remote_workspace_diff_page.dart';
import 'runtime.dart';
import 'runtime_transport.dart';
import 'ui.dart';

/// 距列表底部多近仍算「在跟随最新内容」。
const double _followThreshold = 120;

/// 指令提示里回显输入的字符上限；超出截断，避免输入区被撑成多行。
const int _commandPreviewLength = 48;

/// 把宿主/传输原始错误转成用户可读中文，并移除 `session-...` 等内部标识。
///
/// 协议原始英文（如写句柄冲突）映射为固定中文；其余消息保留原文但截断。
/// debug 日志仍由调用方保留原始 message，本函数只用于可见文案。
String sanitizeRemoteUiMessage(String message, {int maxLength = 240}) {
  final raw = message.trim();
  if (raw.isEmpty) return '操作失败，请稍后重试。';
  final lower = raw.toLowerCase();
  if (lower.contains('already owned by an active write handle') ||
      lower.contains('session/write-conflict') ||
      lower.contains('session/already-owned') ||
      lower.contains('write handle')) {
    return '发送未成功，请稍后重试。';
  }
  if (lower.contains('unsupported-method')) {
    return '这台电脑暂不支持该操作。';
  }
  if (lower.contains('app stream limit reached')) {
    return '正在恢复消息同步…';
  }
  var text = raw
      .replaceAll(
        RegExp(r'''session\s*["'][^"']*["']''', caseSensitive: false),
        '',
      )
      .replaceAll(
        RegExp(r'session[-_][0-9a-fA-F-]{8,}', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .replaceFirst(RegExp(r'^[\s:：,，;；.\-]+'), '')
      .trim();
  if (text.isEmpty) return '操作失败，请稍后重试。';
  if (text.length > maxLength) text = '${text.substring(0, maxLength)}…';
  return text;
}

/// 有界时间线：只保留最近 [max] 条事件，返回裁剪后的列表（最旧事件被丢弃）。
///
/// 用于把长会话的内存占用固定住；页面在裁剪后仍保留「加载更早」入口。
List<Json> trimRemoteConversationEvents(List<Json> events, int max) {
  if (events.length <= max) return events;
  return events.sublist(events.length - max);
}

/// 识别旧版宿主的会话写句柄冲突。发送保持草稿，不弹悬浮提示。
String? remoteWriteHandleConflictMessage(String message) {
  if (!message.contains('already owned by an active write handle')) return null;
  return '发送未成功，请稍后重试。';
}

/// 从会话事件推导「电脑还在执行」。
///
/// remote-host 进程里没有 desktop 进程正在运行的 Agent 时，`session.status` /
/// `tasks.session.live` 都不会报 running；这时只能看日志窗口：
///
/// - 有 `turn/start` 没有对应 `turn/end`；或
/// - 最后一次 `turn/end` 之后仍有未结算的 `tool/call`（没有 `tool/result`）；或
/// - 同样的 open step（有 `step/start` 无 `step/end`）。
///
/// 明确 `turn/end`（含 interrupted/error）之后不再推导运行，交给 ChatTimeline
/// 按既有中断/失败语义展示。返回最近的未结算工具名用于状态条。
({bool running, String? toolName}) inferRemoteExecution(List<Json> events) {
  final openTurns = <int>{};
  final openSteps = <(int, int)>{};
  final calls = <String, (int, String?)>{}; // callId -> (seq, name)
  var lastTurnEndSeq = -1;
  for (final event in events) {
    final seq = event['seq'];
    final data = event['data'];
    if (seq is! int || data is! Map) continue;
    final turn = data['turn'];
    final step = data['step'];
    switch (event['type']) {
      case 'turn/start':
        if (turn is int) openTurns.add(turn);
      case 'turn/end':
        if (turn is int) {
          openTurns.remove(turn);
          openSteps.removeWhere((key) => key.$1 == turn);
        }
        lastTurnEndSeq = seq;
      case 'step/start':
        if (turn is int && step is int) openSteps.add((turn, step));
      case 'step/end':
        if (turn is int && step is int) openSteps.remove((turn, step));
      case 'tool/call':
        final callId = data['callId'];
        if (callId is String && callId.isNotEmpty) {
          calls[callId] = (
            seq,
            data['name'] is String ? data['name'] as String : null,
          );
        }
      case 'tool/result':
        final message = data['message'];
        final source = message is Map ? message['source'] : null;
        final callId = source is Map ? source['callId'] : null;
        if (callId is String) calls.remove(callId);
    }
  }
  final pendingCalls = <(int, String?)>[
    for (final call in calls.values)
      if (call.$1 > lastTurnEndSeq) call,
  ];
  final running =
      openTurns.isNotEmpty || openSteps.isNotEmpty || pendingCalls.isNotEmpty;
  String? toolName;
  if (pendingCalls.isNotEmpty) {
    pendingCalls.sort((left, right) => right.$1.compareTo(left.$1));
    toolName = pendingCalls.first.$2;
  }
  return (running: running, toolName: toolName);
}

/// `tasks.session` 里的一条排队消息（Agent Inbox）。
///
/// [target] 为 `next-turn` 时是当前回合结束后执行的排队消息，`next-step` 是插到
/// 下一步之前的插话；两者在输入卡上方的队列坞里用不同标签区分。
class RemoteQueuedMessage {
  const RemoteQueuedMessage({
    required this.itemId,
    required this.id,
    required this.target,
    required this.prompt,
    required this.status,
    required this.cancellable,
    required this.editable,
    required this.steerable,
  });

  /// 删除这条消息时传给 `tasks.removeQueued` 的标识。
  final String itemId;

  /// 宿主给的展示标识（`queued:<id>`）。
  final String id;

  /// `next-turn` 或 `next-step`。
  final String target;

  /// 消息文本预览；宿主没有给出时为空字符串。
  final String prompt;

  /// `queued` 或 `suspended`。
  final String status;

  /// 是否允许删除（宿主有活动 Agent 且这条消息可撤回）。
  final bool cancellable;

  /// 是否允许编辑（仅 live 且纯文本消息）。
  final bool editable;

  /// 是否允许插话发送（仅 live、纯文本且 Agent 正在运行）。
  final bool steerable;

  /// 是否因宿主恢复执行而处于 suspended 状态。
  bool get suspended => status == 'suspended';

  /// 是否是插到下一步之前的消息。
  bool get nextStep => target == 'next-step';
}

/// `tasks.session` 的工作状态与排队消息快照。
class RemoteSessionTasks {
  const RemoteSessionTasks({
    this.status = 'idle',
    this.queued = 0,
    this.blockingRequests = 0,
    this.pending = const <RemoteQueuedMessage>[],
  });

  /// `live.status`：running / waiting / queued / idle / failed。
  final String status;

  /// 队列里的消息条数（以 `live.queued` 为准，缺失时退回 `pending.length`）。
  final int queued;

  /// 正在阻塞 Agent 的请求数（审批/提问等）。
  final int blockingRequests;

  /// Agent Inbox 里的排队消息，按宿主给出的顺序。
  final List<RemoteQueuedMessage> pending;

  /// 从 `tasks.session` 的应答里解析；顶层不是对象时返回 null（按未读取处理）。
  ///
  /// 单条 pending 坏记录跳过；`itemId` 缺失的条目无法删除，但只要有 `id` 仍可
  /// 展示（`cancellable` 会按宿主值走，不会伪造删除能力）。
  static RemoteSessionTasks? parse(Object? raw) {
    if (raw is! Map) return null;
    var status = 'idle';
    var queued = 0;
    var blocking = 0;
    final live = raw['live'];
    if (live is Map) {
      final liveStatus = live['status'];
      if (liveStatus is String && liveStatus.isNotEmpty) status = liveStatus;
      final liveQueued = live['queued'];
      if (liveQueued is int && liveQueued >= 0) queued = liveQueued;
      final blockingRequests = live['blockingRequests'];
      if (blockingRequests is int && blockingRequests >= 0) {
        blocking = blockingRequests;
      }
    }
    final pending = <RemoteQueuedMessage>[];
    final rows = raw['pending'];
    if (rows is List) {
      for (final row in rows) {
        if (row is! Map) continue;
        final id = row['id'];
        final itemId = row['itemId'];
        final itemKey = itemId is String && itemId.isNotEmpty
            ? itemId
            : (id is String && id.startsWith('queued:')
                  ? id.substring('queued:'.length)
                  : null);
        if (itemKey == null || itemKey.isEmpty) continue;
        final target = row['target'] is String
            ? row['target'] as String
            : 'next-turn';
        pending.add(
          RemoteQueuedMessage(
            itemId: itemKey,
            id: id is String ? id : 'queued:$itemKey',
            target: target,
            prompt: row['prompt'] is String ? row['prompt'] as String : '',
            status: row['status'] is String
                ? row['status'] as String
                : 'queued',
            cancellable: row['cancellable'] == true,
            editable: row['editable'] == true,
            steerable: row['steerable'] == true,
          ),
        );
      }
    }
    return RemoteSessionTasks(
      status: status,
      queued: queued > 0 ? queued : pending.length,
      blockingRequests: blocking,
      pending: pending,
    );
  }

  /// 两份快照是否等价；用于轮询时跳过没有变化的 setState。
  bool sameAs(RemoteSessionTasks other) {
    if (status != other.status ||
        queued != other.queued ||
        blockingRequests != other.blockingRequests ||
        pending.length != other.pending.length) {
      return false;
    }
    for (var index = 0; index < pending.length; index++) {
      final left = pending[index];
      final right = other.pending[index];
      if (left.itemId != right.itemId ||
          left.target != right.target ||
          left.prompt != right.prompt ||
          left.status != right.status ||
          left.cancellable != right.cancellable ||
          left.editable != right.editable ||
          left.steerable != right.steerable) {
        return false;
      }
    }
    return true;
  }
}

/// 远程 DSH 的会话页。
///
/// [source] 由调用方创建并交给本页持有：页面在 [State.dispose] 里释放它。
/// [deviceName] 与 [projectName] 组成副标题「设备 · 项目」，[title] 是初始会话
/// 标题（页内重命名会同时写回电脑）。页面不自动请求输入框焦点，进入时键盘保持
/// 收起；输入框获得焦点后，输入区跟随系统键盘上移。
class RemoteDshConversationPage extends StatefulWidget {
  const RemoteDshConversationPage({
    super.key,
    required this.source,
    required this.deviceName,
    required this.projectName,
    required this.title,
    this.terminalConnection,
    this.deviceId,
    this.conversationCache,
    this.now,
  });

  /// 会话目的地标识的前缀。
  ///
  /// 每个会话是独立的全屏目的地，标识里带会话 id，因此同一会话在栈上只会有一层
  /// （见 [openDestination]）。
  static const String routeDestinationPrefix = 'remote-session:';

  /// 会话 [sessionId] 对应的目的地标识。
  static String destinationFor(String sessionId) =>
      '$routeDestinationPrefix$sessionId';

  /// 会话数据源；本页持有并负责释放。
  final RemoteConversationSource source;

  /// 目标设备的显示名，用于副标题、会话信息与输入区占位文案。
  final String deviceName;

  /// 会话所属项目的显示名，用于副标题与会话信息。
  final String projectName;

  /// 会话标题的初始值；打开后从会话标题投影与页内重命名更新。
  final String title;

  /// 那台电脑的终端连接面，「…」菜单的「终端」入口用它。
  ///
  /// 由打开会话的首页传入，与数据源共用同一条连接，不新建第二条连接；为 null 时
  /// （例如测试里单独构造本页）「终端」入口按「这台电脑不支持终端」置灰。
  final RemoteTerminalConnection? terminalConnection;

  /// 缓存用的电脑标识；为 null 时从实时数据源的连接里取（同
  /// `RemoteConnectionController.activeDevice`）。测试单独构造页面时可直接给。
  final String? deviceId;

  /// 会话本地缓存；为 null 时用 `dsh/runtime` 的默认通道。测试可注入假缓存。
  final RemoteConversationCache? conversationCache;

  /// 页面时钟；默认 `DateTime.now`。测试注入可推进的时钟验证推送优先窗口。
  final DateTime Function()? now;

  @override
  State<RemoteDshConversationPage> createState() =>
      _RemoteDshConversationPageState();
}

class _RemoteDshConversationPageState extends State<RemoteDshConversationPage>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _focus = FocusNode();

  /// 消息列表的滚动位置：进入会话后停在最新内容。
  final _scroll = ScrollController();
  bool _scrollToEndScheduled = false;

  /// 会话事件的投影与原始事件。两者一起交给 [ChatTimeline]。
  final _projection = ChatProjection();
  List<Json> _events = const [];
  ChatTimeline? _timeline;
  List<Json>? _timelineEvents;
  ChatLiveMessage? _timelineLive;
  bool? _timelineRunning;
  final Set<int> _seenSeqs = <int>{};

  ChatLiveMessage? _live;
  Timer? _liveFrameTimer;
  Json? _queuedLiveValue;

  /// 事件流最近一次给出的运行状态；null 表示还没收到过 `session.status`。
  ///
  /// 运行状态优先以事件流为准，避免轮询与事件互相抖动；进入一个已经在工作的
  /// 会话时通常收不到初始事件，此时由 `tasks.session` 的 `live.status` 补上。
  bool? _runningFromEvents;

  /// 事件流与轮询合并后的运行状态（[ChatTimeline] 用）。
  ///
  /// 权威来源优先：`session.status`（推送）与 `tasks.session.live`（轮询）。
  /// 日志推导只在两者都未知时兜底，且超过 [_inferredSilenceTimeout] 没有任何
  /// 新证据就自动降级，避免窗口截断导致「永久工作中」。
  bool get _running =>
      _runningFromEvents == true ||
      _sessionTasks?.status == 'running' ||
      _inferredRunningActive;

  /// 由窗口事件推导的运行态与最近未结算工具名。
  bool _inferredRunning = false;
  String? _inferredToolName;

  /// 日志推导的最近一次证据时间；静默超时后 [_inferredRunningActive] 为 false。
  DateTime? _lastInferredEvidenceAt;

  /// 日志推导的静默超时：20–30s 内没有新事件/状态就隐藏状态条并停止兜底轮询。
  static const Duration _inferredSilenceTimeout = Duration(seconds: 25);

  bool get _inferredRunningActive {
    if (!_inferredRunning) return false;
    final last = _lastInferredEvidenceAt;
    if (last == null) return false;
    return _now().difference(last) < _inferredSilenceTimeout;
  }

  /// 可见会话补偿拉取窗口的定时器（5s，仅推送静默时真正请求）。
  Timer? _inferredRefreshTimer;
  bool _inferredRefreshInFlight = false;

  /// `session.event` 合并刷新：事件先入队，最多每 [_eventBatchWindow] 重建一次；
  /// turn/end 等关键事件立即刷新。
  final List<Json> _pendingEvents = <Json>[];
  Timer? _eventFlushTimer;
  static const Duration _eventBatchWindow = Duration(milliseconds: 180);
  static const Set<String> _immediateEventTypes = <String>{
    'turn/end',
    'session/error',
  };

  /// 最近一次收到该会话实时推送（snapshot/event/live/status）的时间。
  ///
  /// 推送活跃时 inferred 轮询只保留定时器但不发请求；超过
  /// [_pushActiveWindow] 没有任何推送才做一次增量兜底。
  DateTime? _lastRemotePushAt;

  /// 推送活跃窗口：8s 内有推送就跳过 readNewer 兜底。
  static const Duration _pushActiveWindow = Duration(seconds: 8);

  /// 是否还有更早历史可加载（窗口 `hasMore`），以及当前是否在加载。
  bool _hasOlder = false;
  bool _loadingOlder = false;

  /// 时间线保留的事件上限；超出后丢弃最旧事件，仍可通过「加载更早」重新分页。
  /// 400–600 是内存与回看舒适度的折中，避免长会话把整段输出常驻在 UI 层。
  static const int _maxRetainedEvents = 500;

  bool _loading = true;
  bool _sending = false;
  bool _draftEmpty = true;
  String? _loadError;
  String? _status;
  Timer? _statusTimer;
  late String _title;
  StreamSubscription<RemoteConversationUpdate>? _updates;

  /// 会话本地缓存（点开先渲染，随后由实时窗口覆盖）与同步服务。
  late final RemoteConversationCache _conversationCache =
      widget.conversationCache ?? const RemoteConversationCache();

  /// 缓存 key 里的电脑标识；测试或只读数据源可能没有，此时不做本地缓存。
  String? _cacheDeviceId;

  /// 本地缓存读取尚未完成：只显示一个紧凑转圈，不渲染任何缓存来源说明。
  bool _cacheRestorePending = false;

  /// 统计条展开状态：默认展开；异步恢复用户偏好前先用默认值。
  bool _statsExpanded = true;
  bool _statsUserChanged = false;

  /// 缓存写回节的流；1s 节流，页面 dispose 时立即刷一次。
  Timer? _cacheWriteTimer;
  RemoteConversationWindow? _pendingCacheWindow;

  /// 实时窗口的日志切点（缓存写回用）。
  int _windowThroughSeq = 0;

  /// 轮询 `tasks.session` 的定时器；页面销毁或退后台时取消。
  Timer? _sessionTasksTimer;

  /// 是否允许继续安排下一次 `tasks.session` 轮询（退后台/不支持时关闭）。
  bool _sessionTasksPolling = false;

  /// 是否有一次 `tasks.session` 在途；防止轮询与手动刷新并发重入。
  bool _sessionTasksInFlight = false;

  /// 宿主明确不支持 `tasks.session`：隐藏状态条与队列坞，不报错。
  bool _sessionTasksUnsupported = false;

  /// 是否已经成功读到过一份 `tasks.session` 快照。
  ///
  /// 首次读取返回前不渲染面板，避免打开会话瞬间闪一个空状态条。
  bool _sessionTasksLoaded = false;

  /// 最近一次成功读取的任务快照；读取失败时保留上次数据，静默重试。
  RemoteSessionTasks? _sessionTasks;

  /// 队列坞是否展开（>1 条时默认收起，只用计数条）。
  bool _queueExpanded = false;

  /// 正在删除的排队消息 itemId；删除期间禁用那一行的删除按钮。
  String? _removingQueuedId;

  /// 正在编辑的排队消息 itemId 与它的行内输入控制器。
  String? _editingQueuedId;
  TextEditingController? _queuedEditController;

  /// 正在保存编辑/插话发送的排队消息 itemId；期间禁用该行操作。
  String? _queueBusyId;

  /// 应用是否在前台；退后台停止轮询，回前台立即刷新。
  bool _appActive = true;

  /// 当前会话的待处理审批/提问（数据源已按会话过滤）。
  List<RemotePendingInteraction> _interactions =
      const <RemotePendingInteraction>[];

  /// 正在提交答复的交互标识；提交期间该卡片的按钮禁用。
  String? _busyInteractionId;

  /// 每个交互最近一次的答复错误，提交成功或请求消失后清除。
  final Map<String, String> _interactionErrors = <String, String>{};

  /// 当前模型选择；null 表示窗口里还没有可推导的模型。
  RemoteModelChoice? _modelChoice;

  /// 发送因凭据类错误失败时的可操作提示；成功发送或换模型后清除。
  String? _credentialHint;

  /// 常驻的可见说明：自动切换模型后解释为什么换了路由，以及两次失败的原因。
  ///
  /// 与 [_credentialHint] 不同，它不随 3 秒状态条消失，只能由用户点「知道了」、
  /// 手动换模型或页面重建清除。
  String? _persistentNotice;

  /// 当前草稿是不是以 `/` 开头的会话指令；输入区据此显示「会在电脑上执行」的说明。
  bool _draftIsCommand = false;

  /// 最近一条会话指令结果与它的原文；成功、失败都常驻，直到下一条指令、成功
  /// 发送或用户点「知道了」。
  ({String line, RemoteCommandResult result})? _commandResult;

  /// 电脑模型目录里读取失败的服务商（`session.modelCatalog` 的 `failures[].id`）。
  ///
  /// 当前路由的 provider 命中时，发送前给出「会自动改用电脑默认模型」的提示。
  Set<String> _failedModelProviders = const <String>{};

  /// 会话洞察的最近一次读数：待办、会话统计、token 用量与上下文占用。
  ///
  /// 数据源在首屏、重连、手动重试（`reload`）与轮次边界 / 待办写入后重新读取，
  /// 用 [RemoteConversationInsights] 推送；本页只按整体替换持有状态，交给输入区
  /// 上方的待办卡片与下方的统计条渲染。null 表示这一周期没有可用读数。
  RemoteSessionInsights? _insights;

  /// 待办卡片是否展开。属于页面状态：窗口刷新、流式增量重建都不会收起，换到
  /// 别的会话时随新页面重置为收起。
  bool _todosExpanded = false;

  /// 已经用一次成功发送确认过的路由；同一条路由不再显示发送前提示。
  RemoteModelChoice? _routeConfirmed;

  /// 输入卡的当前状态：浏览时缩小、聚焦输入时展开、点推理按钮后显示强度面板。
  ///
  /// 状态由页面持有（[PocketComposer] 是受控组件）：没有焦点且没有草稿时是
  /// [PocketComposerMode.browse]；输入框获得焦点或草稿非空时是
  /// [PocketComposerMode.composing]（草稿非空时即使失焦也保持展开，只有纯浏览
  /// 才收缩）；点工具条上的推理按钮进入 [PocketComposerMode.picker]。
  PocketComposerMode _composerMode = PocketComposerMode.browse;

  /// 推理面板读取的模型目录；只在第一次打开面板时读一次，失败后可重试。
  ///
  /// 面板需要知道当前模型声明了哪些推理强度档位，档位与默认值都来自
  /// `session.modelCatalog`（与既有模型选择弹层同一个读取入口）。
  RemoteModelCatalog? _reasoningCatalog;
  bool _reasoningLoading = false;
  String? _reasoningError;

  /// 正在提交一次推理强度切换；期间滑杆不可点。
  bool _reasoningApplying = false;

  /// 上一次 metrics 事件里键盘是否真的可见。
  ///
  /// 只有 0→可见→0 这种真正的显隐变化才改输入卡状态：Android 在聚焦输入框时
  /// 会先派发若干次「键盘还不可见」的 metrics（动画中间帧、窗口大小抖动），把
  /// 它们当成「用户收起了键盘」会在聚焦后立刻缩回并解焦，键盘就再也起不来。
  bool _keyboardVisible = false;

  /// 是否仍然贴着最新内容。用户向上翻到离底部较远的位置后，键盘、更新都不再
  /// 把列表拽回底部；滚回底部附近时自动恢复跟随。
  bool _pinnedToEnd = true;
  bool _deferKeyboardScroll = false;
  Timer? _composerOpenFallback;

  /// 附件草稿的调用面（远程连接）与本页持有的草稿。
  ///
  /// 页面只认 [AttachmentCallSurface]：本地模式同一套草稿状态机配
  /// `RuntimeController`，远程模式配 `RemoteAttachmentSurface`（设计文档 §3.4.5）。
  /// 数据源不提供附件能力（旧实现）时为 null，页面不渲染附件入口。
  AttachmentCallSurface? _attachmentSurface;
  AttachmentDrafts? _drafts;

  /// 计划模式的状态与写入口；未连接时条不显示（见 `remote_goal_plan.dart`）。
  late final RemoteGoalPlanController _goalPlan;

  /// 权限预设的能力三态、当前值与目录；盾牌与预设弹层由它驱动。
  late final RemotePermissionController _permissions;

  RemoteConversationSource get _source => widget.source;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _title = widget.title.trim().isEmpty ? '远程会话' : widget.title.trim();
    _updates = _source.updates.listen(_onUpdate);
    _source.addListener(_onSourceChanged);
    _focus.addListener(_onFocusChanged);
    final surface = _source.createAttachmentSurface();
    _attachmentSurface = surface;
    if (surface != null) {
      _drafts = AttachmentDrafts(surface)..addListener(_onDraftsChanged);
    }
    // 计划模式先订阅控制流、再读首屏投影；未连接时它保持静默（条不显示）。
    _goalPlan = RemoteGoalPlanController(source: _source);
    unawaited(_goalPlan.start());
    // 权限预设：探测宿主能力并读一次当前值；未连接时保持「正在连接电脑…」。
    _permissions = RemotePermissionController(source: _source);
    _permissions.addListener(_onPermissionsChanged);
    unawaited(_permissions.start());
    // 更新流先订阅、再开始读首屏：首屏快照不会落在订阅建立之前。
    _cacheDeviceId = _resolveCacheDeviceId();
    if (_cacheDeviceId != null) {
      _cacheRestorePending = true;
      unawaited(_restoreConversationCache());
    }
    unawaited(_source.start());
    if (_source.phase == RemoteConnectionPhase.ready) {
      _startSessionTasksPolling();
      _startInferredRefresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focus.removeListener(_onFocusChanged);
    _statusTimer?.cancel();
    _liveFrameTimer?.cancel();
    _composerOpenFallback?.cancel();
    _sessionTasksTimer?.cancel();
    _sessionTasksTimer = null;
    _sessionTasksPolling = false;
    _eventFlushTimer?.cancel();
    _eventFlushTimer = null;
    _inferredRefreshTimer?.cancel();
    _inferredRefreshTimer = null;
    _cacheWriteTimer?.cancel();
    _cacheWriteTimer = null;
    _queuedEditController?.dispose();
    _queuedEditController = null;
    // 页面销毁时尽力把最后一次窗口写回缓存；不 await，避免阻塞路由退出。
    if (_pendingCacheWindow != null || _events.isNotEmpty) {
      unawaited(_flushConversationCache());
    }
    final updates = _updates;
    _updates = null;
    if (updates != null) unawaited(updates.cancel());
    _source.removeListener(_onSourceChanged);
    final drafts = _drafts;
    _drafts = null;
    if (drafts != null) {
      // 草稿先释放：它会在关闭前把本页选中的副本逐个 release 给宿主。
      drafts.removeListener(_onDraftsChanged);
      drafts.dispose();
    }
    // 数据源由本页持有：释放它会取消 follow 观察并显式 api.unsubscribe。
    _goalPlan.dispose();
    _permissions.removeListener(_onPermissionsChanged);
    _permissions.dispose();
    _source.dispose();
    _attachmentSurface?.dispose();
    _scroll.dispose();
    _focus.dispose();
    _input.dispose();
    super.dispose();
  }

  /// 退后台停止 `tasks.session` 轮询，回前台立即刷新并恢复周期读取。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (_appActive == active) return;
    _appActive = active;
    if (!active) {
      _sessionTasksTimer?.cancel();
      _sessionTasksTimer = null;
      _inferredRefreshTimer?.cancel();
      _inferredRefreshTimer = null;
      return;
    }
    _startSessionTasksPolling();
    _startInferredRefresh();
  }

  @override
  void didChangeMetrics() {
    if (_focus.hasFocus || _keyboardVisible) _deferKeyboardScroll = true;
    // 键盘收起（例如按返回键）时输入框不会自动失焦：下一帧 MediaQuery 更新完
    // 再看一次键盘是否还在，决定缩小回浏览态还是保持展开。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncComposerWithKeyboard();
    });
  }

  /// 键盘显隐后同步输入卡状态。
  ///
  /// 只处理**真正的显隐变化**：连续 metrics 事件里 insets 一直为 0 的抖动不改
  /// 状态（聚焦时 Android 会先派发这种事件，误判会让卡片刚展开就缩回并解焦）。
  /// 键盘真正收起时，推理面板保持可见（用户可能只是收起键盘还想调强度，点聊天
  /// 区或表盘再退出）；输入态按草稿决定：有草稿保持展开，纯浏览缩回缩小态。
  void _syncComposerWithKeyboard() {
    if (!mounted) return;
    final visible = View.of(context).viewInsets.bottom > 0;
    final wasVisible = _keyboardVisible;
    _keyboardVisible = visible;
    if (visible == wasVisible) return;
    if (visible) {
      // Wait for the last IME metrics event and the scroll correction before
      // growing the card. Its height otherwise changes during the keyboard move.
      _composerOpenFallback?.cancel();
      _composerOpenFallback = null;
      return;
    }
    if (_composerMode == PocketComposerMode.picker) return;
    if (_input.text.trim().isNotEmpty) return;
    setState(() => _composerMode = PocketComposerMode.browse);
    // 故意不在此处解焦：真机上「键盘闪现后又隐藏」的抖动不应把焦点也丢掉；
    // 缩小态点卡片会再次 requestFocus + TextInput.show，键盘可立刻回来。
  }

  /// 把焦点交给输入框，并显式请求一次输入法显示。
  ///
  /// 真机上出现过「卡片展开了但键盘没起来」：输入框已经聚焦、IME 却被系统藏起
  /// 时，再点一次输入框不会自动重新显示。focus 之后在下一帧补一次
  /// `TextInput.show`（没有活动输入连接时是空操作），让点按一定能进入输入。
  void _requestInputFocus() {
    if (!_focus.hasFocus) _focus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focus.hasFocus) return;
      unawaited(_showInput());
    });
  }

  Future<void> _showInput() async {
    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    } on Object {
      // 没有活动输入连接（或测试环境没有通道）时忽略：展开与焦点不依赖它。
    }
  }

  // ------------------------------------------------------------ 数据源

  void _onSourceChanged() {
    if (!mounted) return;
    setState(() {
      // 首屏还在读时连接就进了终止态：读取不会再成功，把失败原因交给正文显示，
      // 不要把加载指示永远挂在那里。
      if (_loading && _source.phase == RemoteConnectionPhase.failed) {
        _loading = false;
        _loadError = sanitizeRemoteUiMessage(
          _source.lastError ?? '没能连接到这台电脑，请回到首页重新连接。',
        );
      }
    });
    if (_source.phase == RemoteConnectionPhase.ready) {
      _startSessionTasksPolling();
      _startInferredRefresh();
    } else {
      _stopSessionTasksPolling();
      _stopInferredRefresh();
    }
  }

  /// 缓存 key 的电脑标识：显式参数优先，其次实时数据源的活动设备。
  String? _resolveCacheDeviceId() {
    final explicit = widget.deviceId?.trim() ?? '';
    if (explicit.isNotEmpty) return explicit;
    final source = widget.source;
    if (source is RemoteConversationLiveSource) {
      final connection = source.connection;
      if (connection is RemoteControllerConnection) {
        return connection.controller.activeDevice?.id;
      }
    }
    return null;
  }

  /// 读取本地缓存并先渲染时间线；实时快照随后覆盖，断线时仍可阅读。
  Future<void> _restoreConversationCache() async {
    final deviceId = _cacheDeviceId;
    if (deviceId == null) return;
    RemoteConversationCacheEntry? cached;
    bool? expanded;
    try {
      final state = await _conversationCache.readState(
        deviceId,
        _source.sessionId,
      );
      cached = state.entry;
      expanded = state.statsExpanded;
    } on Object {
      cached = null;
    }
    if (!mounted) return;
    if (cached == null || cached.window.events.isEmpty) {
      if (_cacheRestorePending) {
        setState(() {
          _cacheRestorePending = false;
          if (expanded != null && !_statsUserChanged) _statsExpanded = expanded;
        });
      }
      return;
    }
    if (_events.isNotEmpty) {
      // 实时快照已经先到：缓存不再覆盖页面，只用于后续断线兜底。
      setState(() {
        _cacheRestorePending = false;
        if (expanded != null && !_statsUserChanged) _statsExpanded = expanded;
      });
      return;
    }
    setState(() {
      _cacheRestorePending = false;
      if (expanded != null && !_statsUserChanged) _statsExpanded = expanded;
      _loading = false;
      _events = List<Json>.of(cached!.window.events);
      _seenSeqs
        ..clear()
        ..addAll([
          for (final event in _events)
            if (event['seq'] case final int seq) seq,
        ]);
      _projection.reconcile(_events);
      _windowThroughSeq = cached.window.throughSeq;
      final cachedTitle = cached.title.trim();
      // 列表标题来自电脑的新目录；缓存标题可能是更早的「未命名会话」。
      if (cachedTitle.isNotEmpty &&
          (widget.title.trim().isEmpty || widget.title.trim() == '未命名会话') &&
          _title ==
              (widget.title.trim().isEmpty ? '远程会话' : widget.title.trim())) {
        _title = cachedTitle;
      }
    });
    _scheduleScrollToEnd();
    _recomputeInferredRunning();
  }

  /// 用户切换统计条展开状态：立即生效并异步持久化（按设备+会话隔离）。
  void _onStatsExpandedChanged(bool expanded) {
    if (_statsExpanded == expanded) return;
    setState(() {
      _statsExpanded = expanded;
      _statsUserChanged = true;
    });
    final deviceId = _cacheDeviceId;
    if (deviceId == null) return;
    unawaited(
      _conversationCache.saveStatsExpanded(
        deviceId: deviceId,
        sessionId: _source.sessionId,
        expanded: expanded,
      ),
    );
  }

  /// 收到新快照/事件后节流写回缓存；页面 dispose 时再立即刷一次。
  void _scheduleConversationCacheWrite() {
    if (_cacheDeviceId == null || _events.isEmpty) return;
    _pendingCacheWindow = RemoteConversationWindow(
      events: List<Json>.of(_events),
      throughSeq: _windowThroughSeq > 0
          ? _windowThroughSeq
          : (_events.last['seq'] as int? ?? 0),
      firstSeq: _events.first['seq'] as int?,
      hasMore: _hasOlder,
    );
    _cacheWriteTimer?.cancel();
    _cacheWriteTimer = Timer(const Duration(seconds: 1), () {
      unawaited(_flushConversationCache());
    });
  }

  Future<void> _flushConversationCache() async {
    final window = _pendingCacheWindow;
    final deviceId = _cacheDeviceId;
    _pendingCacheWindow = null;
    if (window == null || deviceId == null || window.events.isEmpty) return;
    await _conversationCache.save(
      deviceId: deviceId,
      sessionId: _source.sessionId,
      window: window,
      title: _title,
    );
  }

  // ------------------------------------------------------------ 工作状态与队列

  /// 启动（或补一次）`tasks.session` 轮询。
  ///
  /// 只在页面 mounted、应用前台、连接 ready 时运行；发送消息、收到运行状态变化
  /// 与回到前台都调用它补一次即时刷新。轮询是单次定时器：运行中 3s、空闲 6s。
  void _startSessionTasksPolling() {
    if (!mounted || !_appActive) return;
    if (_source.phase != RemoteConnectionPhase.ready) return;
    _sessionTasksPolling = true;
    unawaited(_refreshSessionTasks());
  }

  void _stopSessionTasksPolling() {
    _sessionTasksPolling = false;
    _sessionTasksTimer?.cancel();
    _sessionTasksTimer = null;
  }

  /// 一次 `tasks.session` 完成后按当前运行态安排下一次（运行 3s / 空闲 6s）。
  void _scheduleNextSessionTasksPoll() {
    _sessionTasksTimer?.cancel();
    _sessionTasksTimer = null;
    if (!_sessionTasksPolling || !mounted || !_appActive) return;
    if (_source.phase != RemoteConnectionPhase.ready) return;
    final seconds = _running ? 3 : 6;
    _sessionTasksTimer = Timer(Duration(seconds: seconds), () {
      _sessionTasksTimer = null;
      unawaited(_refreshSessionTasks());
    });
  }

  /// 日志推导只作兜底：权威 running/idle 已知时不再推导。
  void _recomputeInferredRunning() {
    final authorityRunning =
        _runningFromEvents == true || _sessionTasks?.status == 'running';
    final tasksStatus = _sessionTasks?.status;
    final authorityIdle =
        _runningFromEvents == false ||
        (_sessionTasksLoaded &&
            _sessionTasks != null &&
            tasksStatus != null &&
            tasksStatus != 'running' &&
            tasksStatus != 'unknown');
    if (authorityRunning || authorityIdle) {
      _clearInferredRunning();
      return;
    }
    final inferred = inferRemoteExecution(_events);
    final stale =
        inferred.running &&
        (_lastInferredEvidenceAt == null ||
            _now().difference(_lastInferredEvidenceAt!) >=
                _inferredSilenceTimeout);
    final nextRunning = inferred.running && !stale;
    final nextToolName = nextRunning ? inferred.toolName : null;
    final changed =
        nextRunning != _inferredRunning || nextToolName != _inferredToolName;
    if (changed && mounted) {
      setState(() {
        _inferredRunning = nextRunning;
        _inferredToolName = nextToolName;
      });
    }
    final needsRefresh =
        _appActive && _source.phase == RemoteConnectionPhase.ready;
    if (needsRefresh) {
      _startInferredRefresh();
    } else {
      _stopInferredRefresh();
    }
  }

  /// 清掉日志推导状态；权威来源给出明确 idle 或静默超时时调用。
  void _clearInferredRunning() {
    final changed = _inferredRunning || _inferredToolName != null;
    if (changed) {
      if (mounted) {
        setState(() {
          _inferredRunning = false;
          _inferredToolName = null;
        });
      } else {
        _inferredRunning = false;
        _inferredToolName = null;
      }
    }
  }

  /// 5s 兜底拉取：会话可见且推送静默时增量对账，含漏掉的 turn/end。
  void _startInferredRefresh() {
    if (!mounted || !_appActive) return;
    if (_source.phase != RemoteConnectionPhase.ready) return;
    if (_inferredRefreshTimer != null) return;
    _inferredRefreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_pollInferredWindow()),
    );
  }

  void _stopInferredRefresh() {
    _inferredRefreshTimer?.cancel();
    _inferredRefreshTimer = null;
  }

  /// 读一次窗口并合并；失败静默保留上次内容，不打断会话。
  Future<void> _pollInferredWindow() async {
    if (!mounted ||
        !_appActive ||
        _inferredRefreshInFlight ||
        _source.phase != RemoteConnectionPhase.ready) {
      return;
    }
    // 日志推导静默超过 25s：隐藏状态条；下一轮继续对账，防止漏掉最终事件。
    if (_inferredRunning && !_inferredRunningActive) {
      _clearInferredRunning();
      return;
    }
    // 推送优先：8s 内收到过该会话的任何实时推送就跳过本次兜底。
    final now = _now();
    final lastPush = _lastRemotePushAt;
    if (lastPush != null && now.difference(lastPush) < _pushActiveWindow) {
      return;
    }
    _inferredRefreshInFlight = true;
    try {
      final newer = await _source.readNewer(_windowThroughSeq);
      if (newer == null) {
        // 不支持增量读的数据源退回整窗 reload（测试替身/旧宿主）。
        await _source.reload();
        return;
      }
      await _mergeNewer(newer);
    } on Object {
      // 补偿刷新失败：保留时间线，下一轮再试；错误不显示给用户。
    } finally {
      _inferredRefreshInFlight = false;
    }
  }

  /// 页面时钟（测试可注入）。
  DateTime _now() => widget.now?.call() ?? DateTime.now();

  /// 记录一次实时推送，重置 inferred 轮询的兜底窗口与推导证据时间。
  void _noteRemotePush() {
    final now = _now();
    _lastRemotePushAt = now;
    _lastInferredEvidenceAt = now;
  }

  /// 合并刷新：把一批 `session.event` 一次性并入时间线，避免每个事件都重建。
  void _flushPendingEvents() {
    _eventFlushTimer?.cancel();
    _eventFlushTimer = null;
    if (!mounted || _pendingEvents.isEmpty) return;
    final batch = List<Json>.of(_pendingEvents);
    _pendingEvents.clear();
    setState(() {
      _events = [..._events, ...batch]..sort(_bySeq);
      _windowThroughSeq = _events.last['seq'] as int? ?? _windowThroughSeq;
      _projection.reconcile(_events);
      _trimRetainedEvents();
    });
    _recomputeInferredRunning();
    _scheduleConversationCacheWrite();
    _scheduleScrollToEnd();
  }

  /// 合并一次增量读到的较新窗口：按 seq 去重升序，只有真正新增才重建。
  Future<void> _mergeNewer(RemoteConversationWindow window) async {
    if (!mounted) return;
    if (window.resetRequired) {
      // 增量缺口无法桥接：整窗首屏重读一次，仍只取最新一页。
      await _source.reload();
      return;
    }
    if (window.events.isEmpty) return;
    final added = <Json>[];
    for (final event in window.events) {
      final seq = event['seq'];
      if (seq is! int || !_seenSeqs.add(seq)) continue;
      added.add(event);
    }
    if (added.isEmpty) return;
    _lastInferredEvidenceAt = _now();
    setState(() {
      _events = [..._events, ...added]..sort(_bySeq);
      // 增量窗口可能因数量/字节预算截断；只推进到实际收到的最后一条。
      final receivedSeq = added.last['seq'];
      if (receivedSeq is int && receivedSeq > _windowThroughSeq) {
        _windowThroughSeq = receivedSeq;
      }
      _projection.reconcile(_events);
      _trimRetainedEvents();
    });
    _scheduleConversationCacheWrite();
    _scheduleScrollToEnd();
    _recomputeInferredRunning();
  }

  /// 发送成功/事件到达后主动补一次增量；失败静默，下一轮轮询或事件会补上。
  Future<void> _pullNewer() async {
    if (!mounted || _source.phase != RemoteConnectionPhase.ready) return;
    try {
      final newer = await _source.readNewer(_windowThroughSeq);
      if (newer != null) await _mergeNewer(newer);
    } on Object {
      // 增量补拉失败不打断发送，现有事件流仍会送达后续事件。
    }
  }

  /// 加载更早一页；前插时保持当前阅读位置，不跳到底部。
  Future<void> _loadOlder() async {
    if (!mounted || _loadingOlder || !_hasOlder || _events.isEmpty) return;
    final firstSeq = _events.first['seq'];
    if (firstSeq is! int) return;
    final hadScroll = _scroll.hasClients;
    final previousPixels = hadScroll ? _scroll.position.pixels : 0.0;
    final previousMax = hadScroll ? _scroll.position.maxScrollExtent : 0.0;
    setState(() => _loadingOlder = true);
    try {
      final older = await _source.readOlder(
        beforeSeq: firstSeq,
        throughSeq: _windowThroughSeq,
      );
      if (!mounted) return;
      if (older == null) {
        setState(() => _hasOlder = false);
        return;
      }
      final added = <Json>[];
      for (final event in older.events) {
        final seq = event['seq'];
        if (seq is! int || _seenSeqs.add(seq)) added.add(event);
      }
      if (added.isEmpty) {
        setState(() => _hasOlder = older.hasMore);
        return;
      }
      setState(() {
        _events = [...added, ..._events]..sort(_bySeq);
        _hasOlder = older.hasMore;
        _projection.reconcile(_events);
        _trimRetainedEvents();
      });
      if (hadScroll) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients) return;
          final nextMax = _scroll.position.maxScrollExtent;
          final target = (previousPixels + (nextMax - previousMax)).clamp(
            0.0,
            nextMax,
          );
          _scroll.jumpTo(target);
        });
      }
      _scheduleConversationCacheWrite();
    } on RuntimeTransportFailure catch (failure) {
      if (mounted) _showStatus('加载更早消息失败：${failure.message}');
    } on Object catch (error) {
      if (mounted) _showStatus('加载更早消息失败：$error');
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  /// 有界内存：只保留最近 [_maxRetainedEvents] 条事件，丢弃最旧并保持可再分页。
  void _trimRetainedEvents() {
    if (_events.length <= _maxRetainedEvents) return;
    _events = trimRemoteConversationEvents(_events, _maxRetainedEvents);
    final oldest = _events.first['seq'];
    if (oldest is int) _seenSeqs.removeWhere((seq) => seq < oldest);
    _hasOlder = true;
  }

  /// 读一次 `tasks.session` 快照。
  ///
  /// 失败静默保留上次读数（下一轮再试）；宿主明确不支持时隐藏面板，不打断会话。
  Future<void> _refreshSessionTasks() async {
    if (!mounted || _sessionTasksInFlight || !_appActive) return;
    if (_source.phase != RemoteConnectionPhase.ready) return;
    if (!_source.supports(remoteTasksSessionMethod)) {
      _sessionTasksPolling = false;
      _sessionTasksTimer?.cancel();
      _sessionTasksTimer = null;
      if (!_sessionTasksUnsupported) {
        setState(() => _sessionTasksUnsupported = true);
      }
      return;
    }
    _sessionTasksInFlight = true;
    try {
      final raw = await _source
          .request(remoteTasksSessionMethod, {'sessionId': _source.sessionId})
          .timeout(const Duration(seconds: 5));
      final parsed = RemoteSessionTasks.parse(raw);
      if (!mounted || parsed == null) return;
      final previous = _sessionTasks;
      final changed =
          !_sessionTasksLoaded ||
          _sessionTasksUnsupported ||
          previous == null ||
          !previous.sameAs(parsed);
      if (!changed) return;
      setState(() {
        _sessionTasks = parsed;
        _sessionTasksLoaded = true;
        _sessionTasksUnsupported = false;
      });
      // live 状态已知 running 时停止补偿轮询；反之继续。
      _recomputeInferredRunning();
    } on RuntimeTransportFailure catch (failure) {
      if (!mounted) return;
      if (failure.code == 'unsupported-method') {
        setState(() => _sessionTasksUnsupported = true);
      }
      // 其它失败（断线、瞬时错误）静默：保留上次读数，下一轮再试。
    } on Object {
      // 解析之外的意外失败同样静默，不打断会话。
    } finally {
      _sessionTasksInFlight = false;
      _scheduleNextSessionTasksPoll();
    }
  }

  /// 删除一条可取消的排队消息；成功后立即刷新队列。
  Future<void> _removeQueuedMessage(RemoteQueuedMessage message) async {
    if (_removingQueuedId != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('删除排队消息'),
        content: Text(message.nextStep ? '删除后这条插话不再发送。' : '删除后这条排队消息不再执行。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('remote-queue-remove-confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _removingQueuedId = message.itemId);
    try {
      await _source.request(remoteTasksRemoveQueuedMethod, {
        'sessionId': _source.sessionId,
        'itemId': message.itemId,
      });
      if (!mounted) return;
      await _refreshSessionTasks();
      if (mounted) _showStatus('已删除排队消息');
    } on RuntimeTransportFailure catch (failure) {
      if (mounted) _showStatus('删除排队消息失败：${failure.message}');
    } on Object catch (error) {
      if (mounted) _showStatus('删除排队消息失败：$error');
    } finally {
      if (mounted) setState(() => _removingQueuedId = null);
    }
  }

  /// 进入一条排队消息的行内编辑；不可编辑的行不响应。
  void _beginQueuedEdit(RemoteQueuedMessage message) {
    if (!message.editable || _queueBusyId != null) return;
    _queuedEditController?.dispose();
    final controller = TextEditingController(text: message.prompt);
    setState(() {
      _editingQueuedId = message.itemId;
      _queuedEditController = controller;
    });
  }

  /// 退出行内编辑并丢弃未保存的文本。
  void _cancelQueuedEdit() {
    final controller = _queuedEditController;
    if (mounted) {
      setState(() {
        _editingQueuedId = null;
        _queuedEditController = null;
      });
    } else {
      _editingQueuedId = null;
      _queuedEditController = null;
    }
    controller?.dispose();
  }

  /// 保存排队消息的新文本；失败保留编辑态与输入内容。
  Future<void> _saveQueuedEdit(RemoteQueuedMessage message) async {
    final controller = _queuedEditController;
    if (controller == null || _queueBusyId != null) return;
    final text = controller.text.trim();
    if (text.isEmpty) {
      _showStatus('排队消息内容不能为空');
      return;
    }
    setState(() => _queueBusyId = message.itemId);
    try {
      await _source.request(remoteTasksEditQueuedMethod, {
        'sessionId': _source.sessionId,
        'itemId': message.itemId,
        'text': text,
      });
      if (!mounted) return;
      _cancelQueuedEdit();
      await _refreshSessionTasks();
      if (mounted) _showStatus('已保存排队消息');
    } on RuntimeTransportFailure catch (failure) {
      if (mounted) _showStatus('保存排队消息失败：${failure.message}');
    } on Object catch (error) {
      if (mounted) _showStatus('保存排队消息失败：$error');
    } finally {
      if (mounted) setState(() => _queueBusyId = null);
    }
  }

  /// 把一条可插话的排队消息立即送进运行中的回合；失败给出可读原因。
  Future<void> _steerQueuedMessage(RemoteQueuedMessage message) async {
    if (!message.steerable || _queueBusyId != null) return;
    setState(() => _queueBusyId = message.itemId);
    try {
      await _source.request(remoteTasksSteerQueuedMethod, {
        'sessionId': _source.sessionId,
        'itemId': message.itemId,
      });
      if (!mounted) return;
      await _refreshSessionTasks();
      if (mounted) _showStatus('已插话发送');
    } on RuntimeTransportFailure catch (failure) {
      if (mounted) _showStatus('插话发送失败：${failure.message}');
    } on Object catch (error) {
      if (mounted) _showStatus('插话发送失败：$error');
    } finally {
      if (mounted) setState(() => _queueBusyId = null);
    }
  }

  /// 附件草稿状态（上传中 / 失败 / 移除）变化：发送按钮要看草稿才能决定是否出现。
  void _onDraftsChanged() {
    if (mounted) setState(() {});
  }

  /// 权限预设状态变化（能力探测、目录、当前值）：输入区回显与弹层跟随刷新。
  void _onPermissionsChanged() {
    if (mounted) setState(() {});
  }

  /// 本会话是否已有附件草稿（含失败项）；上传失败时发送按钮仍然可见，发送会给出
  /// 「附件尚未准备完成」的说明。
  bool get _hasDraftAttachments =>
      _drafts?.items(_source.sessionId).isNotEmpty ?? false;

  void _onUpdate(RemoteConversationUpdate update) {
    if (!mounted) return;
    switch (update) {
      case RemoteConversationSnapshot(:final window):
        _noteRemotePush();
        _eventFlushTimer?.cancel();
        _eventFlushTimer = null;
        _pendingEvents.clear();
        setState(() {
          _loading = false;
          _loadError = null;
          _events = List<Json>.of(window.events);
          _seenSeqs
            ..clear()
            ..addAll([for (final event in _events) event['seq'] as int]);
          _windowThroughSeq = window.throughSeq;
          _hasOlder = window.hasMore;
          _projection.reconcile(_events);
          _trimRetainedEvents();
        });
        _recomputeInferredRunning();
        _scheduleConversationCacheWrite();
        _scheduleScrollToEnd();
      case RemoteConversationEvents(:final events):
        // 推送本身（即使与已有 seq 重复）也视为推送活跃，重置兜底窗口。
        _noteRemotePush();
        var immediate = false;
        for (final event in events) {
          final seq = event['seq'];
          if (seq is! int || !_seenSeqs.add(seq)) continue;
          _pendingEvents.add(event);
          final type = event['type'];
          if (type is String && _immediateEventTypes.contains(type)) {
            immediate = true;
          }
        }
        if (_pendingEvents.isEmpty) return;
        if (immediate) {
          _flushPendingEvents();
        } else {
          _eventFlushTimer ??= Timer(_eventBatchWindow, _flushPendingEvents);
        }
      case RemoteConversationLive(:final value):
        _noteRemotePush();
        if (value == null) {
          _liveFrameTimer?.cancel();
          _liveFrameTimer = null;
          _queuedLiveValue = null;
          if (_live != null) setState(() => _live = null);
        } else {
          // A model can send dozens of growing text frames per second. Parsing
          // each whole Markdown reply on the UI thread makes input unresponsive.
          _queuedLiveValue = value;
          _liveFrameTimer ??= Timer(
            const Duration(milliseconds: 120),
            _flushLiveFrame,
          );
        }
      case RemoteConversationRunning(:final running):
        _noteRemotePush();
        if (!running) _flushLiveFrame();
        if (!running) _clearInferredRunning();
        if (_runningFromEvents == running) return;
        setState(() => _runningFromEvents = running);
        _recomputeInferredRunning();
        // 状态切换后尽快同步队列与 live.status，不必等下一轮轮询。
        unawaited(_refreshSessionTasks());
      case RemoteConversationFailure(:final message, :final fatal):
        // 补偿轮询的失败静默：保留上一次时间线，不弹提示。
        if (_inferredRefreshInFlight) return;
        if (fatal) {
          setState(() => _loadError = sanitizeRemoteUiMessage(message));
        } else {
          _showStatus(message);
        }
      case RemoteConversationInteractions(:final requests):
        if (requests.isNotEmpty && _interactions.isEmpty) {
          _focus.unfocus();
        }
        setState(() {
          _interactions = requests;
          // 已经不在列表里的交互不用再保留错误；仍在等待的保留到下次答复或
          // 刷新成功，避免把「宿主还没受理」的说明悄悄丢掉。
          final live = <String>{for (final request in requests) request.id};
          _interactionErrors.removeWhere((id, _) => !live.contains(id));
          if (_busyInteractionId != null &&
              !live.contains(_busyInteractionId)) {
            _busyInteractionId = null;
          }
        });
      case RemoteConversationModel(:final choice):
        if (_modelChoice == choice) return;
        setState(() => _modelChoice = choice);
      case RemoteConversationModelAvailability(:final failedProviders):
        if (_sameProviders(_failedModelProviders, failedProviders)) return;
        setState(() => _failedModelProviders = Set<String>.of(failedProviders));
      case RemoteConversationInsights(:final insights):
        if (_insights == insights) return;
        setState(() => _insights = insights);
    }
  }

  void _flushLiveFrame() {
    _liveFrameTimer?.cancel();
    _liveFrameTimer = null;
    final value = _queuedLiveValue;
    _queuedLiveValue = null;
    if (!mounted || value == null) return;
    setState(() => _live = _liveMessage(value));
    _scheduleScrollToEnd();
  }

  /// 两个服务商集合是否相同；用于跳过内容没变的目录更新。
  static bool _sameProviders(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);

  /// 宿主 `session.live` 的 `value` 与本地模式完全同形，直接转成渲染用的
  /// [ChatLiveMessage]；字段不完整时视为没有流式回复，而不是猜一半。
  static ChatLiveMessage? _liveMessage(Json? value) {
    if (value == null) return null;
    final attemptId = value['attemptId'];
    final turn = value['turn'];
    final step = value['step'];
    final content = value['content'];
    if (attemptId is! String || turn is! int || step is! int) return null;
    if (content is! List) return null;
    return ChatLiveMessage(
      identity: attemptId,
      content: content,
      turn: turn,
      step: step,
      interrupted: value['interrupted'] == true,
      unconfirmed: value['unconfirmed'] == true,
    );
  }

  static int _bySeq(Json left, Json right) =>
      (left['seq'] as int? ?? 0).compareTo(right['seq'] as int? ?? 0);

  /// 重新读取窗口与权限状态：读取失败后的「重试」用它。
  Future<void> _reload() async {
    await _source.reload();
    if (mounted) await _permissions.refresh();
  }

  // ------------------------------------------------------------ 滚动

  void _onFocusChanged() {
    if (!mounted) return;
    if (_focus.hasFocus) {
      // A hardware keyboard has no viewInsets. Let the soft keyboard report
      // its final viewport first; this fallback handles no-IME environments.
      if (_composerMode == PocketComposerMode.browse) {
        _composerOpenFallback?.cancel();
        _composerOpenFallback = Timer(const Duration(milliseconds: 450), () {
          _composerOpenFallback = null;
          if (!_keyboardVisible) _finishComposerEntrance();
        });
      }
      return;
    }
    _composerOpenFallback?.cancel();
    _composerOpenFallback = null;
    // 失焦不立刻缩小：有草稿时保持展开，纯浏览才回到缩小态。
    if (_input.text.trim().isEmpty &&
        _composerMode == PocketComposerMode.composing) {
      setState(() => _composerMode = PocketComposerMode.browse);
    }
  }

  void _finishComposerEntrance() {
    if (!mounted ||
        !_focus.hasFocus ||
        _composerMode != PocketComposerMode.browse) {
      return;
    }
    setState(() => _composerMode = PocketComposerMode.composing);
  }

  void _onKeyboardSettled() {
    if (_keyboardVisible &&
        _focus.hasFocus &&
        _composerMode == PocketComposerMode.browse) {
      _finishComposerEntrance();
      if (!MediaQuery.disableAnimationsOf(context)) return;
    }
    _deferKeyboardScroll = false;
    _scheduleScrollToEnd();
  }

  void _onComposerSizeEnd() {
    if (!_deferKeyboardScroll) return;
    _deferKeyboardScroll = false;
    _scheduleScrollToEnd();
  }

  /// 跳到列表底部，并在下一帧再校正一次：懒加载列表的最大滚动距离要等新行布局
  /// 完才准确。
  void _scheduleScrollToEnd() {
    if (!mounted || _deferKeyboardScroll || _scrollToEndScheduled) return;
    _scrollToEndScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _scrollToEndScheduled = false;
        return;
      }
      _jumpToEnd();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToEndScheduled = false;
        if (mounted) _jumpToEnd();
      });
    });
  }

  void _jumpToEnd() {
    if (!_pinnedToEnd || !_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    if ((position.pixels - position.maxScrollExtent).abs() < .5) return;
    _scroll.jumpTo(position.maxScrollExtent);
  }

  bool _trackScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    switch (notification) {
      case ScrollStartNotification() when notification.dragDetails != null:
        _pinnedToEnd = false;
      case ScrollUpdateNotification():
        final metrics = notification.metrics;
        _pinnedToEnd =
            metrics.maxScrollExtent - metrics.pixels < _followThreshold;
      default:
        break;
    }
    return false;
  }

  // ------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    return PocketScaffold(
      title: const SizedBox.shrink(),
      ambientMotion: false,
      animateEntrance: false,
      bottomHeightDebounce: const Duration(milliseconds: 80),
      keyboardOverlay: true,
      onKeyboardSettled: _onKeyboardSettled,
      header: _header(context),
      headerHeight: 64,
      body: Listener(
        key: const ValueKey('remote-transcript'),
        onPointerDown: _composerMode == PocketComposerMode.picker
            ? (_) => _exitReasoningPanel(keepKeyboard: false)
            : null,
        child: NotificationListener<ScrollNotification>(
          onNotification: _trackScroll,
          child: _transcript(context),
        ),
      ),
      bottom: _bottomDock(context),
    );
  }

  Widget _bottomDock(BuildContext context) {
    final insights = _insights;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?_banner(context),
        if (_interactions.isEmpty) ...[
          _planArea(context),
          ?_todoArea(context),
          ?_modelRouteNotice(context),
          ?_credentialNotice(context),
          ?_commandResultBar(context),
          ?_persistentNoticeBar(context),
        ],
        if (_interactions.isEmpty &&
            insights != null &&
            RemoteStatsBar.hasReadings(insights))
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 2),
            child: RemoteStatsBar(
              insights: insights,
              onTap: _openStatsSheet,
              expanded: _statsExpanded,
              onExpandedChanged: _onStatsExpandedChanged,
            ),
          ),
        if (_interactions.isEmpty) _sessionTasksPanel(context),
        AnimatedSwitcher(
          duration: _remoteAnimationDuration(context),
          reverseDuration: _remoteAnimationDuration(context),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: _bottomDockTransition,
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.bottomCenter,
            children: [...previous, ?current],
          ),
          child: _interactions.isEmpty
              ? KeyedSubtree(
                  key: const ValueKey('remote-composer-dock'),
                  child: _composerArea(context),
                )
              : KeyedSubtree(
                  key: const ValueKey('remote-interaction-dock'),
                  child: _interactionArea(context),
                ),
        ),
      ],
    );
  }

  Widget _bottomDockTransition(Widget child, Animation<double> animation) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final progress = Curves.easeOutCubic.transform(animation.value);
        return Opacity(
          opacity: progress,
          child: Transform.translate(
            offset: Offset(0, (1 - progress) * 18),
            child: ImageFiltered(
              enabled: progress < 1,
              imageFilter: ui.ImageFilter.blur(
                sigmaX: (1 - progress) * 7,
                sigmaY: (1 - progress) * 7,
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }

  /// 连接阶段与非致命错误的条状提示；正常时返回 null。
  Widget? _banner(BuildContext context) {
    final error = _loadError;
    if (error != null && _events.isNotEmpty) {
      return _RemoteNoticeBar(
        key: const ValueKey('remote-conversation-read-error'),
        message: error,
        actionLabel: '重试',
        onAction: _canRetryRead ? () => unawaited(_reload()) : null,
      );
    }
    switch (_source.phase) {
      case RemoteConnectionPhase.ready:
        break;
      case RemoteConnectionPhase.failed:
        return _RemoteNoticeBar(
          key: const ValueKey('remote-conversation-failed'),
          message: sanitizeRemoteUiMessage(
            _source.lastError ?? '没能连接到这台电脑，请回到首页重新连接。',
          ),
          actionLabel: '重新连接',
          onAction: () => unawaited(_source.retry()),
        );
      case RemoteConnectionPhase.idle:
      case RemoteConnectionPhase.connecting:
      case RemoteConnectionPhase.handshaking:
      case RemoteConnectionPhase.reconnecting:
      case RemoteConnectionPhase.lost:
        return const _RemoteNoticeBar(
          key: ValueKey('remote-conversation-connecting'),
          message: '正在连接电脑…',
        );
    }
    if (!_source.supports(remoteConversationSendMethod)) {
      return const _RemoteNoticeBar(
        key: ValueKey('remote-conversation-send-unsupported'),
        message: '这台电脑不支持发送消息，只能查看这个会话。',
      );
    }
    return null;
  }

  /// 读取能力明确不支持时，重试没有意义。
  bool get _canRetryRead =>
      _source.phase != RemoteConnectionPhase.ready ||
      _source.supports(remoteConversationReadMethod);

  Widget _transcript(BuildContext context) {
    if (_loading) {
      // 先给本地缓存一个读取窗口：缓存命中会马上替换成时间线，避免闪一下大空态。
      if (_cacheRestorePending) {
        // 不展示任何缓存来源说明：只给一个紧凑转圈，命中后立即显示内容。
        return const PocketEmpty(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      }
      return const PocketEmpty(
        child: _RemoteNotice(
          icon: Icons.hourglass_top_rounded,
          title: '正在读取会话',
          message: '会话内容从这台电脑上读取。',
        ),
      );
    }
    final error = _loadError;
    if (error != null && _events.isEmpty) {
      return PocketEmpty(
        child: _RemoteNotice(
          icon: Icons.cloud_off_rounded,
          title: '读取会话失败',
          message: error,
          actionLabel: _canRetryRead ? '重试' : null,
          onAction: _canRetryRead ? () => unawaited(_reload()) : null,
        ),
      );
    }
    if (_events.isEmpty) {
      return const PocketEmpty(
        child: _RemoteNotice(
          icon: Icons.chat_bubble_outline_rounded,
          title: '这个会话还没有消息',
          message: '在下面的输入框里开始对话。',
        ),
      );
    }
    final colors = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            key: const ValueKey('remote-conversation-transcript'),
            child: _timelineForCurrentState(),
          ),
        ),
        if (_hasOlder || _loadingOlder)
          Positioned(
            // PocketScaffold overlays its 64dp header above the transcript.
            top: MediaQuery.paddingOf(context).top + 64 + 32,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                color: colors.surfaceContainerHighest.withValues(alpha: .92),
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  key: const ValueKey('remote-load-older'),
                  borderRadius: BorderRadius.circular(14),
                  onTap: _loadingOlder ? null : () => unawaited(_loadOlder()),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_loadingOlder)
                          const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          Icon(
                            Icons.expand_less_rounded,
                            size: 16,
                            color: colors.onSurfaceVariant,
                          ),
                        const SizedBox(width: 6),
                        Text(
                          _loadingOlder ? '正在加载更早消息…' : '加载更早消息',
                          style: AppTextStyle.footnote
                              .of(context)
                              .copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  ChatTimeline _timelineForCurrentState() {
    final running = _running;
    final cached = _timeline;
    if (cached != null &&
        identical(_timelineEvents, _events) &&
        identical(_timelineLive, _live) &&
        _timelineRunning == running) {
      return cached;
    }
    _timelineEvents = _events;
    _timelineLive = _live;
    _timelineRunning = running;
    return _timeline = ChatTimeline(
      sessionId: _source.sessionId,
      projection: _projection,
      controller: _scroll,
      events: _events,
      live: _live,
      running: running,
      compactTurns: true,
      messageImage: (ref) => PocketImageSource.message(
        _source.request,
        _source.sessionId,
        ref,
        generation: () => _attachmentSurface?.connectionGeneration ?? 0,
      ),
      animateRows: false,
    );
  }

  // ------------------------------------------------------------ 头部

  Widget _header(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final canPop = Navigator.canPop(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 6),
      child: Row(
        children: [
          _RemoteIconControl(
            icon: Icons.arrow_back_rounded,
            label: '返回远程会话',
            onPressed: canPop ? () => Navigator.of(context).pop() : null,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.headline.of(context, emphasized: true),
                ),
                Text(
                  '${widget.deviceName} · ${widget.projectName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.footnote
                      .of(context)
                      .copyWith(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _headerPill(context),
        ],
      ),
    );
  }

  /// 右侧「编辑 + 省略号」胶囊：两个 44dp 触摸目标共用一块玻璃面。
  ///
  /// 重命名、本次变更与归档都按方法表三态处理（协议 §10.2）：宿主明确不支持时
  /// 置灰并给出原因，尚未连接时说明「正在连接」，不给点了没反应的控件。
  Widget _headerPill(BuildContext context) {
    final renameState = _capability(remoteConversationRenameMethod);
    return GlassSurface(
      radius: 24,
      child: SizedBox(
        height: 48,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _pillAction(
              icon: Icons.edit_square,
              label: _capabilityLabel(renameState, '重命名会话', pending: '正在连接电脑…'),
              onPressed: renameState == RemoteCapabilityState.available
                  ? () => unawaited(_rename())
                  : null,
            ),
            const SizedBox(width: 2),
            CommonPopupBox(
              // 弹层取代输入焦点，先收起键盘再展开菜单。
              onOpen: _focus.unfocus,
              popupBuilder: (_) => CommonPopupMenu(items: _menuItems()),
              targetBuilder: (open) => _pillAction(
                icon: Icons.more_horiz_rounded,
                label: '更多会话操作',
                onPressed: open,
              ),
            ),
            const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }

  /// 省略号菜单：本次变更、终端、归档与会话信息。
  ///
  /// 不可用的入口保留在菜单里但置灰，`description` 写明原因；这样用户不会以为
  /// 功能消失，也不会点到一个没有反应的按钮。
  List<CommonPopupMenuItem> _menuItems() {
    final diffState = _capabilities(<String>[
      remoteWorkspaceChangesSummaryMethod,
      remoteWorkspaceChangesDiffMethod,
    ]);
    final terminalState = _terminalCapability();
    final archiveState = _capability(remoteConversationArchiveMethod);
    return <CommonPopupMenuItem>[
      CommonPopupMenuItem(
        label: '本次变更',
        glyph: Icons.difference_outlined,
        description: diffState == RemoteCapabilityState.available
            ? null
            : _capabilityReason(diffState, '查看本次变更'),
        onPressed: diffState == RemoteCapabilityState.available
            ? () => unawaited(_openWorkspaceChanges())
            : null,
      ),
      CommonPopupMenuItem(
        label: '终端',
        glyph: Icons.terminal_rounded,
        description: terminalState == RemoteCapabilityState.available
            ? null
            : _capabilityReason(terminalState, '终端'),
        onPressed: terminalState == RemoteCapabilityState.available
            ? () => unawaited(_openTerminal())
            : null,
      ),
      CommonPopupMenuItem(
        label: '归档会话',
        glyph: Icons.archive_outlined,
        description: archiveState == RemoteCapabilityState.available
            ? null
            : _capabilityReason(archiveState, '归档会话'),
        onPressed: archiveState == RemoteCapabilityState.available
            ? () => unawaited(_archive())
            : null,
      ),
      CommonPopupMenuItem(
        label: '会话信息',
        glyph: Icons.info_outline_rounded,
        onPressed: () => unawaited(_showSessionInfo()),
      ),
      CommonPopupMenuItem(
        label: '复制会话信息',
        glyph: Icons.copy_rounded,
        onPressed: () => unawaited(_copySessionInfo()),
      ),
    ];
  }

  /// 一个门面能力的当前三态（协议 §10.2）。
  RemoteCapabilityState _capability(String method) =>
      _source.capability(method);

  /// 同时依赖多个方法的入口：全部可用才算可用；任一无效应按最弱的一环降级。
  RemoteCapabilityState _capabilities(List<String> methods) {
    if (_source.phase != RemoteConnectionPhase.ready) {
      return RemoteCapabilityState.pending;
    }
    for (final method in methods) {
      final state = _source.capability(method);
      if (state == RemoteCapabilityState.unsupported) {
        return RemoteCapabilityState.unsupported;
      }
      if (state == RemoteCapabilityState.pending) {
        return RemoteCapabilityState.pending;
      }
    }
    return RemoteCapabilityState.available;
  }

  /// 「终端」入口的三态，直接复用终端页自己的能力判定。
  ///
  /// 入口与页内用同一份判定（[RemoteTerminalCapability]），因此不会出现「菜单可用、
  /// 打开后却说这台电脑不支持」的分歧；调用方没传连接面时按这台电脑不支持终端处理。
  RemoteCapabilityState _terminalCapability() {
    final connection = widget.terminalConnection;
    if (connection == null) return RemoteCapabilityState.unsupported;
    return switch (RemoteTerminalCapability.of(connection)) {
      RemoteTerminalCapability.available => RemoteCapabilityState.available,
      RemoteTerminalCapability.pending => RemoteCapabilityState.pending,
      RemoteTerminalCapability.unsupported => RemoteCapabilityState.unsupported,
    };
  }

  /// 能力置灰时的原因文案；可用时为 null。
  static String? _capabilityReason(
    RemoteCapabilityState state,
    String subject,
  ) => switch (state) {
    RemoteCapabilityState.available => null,
    RemoteCapabilityState.pending => '正在连接电脑…',
    RemoteCapabilityState.unsupported => '这台电脑不支持$subject',
  };

  /// 图标按钮的无障碍文案：可用时是动作名，否则是原因。
  static String _capabilityLabel(
    RemoteCapabilityState state,
    String action, {
    required String pending,
  }) => switch (state) {
    RemoteCapabilityState.available => action,
    RemoteCapabilityState.pending => pending,
    RemoteCapabilityState.unsupported => '这台电脑不支持$action',
  };

  Widget _pillAction({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) => ElasticPress(
    enabled: onPressed != null,
    preserveAspectRatio: true,
    child: IconButton(
      tooltip: label,
      onPressed: onPressed,
      icon: Icon(icon, size: 22),
      style: IconButton.styleFrom(
        fixedSize: const Size.square(44),
        minimumSize: const Size.square(44),
        maximumSize: const Size.square(44),
        padding: EdgeInsets.zero,
        shape: const CircleBorder(),
        backgroundColor: Colors.transparent,
        disabledBackgroundColor: Colors.transparent,
        splashFactory: NoSplash.splashFactory,
      ),
    ),
  );

  // ------------------------------------------------------------ 输入区

  Widget _composerArea(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final ready = _source.phase == RemoteConnectionPhase.ready;
    final canSend =
        _capability(remoteConversationSendMethod) ==
        RemoteCapabilityState.available;
    final apiState = _capability(remoteConversationApiCallMethod);
    final canSelectModel = apiState == RemoteCapabilityState.available;
    // `+` 的数据源是 `api.call` 的指令目录；这台电脑不支持时置灰并写原因，
    // 而不是弹出一个永远读不到内容的菜单（协议 §10.2）。
    final canOpenMenu = apiState == RemoteCapabilityState.available;
    final hasDraft = !_draftEmpty || _hasDraftAttachments;
    final drafts = _drafts;
    // 权限预设与当前模型是「展开输入时」的上下文：缩小态只留一行悬浮卡与其上方
    // 的会话读数，不展示这些回显行（用户原话「输入框未展开时没有审核权限这一说」）。
    final expanded = _composerMode != PocketComposerMode.browse;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 输入卡上方的回显与提示：权限预设、当前模型、指令提示、状态与结果。
        // 权限与模型回显只在展开态出现；其余提示照旧。
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (ready && expanded) _permissionStatusRow(context),
              if (ready && expanded) _modelLabelRow(context),
              if (ready && !canOpenMenu)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 14,
                          color: colors.onSurfaceVariant.withValues(alpha: .6),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '这台电脑不支持会话指令与添加菜单',
                          key: const ValueKey(
                            'remote-composer-menu-unavailable',
                          ),
                          style: AppTextStyle.footnote
                              .of(context)
                              .copyWith(
                                color: colors.onSurfaceVariant.withValues(
                                  alpha: .75,
                                ),
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ?_commandHint(context),
              if (_status case final status?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      status,
                      key: const ValueKey('remote-conversation-status'),
                      textAlign: TextAlign.center,
                      style: AppTextStyle.footnote
                          .of(context)
                          .copyWith(color: colors.onSurfaceVariant),
                    ),
                  ),
                ),
            ],
          ),
        ),
        // 悬浮输入卡：缩小/展开/推理面板三态，附件 rail 作为卡片上方的插槽。
        RemoteComposer(
          floating: true,
          animateSize: true,
          onSizeEnd: _onComposerSizeEnd,
          margin: const EdgeInsets.fromLTRB(0, 10, 0, 4),
          mode: _composerMode,
          deviceLabel: widget.deviceName,
          placeholder: canSend
              ? '在 ${widget.deviceName} 上工作'
              : ready
              ? '这台电脑不支持发送消息'
              : '先连接这台电脑',
          controller: _input,
          focusNode: _focus,
          approvalLabel: _permissionShieldLabel,
          modelLabel: _modelLabel,
          enabled: canSend && !_sending,
          hasDraft: hasDraft,
          sending: _sending,
          onChanged: _onDraftChanged,
          onSubmitted: (value) => unawaited(_submit(value)),
          onAdd: canOpenMenu ? _exitReasoningPanel : null,
          addPopupBuilder: canOpenMenu ? _buildAddPopup : null,
          onApproval: _permissions.presetsReady ? _openPermissionSheet : null,
          onModel: canSelectModel ? _openModelsFromReasoningPanel : null,
          onReasoning: canSelectModel ? _toggleReasoningPanel : null,
          reasoningDisabledReason: canSelectModel
              ? null
              : apiState == RemoteCapabilityState.pending
              ? '正在连接电脑…'
              : '这台电脑不支持选择模型',
          reasoning: _composerMode == PocketComposerMode.picker
              ? _reasoningPanel(canSelectModel)
              : null,
          onSend: canSend ? _sendDraft : null,
          // 远程数据源没有取消入口（协议方法表里没有取消方法），不画停止按钮。
          onStop: null,
          sendKey: const ValueKey('remote-send'),
          attachments: _attachmentRailSlot(context, drafts),
        ),
      ],
    );
  }

  /// 输入卡上方只展示真实排队消息，不再叠加工作状态提示。
  ///
  /// 连接未就绪、宿主不支持 `tasks.session`、或首次读取还没返回时不渲染；读取失败
  /// 静默保留上次读数。队列坞只在 pending 非空时出现（0 条完全不占位）。
  ///
  /// 队列为空时不占位，避免与输入卡或发送错误文字重叠。
  Widget _sessionTasksPanel(BuildContext context) {
    final content = _sessionTasksContent(context);
    return AnimatedSize(
      duration: _remoteAnimationDuration(context),
      curve: Curves.easeInOutCubic,
      alignment: Alignment.bottomCenter,
      clipBehavior: Clip.none,
      child: content ?? const SizedBox(width: double.infinity, height: 0),
    );
  }

  Widget? _sessionTasksContent(BuildContext context) {
    if (_source.phase != RemoteConnectionPhase.ready) return null;
    final tasks = _sessionTasks;
    final hasTasks = !_sessionTasksUnsupported && _sessionTasksLoaded;
    final pending = hasTasks
        ? tasks?.pending ?? const <RemoteQueuedMessage>[]
        : const <RemoteQueuedMessage>[];
    final queued = hasTasks ? tasks?.queued ?? 0 : 0;
    // pending 非空时队列坞自己会显示「N 条排队消息」，不重复画一条计数状态条。
    final showQueuedCount = hasTasks && queued > 0 && pending.isEmpty;
    if (!showQueuedCount && pending.isEmpty) {
      return null;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showQueuedCount) _queuedCountRow(context, queued),
          if (pending.isNotEmpty) _queueDock(context, pending),
        ],
      ),
    );
  }

  /// 队列里只有计数、没有可展示的 pending 行时的兜底状态条。
  Widget _queuedCountRow(BuildContext context, int queued) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('remote-queue-count'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule_rounded, size: 15, color: colors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$queued 条消息排队中',
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// 动画时长：跟随系统的「减少动态效果」，普通情况下 190ms。
  Duration _remoteAnimationDuration(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 190);

  /// DSH 产品图标（`apps/android/assets/icons/dsh` 取自仓库
  /// `packages/client/ui-primitives/src/icons/artwork.ts`）；颜色跟随当前文字色。
  Widget _dshIcon(String fileName, {double size = 16, required Color color}) =>
      SvgPicture.asset(
        'assets/icons/dsh/$fileName',
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      );

  /// 队列坞：1 条直出；>1 条默认收起成「N 条排队消息」，点开看每一条。
  Widget _queueDock(BuildContext context, List<RemoteQueuedMessage> pending) {
    final colors = Theme.of(context).colorScheme;
    final collapsed = pending.length > 1 && !_queueExpanded;
    return Container(
      key: const ValueKey('remote-queue-dock'),
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ClipRect(
        child: AnimatedSize(
          duration: _remoteAnimationDuration(context),
          curve: Curves.easeInOutCubic,
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (pending.length > 1)
                InkWell(
                  key: const ValueKey('remote-queue-toggle'),
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => setState(() => _queueExpanded = !_queueExpanded),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: Row(
                      children: [
                        _dshIcon(
                          'queue.svg',
                          size: 16,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${pending.length} 条排队消息',
                            style: AppTextStyle.footnote
                                .of(context)
                                .copyWith(color: colors.onSurfaceVariant),
                          ),
                        ),
                        AnimatedRotation(
                          turns: _queueExpanded ? .5 : 0,
                          duration: _remoteAnimationDuration(context),
                          child: Icon(
                            Icons.expand_more_rounded,
                            size: 18,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (!collapsed)
                for (final item in pending) _queueRow(context, item),
            ],
          ),
        ),
      ),
    );
  }

  /// 队列坞里的一行：DSH 图标 lead + 目标标签 + 文本预览 + 编辑/删除/插话发送。
  Widget _queueRow(BuildContext context, RemoteQueuedMessage item) {
    final colors = Theme.of(context).colorScheme;
    final editing = _editingQueuedId == item.itemId;
    final removing = _removingQueuedId == item.itemId;
    final busy = removing || _queueBusyId == item.itemId;
    final iconColor = colors.onSurfaceVariant;
    final disabledColor = iconColor.withValues(alpha: .38);
    final editReason = item.editable
        ? '编辑排队消息'
        : item.suspended
        ? '离线记录，暂不支持编辑'
        : '包含非文本内容，暂不支持编辑';
    final steerEnabled = item.steerable && _running;
    final steerReason = item.steerable && _running ? '插话发送' : '仅运行中可插话发送';
    return Padding(
      key: ValueKey('remote-queue-item-${item.itemId}'),
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
      child: editing
          ? _queuedEditRow(context, item)
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: _dshIcon('queue.svg', size: 14, color: iconColor),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    item.nextStep ? '插话 · 待发送' : '排队 · 待执行',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                      color: colors.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.prompt.trim().isEmpty
                            ? '附件或系统输入'
                            : item.prompt.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyle.footnote.of(context),
                      ),
                      if (item.suspended)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '未恢复执行',
                            style: AppTextStyle.footnote
                                .of(context)
                                .copyWith(color: colors.error),
                          ),
                        ),
                    ],
                  ),
                ),
                _queueIconAction(
                  key: ValueKey('remote-queue-edit-${item.itemId}'),
                  tooltip: editReason,
                  asset: 'edit.svg',
                  color: item.editable ? iconColor : disabledColor,
                  onPressed: item.editable && !busy
                      ? () => _beginQueuedEdit(item)
                      : null,
                ),
                _queueIconAction(
                  key: ValueKey('remote-queue-steer-${item.itemId}'),
                  tooltip: steerReason,
                  asset: 'send.svg',
                  color: steerEnabled ? colors.primary : disabledColor,
                  onPressed: steerEnabled && !busy
                      ? () => unawaited(_steerQueuedMessage(item))
                      : null,
                ),
                if (item.cancellable)
                  SizedBox(
                    width: 30,
                    height: 30,
                    child: removing
                        ? const Padding(
                            padding: EdgeInsets.all(7),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : IconButton(
                            key: ValueKey('remote-queue-remove-${item.itemId}'),
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            tooltip: '删除排队消息',
                            onPressed: busy
                                ? null
                                : () => unawaited(_removeQueuedMessage(item)),
                            icon: _dshIcon(
                              'trash.svg',
                              size: 16,
                              color: iconColor,
                            ),
                          ),
                  ),
              ],
            ),
    );
  }

  /// 队列行内的紧凑图标按钮；禁用时保留置灰图标与 tooltip 原因。
  Widget _queueIconAction({
    required Key key,
    required String tooltip,
    required String asset,
    required Color color,
    VoidCallback? onPressed,
  }) => SizedBox(
    width: 30,
    height: 30,
    child: IconButton(
      key: key,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      tooltip: tooltip,
      onPressed: onPressed,
      icon: _dshIcon(asset, size: 16, color: color),
    ),
  );

  /// 行内编辑：预填原文、自动聚焦，保存/取消在行尾；空文本不能保存。
  Widget _queuedEditRow(BuildContext context, RemoteQueuedMessage item) {
    final controller = _queuedEditController;
    if (controller == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final busy =
        _queueBusyId == item.itemId || _removingQueuedId == item.itemId;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: TextField(
            key: ValueKey('remote-queue-edit-field-${item.itemId}'),
            controller: controller,
            autofocus: true,
            minLines: 1,
            maxLines: 2,
            style: AppTextStyle.footnote.of(context),
            decoration: InputDecoration(
              isDense: true,
              hintText: '编辑排队消息',
              hintStyle: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: colors.onSurfaceVariant),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 6,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
        TextButton(
          key: ValueKey('remote-queue-edit-cancel-${item.itemId}'),
          onPressed: busy ? null : _cancelQueuedEdit,
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: const Text('取消'),
        ),
        TextButton(
          key: ValueKey('remote-queue-edit-save-${item.itemId}'),
          onPressed: busy ? null : () => unawaited(_saveQueuedEdit(item)),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }

  /// 附件 rail 作为悬浮卡上方的插槽；没有草稿也不在选文件时返回 null。
  Widget? _attachmentRailSlot(BuildContext context, AttachmentDrafts? drafts) {
    if (drafts == null) return null;
    final sessionId = _source.sessionId;
    final picking = drafts.pickingSession == sessionId;
    if (!picking && drafts.items(sessionId).isEmpty && drafts.message(sessionId) == null) {
      return null;
    }
    return PocketAttachmentRail(drafts: drafts, sessionId: sessionId);
  }

  /// 发送草稿：先收起推理面板，再走既有发送/指令提交。
  void _sendDraft() {
    _exitReasoningPanel();
    unawaited(_submit(_input.text));
  }

  /// 输入区上方的计划模式条：与本地共用 [ChatPlanDock]。
  ///
  /// 未连接时不显示（[RemoteGoalPlanController] 保持 plan 为空且没有错误）；
  /// `session.projections` 读失败时追加一条可重试说明，写失败由 Dock 自己展示
  /// 原文（`actionKind == 'plan'`）。这里不持有输入草稿，因此写失败不影响输入。
  Widget _planArea(BuildContext context) => ListenableBuilder(
    listenable: _goalPlan,
    builder: (context, _) {
      final error = _goalPlan.error;
      final dock = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ChatPlanDock(controller: _goalPlan),
      );
      if (error == null) return dock;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          dock,
          _RemoteNoticeBar(
            key: const ValueKey('remote-conversation-plan-status'),
            message: error,
            icon: Icons.edit_note_rounded,
            accent: Theme.of(context).colorScheme.warning,
            actionLabel: '重试',
            onAction: () => unawaited(_goalPlan.refresh()),
          ),
        ],
      );
    },
  );

  // ------------------------------------------------------------ 会话洞察

  /// 输入区上方的待办卡片；没有待办投影（或清单为空）时不占布局。
  ///
  /// 卡片放在计划条之后、提示条之前：与本地会话页 `ChatTodoDock` 同在输入区
  /// 上方，但不覆盖输入框；展开状态由页面持有（[_todosExpanded]），窗口刷新与
  /// 流式增量重建都不会收起。
  Widget? _todoArea(BuildContext context) {
    final todos = _insights?.todos;
    if (todos == null || todos.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: RemoteTodoCard(
        todos: todos,
        expanded: _todosExpanded,
        onToggle: () => setState(() => _todosExpanded = !_todosExpanded),
      ),
    );
  }

  /// 打开会话统计详情弹层：弹层取代输入焦点，先收起键盘。
  ///
  /// 统计条只在有统计读数时渲染，这里用同一个判定兜底，避免打开一个没有内容的
  /// 弹层（只有待办的会话不渲染统计条）。
  void _openStatsSheet() {
    _exitReasoningPanel(keepKeyboard: false);
    final insights = _insights;
    if (insights == null || !RemoteStatsBar.hasReadings(insights)) return;
    _focus.unfocus();
    unawaited(showRemoteStatsSheet(context, insights: insights));
  }

  /// 输入区上方的当前模型回显：点按打开模型选择弹层。
  ///
  /// 三态按协议 §10.2 渲染：可用时是可点入口；已连接但宿主不支持、或还没连上时
  /// 显示一行不可点的原因，而不是留一个点了没反应的按钮。
  Widget _modelLabelRow(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final state = _capability(remoteConversationApiCallMethod);
    if (state != RemoteCapabilityState.available) {
      return _modelUnavailableRow(context, state);
    }
    final text = Text(
      _modelLabel,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTextStyle.footnote
          .of(context)
          .copyWith(color: colors.onSurfaceVariant),
    );
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        key: const ValueKey('remote-model-label'),
        onPressed: () => unawaited(_openModelSheet()),
        icon: const Icon(Icons.auto_awesome_outlined, size: 16),
        label: text,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  /// 当前模型的回显文案。
  String get _modelLabel {
    final choice = _modelChoice;
    if (choice == null) return '选择模型';
    final effort = choice.reasoningEffort;
    if (effort == null) return choice.label;
    return '${choice.label} · ${reasoningEffortLabel(effort)}';
  }

  /// 模型入口不可用时的原因行：已连接但宿主不支持，或还在连接中。
  Widget _modelUnavailableRow(
    BuildContext context,
    RemoteCapabilityState state,
  ) {
    final colors = Theme.of(context).colorScheme;
    final reason = state == RemoteCapabilityState.pending
        ? '正在连接电脑…'
        : '这台电脑不支持选择模型';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline_rounded,
              size: 14,
              color: colors.onSurfaceVariant.withValues(alpha: .6),
            ),
            const SizedBox(width: 4),
            Text(
              reason,
              key: const ValueKey('remote-model-unavailable'),
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(
                    color: colors.onSurfaceVariant.withValues(alpha: .75),
                  ),
            ),
          ],
        ),
      ),
    );
  }

  void _onDraftChanged(String value) {
    final trimmed = value.trim();
    final empty = trimmed.isEmpty;
    final command = trimmed.startsWith('/');
    // 指令草稿的每一处改动都要重建：提示行回显的是输入原文。
    if (empty == _draftEmpty && command == _draftIsCommand && !command) return;
    setState(() {
      _draftEmpty = empty;
      _draftIsCommand = command;
      // 有草稿就展开：即使输入框没拿到焦点（例如程序写入草稿），卡片也保持
      // 展开态，用户能看见自己正在编辑什么。
      if (!empty && _composerMode == PocketComposerMode.browse) {
        _composerMode = PocketComposerMode.composing;
      }
    });
  }

  /// 输入以 `/` 开头时的说明行：这一行会在电脑上作为指令执行，不是消息。
  ///
  /// 远程门面不暴露指令目录，因此这里不补全、不猜指令名；宿主不支持指令方法时
  /// 直接说明这一行不会发送，而不是等到提交后才报错。
  Widget? _commandHint(BuildContext context) {
    if (!_draftIsCommand) return null;
    final colors = Theme.of(context).colorScheme;
    final state = _capability(remoteConversationCommandMethod);
    final text = switch (state) {
      RemoteCapabilityState.available =>
        '这条会作为电脑上的命令执行：${_commandPreview(_input.text)}',
      RemoteCapabilityState.pending => '正在连接电脑…',
      RemoteCapabilityState.unsupported => '这台电脑不支持执行会话指令，这一行不会发送。',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(
            Icons.terminal_rounded,
            size: 14,
            color: colors.onSurfaceVariant.withValues(alpha: .75),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              text,
              key: const ValueKey('remote-command-hint'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(
                    color: colors.onSurfaceVariant.withValues(alpha: .75),
                  ),
            ),
          ),
        ],
      ),
    );
  }

  /// 提示里回显的指令行；过长时截断，避免把输入区撑成多行。
  static String _commandPreview(String raw) {
    final line = raw.trim();
    if (line.length <= _commandPreviewLength) return line;
    return '${line.substring(0, _commandPreviewLength - 1)}…';
  }

  /// 提交输入框内容：`session.send` 受理后清空输入框；失败保留原文并把原因
  /// 放到输入区上方，用户可以直接重试。
  ///
  /// 以 `/` 开头的行是电脑上的会话指令，走 [_submitCommand]，绝不落到
  /// `session.send`（哪怕宿主同时支持两者）。
  ///
  /// 附件与本地链路同序（`main.dart`）：提交前 `snapshotIds` 固定本次的草稿 id，
  /// 发送受理后才 `consume`；失败、未识别都保留草稿。附件尚未准备完成时整条消息
  /// 不发送，与本地一致。
  ///
  /// 凭据类失败（宿主没有当前模型可用的 API Key / 账号未登录）会先尝试一次自动
  /// 恢复：读电脑上的默认模型，与当前路由不同就切过去并重发一次（最多一次）。
  /// 自动恢复不了时保留一条可操作提示：用户可以直接打开模型选择，换成这台电脑上
  /// 已配置的模型。
  Future<void> _submit(String raw) async {
    if (_sending) return;
    final text = raw.trim();
    final drafts = _drafts;
    final sessionId = _source.sessionId;
    var attachedIds = const <String>[];
    if (drafts != null) {
      if (!drafts.ready(sessionId)) {
        _showStatus('附件尚未准备完成，请重试或移除失败项。');
        return;
      }
      attachedIds = drafts.snapshotIds(sessionId);
    }
    if (text.isEmpty && attachedIds.isEmpty) return;
    if (text.startsWith('/')) {
      await _submitCommand(text, attachedIds);
      return;
    }
    final sendState = _capability(remoteConversationSendMethod);
    if (sendState != RemoteCapabilityState.available) {
      _showStatus(
        sendState == RemoteCapabilityState.pending ? '正在连接电脑…' : '这台电脑不支持发送消息。',
      );
      return;
    }
    setState(() => _sending = true);
    try {
      await _source.send(text, attachmentIds: attachedIds);
      if (mounted) {
        setState(() => _commandResult = null);
        _clearComposer(routeConfirmed: true);
        // 发送后尽快同步排队消息与工作状态，不等下一轮 2s 轮询；同时增量补拉新事件。
        unawaited(_refreshSessionTasks());
        unawaited(_pullNewer());
      }
      await _consumeAttachments(attachedIds);
    } on RuntimeTransportFailure catch (failure) {
      if (!mounted) return;
      final writeConflict = remoteWriteHandleConflictMessage(failure.message);
      if (writeConflict != null) {
        return;
      }
      if (isRemoteCredentialFailure(failure.message)) {
        final recovered = await _recoverCredentialFailure(
          text,
          failure,
          attachedIds,
        );
        if (recovered) return;
        setState(
          () => _credentialHint =
              '发送失败：这台电脑上没有当前模型可用的凭据。'
              '请选择模型，改用电脑上已登录或已配置 API Key 的模型。',
        );
      }
      _showStatus(failure.message);
    } on Object catch (error) {
      if (mounted) {
        if (remoteWriteHandleConflictMessage(error.toString()) != null) return;
        _showStatus('发送失败：$error');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 提交一条会话指令：电脑上的指令处理器执行，不经过 `session.send`。
  ///
  /// 成功清空草稿与附件，结果条常驻；失败（宿主报错、未识别、传输失败）保留草稿，
  /// 用户可以直接修改重试。宿主不支持指令方法时只给可见说明，不发送任何东西。
  Future<void> _submitCommand(String line, List<String> attachmentIds) async {
    if (!_hasCommandName(line)) {
      setState(
        () => _commandResult = (
          line: line,
          result: const RemoteCommandResult.error('「/」后面还需要指令名，例如 /plan。'),
        ),
      );
      return;
    }
    final state = _capability(remoteConversationCommandMethod);
    if (state != RemoteCapabilityState.available) {
      setState(
        () => _commandResult = (
          line: line,
          result: RemoteCommandResult.error(
            state == RemoteCapabilityState.pending
                ? '正在连接电脑…'
                : '这台电脑不支持执行会话指令，这一行不会发送。',
          ),
        ),
      );
      return;
    }
    setState(() {
      _sending = true;
    });
    try {
      final result = await _source.submitCommand(
        line,
        attachmentIds: attachmentIds,
      );
      if (!mounted) return;
      setState(() => _commandResult = (line: line, result: result));
      if (result.succeeded) {
        _clearComposer();
        await _consumeAttachments(attachmentIds);
      }
    } on RuntimeTransportFailure catch (failure) {
      if (!mounted) return;
      setState(
        () => _commandResult = (
          line: line,
          result: RemoteCommandResult.error(
            remoteWriteHandleConflictMessage(failure.message) ??
                failure.message,
          ),
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _commandResult = (
            line: line,
            result: RemoteCommandResult.error('提交指令失败：$error'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  /// 发送/指令受理后回收本次提交的附件草稿（与 `main.dart` 同序）。
  Future<void> _consumeAttachments(List<String> ids) async {
    if (ids.isEmpty) return;
    final drafts = _drafts;
    if (drafts == null) return;
    await drafts.consume(_source.sessionId, ids);
  }

  /// 指令行在 `/` 之后是否还有指令名；只有 `/`（或 `/   `）时不发请求。
  static bool _hasCommandName(String line) {
    final body = line.trim();
    if (!body.startsWith('/')) return false;
    final name = body.substring(1).trimLeft();
    return name.isNotEmpty && !name.startsWith('/');
  }

  /// 提交被受理后的输入区收尾：清空草稿与发送前提示，并回到列表底部。
  ///
  /// [routeConfirmed] 只由一次成功发送传 true：此后同一条路由不再显示「当前路由
  /// 不可用」的发送前提示。
  void _clearComposer({bool routeConfirmed = false}) {
    _input.clear();
    setState(() {
      _draftEmpty = true;
      _draftIsCommand = false;
      _credentialHint = null;
      if (routeConfirmed) _routeConfirmed = _modelChoice;
    });
    _scheduleScrollToEnd();
  }

  /// 凭据类发送失败后按电脑默认模型自动切换并重发**一次**。
  ///
  /// 只有在电脑给出默认模型、页面知道当前路由、且两者不同的时候才切换；切换或
  /// 重发再失败时把两次失败原因一起写进常驻提示，不再重试（不会无限循环）。
  ///
  /// @param text 用户要发的原文，重发时原样再发一次。
  /// @param failure 第一次发送的失败，用于提示里同时给出两次原因。
  /// @param attachmentIds 本次提交的附件草稿；重发时同样带上，成功后一并回收。
  /// @returns 页面是否已经展示了处理结果；false 表示无法自动切换，调用方保留
  ///   原有的「选择模型」提示。
  Future<bool> _recoverCredentialFailure(
    String text,
    RuntimeTransportFailure failure,
    List<String> attachmentIds,
  ) async {
    RemoteModelChoice? defaultRoute;
    try {
      defaultRoute = await _source.fetchDefaultModelRoute();
    } on Object {
      // 读不到默认模型时按「无法自动切换」处理：调用方保留原有的选择模型提示。
      return false;
    }
    final route = defaultRoute;
    final current = _modelChoice;
    if (route == null || current == null || route == current) {
      return false;
    }
    try {
      await _source.selectModel(route);
    } on RuntimeTransportFailure catch (switchFailure) {
      if (mounted) {
        setState(
          () => _persistentNotice =
              '发送失败：${failure.message}\n'
              '自动切换到这台电脑的默认模型 ${route.label} 也失败了：'
              '${switchFailure.message}',
        );
      }
      return true;
    } on Object catch (switchError) {
      if (mounted) {
        setState(
          () => _persistentNotice =
              '发送失败：${failure.message}\n'
              '自动切换到这台电脑的默认模型 ${route.label} 也失败了：'
              '$switchError',
        );
      }
      return true;
    }
    try {
      await _source.send(text, attachmentIds: attachmentIds);
    } on RuntimeTransportFailure catch (retryFailure) {
      if (mounted) {
        setState(
          () => _persistentNotice =
              '发送失败：${failure.message}\n'
              '已自动切换到 ${route.label} 后重发，仍然失败：'
              '${retryFailure.message}',
        );
      }
      return true;
    } on Object catch (retryError) {
      if (mounted) {
        setState(
          () => _persistentNotice =
              '发送失败：${failure.message}\n'
              '已自动切换到 ${route.label} 后重发，仍然失败：$retryError',
        );
      }
      return true;
    }
    if (!mounted) {
      await _consumeAttachments(attachmentIds);
      return true;
    }
    unawaited(_refreshSessionTasks());
    setState(() {
      _credentialHint = null;
      _persistentNotice =
          '发送失败：${failure.message}\n'
          '已自动切换到这台电脑的默认模型 ${route.label} 并重新发送。';
    });
    setState(() => _commandResult = null);
    _clearComposer(routeConfirmed: true);
    await _consumeAttachments(attachmentIds);
    return true;
  }

  /// 「+」弹层：复用本地那套数据驱动菜单（[ComposerCommands]），数据源是
  /// 电脑上的 `commands.list`（`remote_commands.dart` 的调用面）。
  ///
  /// 远程只支持子集（设计文档 §4.2）：
  /// - `file` 保持附件上行（[AttachmentDrafts.pick]），附件不可用时置灰写原因；
  /// - `model` 打开既有模型弹层；
  /// - `plan` 进入方案模式（[openChatPlanMode]，状态由 [_goalPlan] 驱动）；
  /// - `goal` 延期（D6：激活态依赖远程没有的运行时通知），置灰并写原因，不执行、
  ///   也不把 `/goal ` 插进草稿；
  /// - 其它宿主指令作为 `session.command` 执行；需要输入的指令插进输入框，
  ///   由用户补全参数后按普通指令提交；
  /// - `export` / `skills` 本轮不支持，置灰并写明原因。
  Widget _buildAddPopup(BuildContext context) {
    final drafts = _drafts;
    final state = _attachState();
    final canAttach =
        drafts != null && state == RemoteCapabilityState.available;
    final disabledReasons = <String, String>{
      'export': '远程会话暂不支持导出到手机，请在电脑上导出',
      'skills': '远程会话暂不支持浏览技能',
      'goal': '远程会话暂不支持设置长期目标',
      if (!canAttach)
        'file': _capabilityReason(state, '上传附件') ?? '这台电脑暂不支持上传附件',
    };
    return ComposerCommands(
      runtime: RemoteComposerCommandSurface(_source),
      sessionId: _source.sessionId,
      disabledReasons: disabledReasons,
      // 选中行时 `CommonPopupMenu` 自己会收起承载它的路由（这里就是弹层）；
      // 分发只负责执行，不能再 pop 一次，否则会退到上一页。
      onPick: _pickComposerCommand,
    );
  }

  /// 会话指令菜单选中项的分发：远程子集见 [_openAddSheet] 的说明。
  void _pickComposerCommand(Json command) {
    final key = composerCommandKey(command);
    switch (key) {
      case 'file':
        unawaited(_pickAttachmentDraft());
      case 'model':
        unawaited(_openModelSheet());
      case 'configure-models':
        // 目录读取失败时本地会给出「配置模型与凭据」；远程没有手机侧凭据页，
        // 改用同一个模型选择弹层，仍然解释清楚为什么指令不可用。
        unawaited(_openModelSheet());
      case 'plan':
        unawaited(_openPlanMode());
      case 'export' || 'skills':
        _showStatus('远程会话暂不支持这项能力。');
      default:
        // 与本地 `pickCommand` 的默认分支同判据：需要输入的指令插入草稿等待
        // 补参数，不需要输入的直接在电脑上执行。
        final name = command['name'];
        if (name is! String || name.isEmpty) {
          _showStatus('无法识别这条会话指令。');
          return;
        }
        if (command['input'] != null) {
          setState(() {
            _input.text = '/$name ';
            _input.selection = TextSelection.collapsed(
              offset: _input.text.length,
            );
            _draftEmpty = false;
            _draftIsCommand = true;
          });
          _focus.requestFocus();
          return;
        }
        unawaited(_runHostCommand(name));
    }
  }

  /// 「文件」：选中即上传准备；附件不可用时说明原因而不是静默失败。
  Future<void> _pickAttachmentDraft() async {
    final drafts = _drafts;
    final state = _attachState();
    if (drafts == null || state != RemoteCapabilityState.available) {
      _showStatus(_capabilityReason(state, '上传附件') ?? '这台电脑暂不支持上传附件');
      return;
    }
    await drafts.pick(_source.sessionId);
  }

  /// 执行一条不需要参数的宿主指令（菜单选中项，不进入模型对话）。
  ///
  /// 与输入框提交的区别：它不清空用户正在写的草稿，也不消费附件草稿；结果同样
  /// 落在常驻结果条里。失败不重试，保留原文让用户可以直接重发。
  Future<void> _runHostCommand(String name) async {
    final line = '/$name';
    final state = _capability(remoteConversationCommandMethod);
    if (state != RemoteCapabilityState.available) {
      setState(
        () => _commandResult = (
          line: line,
          result: RemoteCommandResult.error(
            state == RemoteCapabilityState.pending
                ? '正在连接电脑…'
                : '这台电脑不支持执行会话指令，这一行不会发送。',
          ),
        ),
      );
      return;
    }
    setState(() {
      _sending = true;
    });
    try {
      final result = await _source.submitCommand(line);
      if (!mounted) return;
      setState(() => _commandResult = (line: line, result: result));
    } on RuntimeTransportFailure catch (failure) {
      if (!mounted) return;
      setState(
        () => _commandResult = (
          line: line,
          result: RemoteCommandResult.error(
            remoteWriteHandleConflictMessage(failure.message) ??
                failure.message,
          ),
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(
        () => _commandResult = (
          line: line,
          result: RemoteCommandResult.error('提交指令失败：$error'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  /// 方案模式入口：先刷新状态，再打开本地那套计划模式页（`chat_plan.dart`）。
  ///
  /// 计划原文与开关都在同一页；输入区上方的 [ChatPlanDock] 也会在进入计划模式后
  /// 出现「退出计划模式」。
  Future<void> _openPlanMode() async {
    _exitReasoningPanel(keepKeyboard: false);
    _focus.unfocus();
    await _goalPlan.refresh();
    if (!mounted) return;
    await openChatPlanMode(context, _goalPlan);
  }

  /// 计划审核「请求修改」：`interactions.dismiss` 不发送任何答案，计划继续等待
  /// 决定；宿主的 `interactions.changed` 会带着最新快照回来。
  Future<void> _dismissPlan(RemotePendingInteraction request) async {
    if (_busyInteractionId != null) return;
    setState(() {
      _busyInteractionId = request.id;
      _interactionErrors.remove(request.id);
    });
    try {
      final reply = await _source.dismissInteraction(
        request.id,
        request.version,
      );
      if (!mounted) return;
      if (!reply.accepted) {
        setState(
          () => _interactionErrors[request.id] =
              reply.message ?? '电脑还没有接受这次操作，请稍后再试。',
        );
        if (reply.requestStillPending) await _source.refreshInteractions();
      }
    } on Object catch (failure) {
      if (!mounted) return;
      setState(() => _interactionErrors[request.id] = '请求修改未发送：$failure');
      await _source.refreshInteractions();
    } finally {
      if (mounted) setState(() => _busyInteractionId = null);
    }
  }

  /// 打开计划原文：复用既有的 [ChatPlanDocumentPage]，不新造阅读器。
  void _openPlanDocument(RemoteQuestion question, String markdown) {
    unawaited(
      Navigator.of(context).push<void>(
        PocketRoute(
          builder: (_) => ChatPlanDocumentPage(
            title: question.question,
            markdown: markdown,
            sessionId: _source.sessionId,
          ),
        ),
      ),
    );
  }

  /// 附件入口的三态：数据源没有提供调用面时按这台电脑不支持处理。
  RemoteCapabilityState _attachState() {
    if (_drafts == null) return RemoteCapabilityState.unsupported;
    return _capability(remoteAttachmentPrepareMethod);
  }

  // ------------------------------------------------------------ 权限预设

  /// 盾牌按钮的提示文案：可用时是当前预设，否则是置灰原因。
  ///
  /// 只作为工具提示/无障碍文案；可见的回显在 [_permissionStatusRow]。
  String? get _permissionShieldLabel {
    final permissions = _permissions;
    switch (permissions.availability) {
      case RemotePermissionAvailability.available:
        return permissions.currentLabel;
      case RemotePermissionAvailability.pending:
        return permissions.probing ? '正在读取权限预设…' : '正在连接电脑…';
      case RemotePermissionAvailability.unavailable:
        return permissions.unavailableReason ?? '这台电脑未启用权限预设';
    }
  }

  /// 输入区上方的当前权限预设回显（或置灰原因）。未连接时不显示。
  ///
  /// 三态与盾牌一致：可用时是可点入口（点按打开预设列表）；电脑未启用权限预设
  /// （或暂时无法确认）时是一行带锁的原因，而不是一个点了没反应的按钮。
  Widget _permissionStatusRow(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final permissions = _permissions;
    final state = permissions.availability;
    if (state == RemotePermissionAvailability.available) {
      final label = permissions.currentLabel;
      return Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          key: const ValueKey('remote-permission-label'),
          onPressed: _openPermissionSheet,
          icon: const Icon(Icons.shield_outlined, size: 16),
          label: Text(
            label == null ? '权限预设' : '权限预设：$label',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ),
      );
    }
    final reason = state == RemotePermissionAvailability.pending
        ? (permissions.probing ? '正在读取权限预设…' : '正在连接电脑…')
        : permissions.unavailableReason ?? '这台电脑未启用权限预设';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline_rounded,
              size: 14,
              color: colors.onSurfaceVariant.withValues(alpha: .6),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                reason,
                key: const ValueKey('remote-permission-unavailable'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.footnote
                    .of(context)
                    .copyWith(
                      color: colors.onSurfaceVariant.withValues(alpha: .75),
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开权限预设弹层：每次打开都重新读目录，失败只在弹层内报错并可重试。
  void _openPermissionSheet() {
    _exitReasoningPanel(keepKeyboard: false);
    final permissions = _permissions;
    if (!permissions.presetsReady) {
      _showStatus(permissions.unavailableReason ?? '这台电脑暂不可切换权限预设。');
      return;
    }
    _focus.unfocus();
    unawaited(permissions.loadCatalog());
    unawaited(
      showRemotePermissionSheet(
        context,
        builder: (_) => ListenableBuilder(
          listenable: permissions,
          builder: (context, _) => RemotePermissionSheet(
            options:
                permissions.catalog?.options ??
                const <RemotePermissionOption>[],
            currentValue: permissions.currentValue,
            loading: permissions.catalogLoading,
            error: permissions.catalogError,
            onRetry: () => unawaited(permissions.loadCatalog()),
            onApply: _applyPermissionPreset,
          ),
        ),
      ),
    );
  }

  /// 提交一次预设切换；返回 null 表示成功（投影已由控制器刷新）。
  ///
  /// 需要风险确认的预设由弹层在勾选确认后才走到这里，页面不再重复询问。
  Future<String?> _applyPermissionPreset(String value) async {
    final failure = await _permissions.apply(value);
    if (!mounted) return failure;
    if (failure != null) return failure;
    final label = permissionPresetLabel(
      value,
      _permissions.catalog?.optionOf(value)?.name,
    );
    _showStatus('权限预设已改为「$label」');
    return null;
  }

  // ------------------------------------------------------------ 待处理交互

  /// 待处理审批/提问取代输入卡，占据同一底部浮层位置。
  ///
  /// 卡片区最多占屏幕高度的 45%，多个请求（或选项很多）时整块滚动，不会把
  /// 输入区挤出屏幕。
  Widget _interactionArea(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 10, 6, 14),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .55,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final request in _interactions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _RemoteInteractionCard(
                    key: ValueKey('${request.id}:${request.version}'),
                    request: request,
                    busy: _busyInteractionId == request.id,
                    error: _interactionErrors[request.id] == null
                        ? null
                        : sanitizeRemoteUiMessage(
                            _interactionErrors[request.id]!,
                          ),
                    onApprove: (allow) =>
                        unawaited(_replyApproval(request, allow: allow)),
                    onFeedback: (text) => unawaited(
                      _replyApproval(request, allow: false, feedback: text),
                    ),
                    canSendFeedback:
                        _capability(remoteConversationSendMethod) ==
                        RemoteCapabilityState.available,
                    onAnswer: (answers) =>
                        unawaited(_answerQuestion(request, answers)),
                    onDismissPlan: () => unawaited(_dismissPlan(request)),
                    onOpenPlan: _openPlanDocument,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 发送前提示：当前会话路由的服务商在这台电脑的模型目录里读取失败。
  ///
  /// 命中后发送会自动改用电脑默认模型，因此提示在发送前给出，动作直接打开模型
  /// 选择。路由换到可用的服务商、目录刷新后不再命中，或同一条路由已经成功发送过
  /// （[_routeConfirmed]）时不再显示。
  Widget? _modelRouteNotice(BuildContext context) {
    final choice = _modelChoice;
    if (choice == null) return null;
    if (!_failedModelProviders.contains(choice.provider)) return null;
    if (_routeConfirmed == choice) return null;
    return _RemoteNoticeBar(
      key: const ValueKey('remote-conversation-model-route-hint'),
      message: '当前会话绑定的模型在电脑上不可用，发送时会自动改用电脑默认模型',
      icon: Icons.sync_problem_rounded,
      accent: Theme.of(context).colorScheme.warning,
      actionLabel: '选择模型',
      onAction:
          _capability(remoteConversationApiCallMethod) ==
              RemoteCapabilityState.available
          ? () => unawaited(_openModelSheet())
          : null,
    );
  }

  /// 凭据类发送失败的可操作提示：动作直接打开模型选择。
  Widget? _credentialNotice(BuildContext context) {
    final hint = _credentialHint;
    if (hint == null) return null;
    return _RemoteNoticeBar(
      key: const ValueKey('remote-conversation-credential-hint'),
      message: hint,
      actionLabel: '选择模型',
      onAction:
          _capability(remoteConversationApiCallMethod) ==
              RemoteCapabilityState.available
          ? () => unawaited(_openModelSheet())
          : null,
    );
  }

  /// 会话指令结果条：成功、失败与「电脑没识别出这条指令」都常驻，直到下一条
  /// 指令、一次成功发送或用户点「知道了」。
  Widget? _commandResultBar(BuildContext context) {
    final entry = _commandResult;
    if (entry == null) return null;
    final result = entry.result;
    final colors = Theme.of(context).colorScheme;
    return _RemoteNoticeBar(
      key: ValueKey('remote-conversation-command-${result.kind.name}'),
      message: _commandMessage(entry.line, result),
      icon: switch (result.kind) {
        RemoteCommandKind.success => Icons.check_circle_outline_rounded,
        RemoteCommandKind.error => Icons.error_outline_rounded,
        RemoteCommandKind.unrecognized => Icons.help_outline_rounded,
      },
      accent: result.kind == RemoteCommandKind.success
          ? colors.success
          : colors.error,
      actionLabel: '知道了',
      onAction: () => setState(() => _commandResult = null),
    );
  }

  /// 指令结果条上的文案：未识别时带上原文，说明它没有作为消息发给模型。
  static String _commandMessage(String line, RemoteCommandResult result) =>
      result.kind == RemoteCommandKind.unrecognized
      ? '电脑上没有这条指令：$line。它没有发给模型。'
      : sanitizeRemoteUiMessage(result.displayText);

  /// 常驻的可见说明：自动切换模型成功，或切换/重发仍失败时同时给出两次原因。
  ///
  /// 它不随 3 秒状态条消失，用户点「知道了」才收起；发送成功不会把它吞掉，
  /// 否则用户看不到消息为什么换了模型。
  Widget? _persistentNoticeBar(BuildContext context) {
    final notice = _persistentNotice;
    if (notice == null) return null;
    return _RemoteNoticeBar(
      key: const ValueKey('remote-conversation-fallback-notice'),
      message: sanitizeRemoteUiMessage(notice),
      actionLabel: '知道了',
      onAction: () => setState(() => _persistentNotice = null),
    );
  }

  /// 答复审批：受理后宿主会推 `interactions.changed`，卡片随之消失。
  Future<void> _replyApproval(
    RemotePendingInteraction request, {
    required bool allow,
    String? feedback,
  }) async {
    if (_busyInteractionId != null) return;
    setState(() {
      _busyInteractionId = request.id;
      _interactionErrors.remove(request.id);
    });
    try {
      final reply = await _source.replyApproval(
        request.id,
        request.version,
        allow: allow,
      );
      if (!mounted) return;
      if (reply.accepted) {
        if (feedback case final text?) {
          try {
            await _source.send(text);
            if (mounted) {
              unawaited(_refreshSessionTasks());
              unawaited(_pullNewer());
            }
          } on Object catch (error) {
            if (mounted) {
              setState(() {
                _input.text = text;
                _draftEmpty = false;
                _draftIsCommand = false;
                _composerMode = PocketComposerMode.composing;
                _persistentNotice =
                    '审批已拒绝，但补充指令未发送：${sanitizeRemoteUiMessage(error.toString())}';
              });
            }
          }
        } else {
          _showStatus(allow ? '已允许一次' : '已拒绝');
        }
      } else {
        setState(
          () => _interactionErrors[request.id] =
              reply.message ??
              (reply.requestStillPending ? '电脑还没有受理这次答复，请重试。' : '这个请求已处理或失效。'),
        );
      }
      // 被拒绝或结果未确认时核对一次快照：宿主可能已经推进了版本，或请求
      // 已不在等待。受理成功时快照由 interactions.changed 推送，不用再读。
      if (!reply.accepted) await _source.refreshInteractions();
    } on RuntimeTransportFailure catch (failure) {
      if (mounted) {
        setState(() => _interactionErrors[request.id] = failure.message);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _interactionErrors[request.id] = '答复失败：$error');
      }
    } finally {
      if (mounted) setState(() => _busyInteractionId = null);
    }
  }

  /// 提交提问答复；[answers] 已由卡片按问题顺序组好。
  Future<void> _answerQuestion(
    RemotePendingInteraction request,
    List<RemoteQuestionAnswer> answers,
  ) async {
    if (_busyInteractionId != null) return;
    setState(() {
      _busyInteractionId = request.id;
      _interactionErrors.remove(request.id);
    });
    try {
      final reply = await _source.answerQuestion(
        request.id,
        request.version,
        answers,
      );
      if (!mounted) return;
      if (reply.accepted) {
        _showStatus('答复已提交');
        // 计划审核被批准后计划模式会退出：控制流正常会推投影增量，这里再读一次
        // 权威状态，避免宿主没有推送时计划条残留。
        if (_isPlanReview(request)) unawaited(_goalPlan.refresh());
      } else {
        setState(
          () => _interactionErrors[request.id] =
              reply.message ??
              (reply.requestStillPending ? '电脑还没有受理这次答复，请重试。' : '这个请求已处理或失效。'),
        );
      }
      if (!reply.accepted) await _source.refreshInteractions();
    } on RuntimeTransportFailure catch (failure) {
      if (mounted) {
        setState(() => _interactionErrors[request.id] = failure.message);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _interactionErrors[request.id] = '提交回答失败：$error');
      }
    } finally {
      if (mounted) setState(() => _busyInteractionId = null);
    }
  }

  // ------------------------------------------------------------ 模型选择

  /// 待处理提问是否是计划审核（`intent.kind == 'plan-review'`）。
  ///
  /// 与卡片里的判定共用 `planReviewOf`，不另写一套规则；判定不成立时按普通
  /// 提问处理（不额外刷新计划投影）。
  static bool _isPlanReview(RemotePendingInteraction request) =>
      request.kind == RemoteInteractionKind.question &&
      planReviewOf(<QuestionAnswerDraft>[
            for (final question in request.questions)
              QuestionAnswerDraft(question.toJson()),
          ]) !=
          null;

  /// 打开模型选择弹层；应用成功由弹层回调，数据源随后推新的选择。
  Future<void> _openModelSheet() async {
    _exitReasoningPanel(keepKeyboard: false);
    if (_source.phase != RemoteConnectionPhase.ready) {
      _showStatus('先连接这台电脑');
      return;
    }
    if (!_source.supports(remoteConversationApiCallMethod)) {
      _showStatus('这台电脑不支持选择模型。');
      return;
    }
    // 弹层取代输入焦点，先收起键盘再展开。
    _focus.unfocus();
    final applied = await showModalBottomSheet<RemoteModelChoice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: .4),
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (sheetContext) => _RemoteModelSheet(
        source: _source,
        current: _modelChoice,
        onApplied: (choice) => Navigator.of(sheetContext).pop(choice),
      ),
    );
    if (!mounted || applied == null) return;
    setState(() {
      _credentialHint = null;
      // 用户手动换了模型，自动切换的说明不再需要常驻。
      _persistentNotice = null;
    });
    _showStatus('已切换模型：${applied.label}');
  }

  /// 推理强度面板：当前模型、档位与切换入口。
  ///
  /// 档位来自 `session.modelCatalog` 里当前模型声明的 `reasoning.efforts`；目录
  /// 还没读到时只显示模型名与一行进度，读取失败时显示原因与重试。没有档位的
  /// 模型（或目录里找不到当前模型）只显示模型名，不给空滑杆。
  PocketReasoningPanel _reasoningPanel(bool canSelectModel) {
    final choice = _modelChoice;
    final model = _modelOf(_reasoningCatalog, choice);
    final reasoning = model?.reasoning;
    final efforts = reasoning?.efforts ?? const <RemoteReasoningLevel>[];
    final selected = choice?.reasoningEffort ?? reasoning?.defaultEffort;
    final stops = <PocketReasoningStop>[
      for (final effort in efforts)
        PocketReasoningStop(
          id: effort.id,
          label: reasoningEffortLabel(effort.id, fallback: effort.name),
        ),
    ];
    return PocketReasoningPanel(
      modelLabel: model?.name ?? choice?.label ?? '当前模型',
      effortLabel: selected == null ? '默认' : reasoningEffortLabel(selected),
      stops: stops,
      selectedId: selected,
      loading: _reasoningLoading && _reasoningCatalog == null,
      error: _reasoningError,
      busy: _reasoningApplying,
      onOpenModels: canSelectModel ? _openModelsFromReasoningPanel : null,
      onRetry: () => unawaited(_loadReasoningCatalog()),
      onSelected: canSelectModel
          ? (effort) => unawaited(_applyReasoningEffort(effort))
          : null,
    );
  }

  /// 模型目录里按当前选择找到模型声明；找不到时为 null（面板只显示模型名）。
  static RemoteModelInfo? _modelOf(
    RemoteModelCatalog? catalog,
    RemoteModelChoice? choice,
  ) {
    if (catalog == null || choice == null) return null;
    for (final group in catalog.groups) {
      if (group.id != choice.provider) continue;
      for (final model in group.models) {
        if (model.id == choice.model) return model;
      }
    }
    return null;
  }

  /// 打开/收起推理面板。
  ///
  /// 打开时立刻把焦点与输入法还给输入框，并在下一帧再确认一次：点按工具条按钮
  /// 时焦点可能在触摸抬手后才交还，晚一拍会让键盘在面板出现的同时被收起。面板
  /// 本身不依赖键盘 insets 的瞬时值，键盘被系统收起也保持可见。
  void _toggleReasoningPanel() {
    if (_composerMode == PocketComposerMode.picker) {
      _exitReasoningPanel();
      return;
    }
    setState(() => _composerMode = PocketComposerMode.picker);
    _requestInputFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _composerMode != PocketComposerMode.picker) return;
      _requestInputFocus();
    });
    if (_reasoningCatalog == null && !_reasoningLoading) {
      unawaited(_loadReasoningCatalog());
    }
  }

  /// 收起推理面板回到输入态。
  ///
  /// [keepKeyboard] 为 true（点表盘、发送）时把焦点与键盘还给输入框；为 false
  /// （点聊天区、打开别的弹层）时按当前键盘与草稿决定：键盘收起且没有草稿就回到
  /// 缩小态，否则回到展开态但不主动唤起键盘。
  void _exitReasoningPanel({bool keepKeyboard = true}) {
    if (_composerMode != PocketComposerMode.picker) return;
    final keyboardVisible = View.of(context).viewInsets.bottom > 0;
    final expand =
        keepKeyboard || keyboardVisible || _input.text.trim().isNotEmpty;
    setState(
      () => _composerMode = expand
          ? PocketComposerMode.composing
          : PocketComposerMode.browse,
    );
    if (keepKeyboard) {
      _requestInputFocus();
    } else if (!expand && _focus.hasFocus) {
      _focus.unfocus();
    }
  }

  /// 从推理面板第一行打开完整模型选择弹层（面板先收起）。
  void _openModelsFromReasoningPanel() {
    _exitReasoningPanel(keepKeyboard: false);
    unawaited(_openModelSheet());
  }

  /// 读一次模型目录：只为推理面板的档位与默认值，失败后可在面板里重试。
  Future<void> _loadReasoningCatalog() async {
    if (_reasoningLoading) return;
    setState(() {
      _reasoningLoading = true;
      _reasoningError = null;
    });
    try {
      final catalog = await _source.fetchModelCatalog();
      if (!mounted) return;
      setState(() {
        _reasoningCatalog = catalog;
        _reasoningLoading = false;
      });
    } on RuntimeTransportFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _reasoningError = failure.message;
        _reasoningLoading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _reasoningError = '读取模型目录失败：$error';
        _reasoningLoading = false;
      });
    }
  }

  /// 提交一次推理强度切换：与模型弹层同一个 `selectModel`，不另写一套应用逻辑。
  Future<void> _applyReasoningEffort(String effort) async {
    final current = _modelChoice;
    if (current == null || _reasoningApplying) return;
    if (current.reasoningEffort == effort) return;
    setState(() => _reasoningApplying = true);
    try {
      await _source.selectModel(
        RemoteModelChoice(
          provider: current.provider,
          model: current.model,
          reasoningEffort: effort,
        ),
      );
      if (!mounted) return;
      setState(() {
        _credentialHint = null;
        // 用户手动换了强度，自动切换/凭据提示不再需要常驻。
        _persistentNotice = null;
      });
      _showStatus('推理强度已改为「${reasoningEffortLabel(effort)}」');
    } on RuntimeTransportFailure catch (failure) {
      if (mounted) _showStatus('切换推理强度失败：${failure.message}');
    } on Object catch (error) {
      if (mounted) _showStatus('切换推理强度失败：$error');
    } finally {
      if (mounted) setState(() => _reasoningApplying = false);
    }
  }

  // ------------------------------------------------------------ 会话操作

  Future<void> _rename() async {
    if (_capability(remoteConversationRenameMethod) !=
        RemoteCapabilityState.available) {
      _showStatus('这台电脑不支持重命名会话。');
      return;
    }
    final next = await showDialog<String>(
      context: context,
      builder: (_) => _RemoteRenameDialog(initialTitle: _title),
    );
    if (!mounted || next == null) return;
    final title = next.trim();
    if (title.isEmpty || title == _title) return;
    try {
      await _source.rename(title);
      if (!mounted) return;
      setState(() => _title = title);
      _showStatus('已重命名');
    } on RuntimeTransportFailure catch (failure) {
      if (mounted) _showStatus(failure.message);
    }
  }

  /// 归档当前会话：确认后回写电脑，成功时先给出可见结果再离开会话页。
  ///
  /// 归档后的会话会从首页项目列表里消失，因此失败时留在页面上说明原因，成功时
  /// 用 SnackBar 告诉用户去哪里找回；归档入口本身只在方法表支持时可用。
  Future<void> _archive() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('归档会话'),
        content: Text('归档后「$_title」会离开项目列表，可以在「已归档任务」里查看和恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('remote-archive-confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('归档'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await _source.archive();
    } on RuntimeTransportFailure catch (failure) {
      if (mounted) _showStatus('归档失败：${failure.message}');
      return;
    } on Object catch (error) {
      if (mounted) _showStatus('归档失败：$error');
      return;
    }
    if (!mounted) return;
    // 结果交给根 ScaffoldMessenger：会话页即将出栈，提示条要留在首页上可见。
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text('已归档「$_title」')));
    Navigator.of(context).maybePop();
  }

  /// 打开「本次变更」页：独立的全屏目的地，数据源按次创建并交给页面持有。
  ///
  /// 入口本身按方法表置灰，这里再兜底判断一次：数据源创建不出来时只给可见说明，
  /// 不推一个读不到内容的页面。
  Future<void> _openWorkspaceChanges() async {
    final workspaceSource = _source.createWorkspaceChangesSource();
    if (workspaceSource == null) {
      _showStatus('这台电脑不支持查看本次变更。');
      return;
    }
    await openDestination<void>(
      context,
      destination: RemoteWorkspaceDiffPage.routeDestination,
      dragBack: false,
      builder: (_) => RemoteWorkspaceDiffPage(source: workspaceSource),
    );
  }

  /// 打开远程终端页：独立的全屏目的地，同一目的地不会叠第二层。
  ///
  /// 入口本身按能力三态置灰，这里再兜底判断一次：还没连上或那台电脑不支持终端时
  /// 只给可见说明，不推一个只会显示「正在连接 / 不支持」的页面。
  Future<void> _openTerminal() async {
    final connection = widget.terminalConnection;
    if (connection == null) {
      _showStatus('这台电脑不支持终端。');
      return;
    }
    final capability = RemoteTerminalCapability.of(connection);
    if (capability != RemoteTerminalCapability.available) {
      _showStatus(capability.reason ?? '这台电脑暂时不能使用终端。');
      return;
    }
    await openDestination<void>(
      context,
      destination: RemoteSessionTerminalPage.routeDestination,
      builder: (_) => RemoteSessionTerminalPage(
        connection: connection,
        sessionId: widget.source.sessionId,
      ),
    );
  }

  Future<void> _showSessionInfo() async {
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('会话信息'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _RemoteInfoRow(label: '设备', value: widget.deviceName),
              _RemoteInfoRow(label: '项目', value: widget.projectName),
              _RemoteInfoRow(label: '标题', value: _title),
              _RemoteInfoRow(
                label: '消息',
                value: '${_projection.entries.length} 条',
              ),
              _RemoteInfoRow(label: '事件', value: '${_events.length} 个'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _copySessionInfo() => _copy(
    '$_title\n${widget.deviceName} · ${widget.projectName}\n'
        '${_projection.entries.length} 条消息 · ${_events.length} 个事件',
    '会话信息',
  );

  Future<void> _copy(String text, String label) async {
    if (text.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } on PlatformException {
      // 剪贴板被系统拒绝时不静默：把原因放到输入区上方，用户可以重试。
      if (mounted) _showStatus('复制$label失败，请重试');
      return;
    } on MissingPluginException {
      // 没有原生剪贴板的环境（例如宿主预览）同样给出可见反馈。
      if (mounted) _showStatus('复制$label失败，请重试');
      return;
    }
    if (mounted) _showStatus('已复制$label');
  }

  void _showStatus(String message) {
    // 诊断日志保留原始错误；用户可见文案统一脱敏。
    debugPrint('remote-ui-status(raw): $message');
    final visible = sanitizeRemoteUiMessage(message);
    _statusTimer?.cancel();
    setState(() => _status = visible);
    _statusTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _status = null);
    });
  }
}

/// 会话页顶部的单行提示条：说明文字加可选动作。
///
/// 默认是错误样式（红色图标与文字）；发送前提示与会话指令结果用 [accent] 与
/// [icon] 区分「提醒」和「成功」，动作按钮保持同一套交互。
class _RemoteNoticeBar extends StatelessWidget {
  const _RemoteNoticeBar({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.icon = Icons.info_outline_rounded,
    this.accent,
  });

  /// 已经可以直接展示的中文说明（协议 §9.4）。
  final String message;

  /// 动作文案；为空时不显示动作。
  final String? actionLabel;

  /// 动作回调；为空时动作不可点。
  final VoidCallback? onAction;

  /// 左侧图标；默认是信息图标。
  final IconData icon;

  /// 图标与文字的强调色；为空时用主题的错误色。
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = accent ?? colors.error;
    final actionLabel = this.actionLabel;
    final onAction = this.onAction;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Semantics(
        liveRegion: true,
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                message,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.footnote.of(context).copyWith(color: color),
              ),
            ),
            if (actionLabel != null && onAction != null)
              TextButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
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

/// 会话信息里的一行「标签：值」。
class _RemoteInfoRow extends StatelessWidget {
  const _RemoteInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(value, style: AppTextStyle.subheadline.of(context)),
          ),
        ],
      ),
    );
  }
}

/// 重命名会话的输入弹窗；控制器由弹窗自己持有，跟随时序一起释放。
class _RemoteRenameDialog extends StatefulWidget {
  const _RemoteRenameDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_RemoteRenameDialog> createState() => _RemoteRenameDialogState();
}

class _RemoteRenameDialogState extends State<_RemoteRenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialTitle)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.initialTitle.length,
        );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('重命名会话'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submit(),
      decoration: const InputDecoration(hintText: '会话标题'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      TextButton(onPressed: _submit, child: const Text('保存')),
    ],
  );
}

/// 48dp 的圆形玻璃图标按钮。
///
/// 共享的 [GlassButton] 视觉尺寸上限为 44dp，达不到远程外壳要求的 48dp 触摸目标，
/// 因此这里用同一套基元（[LiquidGlass]、[ElasticPress]）按 48dp 重建同等外观。
class _RemoteIconControl extends StatelessWidget {
  const _RemoteIconControl({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;

  /// 无障碍文案，同时作为长按提示。
  final String label;

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final glass = LiquidGlassScope.of(context);
    final colors = Theme.of(context).colorScheme;
    return ElasticPress(
      enabled: onPressed != null,
      preserveAspectRatio: true,
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        icon: Icon(icon),
        style:
            IconButton.styleFrom(
              fixedSize: const Size.square(48),
              minimumSize: const Size.square(48),
              maximumSize: const Size.square(48),
              iconSize: 24,
              padding: EdgeInsets.zero,
              shape: const CircleBorder(),
              backgroundColor: glass ? Colors.transparent : null,
              disabledBackgroundColor: glass ? Colors.transparent : null,
              // 玻璃面自己负责按下时的亮度，水波纹会在玻璃后面留下多余痕迹。
              overlayColor: Colors.transparent,
              splashFactory: NoSplash.splashFactory,
            ).copyWith(
              backgroundBuilder: glass
                  ? (context, states, child) => LiquidGlass(
                      style: PocketGlass.regular(colors),
                      pressed: states.contains(WidgetState.pressed),
                      borderRadius: AppRadius.full,
                      child: child,
                    )
                  : null,
            ),
      ),
    );
  }
}

/// 输入区上方的待处理交互卡片：审批给「允许一次 / 拒绝」，提问给选项与提交。
///
/// 提问的选择状态属于本卡片（键里带 `id:version`，宿主推进版本就重建）：单选
/// 选中选项时清空自定义文字，填写自定义文字时清空选项；多选允许两者同时提交。
/// 卡片只回调页面，不直接调数据源，错误与忙碌状态由页面统一持有。
class _RemoteInteractionCard extends StatefulWidget {
  const _RemoteInteractionCard({
    super.key,
    required this.request,
    required this.busy,
    required this.error,
    required this.onApprove,
    required this.onFeedback,
    required this.canSendFeedback,
    required this.onAnswer,
    required this.onDismissPlan,
    required this.onOpenPlan,
  });

  /// 待处理的交互。
  final RemotePendingInteraction request;

  /// 是否正在提交这次答复。
  final bool busy;

  /// 上一次答复的可见错误；没有时为 null。
  final String? error;

  /// 审批回调：true = 允许一次，false = 拒绝。
  final ValueChanged<bool> onApprove;

  /// 拒绝当前调用后，将补充指令作为会话消息发送。
  final ValueChanged<String> onFeedback;

  final bool canSendFeedback;

  /// 提问回调：按问题顺序组装好的答复。
  final ValueChanged<List<RemoteQuestionAnswer>> onAnswer;

  /// 计划审核「请求修改」：`interactions.dismiss`，不发送答案。
  final VoidCallback onDismissPlan;

  /// 计划原文查看回调：打开既有 [ChatPlanDocumentPage]。
  final void Function(RemoteQuestion question, String markdown) onOpenPlan;

  @override
  State<_RemoteInteractionCard> createState() => _RemoteInteractionCardState();
}

class _RemoteInteractionCardState extends State<_RemoteInteractionCard> {
  final TextEditingController _feedback = TextEditingController();
  final Map<String, Set<String>> _selected = <String, Set<String>>{};
  final Map<String, TextEditingController> _custom =
      <String, TextEditingController>{};

  /// 计划审核判定：与本地审批页共用 `planReviewOf` 的规则，不成立时为 null。
  late final ({String id, String approve, String plan})? _planReview =
      planReviewOf(<QuestionAnswerDraft>[
        for (final question in widget.request.questions)
          QuestionAnswerDraft(question.toJson()),
      ]);

  @override
  void initState() {
    super.initState();
    for (final question in widget.request.questions) {
      _selected[question.id] = <String>{};
      _custom[question.id] = TextEditingController();
    }
  }

  @override
  void dispose() {
    _feedback.dispose();
    for (final controller in _custom.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _isApproval => widget.request.kind == RemoteInteractionKind.approval;

  String get _commandPreview {
    final summary = widget.request.summary;
    if (summary == null || summary.isEmpty) {
      return widget.request.toolName ?? '工具调用';
    }
    final first = summary.split(' · ').first;
    return first.startsWith('command: ') ? first.substring(9) : first;
  }

  /// 单个问题是否已经可以提交。
  ///
  /// 单选时选项与自定义文字互斥（输入时由本卡片保证）；多选时两者可以同时使用。
  bool _complete(RemoteQuestion question) {
    final selected = _selected[question.id] ?? const <String>{};
    final custom = _custom[question.id]?.text.trim() ?? '';
    return selected.isNotEmpty || custom.isNotEmpty;
  }

  bool get _canSubmit =>
      !widget.busy &&
      widget.request.questions.isNotEmpty &&
      widget.request.questions.every(_complete);

  List<RemoteQuestionAnswer> _answers() => <RemoteQuestionAnswer>[
    for (final question in widget.request.questions)
      RemoteQuestionAnswer(
        id: question.id,
        selected: List<String>.of(_selected[question.id] ?? const <String>{}),
        custom: _customText(question),
      ),
  ];

  /// 去掉空白后的自定义回答；空字符串不提交（协议要求 `custom` 可省略）。
  String? _customText(RemoteQuestion question) {
    final text = _custom[question.id]?.text.trim() ?? '';
    return text.isEmpty ? null : text;
  }

  void _choose(RemoteQuestion question, RemoteQuestionOption option) {
    if (widget.busy) return;
    final selected = _selected[question.id]!;
    setState(() {
      if (question.multiSelect) {
        if (!selected.remove(option.label)) selected.add(option.label);
      } else {
        selected
          ..clear()
          ..add(option.label);
        _custom[question.id]?.clear();
      }
    });
  }

  void _writeCustom(RemoteQuestion question, String text) {
    if (widget.busy) return;
    final selected = _selected[question.id]!;
    setState(() {
      // 单选问题不能同时提交选项与自定义文字；多选允许。
      if (!question.multiSelect && text.trim().isNotEmpty) selected.clear();
    });
  }

  void _submitFeedback() {
    final text = _feedback.text.trim();
    if (text.isEmpty || widget.busy || !widget.canSendFeedback) return;
    FocusScope.of(context).unfocus();
    widget.onFeedback(text);
  }

  @override
  Widget build(BuildContext context) {
    if (_isApproval) return _approvalCard(context);
    final colors = Theme.of(context).colorScheme;
    final request = widget.request;
    return Container(
      key: ValueKey('remote-interaction-${request.id}'),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: AppRadius.lg,
        border: Border.all(color: colors.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                _isApproval
                    ? Icons.verified_user_outlined
                    : _planReview != null
                    ? Icons.edit_note_rounded
                    : Icons.question_answer_outlined,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _isApproval
                      ? '需要授权：${request.toolName ?? '工具调用'}'
                      : _planReview != null
                      ? '计划审核'
                      : 'Agent 提问',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.subheadline.of(context, emphasized: true),
                ),
              ),
            ],
          ),
          if (_planReview case final review?) ...[
            // 计划审核：标题/摘要来自 `planReviewPreview`，批准回 `intent.approve`
            // 选项，请求修改走 `interactions.dismiss`，原文推入既有阅读器。
            _planReviewBody(context, review),
          ] else ...[
            for (final question in request.questions) ...[
              const SizedBox(height: 8),
              if (question.header case final header?)
                Text(
                  header,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.footnote
                      .of(context)
                      .copyWith(color: colors.onSurfaceVariant),
                ),
              Text(
                question.question,
                style: AppTextStyle.subheadline.of(context),
              ),
              if (question.detail case final detail?)
                Text(
                  detail,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.footnote
                      .of(context)
                      .copyWith(color: colors.onSurfaceVariant),
                ),
              const SizedBox(height: 6),
              for (final option in question.options)
                _optionTile(question, option),
              const SizedBox(height: 4),
              TextField(
                key: ValueKey(
                  'remote-question-custom-${request.id}-${question.id}',
                ),
                controller: _custom[question.id],
                enabled: !widget.busy,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: question.options.isEmpty
                      ? '输入你的回答'
                      : question.multiSelect
                      ? '补充自定义回答（可选）'
                      : '或填写自定义回答',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (text) => _writeCustom(question, text),
              ),
            ],
            const SizedBox(height: 10),
            PocketButton(
              key: ValueKey('remote-question-submit-${request.id}'),
              onPressed: _canSubmit ? () => widget.onAnswer(_answers()) : null,
              child: Text(widget.busy ? '正在提交' : '提交回答'),
            ),
          ],
          if (widget.error case final error?) ...[
            const SizedBox(height: 8),
            Text(
              error,
              key: ValueKey('remote-interaction-error-${request.id}'),
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: colors.error),
            ),
          ],
        ],
      ),
    );
  }

  Widget _approvalCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final request = widget.request;
    final title = request.reason?.trim().isNotEmpty == true
        ? request.reason!.trim()
        : '是否允许本次 ${request.toolName ?? '工具'} 调用？';
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: .15),
            blurRadius: 32,
            spreadRadius: -8,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: GlassSurface(
        key: ValueKey('remote-interaction-${request.id}'),
        radius: 30,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.headline.of(context, emphasized: true),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _commandPreview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.subheadline
                      .of(context)
                      .copyWith(
                        fontFamily: 'monospace',
                        color: colors.onSurfaceVariant,
                      ),
                ),
              ),
              const SizedBox(height: 18),
              FilledButton(
                key: ValueKey('remote-approval-allow-${request.id}'),
                onPressed: widget.busy ? null : () => widget.onApprove(true),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.brightness == Brightness.dark
                      ? Colors.white
                      : Colors.black,
                  foregroundColor: colors.brightness == Brightness.dark
                      ? Colors.black
                      : Colors.white,
                  minimumSize: const Size.fromHeight(42),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                child: Text(widget.busy ? '正在提交' : '允许一次'),
              ),
              const SizedBox(height: 16),
              Divider(color: colors.outlineVariant.withValues(alpha: .7)),
              const SizedBox(height: 8),
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    Icon(
                      Icons.edit_outlined,
                      size: 20,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        key: ValueKey('remote-approval-feedback-${request.id}'),
                        controller: _feedback,
                        enabled: !widget.busy && widget.canSendFeedback,
                        maxLines: 1,
                        textInputAction: TextInputAction.send,
                        onTapOutside: (_) =>
                            FocusManager.instance.primaryFocus?.unfocus(),
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _submitFeedback(),
                        decoration: InputDecoration.collapsed(
                          hintText: widget.canSendFeedback
                              ? '告诉 Agent 要做什么'
                              : '这台电脑暂不支持补充指令',
                        ),
                      ),
                    ),
                    if (_feedback.text.trim().isNotEmpty)
                      IconButton(
                        key: ValueKey(
                          'remote-approval-feedback-send-${request.id}',
                        ),
                        tooltip: '发送补充指令并拒绝本次调用',
                        onPressed: widget.busy ? null : _submitFeedback,
                        icon: const Icon(Icons.arrow_upward_rounded),
                      ),
                    OutlinedButton(
                      key: ValueKey('remote-approval-deny-${request.id}'),
                      onPressed: widget.busy
                          ? null
                          : () => widget.onApprove(false),
                      style: OutlinedButton.styleFrom(
                        shape: const StadiumBorder(),
                        minimumSize: const Size(0, 42),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                      ),
                      child: const Text('拒绝'),
                    ),
                  ],
                ),
              ),
              if (widget.error case final error?) ...[
                const SizedBox(height: 8),
                Text(
                  error,
                  key: ValueKey('remote-interaction-error-${request.id}'),
                  style: AppTextStyle.footnote
                      .of(context)
                      .copyWith(color: colors.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 计划审核卡片的正文：标题、摘要、原文入口与两个决定按钮。
  ///
  /// 按钮只回调页面（与审批/提问卡片同一约定），错误与忙碌状态由页面统一持有；
  /// 「批准」回 `intent.approve` 选项，「请求修改」走 `interactions.dismiss`。
  Widget _planReviewBody(
    BuildContext context,
    ({String id, String approve, String plan}) review,
  ) {
    final colors = Theme.of(context).colorScheme;
    final request = widget.request;
    final preview = planReviewPreview(review.plan);
    final title = preview.title.isEmpty
        ? request.questions.single.question
        : preview.title;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyle.subheadline.of(context, emphasized: true),
        ),
        if (preview.summary.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            preview.summary,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyle.footnote
                .of(context)
                .copyWith(color: colors.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 10),
        PocketButton.tonal(
          key: ValueKey('remote-plan-open-${request.id}'),
          onPressed: widget.busy
              ? null
              : () => widget.onOpenPlan(request.questions.single, review.plan),
          child: const Text('单独查看完整计划'),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: PocketButton.tonal(
                key: ValueKey('remote-plan-dismiss-${request.id}'),
                onPressed: widget.busy ? null : widget.onDismissPlan,
                child: Text(widget.busy ? '正在提交' : '请求修改'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: PocketButton(
                key: ValueKey('remote-plan-approve-${request.id}'),
                onPressed: widget.busy
                    ? null
                    : () => widget.onAnswer(<RemoteQuestionAnswer>[
                        RemoteQuestionAnswer(
                          id: review.id,
                          selected: <String>[review.approve],
                        ),
                      ]),
                child: Text(widget.busy ? '正在提交' : '批准计划'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _optionTile(RemoteQuestion question, RemoteQuestionOption option) {
    final colors = Theme.of(context).colorScheme;
    final selected = _selected[question.id]?.contains(option.label) ?? false;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        selected: selected,
        child: Material(
          color: selected
              ? colors.primaryContainer
              : colors.surfaceContainerHighest,
          borderRadius: AppRadius.md,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey(
              'remote-question-option-${widget.request.id}-'
              '${question.id}-${option.label}',
            ),
            onTap: widget.busy ? null : () => _choose(question, option),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    size: 18,
                    color: selected ? colors.primary : colors.outline,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          option.label,
                          style: AppTextStyle.subheadline.of(context),
                        ),
                        if (option.description case final description?)
                          Text(
                            description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyle.footnote
                                .of(context)
                                .copyWith(color: colors.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 会话模型选择弹层：模型目录（`session.modelCatalog`）、当前选择与推理强度。
///
/// 目录只在打开时读一次；应用走 `session.selectModel`，成功后由调用方收起弹层。
/// 失败原因留在弹层里，不关闭弹层，用户可以直接重试或换一个模型。
class _RemoteModelSheet extends StatefulWidget {
  const _RemoteModelSheet({
    required this.source,
    required this.current,
    required this.onApplied,
  });

  /// 会话数据源。
  final RemoteConversationSource source;

  /// 打开弹层时的当前选择，用于高亮与「已是当前模型」判断。
  final RemoteModelChoice? current;

  /// 应用成功后的回调（由调用方收起弹层）。
  final ValueChanged<RemoteModelChoice> onApplied;

  @override
  State<_RemoteModelSheet> createState() => _RemoteModelSheetState();
}

class _RemoteModelSheetState extends State<_RemoteModelSheet> {
  RemoteModelCatalog? _catalog;
  RemoteModelChoice? _selected;
  bool _loading = true;
  bool _applying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selected = widget.current;
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final catalog = await widget.source.fetchModelCatalog();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _loading = false;
      });
    } on RuntimeTransportFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _error = failure.message;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '读取模型目录失败：$error';
        _loading = false;
      });
    }
  }

  RemoteModelInfo? get _selectedModel {
    final catalog = _catalog;
    final selected = _selected;
    if (catalog == null || selected == null) return null;
    for (final group in catalog.groups) {
      if (group.id != selected.provider) continue;
      for (final model in group.models) {
        if (model.id == selected.model) return model;
      }
    }
    return null;
  }

  bool get _isCurrent => _selected == widget.current;

  bool get _canApply =>
      _selected != null && !_applying && !_loading && !_isCurrent;

  void _choose(RemoteModelGroup group, RemoteModelInfo model) {
    if (_applying) return;
    setState(() {
      // 换模型时清掉推理强度：新模型不一定声明同一档位。
      _selected = RemoteModelChoice(provider: group.id, model: model.id);
      _error = null;
    });
  }

  void _chooseEffort(String? effort) {
    final selected = _selected;
    if (selected == null || _applying) return;
    setState(() {
      _selected = RemoteModelChoice(
        provider: selected.provider,
        model: selected.model,
        reasoningEffort: effort,
      );
    });
  }

  Future<void> _apply() async {
    final selected = _selected;
    if (selected == null || !_canApply) return;
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      await widget.source.selectModel(selected);
      if (!mounted) return;
      widget.onApplied(selected);
    } on RuntimeTransportFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _error = failure.message;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _error = '切换模型失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 目录还没读到时错误显示在正文里；已有目录时错误（应用失败）显示在按钮上方。
    final error = _catalog == null ? null : _error;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .82,
          ),
          child: GlassSurface(
            radius: AppCorner.xxl,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 6),
                SizedBox(
                  height: 52,
                  child: Row(
                    children: [
                      const SizedBox(width: 52),
                      Expanded(
                        child: Text(
                          '选择会话模型',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: AppTextStyle.headline.of(
                            context,
                            emphasized: true,
                          ),
                        ),
                      ),
                      _RemoteIconControl(
                        icon: Icons.close_rounded,
                        label: '关闭模型选择',
                        onPressed: () => Navigator.maybePop(context),
                      ),
                    ],
                  ),
                ),
                Flexible(child: _body(context)),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: Text(
                      error,
                      key: const ValueKey('remote-model-error'),
                      style: AppTextStyle.footnote
                          .of(context)
                          .copyWith(color: colors.error),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: PocketButton(
                    key: const ValueKey('remote-model-apply'),
                    onPressed: _canApply ? _apply : null,
                    child: Text(
                      _applying
                          ? '正在切换…'
                          : _isCurrent
                          ? '已是当前模型'
                          : '应用此模型',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final catalog = _catalog;
    final current = widget.current;
    if (_loading && catalog == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (catalog == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Text(_error ?? '这台电脑还没有可用的模型。', textAlign: TextAlign.center),
      );
    }
    final selectedModel = _selectedModel;
    final reasoning = selectedModel?.reasoning;
    final efforts = reasoning?.efforts ?? const <RemoteReasoningLevel>[];
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
            child: Text(
              current == null ? '当前会话还没有模型' : '当前：${current.label}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          for (final failure in catalog.failures)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: Text(
                failure,
                style: AppTextStyle.footnote
                    .of(context)
                    .copyWith(color: colors.error),
              ),
            ),
          if (catalog.groups.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
              child: Text(
                '这台电脑还没有可用的模型。请先在电脑上登录账号或配置服务商。',
                style: AppTextStyle.footnote.of(context),
              ),
            ),
          for (final group in catalog.groups)
            PocketSection(
              title: group.name,
              children: [
                for (final model in group.models) _modelTile(group, model),
              ],
            ),
          if (efforts.isNotEmpty)
            PocketSection(
              title: '推理强度',
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SegmentedControl<String?>(
                    key: const ValueKey('remote-model-reasoning'),
                    segments: [
                      (null, '默认'),
                      for (final effort in efforts)
                        (
                          effort.id,
                          reasoningEffortLabel(
                            effort.id,
                            fallback: effort.name,
                          ),
                        ),
                    ],
                    value: _selected?.reasoningEffort,
                    onChanged: _applying ? null : _chooseEffort,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _modelTile(RemoteModelGroup group, RemoteModelInfo model) {
    final colors = Theme.of(context).colorScheme;
    final selected =
        _selected?.provider == group.id && _selected?.model == model.id;
    final current =
        widget.current?.provider == group.id &&
        widget.current?.model == model.id;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: PocketTile(
        key: ValueKey('remote-model-${group.id}-${model.id}'),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 12,
        ),
        leading: Icon(
          selected
              ? Icons.check_circle_rounded
              : Icons.radio_button_unchecked_rounded,
          color: selected ? colors.primary : colors.outline,
        ),
        title: Text(model.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: selected && !current
            ? const Text('待应用')
            : current
            ? const Text('当前会话使用')
            : null,
        onTap: _applying ? null : () => _choose(group, model),
      ),
    );
  }
}
