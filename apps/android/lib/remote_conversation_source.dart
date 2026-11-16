// 远程会话页的数据源契约。
//
// 会话页只认识这一个接口：读窗口、发消息、执行会话指令、收更新、报连接阶段与
// 能力，以及「待处理审批/提问」「会话模型选择」「本次变更」「归档会话」。真实
// 实现在 `remote_conversation_live_source.dart`（走 PC 门面的
// `session.readWindow`、`session.send`、`session.command`、`api.subscribe` 的
// `session.follow`、`interactions.*`、`api.call` 的 `session.modelCatalog` /
// `session.selectModel`、`workspaceChanges.*` 与
// `library.sessionArchive`）；测试实现由测试自己提供假数据，不连任何宿主。
//
// 以 `/` 开头的输入是会话指令，走 [RemoteConversationSource.submitCommand]：
// 电脑上的指令处理器执行它，结果由 [RemoteCommandResult] 承载，不进入模型
// 对话。输入补全不做，但 `+` 弹层的指令目录由 [RemoteConversationSource.request]
// 读 `api.call` 的 `commands.list`（与本地 `ComposerCommands` 同一份数据驱动
// 菜单，见 `remote_commands.dart`）。计划模式读
// [RemoteConversationSource.readProjections] 与
// [RemoteConversationSource.watchSessionControl]，写走
// [RemoteConversationSource.submitPlan]。会话洞察（待办、统计、token 用量与上下文
// 占用）来自同一份 `session.projections` 的 `values`：数据源用
// [RemoteConversationSource.readInsights] 读，并在读完后推
// [RemoteConversationInsights] 给页面，页面只持有最近一次读数（渲染由后续 UI
// 接入）。附件草稿的调用面由
// [RemoteConversationSource.createAttachmentSurface]
// 提供（设计与线上契约见 `docs/remote-dsh/p5-remaining-design.md` §3.4）；
// 消息与指令都接受 `attachmentIds`，字节由宿主在准备阶段反向拉取。模型路由的
// 可用性由 `session.modelCatalog` 投影成
// [RemoteConversationModelAvailability]：当前路由的服务商出现在失败列表里、
// 或不在目录的 `routableProviders` 里（没有配置凭据时宿主返回空模型列表，
// 服务商在目录里静默缺席）都算不可用。页面据此在发送前提示当前路由在电脑上
// 不可用，而不是等发送失败后才解释。
//
// 同一个文件还给出「本次变更」页自己的数据源契约
// [RemoteWorkspaceChangesSource]：该页只认这一个入口，owner / requestId /
// 有界扫描等线上细节留在真实实现里，页面因此可以直接用替身测试。
//
// 值类型直接沿用既有数据形态：窗口里的 `events` 就是 `session.readWindow` 返回
// 的会话事件，更新里的 `value` 就是宿主 `session.live` 通知的 `value`。因此页面
// 可以把它们直接交给既有的 `ChatProjection` / `ChatLiveMessage`，不另造一套
// 消息模型。审批、提问与模型目录的线上字段见
// `apps/android/runtime/interactions.mjs` 与 `session_models.dart`，这里只做
// 页面要用的投影：页面不解析线上 JSON，也不自己拼 `interactions.reply` 的
// `response`。

library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'attachment_surface.dart';
import 'remote_connection.dart';
import 'remote_session_insights.dart';
import 'runtime.dart';
import 'workspace_changes.dart';

/// 读取会话窗口用的门面方法（`apps/android/runtime/index.mjs`）。
const String remoteConversationReadMethod = 'session.readWindow';

/// 发送消息用的门面方法。
const String remoteConversationSendMethod = 'session.send';

/// 执行会话指令用的门面方法（参数 `{sessionId, line, attachmentIds?}`）。
///
/// 与 [remoteConversationSendMethod] 是两条路：以 `/` 开头的行由电脑上的指令
/// 处理器执行，不进入模型对话，返回值是处理器给的结果。
const String remoteConversationCommandMethod = 'session.command';

/// 重命名会话用的门面方法（`library.*` 写入口）。
const String remoteConversationRenameMethod = 'library.sessionRename';

/// 归档会话用的门面方法（`library.*` 写入口，参数 `archived: true`）。
const String remoteConversationArchiveMethod = 'library.sessionArchive';

/// 读取某轮变更摘要的门面方法（`workspaceChanges.summary`，协议 §4.2）。
///
/// 参数是 `{owner, requestId, sessionId, seq}`，`seq` 必须取会话里那条
/// `workspace/changes` 事件的序号；宿主只为该序号保留快照。
const String remoteWorkspaceChangesSummaryMethod = 'workspaceChanges.summary';

/// 读取某轮单个文件差异的门面方法（`workspaceChanges.diff`）。
const String remoteWorkspaceChangesDiffMethod = 'workspaceChanges.diff';

/// 取消一次在途变更读取的门面方法（`workspaceChanges.cancel`）。
const String remoteWorkspaceChangesCancelMethod = 'workspaceChanges.cancel';

/// 变更快照查找的最大步数。
///
/// 正常路径直接命中会话窗口里的 `workspace/changes` 事件（一轮一条），只有窗口里
/// 找不到这类事件时才做兜底扫描。页面任何情况下都不会无限循环。
const int remoteWorkspaceChangesScanLimit = 30;

/// 窗口里没有 `workspace/changes` 事件时，兜底向下扫描的步数上限。
///
/// 宿主只在轮次结束时追加这个事件，正常路径不需要扫描；这里只防窗口被截断或
/// 宿主行为变化，向前找几步就应当停，不能把一次页面打开变成连续几十次请求。
const int remoteWorkspaceChangesFallbackScanSteps = 5;

/// 订阅会话更新用的门面方法：`api.subscribe` 的 `namespace`（协议 §6.5）。
const String remoteConversationFollowNamespace = 'session';

/// 订阅会话更新用的门面方法：`api.subscribe` 的 `method`（协议 §6.5）。
const String remoteConversationFollowMethod = 'follow';

/// 计划模式投影的 typert 命名空间（`api.call` 的 `session.projections`）。
const String remoteConversationPlanNamespace = 'session';

/// 读取会话投影的 typert 方法（`api.call` 的 `method`）。
const String remoteConversationProjectionsMethod = 'projections';

/// 会话控制流的订阅命名空间（`api.subscribe` 的 `namespace`，协议 §6.5）。
const String remoteConversationControlNamespace = 'session';

/// 会话控制流的订阅方法（`api.subscribe` 的 `method`，协议 §6.5）。
const String remoteConversationControlMethod = 'control';

/// 读取待处理交互（审批与提问）用的门面方法。
const String remoteConversationInteractionsListMethod = 'interactions.list';

/// 答复待处理交互用的门面方法：审批 outcome 与提问 answers 共用这一个入口。
const String remoteConversationInteractionsReplyMethod = 'interactions.reply';

/// typert 命名空间方法的一元透传入口（`api.call`）。
const String remoteConversationApiCallMethod = 'api.call';

/// `api.call` 里会话模型相关方法的命名空间。
const String remoteConversationModelNamespace = 'session';

/// 读取会话模型目录的 typert 方法（`api.call` 的 `method`）。
const String remoteConversationModelCatalogMethod = 'modelCatalog';

/// 切换会话模型的 typert 方法（`api.call` 的 `method`）。
const String remoteConversationSelectModelMethod = 'selectModel';

/// 发送失败消息里出现这些片段时，说明失败来自「电脑上没有当前模型的凭据」。
///
/// HANDOFF §3.5：远程宿主若只有账号凭据，沿用 `deepseek-official` 路由的会话会以
/// `llm-deepseek: no API key for provider route "deepseek-official"` 失败；账号
/// 路由缺登录时宿主给的是 `Sign in to DeepSeek…`。这两种失败都能通过切换模型
/// 恢复，页面据此把普通错误升级成指向模型选择器的可操作提示。
const List<String> remoteCredentialFailureMarkers = <String>[
  'no API key',
  'Sign in to DeepSeek',
];

/// [message] 是否是凭据类发送失败（大小写不敏感）。
bool isRemoteCredentialFailure(String message) {
  final lowered = message.toLowerCase();
  return remoteCredentialFailureMarkers.any(
    (marker) => lowered.contains(marker.toLowerCase()),
  );
}

/// 一次 `session.readWindow` 的结果。
///
/// 字段与门面返回同名同义：`events` 是会话事件（按 `seq` 升序），`throughSeq`
/// 是这次读取钉住的日志切点，`firstSeq` 是窗口内最早事件的序号（空窗口为 null），
/// `hasMore` 表示更早还有内容。
@immutable
class RemoteConversationWindow {
  const RemoteConversationWindow({
    required this.events,
    required this.throughSeq,
    this.firstSeq,
    this.hasMore = false,
  });

  /// 会话事件，按 `seq` 升序。
  final List<Json> events;

  /// 这次读取的日志切点。
  final int throughSeq;

  /// 窗口内最早事件的序号；窗口为空时为 null。
  final int? firstSeq;

  /// 更早是否还有内容。
  final bool hasMore;
}

/// 会话数据源推给页面的一次更新。
sealed class RemoteConversationUpdate {
  const RemoteConversationUpdate();
}

/// 窗口快照：整体替换已加载的事件。
///
/// 首次打开与断线重连都走这一条（协议 §7.3：`session.follow` 的 opening 快照
/// 先整体替换、再追加增量）。
final class RemoteConversationSnapshot extends RemoteConversationUpdate {
  const RemoteConversationSnapshot(this.window);

  /// 新的窗口。
  final RemoteConversationWindow window;
}

/// 追加的会话事件；页面按 `seq` 去重后合并。
final class RemoteConversationEvents extends RemoteConversationUpdate {
  const RemoteConversationEvents(this.events);

  /// 要追加的事件，按 `seq` 升序。
  final List<Json> events;
}

/// 正在生成的助手回复，形态是宿主 `session.live` 通知的 `value`。
///
/// `value` 为 null 表示这一轮已经落盘，调用方应清掉流式行。
final class RemoteConversationLive extends RemoteConversationUpdate {
  const RemoteConversationLive(this.value);

  /// 组装好的助手内容（`attemptId` / `revision` / `turn` / `step` / `content`）；
  /// null 表示当前没有进行中的回复。
  final Json? value;
}

/// 会话的运行状态。
final class RemoteConversationRunning extends RemoteConversationUpdate {
  const RemoteConversationRunning(this.running);

  /// 当前是否有正在执行的轮次。
  final bool running;
}

/// 会话的可见错误；[fatal] 为 true 时页面按「读不到内容」处理。
final class RemoteConversationFailure extends RemoteConversationUpdate {
  const RemoteConversationFailure(this.message, {this.fatal = false});

  /// 已经可以直接展示的中文说明（协议 §9.4）。
  final String message;

  /// 是否让整段会话不可读（读取窗口失败），而不是一条可以继续操作的状态提示。
  final bool fatal;
}

/// 这个会话当前的待处理交互（审批与提问）快照。
///
/// 宿主用 `interactions.list` 与 `interactions.changed` 给出全量快照，数据源已按
/// [RemoteConversationSource.sessionId] 过滤；空列表表示这个会话没有待处理项。
/// 快照语义是整体替换：页面不能把更新的列表与旧列表合并。
final class RemoteConversationInteractions extends RemoteConversationUpdate {
  const RemoteConversationInteractions(this.requests);

  /// 待处理交互，按宿主给出的顺序。
  final List<RemotePendingInteraction> requests;
}

/// 会话当前的模型选择（来自窗口里的 `model/selection` / `request/header` 投影，
/// 或刚通过 [RemoteConversationSource.selectModel] 应用的结果）。
///
/// [choice] 为 null 表示窗口里还没有可推导的模型：会话尚未产生请求头，也没有
/// 待生效的选择。页面据此显示「选择模型」而不是编一个默认值。
final class RemoteConversationModel extends RemoteConversationUpdate {
  const RemoteConversationModel(this.choice);

  /// 当前生效（或待生效）的模型路由。
  final RemoteModelChoice? choice;
}

/// 电脑上当前会话路由不可用的服务商标识（`session.modelCatalog` 的投影）。
///
/// 不可用有两种来源：目录把它列进 `failures[].id`（例如读取失败），或者它不在
/// `routableProviders` 里——没有配置凭据的服务商在目录里是静默缺席的，既不成组
/// 也不报错。页面把当前路由的 provider 与这个集合对比：命中说明会话绑定的模型在
/// 这台电脑上不可用，发送时会自动改用电脑的默认模型，因此在发送前给出可操作
/// 提示。空集合表示没有不可用项，或这一轮没能读到目录——两种情况页面都不提示。
///
/// 数据源保证每次「打开 / 重连 / 会话模型变化」最多读一次目录并缓存，读取失败
/// 也不会影响发送。
final class RemoteConversationModelAvailability
    extends RemoteConversationUpdate {
  const RemoteConversationModelAvailability(this.unavailableProviders);

  /// 电脑上没有可用路由的服务商标识。
  final Set<String> unavailableProviders;

  /// 页面既有解构名；集合语义已从「目录读取失败」扩展为「当前路由不可用」，
  /// 与 [unavailableProviders] 同值。
  Set<String> get failedProviders => unavailableProviders;
}

/// 页面角色可用的会话洞察读数的最近一次快照。
///
/// [insights] 为 null 表示宿主没有可用的会话投影（会话不存在、没有注册这些投影，
/// 或本周期还没读到）；数据源在「打开 / 重连 / reload / 一轮开始或结束 / 待办写入」
/// 之后重新读取并推这个更新，不做定时轮询。页面收到后整体替换旧读数；读数没变时
/// 数据源不会推。
final class RemoteConversationInsights extends RemoteConversationUpdate {
  const RemoteConversationInsights(this.insights);

  /// 最近一次读到的洞察读数；null 表示这一周期没有可用读数。
  final RemoteSessionInsights? insights;
}

/// 待处理交互的种类。
enum RemoteInteractionKind {
  /// 工具执行前的授权请求：答复 `allowed-once` / `rejected`。
  approval,

  /// Agent 的提问：答复每个问题的选项。
  question,
}

/// 一个提问提供的选项。
@immutable
class RemoteQuestionOption {
  const RemoteQuestionOption({required this.label, this.description});

  /// 线上回传的选项标识（`interactions.reply` 的 `selected` 用它）。
  final String label;

  /// 选项说明；宿主没有提供时为 null。
  final String? description;

  /// 还原成宿主下发的选项对象（见 [RemoteQuestion.toJson]）。
  Json toJson() => <String, dynamic>{
    'label': label,
    if (description != null) 'description': description,
  };
}

/// 一个提问里的单个问题。
@immutable
class RemoteQuestion {
  const RemoteQuestion({
    required this.id,
    required this.question,
    this.header,
    this.detail,
    this.multiSelect = false,
    this.options = const <RemoteQuestionOption>[],
    this.intent,
  });

  /// 问题标识（`interactions.reply` 的 `answers[].id`）。
  final String id;

  /// 问题正文。
  final String question;

  /// 可选的短标题。
  final String? header;

  /// 可选的补充说明（例如计划原文）；页面只展示摘要。
  final String? detail;

  /// 是否可多选；单选时最多选一个选项，且不能与自定义文字同时提交。
  final bool multiSelect;

  /// 可选项；宿主没有提供选项时为空，此时只能填自定义回答。
  final List<RemoteQuestionOption> options;

  /// 宿主给的问题意图（例如计划审核的 `{kind:'plan-review', approve:'…'}`）。
  ///
  /// 页面据此把计划审核渲染成专属决策卡片；不做解释时原样保留，供
  /// `approvals_draft.dart` 的 `planReviewOf` 复用同一套判定。
  final Json? intent;

  /// 还原成宿主下发的提问对象。
  ///
  /// 只包含页面判断需要的字段，交给 `planReviewOf` / `QuestionAnswerDraft`
  /// 复用既有解析，不另写一套判定。
  Json toJson() => <String, dynamic>{
    'id': id,
    'question': question,
    if (header != null) 'header': header,
    if (detail != null) 'detail': detail,
    'multiSelect': multiSelect,
    'options': <Json>[for (final option in options) option.toJson()],
    if (intent != null) 'intent': intent,
  };
}

/// 页面提交给 [RemoteConversationSource.answerQuestion] 的单个问题答复。
@immutable
class RemoteQuestionAnswer {
  const RemoteQuestionAnswer({
    required this.id,
    this.selected = const <String>[],
    this.custom,
  });

  /// 问题标识。
  final String id;

  /// 选中的选项标签；顺序原样上线。
  final List<String> selected;

  /// 自定义文字回答；没有时不上线。
  final String? custom;

  /// 组装成 `interactions.reply` 的 `answers[]` 元素。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'selected': List<String>.of(selected),
    if (custom != null && custom!.trim().isNotEmpty) 'custom': custom!.trim(),
  };
}

/// 一个待处理交互（审批或提问）。
@immutable
class RemotePendingInteraction {
  const RemotePendingInteraction({
    required this.id,
    required this.version,
    required this.sessionId,
    required this.kind,
    this.toolName,
    this.summary,
    this.reason,
    this.callId,
    this.questions = const <RemoteQuestion>[],
  });

  /// 交互标识；答复时原样回传。
  final String id;

  /// 交互版本；宿主用它拒绝过期的答复。
  final int version;

  /// 所属会话（数据源已按当前会话过滤）。
  final String sessionId;

  /// 交互种类。
  final RemoteInteractionKind kind;

  /// 触发审批的工具名；提问类为 null。
  final String? toolName;

  /// 一行输入摘要（来自工具调用参数）；没有可用摘要时为 null。
  final String? summary;

  /// 宿主给出的请求原因；没有时为 null。
  final String? reason;

  /// 关联的工具调用标识；没有时为 null。
  final String? callId;

  /// 提问类的问题列表；审批类为空。
  final List<RemoteQuestion> questions;
}

/// `interactions.reply` 的结果。
@immutable
class RemoteInteractionReply {
  const RemoteInteractionReply({
    required this.accepted,
    required this.requestStillPending,
    this.message,
  });

  /// 宿主是否受理了这次答复。
  final bool accepted;

  /// 答复没有落地时，原请求是否仍在等待（true 表示可以重试）。
  final bool requestStillPending;

  /// 宿主给的可直接展示的说明；没有时为 null。
  final String? message;
}

/// 一条会话指令在电脑上的执行结果。
///
/// 门面 `session.command` 的返回值是命令处理器的结果：正常时是
/// `{commandId, result: {kind: 'success' | 'error', text?}}`，没有识别出指令时
/// （语法不成立或名字不在当前会话的指令表里）是 null，此时什么都不会执行。
/// 页面不解析这两种线上形态，只渲染这里拍平后的结果。
enum RemoteCommandKind {
  /// 指令处理器报告执行成功。
  success,

  /// 指令处理器明确报告失败（例如当前状态不允许这一步）。
  error,

  /// 电脑没有识别出这条指令：语法不成立或名字不在指令表里，什么都没执行。
  unrecognized,
}

/// 一次 `session.command` 的结果。
@immutable
class RemoteCommandResult {
  const RemoteCommandResult({required this.kind, this.text, this.commandId});

  /// 成功结果；[text] 是宿主给的说明，null 表示用页面的中性兜底文案。
  const RemoteCommandResult.success({this.text, this.commandId})
    : kind = RemoteCommandKind.success;

  /// 失败结果；[text] 是宿主给的、可直接展示的原因。
  const RemoteCommandResult.error(this.text)
    : kind = RemoteCommandKind.error,
      commandId = null;

  /// 电脑没有识别出指令（门面返回 null）。
  const RemoteCommandResult.unrecognized()
    : kind = RemoteCommandKind.unrecognized,
      text = null,
      commandId = null;

  /// 执行结果的种类。
  final RemoteCommandKind kind;

  /// 宿主给的说明；没有时为 null。`unrecognized` 时恒为 null。
  final String? text;

  /// 这次执行的配对标识（`command/run` / `command/done` 事件用它关联）；
  /// 没有时（未识别或旧宿主）为 null。
  final String? commandId;

  /// 是否明确执行成功。
  bool get succeeded => kind == RemoteCommandKind.success;

  /// 页面直接展示的文案：宿主给了说明就用它，否则按种类给中性兜底，不编造原因。
  String get displayText {
    final value = text?.trim();
    if (value != null && value.isNotEmpty) return value;
    return switch (kind) {
      RemoteCommandKind.success => '指令已执行。',
      RemoteCommandKind.error => '指令执行失败。',
      RemoteCommandKind.unrecognized => '电脑上没有这条指令。',
    };
  }
}

/// 会话的模型路由：provider + model + 可选推理强度。
///
/// 字段与 `session.selectModel` 的 `request` 一一对应，`reasoningEffort` 为 null
/// 表示使用模型的默认强度。
@immutable
class RemoteModelChoice {
  const RemoteModelChoice({
    required this.provider,
    required this.model,
    this.reasoningEffort,
  });

  /// 服务商标识（目录里的 `groups[].id`）。
  final String provider;

  /// 模型标识（目录里的 `groups[].models[].id`）。
  final String model;

  /// 推理强度标识；null 表示使用模型默认值。
  final String? reasoningEffort;

  /// 输入区回显用的「provider/model」。
  String get label => '$provider/$model';

  /// 组装成 `session.selectModel` 的 `request`。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider': provider,
    'model': model,
    if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
  };

  @override
  bool operator ==(Object other) =>
      other is RemoteModelChoice &&
      other.provider == provider &&
      other.model == model &&
      other.reasoningEffort == reasoningEffort;

  @override
  int get hashCode => Object.hash(provider, model, reasoningEffort);

  @override
  String toString() => 'RemoteModelChoice($label)';
}

/// 模型目录里的一个推理强度档位。
@immutable
class RemoteReasoningLevel {
  const RemoteReasoningLevel({required this.id, this.name});

  /// 档位标识，进入 `selectModel` 的 `reasoningEffort`。
  final String id;

  /// 宿主给的显示名；没有时按标识显示。
  final String? name;
}

/// 模型声明的推理强度。
@immutable
class RemoteReasoningInfo {
  const RemoteReasoningInfo({
    this.efforts = const <RemoteReasoningLevel>[],
    this.defaultEffort,
  });

  /// 可选档位；空列表表示这个模型不声明推理强度。
  final List<RemoteReasoningLevel> efforts;

  /// 宿主声明的默认档位；没有时为 null（由模型自己决定）。
  final String? defaultEffort;
}

/// 模型目录里的一个模型。
@immutable
class RemoteModelInfo {
  const RemoteModelInfo({required this.id, required this.name, this.reasoning});

  /// 模型标识。
  final String id;

  /// 显示名；宿主没有提供时与 [id] 相同。
  final String name;

  /// 推理强度声明；模型不支持时为 null。
  final RemoteReasoningInfo? reasoning;
}

/// 模型目录里的一个服务商分组。
@immutable
class RemoteModelGroup {
  const RemoteModelGroup({
    required this.id,
    required this.name,
    required this.models,
  });

  /// 服务商标识，进入 `selectModel` 的 `provider`。
  final String id;

  /// 显示名；宿主没有提供时与 [id] 相同。
  final String name;

  /// 该服务商下的模型。
  final List<RemoteModelInfo> models;
}

/// 一次 `session.modelCatalog` 读取的结果。
@immutable
class RemoteModelCatalog {
  const RemoteModelCatalog({
    this.defaultChoice,
    this.groups = const <RemoteModelGroup>[],
    this.failures = const <String>[],
    this.failedProviders = const <String>{},
    this.routableProviders = const <String>{},
  });

  /// 宿主默认模型路由；没有时为 null。
  final RemoteModelChoice? defaultChoice;

  /// 可选的分组；目录读不到可用模型时为空。
  final List<RemoteModelGroup> groups;

  /// 读取失败的服务商说明（例如凭据缺失），可直接展示。
  final List<String> failures;

  /// 读取失败的服务商标识（与 [failures] 一一对应；目录没给 id 时不含）。
  ///
  /// 会话路由的 provider 落在这里，说明这个会话绑定的模型在电脑上不可用。
  final Set<String> failedProviders;

  /// 至少有一个可用模型的服务商标识（宿主的 `routableProviders`）。
  ///
  /// 会话路由的服务商既不在这里、也不在 [failedProviders] 里时，说明它在目录里
  /// 静默缺席（例如没有配置凭据时宿主返回空模型列表，既不成组也不报错），同样
  /// 不可用。旧宿主没有这个字段时，解析层用非空分组的 id 集合兜底。
  final Set<String> routableProviders;
}

/// 一个门面能力在页面上的三态（协议 §10.2）。
///
/// 三态把「还没连上」和「这台电脑明确不支持」分开：前者等连接就绪后可能变可用，
/// 后者只能置灰并说明原因，不能给一个点了没反应的控件。
enum RemoteCapabilityState {
  /// 已就绪且方法表里可用。
  available,

  /// 已就绪但方法表不含该方法（或 `unsupported` 覆盖了它）。
  unsupported,

  /// 尚未就绪：未握手、重连中或已断开，能力暂时无法判定。
  pending,
}

/// 一次变更快照查找的进度。
@immutable
class RemoteWorkspaceScanProgress {
  const RemoteWorkspaceScanProgress({
    required this.attempt,
    required this.limit,
    required this.seq,
  });

  /// 当前是第几步，从 1 开始。
  final int attempt;

  /// 本次查找最多几步，等于候选序号的数量；只有 1 步时页面不必显示步数。
  final int limit;

  /// 这一步正在探测的会话事件序号。
  final int seq;
}

/// 一次「本次变更」快照查找的结果。
sealed class RemoteWorkspaceChangesResolution {
  const RemoteWorkspaceChangesResolution();
}

/// 找到了可读取的快照。
final class RemoteWorkspaceChangesFound
    extends RemoteWorkspaceChangesResolution {
  const RemoteWorkspaceChangesFound({required this.seq, required this.summary});

  /// 快照对应的 `workspace/changes` 事件序号。
  final int seq;

  /// 这一轮的变更摘要。
  final WorkspaceChangesSummary summary;
}

/// 这轮没有可读取的变更快照。
///
/// 宿主只为当前进程里的 `workspace/changes` 事件保留快照；电脑重启或宿主重启后
/// 旧轮次会返回 `workspace-changes/unavailable`，这是正常降级而不是硬错误。
final class RemoteWorkspaceChangesUnavailable
    extends RemoteWorkspaceChangesResolution {
  const RemoteWorkspaceChangesUnavailable({
    required this.scanned,
    required this.limit,
    required this.startSeq,
    required this.announced,
  });

  /// 实际尝试过的步数。
  final int scanned;

  /// 本次查找的步数上限。
  final int limit;

  /// 查找开始时的最新序号；窗口为空时为 0。
  final int startSeq;

  /// 会话窗口里是否出现过 `workspace/changes` 事件。
  ///
  /// true 表示快照曾经存在、只是宿主已经不再保留；false 表示窗口里没有这类
  /// 事件，这一轮本来就没有可查看的变更。
  final bool announced;
}

/// 本轮还没结束：还没有 `workspace/changes` 事件，但有正在执行的轮次。
final class RemoteWorkspaceChangesPendingTurn
    extends RemoteWorkspaceChangesResolution {
  const RemoteWorkspaceChangesPendingTurn();
}

/// 查找失败：连接断开、方法不支持或宿主拒绝。
final class RemoteWorkspaceChangesFailure
    extends RemoteWorkspaceChangesResolution {
  const RemoteWorkspaceChangesFailure(this.message);

  /// 已经可以直接展示的中文说明。
  final String message;
}

/// 「本次变更」页的数据来源。
///
/// 页面只认这三个入口：有界查找快照、读取单个文件差异、取消在途请求。
/// owner / requestId / 序号扫描等线上细节由真实实现
/// （`RemoteConversationLiveSource` 的 `RemoteWorkspaceChangesLiveSource`）负责，
/// 页面测试因此可以注入替身，不连宿主、不碰门面方法名。
abstract class RemoteWorkspaceChangesSource {
  /// 定位本轮可读取的变更快照。
  ///
  /// 正常路径只读会话窗口里最后一条 `workspace/changes` 事件的序号：宿主只为
  /// 这个序号保留快照，其它序号一律是 `workspace-changes/unavailable`。没有这类
  /// 事件（本轮还没结束，或窗口被截断）时才做至多
  /// [remoteWorkspaceChangesFallbackScanSteps] 步的向下兜底扫描；整体步数受
  /// [remoteWorkspaceChangesScanLimit] 约束。每次尝试前回调 [onProgress]，页面
  /// 据此显示进度；找到即停止。失败与降级都通过返回值表达，不抛异常。
  Future<RemoteWorkspaceChangesResolution> resolveSnapshot({
    void Function(RemoteWorkspaceScanProgress progress)? onProgress,
  });

  /// 读取第 [seq] 轮第 [index] 个文件的差异。
  ///
  /// 失败抛 `RuntimeTransportFailure`，`message` 已是可以直接展示的中文。
  Future<WorkspaceFileDiff> loadDiff(int seq, int index);

  /// 取消正在进行的请求（页面关闭或重新开始查找时调用）。
  ///
  /// 实现必须容忍重复调用，且不得因取消失败而抛出。
  Future<void> cancelInFlight();

  /// 释放数据源；页面销毁时调用，之后不再发请求。
  void dispose();
}

/// 远程会话页依赖的数据源。
///
/// 实现者负责把连接阶段、能力表与门面调用投影成这里的方法；页面不直接碰
/// [RemoteConnectionController]，也不自己建连接。构造后页面先订阅 [updates]，
/// 再调用 [start]；页面销毁时调用 [dispose]。
abstract class RemoteConversationSource extends ChangeNotifier {
  /// 会话标识（`session.readWindow` 的 `sessionId`）。
  String get sessionId;

  /// 当前连接阶段；页面据此显示「连接中 / 就绪 / 失败」。
  RemoteConnectionPhase get phase;

  /// 终止态的失败原因；没有失败时为 null。
  String? get lastError;

  /// 宿主是否支持某个门面方法（协议 §10.1、§10.2）。
  ///
  /// 尚未握手成功时一律返回 false，调用方只在 [phase] 为
  /// [RemoteConnectionPhase.ready] 时把 false 当作「这台电脑不支持」。
  bool supports(String method);

  /// [method] 在页面上的能力三态（协议 §10.2）。
  ///
  /// 尚未就绪时返回 [RemoteCapabilityState.pending]：页面据此给出「正在连接」
  /// 之类的临时说明，而不是把入口当成这台电脑永久不支持。
  RemoteCapabilityState capability(String method) {
    if (phase != RemoteConnectionPhase.ready) {
      return RemoteCapabilityState.pending;
    }
    return supports(method)
        ? RemoteCapabilityState.available
        : RemoteCapabilityState.unsupported;
  }

  /// 开始首屏：读取窗口并订阅更新。重复调用返回同一次开始。
  Future<void> start();

  /// 重新读取窗口；读取失败后的「重试」用它。
  Future<void> reload();

  /// 发送一条消息；空白文本由调用方过滤，这里不再兜底。
  ///
  /// [attachmentIds] 是本次要随消息发送的附件草稿（`attachments.prepare` 已经
  /// 在宿主上登记过的 `id`）；空列表表示这条消息没有附件。附件字节不在这里
  /// 上传：宿主在准备阶段用反向请求分页读取手机上的私有副本（设计文档 §3.4）。
  Future<void> send(
    String text, {
    List<String> attachmentIds = const <String>[],
  });

  /// 提交一条以 `/` 开头的会话指令（门面 `session.command`）。
  ///
  /// [line] 是包含前导 `/` 的完整指令行；电脑上的指令处理器执行它，不进入模型
  /// 对话，也不经过 [send]。返回值把宿主的执行结果（`{commandId,
  /// result:{kind, text?}}`）或 null（没有识别出指令）拍平成页面可渲染的结果；
  /// 传输失败抛 [RuntimeTransportFailure]，`message` 已经是可以直接展示的中文。
  ///
  /// [attachmentIds] 与 [send] 相同：指令的 `attachmentIds` 由电脑上的处理器解释，
  /// 不接受附件的指令会自行拒绝。
  ///
  /// 未识别指令时不会抛异常：那是电脑对这条行的正常判断，页面据此保留草稿并
  /// 说明没有执行。
  Future<RemoteCommandResult> submitCommand(
    String line, {
    List<String> attachmentIds = const <String>[],
  });

  /// 确保会话已在电脑上恢复（门面 `session.ensure`）。
  ///
  /// 返回宿主的 `{sessionId, created}`。读指令目录、写计划模式等「会话级」操作
  /// 之前先调它；幂等，冷会话可能触发宿主唤醒（与本地 `ensureSession` 同语义）。
  Future<Json> ensureSession();

  /// 向电脑发一个门面请求（方法名 + 参数）。
  ///
  /// 数据源负责连接阶段、失败翻译（抛 [RuntimeTransportFailure]，`message` 已经
  /// 可以直接展示）与在途请求归属。会话指令目录（`api.call` 的
  /// `commands.list`）等通用透传读用它，页面不自己拼 `api.call` 的信封。
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]);

  /// 读取会话投影（门面 `api.call` 的 `session.projections`）。
  ///
  /// 返回 `{kind:'sequenced', asOfSeq, values}`；宿主还没有该会话的投影时返回
  /// null（与本地 `ChatGoalPlanController.refresh` 的判据一致）。形状不符时抛
  /// `FormatException`，由调用方按「状态待确认」降级。
  Future<Json?> readProjections();

  /// 读取会话洞察（待办 / 统计 / token 用量 / 上下文占用）。
  ///
  /// 默认实现复用 [readProjections]：只有 `kind == 'sequenced'` 的快照才解析
  /// `values`，其余情况（null、迁移提示、缺 `values`）返回 null；构造
  /// [RemoteSessionInsights] 的解析对缺失键与坏类型容错，不会抛异常。读取本身失败
  /// （连接断开、方法不支持）时仍按 [readProjections] 的约定抛出，由调用方决定是否
  /// 展示——真实数据源刷新洞察时吞掉这类失败并保留上一次读数。
  ///
  /// 返回 null 表示这个会话暂时没有洞察读数；[RemoteSessionInsights] 的四个字段
  /// 仍可能各自为 null（宿主只注册了部分投影）。
  Future<RemoteSessionInsights?> readInsights() async {
    final projections = await readProjections();
    if (projections == null) return null;
    if (projections['kind'] != 'sequenced') return null;
    return RemoteSessionInsights.fromProjectionValues(projections['values']);
  }

  /// 订阅会话控制流（`api.subscribe {namespace:'session', method:'control'}`）。
  ///
  /// 每次监听都新开一条流（新 `streamId`），窗口化回执由数据源统一管理。流帧与
  /// 本地 `RuntimeController.watchApi('session', 'control')` 同形：
  /// `{type:'opening'|'item'|'disconnected'}`；计划模式的状态增量在
  /// `item.value.type == 'projection'`、`item.value.key == 'plan'` 的帧里。
  Stream<Json> watchSessionControl();

  /// 切换计划模式（`session.command` 的 `/plan` 与 `/plan off`）。
  ///
  /// 宿主明确报错（`result.kind == 'error'`）或没有识别这条指令时抛
  /// [StateError]（`message` 可直接展示）；传输失败抛 [RuntimeTransportFailure]。
  /// 调用方保留输入与草稿，只提示结果未确认。
  Future<void> submitPlan(bool enabled);

  /// 放弃一个待处理交互（门面 `interactions.dismiss`）。
  ///
  /// 计划审核的「请求修改」用它：不发送任何答案，计划继续等待决定。返回值与
  /// [replyApproval] 相同；宿主受理且请求仍在等待时 `requestStillPending` 为 true。
  Future<RemoteInteractionReply> dismissInteraction(String id, int version);

  /// 重命名会话。
  Future<void> rename(String title);

  /// 归档当前会话（`library.sessionArchive` 的 `archived: true`）。
  ///
  /// 成功后会话离开电脑上的项目列表，可在「已归档任务」里查看和恢复。
  Future<void> archive();

  /// 重新读取当前会话的待处理交互；答复被拒绝或状态不确定后用它核对。
  Future<void> refreshInteractions();

  /// 答复一个审批请求：[allow] 为 true 时回 `allowed-once`，否则回 `rejected`。
  ///
  /// 返回值说明宿主是否受理；页面在 `accepted == false` 时展示 [message] 并调用
  /// [refreshInteractions] 核对。
  Future<RemoteInteractionReply> replyApproval(
    String id,
    int version, {
    required bool allow,
  });

  /// 答复一个提问请求；[answers] 必须覆盖请求里的每个问题。
  Future<RemoteInteractionReply> answerQuestion(
    String id,
    int version,
    List<RemoteQuestionAnswer> answers,
  );

  /// 读取电脑上的会话模型目录（`api.call` 的 `session.modelCatalog`）。
  Future<RemoteModelCatalog> fetchModelCatalog();

  /// 切换当前会话的模型（`api.call` 的 `session.selectModel`）。
  ///
  /// 成功后数据源从 `result.selected` 更新本地选择并推 [RemoteConversationModel]，
  /// 后续 `session.send` 立即使用新路由。
  Future<void> selectModel(RemoteModelChoice choice);

  /// 读取电脑上的默认模型路由（`settings.describe` 的 `agent-default-model`）。
  ///
  /// 发送遇到凭据类失败时，页面用它判断能否自动切到这台电脑已经配置好的默认
  /// 模型。设置里没有默认模型、宿主不支持 `settings.describe` 或读取失败时返回
  /// null：调用方保留原有提示，不做自动切换。
  Future<RemoteModelChoice?> fetchDefaultModelRoute();

  /// 创建「本次变更」页的数据源；宿主不支持摘要或差异读取时返回 null。
  ///
  /// 每次打开页面都返回一个新对象，由页面持有并在销毁时释放。
  RemoteWorkspaceChangesSource? createWorkspaceChangesSource();

  /// 创建会话页附件草稿的调用面（设计文档 §3.4.5）；不支持附件的实现返回 null。
  ///
  /// 每次打开会话页调用一次，返回的对象由页面持有并在销毁时 [AttachmentCallSurface.dispose]。
  /// 默认返回 null：既有实现（含测试替身）因此不需要改动，页面据此不渲染附件入口。
  AttachmentCallSurface? createAttachmentSurface() => null;

  /// 终止态下的「重新连接」：重连当前这台电脑。
  Future<void> retry();

  /// 更新流。页面在 [start] 之前就应订阅，以便拿到首屏快照。
  Stream<RemoteConversationUpdate> get updates;
}
