// 远程会话相关测试的假实现：不连宿主、不拨号、不读设备表。
//
// - [FakeRemoteConversationSource]：会话页的数据源，页面测试用它驱动首屏、发送、
//   阶段变化与重连快照，以及归档、默认模型与「本次变更」页数据源；
// - [FakeRemoteWorkspaceChangesSource]：「本次变更」页的数据源，可配置查找结果、
//   进度、差异与失败；
// - [FakeRemoteDshSource]：远程首页的数据源，只提供一台电脑上的一个项目与会话；
// - [FakeRemoteTransport] / [FakeRemoteConnection]：真实数据源（
//   `RemoteConversationLiveSource`）的单测替身，记录门面调用并允许注入 `api.stream`
//   帧。

import 'dart:async';

import 'package:dsh_android/attachment_surface.dart';
import 'package:dsh_android/remote_attachments.dart';
import 'package:dsh_android/remote_connection.dart';
import 'package:dsh_android/remote_conversation_live_source.dart';
import 'package:dsh_android/remote_conversation_source.dart';
import 'package:dsh_android/remote_dsh_page.dart';
import 'package:dsh_android/remote_session_insights.dart';
import 'package:dsh_android/runtime_transport.dart';
import 'package:dsh_android/workspace_changes.dart';
import 'package:flutter/foundation.dart';

import '../chat_projection_test.dart' as fixture;

/// 一组最小的真实事件：一条用户消息 + 一条助手回复。
List<Map<String, dynamic>> conversationEvents() => [
  fixture.input(0, '你好'),
  fixture.assistant(1, '你好，我在。'),
];

/// `commands.list` 的缺省目录：计划、压缩与导出各一条（覆盖菜单的
/// 「添加 / 指令」分组与置灰项）。与本地测试用的目录同一套 definitionId。
const List<Map<String, dynamic>> defaultRemoteCommandCatalog =
    <Map<String, dynamic>>[
      <String, dynamic>{
        'name': 'plan',
        'definitionId': '@deepseek-ai/dsh-plan-mode',
        'description': '进入或退出计划模式',
        'input': <String, dynamic>{'hint': '<text>'},
      },
      <String, dynamic>{
        'name': 'compact',
        'definitionId': '@deepseek-ai/dsh-command-compact',
        'description': '压缩以上对话内容',
      },
      <String, dynamic>{
        'name': 'export',
        'definitionId': '@deepseek-ai/dsh-session-log-export',
        'description': '将当前会话内容导出为 ZIP',
        'input': <String, dynamic>{'hint': '<text>'},
      },
    ];

/// 会话页的假数据源。
class FakeRemoteConversationSource extends RemoteConversationSource {
  /// 创建假数据源。
  ///
  /// [supported] 缺省支持读窗口、发送、重命名、交互与模型选择；[window] 是
  /// [start] 推给页面的首屏快照；[interactions] 与 [modelChoice] 在 [start] 时
  /// 作为快照推给页面。[workspaceChanges] 是「本次变更」页的假数据源，只有
  /// [supported] 同时包含摘要与差异方法时 [createWorkspaceChangesSource] 才会
  /// 返回它。[insights] 是 [readInsights] 的固定返回，配置后 [start] 会像真实
  /// 数据源一样推一次 [RemoteConversationInsights]。
  FakeRemoteConversationSource({
    this.sessionId = 's-1',
    Set<String>? supported,
    this.phase = RemoteConnectionPhase.ready,
    this.lastError,
    this.window,
    List<RemotePendingInteraction> interactions =
        const <RemotePendingInteraction>[],
    this.modelChoice,
    RemoteModelCatalog? modelCatalog,
    Set<String> failedModelProviders = const <String>{},
    this.workspaceChanges,
    this.defaultModelRoute,
    this.insights,
  }) : supportedMethods =
           supported ??
           <String>{
             remoteConversationReadMethod,
             remoteConversationSendMethod,
             remoteConversationCommandMethod,
             remoteConversationRenameMethod,
             remoteConversationInteractionsListMethod,
             remoteConversationInteractionsReplyMethod,
             remoteConversationApiCallMethod,
             remoteAttachmentPrepareMethod,
           },
       failedModelProviders = Set<String>.of(failedModelProviders),
       pendingInteractions = List<RemotePendingInteraction>.of(interactions),
       modelCatalog = modelCatalog ?? defaultRemoteModelCatalog;

  @override
  final String sessionId;

  /// 宿主方法表里存在的方法。
  final Set<String> supportedMethods;

  /// 首屏窗口；为 null 时 [start] 不推快照，页面停在「正在读取」。
  RemoteConversationWindow? window;

  /// 待处理交互快照；[start] 与 [refreshInteractions] 会推给页面。
  List<RemotePendingInteraction> pendingInteractions;

  /// 当前模型选择；null 表示窗口里还没有模型。
  RemoteModelChoice? modelChoice;

  /// [fetchModelCatalog] 的返回；调用方可以替换成自己的目录。
  RemoteModelCatalog modelCatalog;

  /// [fetchModelCatalog] 抛出的失败；为 null 时正常返回 [modelCatalog]。
  RuntimeTransportFailure? modelCatalogFailure;

  /// [ensureSession] 的失败；为 null 时返回会话信息。
  RuntimeTransportFailure? ensureFailure;

  /// [ensureSession] 被调用的次数。
  int ensureCalls = 0;

  /// [request] 收到的门面调用（`api.call`、`commands.list` 等）。
  final List<({String method, Map<String, dynamic> params})> requests =
      <({String method, Map<String, dynamic> params})>[];

  /// 按门面方法名配置的 [request] 应答；未配置时返回空对象。
  final Map<String, Object? Function(Map<String, dynamic> params)> answers =
      <String, Object? Function(Map<String, dynamic> params)>{};

  /// [readInsights] 的返回；null 表示这次没有会话洞察读数。
  ///
  /// 配置后页面/数据源测试可以直接给出一组读数；不配置时按 [projections] 的
  /// `values` 走真实解析，同一份 `session.projections` 应答可以同时覆盖计划模式
  /// 与洞察。
  RemoteSessionInsights? insights;

  /// [readInsights] 抛出的失败；为 null 时正常返回 [insights] 或解析 [projections]。
  RuntimeTransportFailure? insightsFailure;

  /// [readInsights] 被调用的次数。
  int insightReads = 0;

  /// [readProjections] 的返回；null 表示会话还没有投影（计划条不显示）。
  Map<String, dynamic>? projections;

  /// [readProjections] 抛出的失败。
  RuntimeTransportFailure? projectionsFailure;

  /// [readProjections] 被调用的次数。
  int projectionReads = 0;

  /// [watchSessionControl] 的流；测试用 [emitControl] 推帧。
  final StreamController<Map<String, dynamic>> _control =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);

  /// [submitPlan] 收到的开关序列。
  final List<bool> planCommands = <bool>[];

  /// [submitPlan] 抛出的失败。
  RuntimeTransportFailure? planFailure;

  /// [dismissInteraction] 收到的请求。
  final List<({String id, int version})> dismissedInteractions =
      <({String id, int version})>[];

  /// [dismissInteraction] 的返回；为 null 时按「受理且请求仍在等待」处理。
  RemoteInteractionReply? dismissReply;

  /// [dismissInteraction] 抛出的失败。
  RuntimeTransportFailure? dismissFailure;

  /// 电脑模型目录里读取失败的服务商；[start] 时作为
  /// [RemoteConversationModelAvailability] 推给页面。页面据此显示发送前提示。
  Set<String> failedModelProviders;

  /// [submitCommand] 返回的结果。
  RemoteCommandResult commandResult = const RemoteCommandResult.success();

  /// [submitCommand] 抛出的失败；为 null 时正常返回 [commandResult]。
  RuntimeTransportFailure? commandFailure;

  /// 非空时 [submitCommand] 会等它完成，用来观察「正在执行指令」的忙态。
  Completer<void>? commandHold;

  /// [submitCommand] 被调用的次数（含抛失败的尝试）。
  int commandCalls = 0;

  /// [send] 抛出的失败；为 null 时记录到 [sent]。
  RuntimeTransportFailure? sendFailure;

  /// 每次成功 [send] 的附件草稿 id。
  final List<List<String>> sentAttachmentIds = <List<String>>[];

  /// 每次 [submitCommand] 的附件草稿 id。
  final List<List<String>> commandAttachmentIds = <List<String>>[];

  /// 会话页附件 rail 的假调用面；为 null 时页面不渲染附件入口。
  ///
  /// 页面通过 [createAttachmentSurface] 取到它并交给内部 `AttachmentDrafts`，
  /// 因此测试可以断言 pick 之后 `attachments.prepare` 的参数与释放时机。
  AttachmentCallSurface? attachmentSurface;

  /// 按顺序消费的发送失败：第 n 次发送抛第 n 个失败，队列空后按成功处理。
  ///
  /// 自动切换模型的重发测试用它模拟「第一次失败、切换后第二次成功」。
  final List<RuntimeTransportFailure> sendFailures =
      <RuntimeTransportFailure>[];

  /// [send] 被调用的次数（含抛失败的尝试）。
  int sendCalls = 0;

  /// [archive] 抛出的失败；为 null 时正常归档。
  RuntimeTransportFailure? archiveFailure;

  /// 是否已经被 [archive] 归档。
  bool archived = false;

  /// [archive] 被调用的次数。
  int archiveCalls = 0;

  /// [fetchDefaultModelRoute] 返回的默认模型；null 表示电脑没有默认模型。
  RemoteModelChoice? defaultModelRoute;

  /// [fetchDefaultModelRoute] 抛出的失败。
  RuntimeTransportFailure? defaultRouteFailure;

  /// [fetchDefaultModelRoute] 被调用的次数。
  int defaultRouteFetches = 0;

  /// 「本次变更」页的假数据源；[createWorkspaceChangesSource] 的返回值。
  RemoteWorkspaceChangesSource? workspaceChanges;

  /// [replyApproval] / [answerQuestion] 的返回；为 null 时按受理成功处理。
  RemoteInteractionReply? interactionReply;

  /// [replyApproval] 抛出的失败。
  RuntimeTransportFailure? replyFailure;

  final List<String> sent = <String>[];

  /// [submitCommand] 收到的完整指令行（含前导 `/`）。
  final List<String> commands = <String>[];

  final List<String> renamed = <String>[];
  final List<({String id, int version, bool allow})> approvalReplies =
      <({String id, int version, bool allow})>[];
  final List<({String id, int version, List<RemoteQuestionAnswer> answers})>
  questionAnswers =
      <({String id, int version, List<RemoteQuestionAnswer> answers})>[];
  final List<RemoteModelChoice> selectedModels = <RemoteModelChoice>[];

  /// [selectModel] 抛出的失败；为 null 时正常应用选择。
  RuntimeTransportFailure? selectModelFailure;
  int catalogFetches = 0;
  int interactionRefreshes = 0;
  int starts = 0;
  int reloads = 0;
  int retries = 0;
  bool disposed = false;

  final StreamController<RemoteConversationUpdate> _updates =
      StreamController<RemoteConversationUpdate>.broadcast(sync: true);

  @override
  RemoteConnectionPhase phase;

  @override
  String? lastError;

  @override
  bool supports(String method) => supportedMethods.contains(method);

  @override
  Stream<RemoteConversationUpdate> get updates => _updates.stream;

  /// 推一条更新给页面。
  void emit(RemoteConversationUpdate update) {
    if (!_updates.isClosed) _updates.add(update);
  }

  /// 切换连接阶段并通知页面；[lastError] 只在该阶段是失败态时有意义。
  void setPhase(RemoteConnectionPhase next, {String? lastError}) {
    phase = next;
    this.lastError = lastError;
    notifyListeners();
  }

  @override
  Future<void> start() async {
    starts++;
    final window = this.window;
    if (window != null) emit(RemoteConversationSnapshot(window));
    if (modelChoice != null) emit(RemoteConversationModel(modelChoice));
    emit(RemoteConversationModelAvailability(failedModelProviders));
    if (pendingInteractions.isNotEmpty) {
      emit(RemoteConversationInteractions(pendingInteractions));
    }
    // 真实数据源在首屏读完后推一次洞察；配置了读数或投影时补上同样的推送。
    if (insights != null || projections != null) {
      emit(RemoteConversationInsights(await readInsights()));
    }
  }

  @override
  Future<void> reload() async {
    reloads++;
    final window = this.window;
    if (window != null) emit(RemoteConversationSnapshot(window));
  }

  @override
  Future<void> send(
    String text, {
    List<String> attachmentIds = const <String>[],
  }) async {
    sendCalls++;
    final queued = sendFailures.isEmpty ? null : sendFailures.removeAt(0);
    final failure = queued ?? sendFailure;
    if (failure != null) throw failure;
    sent.add(text);
    sentAttachmentIds.add(List<String>.of(attachmentIds));
  }

  @override
  Future<RemoteCommandResult> submitCommand(
    String line, {
    List<String> attachmentIds = const <String>[],
  }) async {
    commandCalls++;
    commands.add(line);
    commandAttachmentIds.add(List<String>.of(attachmentIds));
    final gate = commandHold;
    if (gate != null) await gate.future;
    final failure = commandFailure;
    if (failure != null) throw failure;
    return commandResult;
  }

  @override
  Future<Map<String, dynamic>> ensureSession() async {
    ensureCalls++;
    final failure = ensureFailure;
    if (failure != null) throw failure;
    return <String, dynamic>{'sessionId': sessionId, 'created': false};
  }

  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) async {
    requests.add((method: method, params: Map<String, dynamic>.of(params)));
    final answer = answers[method];
    if (answer != null) return answer(params);
    if (method == 'api.call' &&
        params['namespace'] == 'commands' &&
        params['method'] == 'list') {
      return defaultRemoteCommandCatalog;
    }
    return <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>?> readProjections() async {
    projectionReads++;
    final failure = projectionsFailure;
    if (failure != null) throw failure;
    return projections;
  }

  @override
  Future<RemoteSessionInsights?> readInsights() async {
    insightReads++;
    final failure = insightsFailure;
    if (failure != null) throw failure;
    final configured = insights;
    if (configured != null) return configured;
    return RemoteSessionInsights.fromProjectionValues(projections?['values']);
  }

  @override
  Stream<Map<String, dynamic>> watchSessionControl() => _control.stream;

  /// 给 [watchSessionControl] 的订阅者推一帧（`opening` / `item` / `disconnected`）。
  void emitControl(Map<String, dynamic> frame) {
    if (!_control.isClosed) _control.add(frame);
  }

  /// 结束控制流：模拟连接重建时宿主/传输退役旧订阅。
  Future<void> closeControl() async {
    if (!_control.isClosed) await _control.close();
  }

  @override
  Future<void> submitPlan(bool enabled) async {
    planCommands.add(enabled);
    final failure = planFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<RemoteInteractionReply> dismissInteraction(
    String id,
    int version,
  ) async {
    dismissedInteractions.add((id: id, version: version));
    final failure = dismissFailure;
    if (failure != null) throw failure;
    return dismissReply ??
        const RemoteInteractionReply(accepted: true, requestStillPending: true);
  }

  @override
  Future<void> rename(String title) async {
    renamed.add(title);
  }

  @override
  Future<void> archive() async {
    archiveCalls++;
    final failure = archiveFailure;
    if (failure != null) throw failure;
    archived = true;
  }

  @override
  Future<RemoteModelChoice?> fetchDefaultModelRoute() async {
    defaultRouteFetches++;
    final failure = defaultRouteFailure;
    if (failure != null) throw failure;
    return defaultModelRoute;
  }

  @override
  RemoteWorkspaceChangesSource? createWorkspaceChangesSource() {
    final source = workspaceChanges;
    if (source == null) return null;
    if (!supportedMethods.contains(remoteWorkspaceChangesSummaryMethod) ||
        !supportedMethods.contains(remoteWorkspaceChangesDiffMethod)) {
      return null;
    }
    return source;
  }

  @override
  AttachmentCallSurface? createAttachmentSurface() => attachmentSurface;

  @override
  Future<void> refreshInteractions() async {
    interactionRefreshes++;
    emit(RemoteConversationInteractions(pendingInteractions));
  }

  @override
  Future<RemoteInteractionReply> replyApproval(
    String id,
    int version, {
    required bool allow,
  }) async {
    final failure = replyFailure;
    if (failure != null) throw failure;
    approvalReplies.add((id: id, version: version, allow: allow));
    final reply =
        interactionReply ??
        const RemoteInteractionReply(
          accepted: true,
          requestStillPending: false,
        );
    if (reply.accepted) {
      pendingInteractions = [
        for (final request in pendingInteractions)
          if (request.id != id) request,
      ];
      // 宿主受理后会推 interactions.changed；假数据源同步推一份同样的快照，
      // 页面因此和真实链路一样从卡片消失。
      emit(RemoteConversationInteractions(pendingInteractions));
    }
    return reply;
  }

  @override
  Future<RemoteInteractionReply> answerQuestion(
    String id,
    int version,
    List<RemoteQuestionAnswer> answers,
  ) async {
    final failure = replyFailure;
    if (failure != null) throw failure;
    questionAnswers.add((id: id, version: version, answers: answers));
    final reply =
        interactionReply ??
        const RemoteInteractionReply(
          accepted: true,
          requestStillPending: false,
        );
    if (reply.accepted) {
      pendingInteractions = [
        for (final request in pendingInteractions)
          if (request.id != id) request,
      ];
      emit(RemoteConversationInteractions(pendingInteractions));
    }
    return reply;
  }

  @override
  Future<RemoteModelCatalog> fetchModelCatalog() async {
    catalogFetches++;
    final failure = modelCatalogFailure;
    if (failure != null) throw failure;
    return modelCatalog;
  }

  @override
  Future<void> selectModel(RemoteModelChoice choice) async {
    final failure = selectModelFailure;
    if (failure != null) throw failure;
    selectedModels.add(choice);
    modelChoice = choice;
    emit(RemoteConversationModel(choice));
  }

  @override
  Future<void> retry() async {
    retries++;
  }

  @override
  void dispose() {
    disposed = true;
    unawaited(_updates.close());
    unawaited(_control.close());
    super.dispose();
  }
}

/// 测试用的默认模型目录：一个账号分组、两个模型，其中一个声明推理强度。
final RemoteModelCatalog defaultRemoteModelCatalog = RemoteModelCatalog(
  defaultChoice: const RemoteModelChoice(
    provider: 'deepseek-account',
    model: 'deepseek-flash',
  ),
  groups: const <RemoteModelGroup>[
    RemoteModelGroup(
      id: 'deepseek-account',
      name: 'DeepSeek 账号',
      models: <RemoteModelInfo>[
        RemoteModelInfo(id: 'deepseek-flash', name: 'DeepSeek Flash'),
        RemoteModelInfo(
          id: 'deepseek-v4-pro',
          name: 'DeepSeek V4 Pro',
          reasoning: RemoteReasoningInfo(
            efforts: <RemoteReasoningLevel>[
              RemoteReasoningLevel(id: 'low', name: '低'),
              RemoteReasoningLevel(id: 'high', name: '高'),
            ],
            defaultEffort: 'high',
          ),
        ),
      ],
    ),
  ],
);

/// 远程首页的假数据源：一台在线电脑、一个项目、一个会话。
class FakeRemoteDshSource implements RemoteDshDataSource {
  /// 创建假首页数据源。
  const FakeRemoteDshSource({
    this.hostName = '客厅的电脑',
    this.projects = const <RemoteDshProject>[
      RemoteDshProject(
        id: 'cwd:C:/work/Pocket',
        deviceId: 'device-1',
        name: 'Pocket',
        sessions: <RemoteDshSession>[
          RemoteDshSession(id: 's-1', title: '修复登录'),
        ],
      ),
    ],
  });

  @override
  final String hostName;

  /// 那台电脑上的项目。
  final List<RemoteDshProject> projects;

  @override
  RemoteDshConnectionState get connection => RemoteDshConnectionState.connected;

  @override
  Future<List<RemoteDshDevice>> listDevices() async => const <RemoteDshDevice>[
    RemoteDshDevice(id: 'device-1', label: '客厅的电脑'),
  ];

  @override
  Future<List<RemoteDshProject>> listProjects() async => projects;
}

/// 记录门面调用并允许注入入站帧的传输替身。
class FakeRemoteTransport implements RuntimeTransport {
  /// 按调用顺序记录的方法名与参数。
  final List<({String method, Map<String, dynamic> params})> requests =
      <({String method, Map<String, dynamic> params})>[];

  /// 每个方法的应答工厂；没有配置时返回空对象。
  final Map<String, Object? Function(Map<String, dynamic> params)> answers =
      <String, Object? Function(Map<String, dynamic> params)>{};

  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);

  /// 全部调用过的方法名。
  List<String> get methods => [for (final request in requests) request.method];

  /// 某个方法的全部参数。
  List<Map<String, dynamic>> paramsOf(String method) => [
    for (final request in requests)
      if (request.method == method) request.params,
  ];

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
    switch (method) {
      case 'api.ack':
        return <String, dynamic>{'accepted': true, 'upTo': params['upTo']};
      case 'api.unsubscribe':
        return <String, dynamic>{'closed': true};
      default:
        return <String, dynamic>{};
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
  Future<void> close() async {}
}

/// 真实数据源需要的假连接：阶段、方法表与传输都可以直接改。
class FakeRemoteConnection extends ChangeNotifier
    implements RemoteConversationConnection {
  /// 创建假连接。
  FakeRemoteConnection({
    required this.transport,
    Set<String>? supported,
    this.phase = RemoteConnectionPhase.ready,
    this.lastError,
    this.windowAck = false,
  }) : supportedMethods =
           supported ??
           <String>{
             remoteConversationReadMethod,
             remoteConversationSendMethod,
             remoteConversationRenameMethod,
           };

  @override
  final RuntimeTransport? transport;

  /// 宿主方法表里存在的方法。
  final Set<String> supportedMethods;

  /// 宿主是否声明了 `window-ack`（协议 §6.4）。
  @override
  final bool windowAck;

  /// 重新连接被调用的次数。
  int retries = 0;

  @override
  RemoteConnectionPhase phase;

  @override
  String? lastError;

  @override
  bool supports(String method) => supportedMethods.contains(method);

  @override
  Future<void> reconnect() async {
    retries++;
  }

  /// 切换阶段并通知监听者。
  void setPhase(RemoteConnectionPhase next, {String? lastError}) {
    phase = next;
    this.lastError = lastError;
    notifyListeners();
  }
}

/// 「本次变更」页的假数据源：可配置查找结果、进度、差异与失败，并记录页面发出的
/// 每一次读取与取消，因此页面测试不需要真实门面。
class FakeRemoteWorkspaceChangesSource implements RemoteWorkspaceChangesSource {
  /// 创建假数据源。
  ///
  /// [resolution] 是 [resolveSnapshot] 的默认返回值；[resolutionBuilder] 优先于
  /// 它，用于「第一次失败、重试成功」这类多次查找的场景。[diffs] 按文件下标给出
  /// [loadDiff] 的结果，缺少的下标按「找不到」失败。[progress] 在每次查找返回前
  /// 依次回调，用来验证进度文案。[hold] 非空时查找会等它完成，用来观察加载态。
  FakeRemoteWorkspaceChangesSource({
    this.resolution,
    this.resolutionBuilder,
    Map<int, WorkspaceFileDiff>? diffs,
    this.diffFailure,
    List<RemoteWorkspaceScanProgress> progress =
        const <RemoteWorkspaceScanProgress>[],
    this.hold,
  }) : diffs = Map<int, WorkspaceFileDiff>.of(
         diffs ?? const <int, WorkspaceFileDiff>{},
       ),
       progress = List<RemoteWorkspaceScanProgress>.of(progress);

  /// [resolveSnapshot] 的默认返回值；null 时按「没有可查看的变更」降级。
  RemoteWorkspaceChangesResolution? resolution;

  /// 每次 [resolveSnapshot] 调用时生成返回值；非空时忽略 [resolution]。
  RemoteWorkspaceChangesResolution Function()? resolutionBuilder;

  /// 按文件下标配置的差异；没有配置的下标按「找不到」失败。
  final Map<int, WorkspaceFileDiff> diffs;

  /// [loadDiff] 抛出的失败；非空时所有差异读取都失败。
  RuntimeTransportFailure? diffFailure;

  /// 查找返回前依次回调的进度。
  final List<RemoteWorkspaceScanProgress> progress;

  /// 非空时查找会等它完成再返回，用来观察「正在读取」的加载态。
  Completer<void>? hold;

  /// [resolveSnapshot] 被调用的次数。
  int resolves = 0;

  /// [cancelInFlight] 被调用的次数。
  int cancels = 0;

  /// [loadDiff] 请求过的轮次序号。
  final List<int> diffSeqs = <int>[];

  /// [loadDiff] 请求过的文件下标。
  final List<int> diffIndexes = <int>[];

  /// [dispose] 是否已经被调用。
  bool disposed = false;

  @override
  Future<RemoteWorkspaceChangesResolution> resolveSnapshot({
    void Function(RemoteWorkspaceScanProgress progress)? onProgress,
  }) async {
    resolves++;
    for (final step in progress) {
      onProgress?.call(step);
    }
    final gate = hold;
    if (gate != null) await gate.future;
    return resolutionBuilder?.call() ??
        resolution ??
        const RemoteWorkspaceChangesUnavailable(
          scanned: 0,
          limit: remoteWorkspaceChangesScanLimit,
          startSeq: 0,
          announced: false,
        );
  }

  @override
  Future<WorkspaceFileDiff> loadDiff(int seq, int index) async {
    diffSeqs.add(seq);
    diffIndexes.add(index);
    final failure = diffFailure;
    if (failure != null) throw failure;
    final diff = diffs[index];
    if (diff == null) {
      throw const RuntimeTransportFailure(
        code: 'workspace-changes/unavailable',
        message: '这轮改动的内容已不可用。',
      );
    }
    return diff;
  }

  @override
  Future<void> cancelInFlight() async {
    cancels++;
  }

  @override
  void dispose() {
    disposed = true;
  }
}

/// 一份测试用变更摘要：默认一轮、一个文件。
WorkspaceChangesSummary testWorkspaceChangesSummary({
  int turn = 2,
  String display = 'lib/a.dart',
  int added = 2,
  int deleted = 1,
  int? total,
}) => WorkspaceChangesSummary(
  turn: turn,
  total: total ?? 1,
  added: added,
  deleted: deleted,
  files: <WorkspaceChangedFile>[
    WorkspaceChangedFile(
      path: display,
      display: display,
      added: added,
      deleted: deleted,
    ),
  ],
);

/// 一份测试用文件差异：默认一个同时含新增、上下文与删除行的 hunk。
WorkspaceFileDiff testWorkspaceFileDiff({
  String display = 'lib/a.dart',
  List<String> lines = const <String>[
    '+added line',
    ' context line',
    '-deleted line',
  ],
}) => WorkspaceFileDiff(
  kind: WorkspaceDiffKind.text,
  path: display,
  display: display,
  hunks: <WorkspaceDiffHunk>[
    WorkspaceDiffHunk(
      oldStart: 1,
      oldLines: 2,
      newStart: 1,
      newLines: 2,
      lines: lines,
    ),
  ],
);

/// 会话页附件 rail 的假调用面：记录 `attachments.prepare` / `.release` 参数，
/// 允许注入失败，并可以推进连接代际模拟「重连后凭据失效」。
///
/// 与真实远程调用面一样实现 [AttachmentMetadataSurface]：`attachments.prepare`
/// 因此会带上草稿的 `name` / `mediaType` / `bytes`（宿主用它们命名收据并对账）。
class FakeAttachmentSurface extends ChangeNotifier
    implements AttachmentCallSurface, AttachmentMetadataSurface {
  /// 创建假调用面；默认已就绪、准备成功。
  FakeAttachmentSurface({bool ready = true, String? phase})
    : _ready = ready,
      _phase = phase ?? (ready ? 'ready' : 'connecting');

  bool _ready;
  String _phase;

  /// 每次调用的方法名与参数。
  final List<({String method, Map<String, dynamic> params})> calls =
      <({String method, Map<String, dynamic> params})>[];

  /// `attachments.prepare` 的成功应答；null 时按 `id` 生成一个文件收据。
  Map<String, dynamic>? prepared;

  /// 按顺序消费的 `attachments.prepare` 失败；队列空后按成功处理。
  final List<Exception> prepareFailures = <Exception>[];

  /// `attachments.prepare` 被调用的次数（含失败）。
  int prepares = 0;

  /// `attachments.release` 被调用的次数（含 dispose 触发的清理）。
  int releases = 0;

  bool disposed = false;

  @override
  bool get ready => !disposed ? _ready : false;

  @override
  String get phase => disposed || !_ready ? _phase : 'ready';

  @override
  int connectionGeneration = 0;

  /// 模拟一次断连重连：代际递增并通知草稿把已上传凭据置为可重试。
  void reconnect() {
    connectionGeneration++;
    _ready = true;
    _phase = 'ready';
    notifyListeners();
  }

  /// 模拟连接断开：不换代，只让调用面进入未就绪态。
  void disconnect({String phase = 'reconnecting'}) {
    _ready = false;
    _phase = phase;
    notifyListeners();
  }

  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) async {
    calls.add((method: method, params: Map<String, dynamic>.of(params)));
    switch (method) {
      case remoteAttachmentPrepareMethod:
        prepares++;
        if (prepareFailures.isNotEmpty) throw prepareFailures.removeAt(0);
        final id = params['id'] as String;
        return prepared ??
            <String, dynamic>{
              'id': id,
              'kind': 'file',
              'name': '${params['name'] ?? id}',
              'bytes': params['bytes'] ?? 10,
              'receiptId': 'receipt-$id',
            };
      case remoteAttachmentReleaseMethod:
        releases++;
        return <String, dynamic>{'released': true};
      default:
        throw StateError('Unexpected attachment method $method');
    }
  }

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    super.dispose();
  }
}
