// 远程 DSH 的会话页：头部（返回、标题与副标题、编辑与省略号胶囊）、消息区与
// 底部输入区。
//
// 页面只依赖 [RemoteConversationSource]：首屏由数据源用 `session.readWindow`
// 读回，发送走 `session.send`，增量与流式回复从数据源的更新流进来。消息用既有
// 内核的数据形态直接渲染：窗口事件交给 [ChatProjection]，正文与流式回复交给
// [ChatTimeline]（内部是 `ChatMessage` / `ChatContent`），本文件不复制一份对话
// 内核的投影或渲染逻辑，也不含任何样例消息。
//
// 待处理的审批与提问显示在输入区上方的卡片里：审批卡片写明工具名与一行输入
// 摘要，提供「允许一次 / 拒绝」；提问卡片按 `multiSelect` 渲染选项（可补自定义
// 文字），每个问题都有答复后「提交」才可用。答复走数据源的
// [RemoteConversationSource.replyApproval] / [RemoteConversationSource.answerQuestion]，
// 页面不拼线上 `response` 字段。
//
// 模型入口在输入区：显示当前 `provider/model`，点按打开底部弹层（模型目录来自
// `api.call` 的 `session.modelCatalog`），应用后数据源推新的选择。发送因凭据类
// 错误失败时，页面先尝试一次自动恢复：读电脑上的默认模型（`settings.describe`），
// 与当前路由不同就切过去并重发一次；成功或两次都失败都在输入区上方留下常驻说明，
// 自动恢复不了时保留一条直接指向模型选择的可操作提示。
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

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'approvals_draft.dart';
import 'attachment_surface.dart';
import 'attachments.dart';
import 'chat_messages.dart';
import 'chat_plan.dart';
import 'chat_projection.dart';
import 'composer_commands.dart';
import 'flclash/color.dart';
import 'flclash/daylight.dart';
import 'flclash/popup.dart';
import 'flclash/typography.dart';
import 'model_reasoning.dart';
import 'remote_attachments.dart';
import 'remote_commands.dart';
import 'remote_connection.dart';
import 'remote_conversation_source.dart';
import 'remote_dsh_widgets.dart';
import 'remote_goal_plan.dart';
import 'remote_terminal_page.dart';
import 'remote_workspace_diff_page.dart';
import 'runtime.dart';
import 'runtime_transport.dart';
import 'ui.dart';

/// 距列表底部多近仍算「在跟随最新内容」。
const double _followThreshold = 120;

/// 指令提示里回显输入的字符上限；超出截断，避免输入区被撑成多行。
const int _commandPreviewLength = 48;

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

  /// 列表滚动时用来暂停背景的流动光，避免滚动期间每帧重绘氛围层。
  final _scrolling = ValueNotifier<bool>(false);

  /// 会话事件的投影与原始事件。两者一起交给 [ChatTimeline]。
  final _projection = ChatProjection();
  List<Json> _events = const [];
  final Set<int> _seenSeqs = <int>{};

  ChatLiveMessage? _live;
  bool _running = false;
  bool _loading = true;
  bool _sending = false;
  bool _draftEmpty = true;
  String? _loadError;
  String? _status;
  Timer? _statusTimer;
  late String _title;
  StreamSubscription<RemoteConversationUpdate>? _updates;

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

  /// 正在提交会话指令。与发送共用 [_sending] 的忙态，只是文案不同。
  bool _submittingCommand = false;

  /// 最近一条会话指令结果与它的原文；成功、失败都常驻，直到下一条指令、成功
  /// 发送或用户点「知道了」。
  ({String line, RemoteCommandResult result})? _commandResult;

  /// 电脑模型目录里读取失败的服务商（`session.modelCatalog` 的 `failures[].id`）。
  ///
  /// 当前路由的 provider 命中时，发送前给出「会自动改用电脑默认模型」的提示。
  Set<String> _failedModelProviders = const <String>{};

  /// 已经用一次成功发送确认过的路由；同一条路由不再显示发送前提示。
  RemoteModelChoice? _routeConfirmed;

  /// 是否仍然贴着最新内容。用户向上翻到离底部较远的位置后，键盘、更新都不再
  /// 把列表拽回底部；滚回底部附近时自动恢复跟随。
  bool _pinnedToEnd = true;

  /// 附件草稿的调用面（远程连接）与本页持有的草稿。
  ///
  /// 页面只认 [AttachmentCallSurface]：本地模式同一套草稿状态机配
  /// `RuntimeController`，远程模式配 `RemoteAttachmentSurface`（设计文档 §3.4.5）。
  /// 数据源不提供附件能力（旧实现）时为 null，页面不渲染附件入口。
  AttachmentCallSurface? _attachmentSurface;
  AttachmentDrafts? _drafts;

  /// 计划模式的状态与写入口；未连接时条不显示（见 `remote_goal_plan.dart`）。
  late final RemoteGoalPlanController _goalPlan;

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
    // 更新流先订阅、再开始读首屏：首屏快照不会落在订阅建立之前。
    unawaited(_source.start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focus.removeListener(_onFocusChanged);
    _statusTimer?.cancel();
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
    _source.dispose();
    _attachmentSurface?.dispose();
    _scrolling.dispose();
    _scroll.dispose();
    _focus.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // 键盘与安全区变化会改变列表视口高度；仍贴着最新内容时重新贴住。
    _scheduleScrollToEnd();
  }

  // ------------------------------------------------------------ 数据源

  void _onSourceChanged() {
    if (!mounted) return;
    setState(() {
      // 首屏还在读时连接就进了终止态：读取不会再成功，把失败原因交给正文显示，
      // 不要把加载指示永远挂在那里。
      if (_loading && _source.phase == RemoteConnectionPhase.failed) {
        _loading = false;
        _loadError = _source.lastError ?? '没能连接到这台电脑，请回到首页重新连接。';
      }
    });
  }

  /// 附件草稿状态（上传中 / 失败 / 移除）变化：发送按钮要看草稿才能决定是否出现。
  void _onDraftsChanged() {
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
        setState(() {
          _loading = false;
          _loadError = null;
          _events = List<Json>.of(window.events);
          _seenSeqs
            ..clear()
            ..addAll([for (final event in _events) event['seq'] as int]);
          _projection.reconcile(_events);
        });
        _scheduleScrollToEnd();
      case RemoteConversationEvents(:final events):
        final added = <Json>[];
        for (final event in events) {
          final seq = event['seq'];
          if (seq is! int || !_seenSeqs.add(seq)) continue;
          added.add(event);
        }
        if (added.isEmpty) return;
        setState(() {
          _events = [..._events, ...added]..sort(_bySeq);
          _projection.reconcile(_events);
        });
        _scheduleScrollToEnd();
      case RemoteConversationLive(:final value):
        setState(() => _live = _liveMessage(value));
        _scheduleScrollToEnd();
      case RemoteConversationRunning(:final running):
        if (_running == running) return;
        setState(() => _running = running);
      case RemoteConversationFailure(:final message, :final fatal):
        if (fatal) {
          setState(() => _loadError = message);
        } else {
          _showStatus(message);
        }
      case RemoteConversationInteractions(:final requests):
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
    }
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

  Future<void> _reload() => _source.reload();

  // ------------------------------------------------------------ 滚动

  void _onFocusChanged() {
    if (_focus.hasFocus) _scheduleScrollToEnd();
  }

  /// 跳到列表底部，并在下一帧再校正一次：懒加载列表的最大滚动距离要等新行布局
  /// 完才准确。
  void _scheduleScrollToEnd() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _jumpToEnd();
      WidgetsBinding.instance.addPostFrameCallback((_) {
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
      case ScrollStartNotification():
        _scrolling.value = true;
      case ScrollEndNotification():
        _scrolling.value = false;
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
    final glass = LiquidGlassScope.of(context);
    return Scaffold(
      // 输入区是正文 Column 的最后一行，所以键盘弹起时由 Scaffold 按
      // `MediaQuery.viewInsets` 缩短正文，输入区随之让位到键盘上方。
      resizeToAvoidBottomInset: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (glass) DaylightBackdrop(suspendMotion: _scrolling),
          SafeArea(
            child: Column(
              children: [
                _header(context),
                ?_banner(context),
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _trackScroll,
                    child: _transcript(context),
                  ),
                ),
                ?_interactionArea(context),
                _planArea(context),
                ?_modelRouteNotice(context),
                ?_credentialNotice(context),
                ?_commandResultBar(context),
                ?_persistentNoticeBar(context),
                _composerArea(context),
              ],
            ),
          ),
        ],
      ),
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
          message: _source.lastError ?? '没能连接到这台电脑，请回到首页重新连接。',
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
    return Stack(
      children: [
        Positioned.fill(
          child: ChatTimeline(
            sessionId: _source.sessionId,
            projection: _projection,
            controller: _scroll,
            events: _events,
            live: _live,
            running: _running,
          ),
        ),
        // 输入区是实心的，列表在它上方被硬边裁掉；这一条渐隐把最后一行融进页面底色。
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SizedBox(
            height: 26,
            child: FloatingEdgeScrim(
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              bottom: true,
              fadeStart: .25,
            ),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 头部

  Widget _header(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final canPop = Navigator.canPop(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ready) _modelLabelRow(context),
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
                      key: const ValueKey('remote-composer-menu-unavailable'),
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
          if (canSend && _sending)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _submittingCommand ? '正在执行电脑上的指令…' : '正在发送…',
                    style: AppTextStyle.footnote
                        .of(context)
                        .copyWith(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            )
          else if (canSend && (!_draftEmpty || _hasDraftAttachments))
            Align(
              alignment: Alignment.centerRight,
              child: PocketButton(
                key: const ValueKey('remote-send'),
                onPressed: () => unawaited(_submit(_input.text)),
                child: const Text('发送'),
              ),
            ),
          if (_drafts case final drafts?)
            PocketAttachmentRail(drafts: drafts, sessionId: _source.sessionId),
          RemoteComposer(
            deviceLabel: widget.deviceName,
            placeholder: canSend
                ? '在 ${widget.deviceName} 上工作'
                : ready
                ? '这台电脑不支持发送消息'
                : '先连接这台电脑',
            controller: _input,
            focusNode: _focus,
            approvalLabel: _approvalLabel(_approval),
            modelLabel: _modelLabel,
            enabled: canSend && !_sending,
            onChanged: _onDraftChanged,
            onSubmitted: (value) => unawaited(_submit(value)),
            onAdd: canOpenMenu ? _openAddSheet : null,
            onApproval: _openApprovalSheet,
            onModel: canSelectModel ? () => unawaited(_openModelSheet()) : null,
          ),
        ],
      ),
    );
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
      }
      await _consumeAttachments(attachedIds);
    } on RuntimeTransportFailure catch (failure) {
      if (!mounted) return;
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
      if (mounted) _showStatus('发送失败：$error');
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
      _submittingCommand = true;
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
          result: RemoteCommandResult.error(failure.message),
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
          _submittingCommand = false;
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
  /// - 其它宿主指令作为 `session.command` 执行；需要输入的指令插进输入框，
  ///   由用户补全参数后按普通指令提交；
  /// - `export` / `skills` 本轮不支持，置灰并写明原因。
  void _openAddSheet() {
    final drafts = _drafts;
    final state = _attachState();
    final canAttach =
        drafts != null && state == RemoteCapabilityState.available;
    final disabledReasons = <String, String>{
      'export': '远程会话暂不支持导出到手机，请在电脑上导出',
      'skills': '远程会话暂不支持浏览技能',
      if (!canAttach)
        'file': _capabilityReason(state, '上传附件') ?? '这台电脑暂不支持上传附件',
    };
    unawaited(
      showRemoteCommandsSheet(
        context,
        builder: (_) => ComposerCommands(
          runtime: RemoteComposerCommandSurface(_source),
          sessionId: _source.sessionId,
          disabledReasons: disabledReasons,
          // 选中行时 `CommonPopupMenu` 自己会收起承载它的路由（这里就是弹层）；
          // 分发只负责执行，不能再 pop 一次，否则会退到上一页。
          onPick: _pickComposerCommand,
        ),
      ),
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
      _submittingCommand = true;
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
          result: RemoteCommandResult.error(failure.message),
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
          _submittingCommand = false;
        });
      }
    }
  }

  /// 方案模式入口：先刷新状态，再打开本地那套计划模式页（`chat_plan.dart`）。
  ///
  /// 计划原文与开关都在同一页；输入区上方的 [ChatPlanDock] 也会在进入计划模式后
  /// 出现「退出计划模式」。
  Future<void> _openPlanMode() async {
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

  void _openApprovalSheet() {
    unawaited(
      showRemoteApprovalSheet(
        context,
        selected: _approval,
        onSelected: _selectApproval,
      ),
    );
  }

  RemoteApprovalPreset _approval = RemoteApprovalPreset.ask;

  void _selectApproval(RemoteApprovalPreset preset) {
    if (preset == _approval) return;
    setState(() => _approval = preset);
    _showStatus('审批策略已改为「${_approvalLabel(preset)}」');
  }

  // ------------------------------------------------------------ 待处理交互

  /// 输入区上方的待处理审批/提问卡片；没有待处理项时返回 null。
  ///
  /// 卡片区最多占屏幕高度的 45%，多个请求（或选项很多）时整块滚动，不会把
  /// 输入区挤出屏幕。
  Widget? _interactionArea(BuildContext context) {
    if (_interactions.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .45,
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
                    error: _interactionErrors[request.id],
                    onApprove: (allow) =>
                        unawaited(_replyApproval(request, allow: allow)),
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
      : result.displayText;

  /// 常驻的可见说明：自动切换模型成功，或切换/重发仍失败时同时给出两次原因。
  ///
  /// 它不随 3 秒状态条消失，用户点「知道了」才收起；发送成功不会把它吞掉，
  /// 否则用户看不到消息为什么换了模型。
  Widget? _persistentNoticeBar(BuildContext context) {
    final notice = _persistentNotice;
    if (notice == null) return null;
    return _RemoteNoticeBar(
      key: const ValueKey('remote-conversation-fallback-notice'),
      message: notice,
      actionLabel: '知道了',
      onAction: () => setState(() => _persistentNotice = null),
    );
  }

  /// 答复审批：受理后宿主会推 `interactions.changed`，卡片随之消失。
  Future<void> _replyApproval(
    RemotePendingInteraction request, {
    required bool allow,
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
        _showStatus(allow ? '已允许一次' : '已拒绝');
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
    _statusTimer?.cancel();
    setState(() => _status = message);
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
                      style: LiquidGlassStyle.regular(colors),
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

/// 审批策略的显示名，用于输入区盾牌按钮的回显。
String _approvalLabel(RemoteApprovalPreset preset) => switch (preset) {
  RemoteApprovalPreset.ask => '请求批准',
  RemoteApprovalPreset.auto => '替我批准',
  RemoteApprovalPreset.fullAccess => '完全访问',
  RemoteApprovalPreset.custom => '自定义',
};

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
    for (final controller in _custom.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _isApproval => widget.request.kind == RemoteInteractionKind.approval;

  String get _summary => widget.request.summary ?? widget.request.reason ?? '';

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

  @override
  Widget build(BuildContext context) {
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
          if (_isApproval) ...[
            if (_summary.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                _summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.footnote
                    .of(context)
                    .copyWith(color: colors.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: PocketButton.tonal(
                    key: ValueKey('remote-approval-deny-${request.id}'),
                    onPressed: widget.busy
                        ? null
                        : () => widget.onApprove(false),
                    child: Text(widget.busy ? '正在提交' : '拒绝'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PocketButton(
                    key: ValueKey('remote-approval-allow-${request.id}'),
                    onPressed: widget.busy
                        ? null
                        : () => widget.onApprove(true),
                    child: Text(widget.busy ? '正在提交' : '允许一次'),
                  ),
                ),
              ],
            ),
          ] else if (_planReview case final review?) ...[
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
