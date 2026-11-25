import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/services.dart';

import 'runtime.dart';
import 'remote_dsh_page.dart';
import 'remote_notification_navigation.dart';
import 'remote_sync_service.dart';
import 'runtime_selection.dart';
import 'files.dart';
import 'ui.dart';
import 'prism_bridge.dart';
import 'appearance.dart';
import 'approvals.dart';
import 'tasks.dart';
import 'diagnostics.dart';
import 'export.dart';
import 'attachments.dart';
import 'image_preview.dart';
import 'attachment_file.dart';
import 'composer_commands.dart';
import 'session_models.dart';
import 'session_model_projection.dart';
import 'models_label.dart';
import 'session_document.dart';
import 'session_files.dart';
import 'session_browser.dart';
import 'session_terminal.dart';
import 'terminal_shells.dart';
import 'models.dart';
import 'models_data.dart';
import 'model_reasoning.dart';
import 'account.dart';
import 'account_quota_notice.dart';
import 'settings.dart';
import 'design/popup.dart';
import 'pocket_composer.dart';
import 'remote_dsh_widgets.dart';
import 'automations.dart';
import 'chat_projection.dart';
import 'chat_quotes.dart';
import 'chat_messages.dart';
import 'chat_turn_navigation.dart';
import 'chat_sidebar.dart';
import 'agent_presets.dart';
import 'skills.dart';
import 'chat_references.dart';
import 'chat_deliverables.dart';
import 'chat_goal.dart';
import 'chat_plan.dart';
import 'chat_goal_plan_state.dart';
import 'session_feedback.dart';
import 'chat_reading.dart';
import 'chat_shortcuts.dart';
import 'resource_hub.dart';
import 'session_trajectory.dart';
import 'subagents.dart';
import 'workspace_changes_preference.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PocketHarnessApp());
}

class PocketHarnessApp extends StatefulWidget {
  const PocketHarnessApp({super.key});
  @override
  State<PocketHarnessApp> createState() => _PocketHarnessAppState();
}

class _PocketHarnessAppState extends State<PocketHarnessApp>
    with WidgetsBindingObserver {
  final runtime = RuntimeController();
  final appearance = AppearanceController();
  final rootNavigator = GlobalKey<NavigatorState>();

  /// 根对话页的 state；通知深链的导航统一交给它（它拥有侧栏与目的地栈）。
  final chatKey = GlobalKey<_ChatPageState>();

  /// 远程通知点击深链：平台层 take 一次即清空；根页面还没挂载时保留重试。
  late final notificationNavigation = RemoteNotificationNavigation(
    source: const MethodChannelRemoteNotificationLaunchSource(),
    open: (launch) {
      final chat = chatKey.currentState;
      if (chat == null) return false;
      chat.openRemoteNotification(launch);
      return true;
    },
  );
  late final quotaNotices = AccountQuotaNoticeController(
    runtime.liveSessionEvents,
  );
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(appearance.load());
    unawaited(runtime.start().catchError(runtime.fail));
    // 应用级远程后台同步：即使没进远程页，也按偏好恢复最近连接的电脑并启动前台
    // 同步服务（进程被系统杀死后，打开 App 即恢复连接与推送）。
    unawaited(RemoteBackgroundSync.instance.attach(runtime));
    // 冷启动由系统通知拉起时，启动 Intent 里的深链在第一帧之后取走。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(notificationNavigation.consume());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    quotaNotices.dispose();
    runtime.dispose();
    appearance.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(runtime.resume());
      // 进程被系统重启/连接在后台断开后，回到前台立即补心跳并尝试恢复连接。
      unawaited(RemoteBackgroundSync.instance.onAppResumed());
      // App 存活时点通知：MainActivity.onNewIntent 已把 extra 存成 pending，
      // 回到前台后在这里取走；重复调用由平台侧 take 语义保证只导航一次。
      unawaited(notificationNavigation.consume());
    }
  }

  @override
  Widget build(BuildContext context) => AppearanceScope(
    controller: appearance,
    child: ListenableBuilder(
      listenable: appearance,
      builder: (context, _) => DynamicColorBuilder(
        builder: (light, dark) => MaterialApp(
          title: 'Pocket Harness',
          navigatorKey: rootNavigator,
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          themeMode: appearance.mode,
          themeAnimationDuration:
              appearance.reduceMotion ||
                  MediaQuery.maybeOf(context)?.disableAnimations == true
              ? Duration.zero
              : const Duration(milliseconds: 250),
          theme: pocketTheme(
            Brightness.light,
            seed: appearance.dynamicColor
                ? light?.primary ?? Color(appearance.seed)
                : Color(appearance.seed),
            style: appearance.style,
          ),
          darkTheme: pocketTheme(
            Brightness.dark,
            seed: appearance.dynamicColor
                ? dark?.primary ?? Color(appearance.seed)
                : Color(appearance.seed),
            style: appearance.style,
            pureBlack: appearance.pureBlack,
          ),
          builder: (context, child) => PocketPrismScope(
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations:
                    appearance.reduceMotion ||
                    MediaQuery.disableAnimationsOf(context),
                textScaler: appearance.textScale == 0
                    ? MediaQuery.textScalerOf(context)
                    : TextScaler.linear(appearance.textScale),
              ),
              child: LiquidGlassScope(
                enabled: appearance.glassEnabled,
                quality: appearance.quality,
                child: LiquidGlassHost(
                  enabled: appearance.glassEnabled,
                  child: AccountQuotaNoticeHost(
                    runtime: runtime,
                    notices: quotaNotices,
                    openAccount: () {
                      rootNavigator.currentState?.push<void>(
                        PocketRoute<void>(
                          builder: (_) => AccountPage(runtime: runtime),
                        ),
                      );
                    },
                    child: child!,
                  ),
                ),
              ),
            ),
          ),
          home: ChatPage(key: chatKey, runtime: runtime),
        ),
      ),
    ),
  );
}

class ChatPage extends StatefulWidget {
  const ChatPage({required this.runtime, super.key});
  final RuntimeController runtime;
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  final input = TextEditingController();
  final inputFocus = FocusNode();
  final scaffold = GlobalKey<ScaffoldState>();
  late final ChatKeyboardShortcuts keyboardShortcuts;
  late String sessionId = widget.runtime.newSession();
  int sidebarSearchRequest = 0;
  int sessionNavigationEpoch = 0;
  final drafts = <String, TextEditingValue>{};
  final errors = <String, String>{};
  final submissions = <String>{};
  final commandDrafts = <String, Json>{};
  final localDraftSessions = <String>{};
  final skillDraftPreparation = <String, Future<void>>{};
  final skillCatalogs = <String, SessionSkillsController>{};
  final chatProjections = <String, ChatProjection>{};
  SessionModelProjection modelProjection = SessionModelProjection();
  late AttachmentDrafts attachments;
  late ChatGoalPlanController goalPlan;
  late WorkspaceChangesPreference codingTools;
  late CurrentModelCatalog currentModelCatalog;
  final messageScroll = ScrollController();
  bool navigationScheduled = false;
  bool drawerOpen = false;
  (String?, int)? notificationViewing;
  (String, int, Object?)? observedTimeline;
  int scrollRequest = 0;
  bool followPending = false;
  bool userScrolling = false;
  int? submittedAfterSeq;
  bool followSubmittedMessage = true;

  /// 输入卡的当前状态：纯浏览时缩小、聚焦/有草稿时展开、点推理按钮后显示强度面板。
  ///
  /// 与远程会话页同一套语义（`remote_dsh_conversation.dart`）：[PocketComposer]
  /// 是受控组件，状态由本页持有。草稿非空时即使在浏览态也按展开渲染（见
  /// [_composerModeFor]）；失焦且草稿为空才收缩，键盘收起且草稿为空也收缩。
  PocketComposerMode _composerMode = PocketComposerMode.browse;

  /// 当前会话模型目录；第一次打开推理面板时读一次，失败后可在面板里重试。
  ///
  /// 与 `SessionModelPage` 同一个读取入口（`api.call session.modelCatalog`），
  /// 档位与默认强度来自目录里当前模型声明的 `reasoning`。
  Json? _reasoningCatalog;
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

  bool get submitting => submissions.contains(sessionId);
  String? get submitError => errors[sessionId];
  set submitError(String? error) {
    if (error == null) {
      errors.remove(sessionId);
    } else {
      errors[sessionId] = error;
    }
  }

  RuntimeController get runtime => widget.runtime;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    inputFocus.addListener(_onComposerFocusChanged);
    // 全屏子页面（例如「远程 DSH」）原地挂出同一份侧栏，需要根页面的动作。
    registerAppShellActions(
      AppShellActions(
        newChat: newChat,
        openSession: (id) {
          if (mounted) unawaited(loadConversation(id));
        },
        openTasks: () => unawaited(openTasks()),
        openAutomations: openAutomations,
      ),
    );
    runtime.plugins.attach();
    unawaited(runtime.plugins.load());
    currentModelCatalog = CurrentModelCatalog(runtime);
    codingTools = WorkspaceChangesPreference(runtime);
    unawaited(codingTools.start());
    keyboardShortcuts = ChatKeyboardShortcuts(
      isActive: () => mounted && (ModalRoute.of(context)?.isCurrent ?? false),
      isComposing: () {
        final focused = FocusManager.instance.primaryFocus?.context;
        final editor = focused?.findAncestorWidgetOfExactType<EditableText>();
        return editor?.controller.value.composing.isValid ?? false;
      },
      isEditingOtherField: () {
        if (inputFocus.hasFocus) return false;
        final focused = FocusManager.instance.primaryFocus?.context;
        return focused?.findAncestorWidgetOfExactType<EditableText>() != null;
      },
      newChat: () {
        scaffold.currentState?.closeDrawer();
        newChat();
        inputFocus.requestFocus();
      },
      searchConversations: () {
        scaffold.currentState?.openDrawer();
        setState(() => sidebarSearchRequest++);
      },
      toggleSidebar: () {
        if (drawerOpen) {
          scaffold.currentState?.closeDrawer();
        } else {
          scaffold.currentState?.openDrawer();
        }
      },
      openSettings: () {
        scaffold.currentState?.closeDrawer();
        inputFocus.unfocus();
        navigate(SettingsPage(runtime: runtime));
      },
      canOpenSessionResource: () =>
          runtime.ready &&
          !localDraftSessions.contains(sessionId) &&
          ((runtime.timelines[sessionId]?.isNotEmpty ?? false) ||
              runtime.sessions.any(
                (item) => (item['header'] as Json?)?['id'] == sessionId,
              )),
      openFiles: openSessionFiles,
      openBrowser: () =>
          openSessionResource(SessionBrowserPage(runtime: runtime)),
      openTerminal: () => openSessionResource(
        SessionTerminalsPage(
          runtime: runtime,
          sessionId: sessionId,
          shellSource: TerminalShellCatalog(runtime),
        ),
      ),
      focusComposer: inputFocus.requestFocus,
      dismiss: () {
        if (inputFocus.hasFocus) {
          inputFocus.unfocus();
          return true;
        }
        if (drawerOpen) {
          scaffold.currentState?.closeDrawer();
          return true;
        }
        return false;
      },
    )..attach();
    localDraftSessions.add(sessionId);
    runtime.addListener(handleNavigation);
    attachments = AttachmentDrafts(runtime)..addListener(attachmentChanged);
    connectGoalPlan();
    handleNavigation();
  }

  void connectGoalPlan() {
    goalPlan = ChatGoalPlanController(runtime: runtime, sessionId: sessionId);
    unawaited(goalPlan.start());
  }

  @override
  void didUpdateWidget(ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != runtime) {
      oldWidget.runtime.plugins.detach();
      runtime.plugins.attach();
      unawaited(runtime.plugins.load());
      currentModelCatalog.dispose();
      currentModelCatalog = CurrentModelCatalog(runtime);
      codingTools.dispose();
      codingTools = WorkspaceChangesPreference(runtime);
      unawaited(codingTools.start());
      sessionNavigationEpoch++;
      goalPlan.dispose();
      connectGoalPlan();
      for (final catalog in skillCatalogs.values) {
        catalog.dispose();
      }
      skillCatalogs.clear();
      skillDraftPreparation.clear();
      chatProjections.clear();
      modelProjection = SessionModelProjection();
      oldWidget.runtime.removeListener(handleNavigation);
      attachments.removeListener(attachmentChanged);
      attachments.dispose();
      attachments = AttachmentDrafts(runtime)..addListener(attachmentChanged);
      runtime.addListener(handleNavigation);
      handleNavigation();
    }
  }

  void handleNavigation() {
    if (!mounted ||
        navigationScheduled ||
        (!runtime.ready &&
            ![
              'account',
              'tasks',
            ].contains(runtime.navigationRequest?['route'])) ||
        runtime.navigationRequest == null) {
      return;
    }
    navigationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigationScheduled = false;
      if (!mounted) return;
      final request = runtime.navigationRequest;
      if (request == null ||
          (!runtime.ready &&
              !['account', 'tasks'].contains(request['route']))) {
        return;
      }
      runtime.consumeNavigation();
      if (request['route'] == 'account') {
        scaffold.currentState?.closeDrawer();
        inputFocus.unfocus();
        navigate(AccountPage(runtime: runtime));
        return;
      }
      if (request['route'] == 'tasks') {
        scaffold.currentState?.closeDrawer();
        inputFocus.unfocus();
        unawaited(openTasks());
        return;
      }
      if (request['route'] == 'session' &&
          request['sessionId'] is String &&
          (request['sessionId'] as String).trim().isNotEmpty) {
        scaffold.currentState?.closeDrawer();
        inputFocus.unfocus();
        final chatRoute = ModalRoute.of(context);
        Navigator.of(context).popUntil((route) => route == chatRoute);
        final id = request['sessionId'] as String;
        activateSession(id);
        unawaited(readNotifiedSession(id));
        return;
      }
      if (request['route'] != 'approval' ||
          request['requestId'] is! String ||
          request['requestVersion'] is! int) {
        return;
      }
      scaffold.currentState?.closeDrawer();
      inputFocus.unfocus();
      navigate(
        ApprovalsPage(
          runtime: runtime,
          requestId: request['requestId'] as String,
          requestVersion: request['requestVersion'] as int,
        ),
      );
    });
    // Navigation must schedule its own frame, including when a hidden page's
    // runtime selection correctly ignores this otherwise unrelated event.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    registerAppShellActions(null);
    WidgetsBinding.instance.removeObserver(this);
    inputFocus.removeListener(_onComposerFocusChanged);
    runtime.plugins.detach();
    currentModelCatalog.dispose();
    keyboardShortcuts.dispose();
    codingTools.dispose();
    unawaited(publishNotificationViewing(null));
    goalPlan.dispose();
    for (final catalog in skillCatalogs.values) {
      catalog.dispose();
    }
    runtime.removeListener(handleNavigation);
    attachments.removeListener(attachmentChanged);
    attachments.dispose();
    input.dispose();
    inputFocus.dispose();
    messageScroll.dispose();
    super.dispose();
  }

  /// 推入一个全屏目的地。
  ///
  /// [destination] 是去重标识：同一个目的地不会在栈上叠第二层（见
  /// [openDestination]）。缺省用页面类型作标识，因此任何页面被重复推入都会被
  /// 拦下；需要与侧栏入口共用同一标识时（如后台任务、自动化任务）显式传入。
  void navigate(Widget page, {String? destination}) {
    unawaited(
      openDestination<void>(
        context,
        destination: destination ?? page.runtimeType.toString(),
        builder: (_) => page,
      ).then((_) {
        if (mounted) unawaited(currentModelCatalog.refresh());
      }),
    );
  }

  void openSessionResource(Widget page) {
    scaffold.currentState?.closeDrawer();
    inputFocus.unfocus();
    navigate(page);
  }

  /// 打开通知里的远程会话：回到根对话页，再推入远程首页并在连接就绪后打开会话。
  ///
  /// 远程首页是稳定目的地（见 [RemoteDshPage.routeDestination]）；已经压着别的全屏
  /// 页时先退回根页，避免同一目的地在栈上叠第二层，也保证用户按返回键回到聊天。
  /// 真正的打开时机与失败提示由远程首页处理（它需要等连接就绪并读会话列表）。
  void openRemoteNotification(RemoteNotificationLaunch launch) {
    final chatRoute = ModalRoute.of(context);
    if (chatRoute == null) return;
    scaffold.currentState?.closeDrawer();
    inputFocus.unfocus();
    Navigator.of(context)
        .popUntil((route) => route == chatRoute || route.isFirst);
    navigate(
      RemoteDshPage(
        runtime: runtime,
        notificationLaunch: launch.isHome ? null : launch,
      ),
      destination: RemoteDshPage.routeDestination,
    );
  }

  void openSessionFiles() {
    openSessionResource(
      SessionFilesPage(
        runtime: runtime,
        sessionId: sessionId,
        onOpenDocument: (context, id, path) => Navigator.of(context).push<void>(
          PocketRoute<void>(
            builder: (_) => SessionDocumentPage(
              runtime: runtime,
              sessionId: id,
              path: path,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> readNotifiedSession(String id) async {
    try {
      await runtime.openSession(id);
    } catch (failure) {
      if (mounted) setState(() => errors[id] = '读取会话失败：$failure');
    }
  }

  Future<void> publishNotificationViewing(String? id) async {
    try {
      await RuntimeController.channel.invokeMethod<void>(
        'notifications.viewing',
        {'sessionId': id},
      );
    } catch (failure) {
      // This optional suppression cannot interrupt reading. Native lifecycle
      // still clears its foreground state when the Activity leaves the screen.
      debugPrint('Notification visibility could not be synchronized');
    }
  }

  void synchronizeNotificationViewing() {
    final visible = !drawerOpen && (ModalRoute.of(context)?.isCurrent ?? true);
    final next = (visible ? sessionId : null, runtime.connectionGeneration);
    if (notificationViewing == next) return;
    notificationViewing = next;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && notificationViewing == next) {
        unawaited(publishNotificationViewing(next.$1));
      }
    });
  }

  void attachmentChanged() {
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------ 输入卡状态

  @override
  void didChangeMetrics() {
    // 键盘与安全区变化会改变输入卡可用高度；下一帧 MediaQuery 更新完再看一次
    // 键盘是否还在，决定收缩回浏览态还是保持展开。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncComposerWithKeyboard();
    });
  }

  /// 键盘显隐后同步输入卡状态。
  ///
  /// 只处理**真正的显隐变化**：连续 metrics 事件里 insets 一直为 0 的抖动不改
  /// 状态（聚焦时 Android 会先派发这种事件，误判会让卡片刚展开就缩回并解焦）。
  /// 键盘真正收起时推理面板保持可见（用户可能只是收起键盘还想调强度，点聊天区
  /// 或表盘再退出）；输入态按草稿决定：有草稿保持展开，纯浏览缩回缩小态。
  void _syncComposerWithKeyboard() {
    if (!mounted) return;
    final visible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final wasVisible = _keyboardVisible;
    _keyboardVisible = visible;
    if (visible == wasVisible) return;
    if (visible) {
      if (_composerMode == PocketComposerMode.browse) {
        setState(() => _composerMode = PocketComposerMode.composing);
      }
      return;
    }
    if (_composerMode == PocketComposerMode.picker) return;
    if (input.text.trim().isNotEmpty) return;
    setState(() => _composerMode = PocketComposerMode.browse);
    // 故意不在此处解焦：真机上「键盘闪现后又隐藏」的抖动不应把焦点也丢掉；
    // 缩小态点卡片会再次 requestFocus + TextInput.show，键盘可立刻回来。
  }

  /// 把焦点交给输入框，并在下一帧补一次输入法显示请求。
  ///
  /// 真机上出现过「卡片展开了但键盘没起来」：输入框已经聚焦、IME 却被系统藏起
  /// 时，再点一次输入框不会自动重新显示。focus 完成后在下一帧调
  /// `TextInput.show`（没有活动输入连接时是空操作），保证一次点按就能进入输入。
  void _requestInputFocus() {
    if (!inputFocus.hasFocus) inputFocus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !inputFocus.hasFocus) return;
      unawaited(_showInput());
    });
  }

  Future<void> _showInput() async {
    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    } on Object {
      // 测试环境或输入连接尚未建立时通道可能不可用：忽略即可，点按展开不依赖它。
    }
  }

  /// 点输入卡（含缩小态空白处）时先展开并聚焦，不等输入框自己抢焦点。
  ///
  /// 真机上缩小态的 TextField 只有一行高度，点卡片空白处不会命中它；组件内部
  /// 也有兜底，这里再补一次页面级的 focus + 下一帧 IME 请求，确保一次点按就能
  /// 进入输入并弹出键盘（与远程会话页同一做法）。
  void _onComposerPointerDown() {
    if (_composerMode == PocketComposerMode.picker) return;
    if (_composerMode == PocketComposerMode.browse) {
      setState(() => _composerMode = PocketComposerMode.composing);
    }
    _requestInputFocus();
  }

  /// 聚焦即展开；失焦只在草稿为空时收缩（草稿非空保持展开）。
  void _onComposerFocusChanged() {
    if (!mounted) return;
    if (inputFocus.hasFocus) {
      if (_composerMode == PocketComposerMode.browse) {
        setState(() => _composerMode = PocketComposerMode.composing);
      }
      return;
    }
    if (input.text.trim().isEmpty &&
        _composerMode == PocketComposerMode.composing) {
      setState(() => _composerMode = PocketComposerMode.browse);
    }
  }

  /// 交给组件的渲染状态：草稿非空时即使失焦也按展开渲染；推理面板优先。
  PocketComposerMode _composerModeFor({required bool hasDraft}) {
    if (_composerMode == PocketComposerMode.picker) {
      return PocketComposerMode.picker;
    }
    if (hasDraft) return PocketComposerMode.composing;
    return _composerMode;
  }

  /// 发送或切换会话后按当前草稿重新定状态：空草稿且没有焦点时缩回浏览态。
  void _settleComposerMode() {
    if (_composerMode == PocketComposerMode.picker) return;
    _composerMode = input.text.trim().isEmpty && !inputFocus.hasFocus
        ? PocketComposerMode.browse
        : PocketComposerMode.composing;
  }

  // ------------------------------------------------------------ 输入卡入口

  /// 「+」：复用本地那套数据驱动的 `ComposerCommands`，外壳与远程会话页一致
  /// （底部弹层，`showRemoteCommandsSheet`）。
  void _openComposerCommands() {
    _exitReasoningPanel(keepKeyboard: false);
    inputFocus.unfocus();
    final id = sessionId;
    unawaited(
      showRemoteCommandsSheet(
        context,
        builder: (sheetContext) => ComposerCommands(
          runtime: runtime,
          sessionId: id,
          deferActivation:
              !localDraftSessions.contains(id) &&
              !['idle', 'running', 'waiting'].contains(runtime.statuses[id]),
          maxHeight:
              (MediaQuery.sizeOf(sheetContext).height -
                      MediaQuery.paddingOf(sheetContext).vertical -
                      MediaQuery.viewInsetsOf(sheetContext).bottom -
                      40)
                  .clamp(100.0, 520.0),
          onPick: pickCommand,
        ),
      ),
    );
  }

  /// 盾牌：打开本地权限预设页。
  ///
  /// 本地没有常驻的权限目录投影；这里懒读一次会话指令目录拿到 `/permission`
  /// 的描述（`SessionPermissionPage` 用它拼指令行），读不到就在输入卡上方给出
  /// 可见原因，而不是留一个点了没反应的按钮。
  Future<void> _openSessionPermissions() async {
    if (!runtime.ready) return;
    _exitReasoningPanel(keepKeyboard: false);
    inputFocus.unfocus();
    final id = sessionId;
    try {
      final catalog = await loadComposerCatalog(runtime, id);
      if (!mounted || id != sessionId || !runtime.ready) return;
      final command = composerCommandRows(catalog)
          .where((row) => composerCommandKey(row) == 'permission')
          .firstOrNull;
      if (command == null) throw StateError('当前会话没有权限预设指令');
      await Navigator.of(context).push(
        PocketRoute<void>(
          builder: (_) => SessionPermissionPage(
            runtime: runtime,
            sessionId: id,
            command: command,
          ),
        ),
      );
    } catch (failure) {
      if (mounted) {
        setState(() => errors[id] = '无法打开权限预设：$failure');
      }
    }
  }

  /// 推理按钮：进入/退出强度面板；打开时保持键盘（输入框离屏但仍有焦点）。
  ///
  /// 打开时立刻把焦点与输入法还给输入框，并在下一帧再确认一次：点按工具条按钮
  /// 时焦点可能在触摸抬手后才交还，晚一拍会让键盘在面板出现的同时被收起。
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

  /// 收起强度面板回到输入态。
  ///
  /// [keepKeyboard] 为 true（点表盘、发送）时把焦点与键盘还给输入框；为 false
  /// （点聊天区、打开别的弹层）时按当前键盘与草稿决定：键盘收起且没有草稿就回到
  /// 缩小态，否则回到展开态但不主动唤起键盘。
  void _exitReasoningPanel({bool keepKeyboard = true}) {
    if (_composerMode != PocketComposerMode.picker) return;
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final expand =
        keepKeyboard || keyboardVisible || input.text.trim().isNotEmpty;
    setState(
      () => _composerMode = expand
          ? PocketComposerMode.composing
          : PocketComposerMode.browse,
    );
    if (keepKeyboard) {
      _requestInputFocus();
    } else if (!expand && inputFocus.hasFocus) {
      inputFocus.unfocus();
    }
  }

  /// 读一次会话模型目录：只为强度面板的档位与默认值，失败后可在面板里重试。
  Future<void> _loadReasoningCatalog() async {
    if (_reasoningLoading) return;
    final id = sessionId;
    final owner = runtime;
    final generation = owner.connectionGeneration;
    setState(() {
      _reasoningLoading = true;
      _reasoningError = null;
    });
    try {
      await owner.ensureSession(id);
      final catalog = await modelsApi(owner, 'session', 'modelCatalog');
      if (catalog is! Json) throw const FormatException('模型目录数据不完整');
      if (!mounted || id != sessionId || owner != runtime) return;
      if (generation != owner.connectionGeneration || !owner.ready) return;
      setState(() => _reasoningCatalog = catalog);
    } catch (failure) {
      if (mounted && id == sessionId) {
        setState(() => _reasoningError = '读取模型目录失败：$failure');
      }
    } finally {
      if (mounted) setState(() => _reasoningLoading = false);
    }
  }

  /// 提交一次推理强度切换：与 `SessionModelPage` 同一个 `session.selectModel`。
  ///
  /// 当前选择写进会话日志（`model/selection`），页面上的模型回显与强度面板都从
  /// 会话投影刷新，因此这里不做乐观状态。
  Future<void> _applyReasoningEffort(Json selection, String effort) async {
    if (_reasoningApplying) return;
    final model = _reasoningModel(selection);
    final fallback =
        model?['reasoning']?['defaultEffort'] ??
        _reasoningCatalog?['default']?['reasoningEffort'];
    final current = selection['reasoningEffort'] ?? fallback;
    if (current == effort) return;
    final id = sessionId;
    final owner = runtime;
    setState(() {
      _reasoningApplying = true;
      _reasoningError = null;
    });
    try {
      await owner.ensureSession(id);
      await modelsApi(owner, 'session', 'selectModel', {
        'request': {
          'sessionId': id,
          if (selection['provider'] is String)
            'provider': selection['provider'],
          if (selection['model'] is String) 'model': selection['model'],
          'reasoningEffort': effort,
        },
      });
    } catch (failure) {
      if (mounted && id == sessionId) {
        setState(() => _reasoningError = '切换推理强度失败：$failure');
      }
    } finally {
      if (mounted) setState(() => _reasoningApplying = false);
    }
  }

  /// 模型目录里按当前选择找到模型声明；找不到时面板只显示模型名。
  Json? _reasoningModel(Json selection) {
    final groups = _reasoningCatalog?['groups'];
    if (groups is! List) return null;
    for (final group in groups) {
      if (group is! Map || group['id'] != selection['provider']) continue;
      final models = group['models'];
      if (models is! List) continue;
      for (final model in models) {
        if (model is! Map || model['id'] != selection['model']) continue;
        return Map<String, dynamic>.from(model);
      }
    }
    return null;
  }

  /// 强度面板的数据：当前模型、可调档位与切换入口；档位来自会话模型目录。
  PocketReasoningPanel _reasoningPanel(Json selection) {
    final model = _reasoningModel(selection);
    final reasoning = model?['reasoning'];
    final efforts = reasoning is Map && reasoning['efforts'] is List
        ? (reasoning['efforts'] as List).cast<Json>()
        : const <Json>[];
    final defaultEffort =
        reasoning is Map && reasoning['defaultEffort'] is String
        ? reasoning['defaultEffort'] as String
        : null;
    final selected = selection['reasoningEffort'] as String? ?? defaultEffort;
    final modelName = model?['name'];
    return PocketReasoningPanel(
      modelLabel: modelName is String && modelName.trim().isNotEmpty
          ? modelName
          : '${selection['model'] ?? '当前模型'}',
      effortLabel: reasoningEffortLabel(selected),
      stops: <PocketReasoningStop>[
        for (final effort in efforts)
          if (effort['id'] is String)
            PocketReasoningStop(
              id: effort['id'] as String,
              label: reasoningEffortLabel(
                effort['id'] as String,
                fallback: effort['name'] is String
                    ? effort['name'] as String
                    : null,
              ),
            ),
      ],
      selectedId: selected,
      loading: _reasoningLoading && _reasoningCatalog == null,
      error: _reasoningError,
      busy: _reasoningApplying,
      onOpenModels: () => _openModelsFromReasoningPanel(),
      onRetry: () => unawaited(_loadReasoningCatalog()),
      onSelected: _reasoningApplying
          ? null
          : (effort) => unawaited(_applyReasoningEffort(selection, effort)),
    );
  }

  /// 从强度面板第一行打开完整模型选择：先收起面板再推既有会话模型页。
  void _openModelsFromReasoningPanel() {
    _exitReasoningPanel(keepKeyboard: false);
    inputFocus.unfocus();
    navigate(SessionModelPage(runtime: runtime, sessionId: sessionId));
  }

  /// 发送草稿：先收起强度面板，再走既有发送逻辑。
  void _sendDraft() {
    _exitReasoningPanel();
    unawaited(send());
  }

  /// 停止当前任务；失败原因显示在输入卡上方（与发送错误同一个位置）。
  Future<void> _cancelTask() async {
    final id = sessionId;
    try {
      await runtime.call('session.cancel', {'sessionId': id});
    } catch (error) {
      if (mounted) setState(() => errors[id] = '$error');
    }
  }

  /// 悬浮卡上方的插槽：引用/斜杠建议、命令 chip、附件 rail、等待授权提示与错误。
  ///
  /// 这些入口在缩小态也保持可见（附件、命令 chip、等待授权都不能因为卡片收起
  /// 而藏起来），顺序与悬浮卡之前的输入区一致。
  Widget _composerTop(BuildContext context, List<Json> sessionRequests) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ComposerReferenceSuggestions(
          key: ValueKey((runtime, sessionId)),
          runtime: runtime,
          sessionId: sessionId,
          input: input,
          focus: inputFocus,
          prepare: prepareReferences(sessionId),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: input,
          builder: (context, value, _) {
            final query = RegExp(r'^\s*/([^\s]*)$')
                .firstMatch(value.text)
                ?.group(1);
            if (query == null || commandDrafts[sessionId] != null) {
              return const SizedBox.shrink();
            }
            final id = sessionId;
            return ComposerSlashSuggestions(
              key: ValueKey((runtime, id)),
              runtime: runtime,
              sessionId: id,
              query: query,
              skills: skillsFor(id),
              onCommand: (command) => pickTypedCommand(id, command),
              onSkill: (skill) => insertSkill(id, skill),
              onMoreSkills: pickSkill,
            );
          },
        ),
        if (commandDrafts[sessionId] != null)
          ComposerCommandChip(
            command: commandDrafts[sessionId]!,
            onRemove: () => setState(() => commandDrafts.remove(sessionId)),
          ),
        PocketAttachmentRail(drafts: attachments, sessionId: sessionId),
        if (sessionRequests.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: GlassSurface(
              radius: 22,
              child: PocketTile(
                leading: const Icon(Icons.pending_actions_rounded),
                title: Text(
                  sessionRequests.length == 1
                      ? sessionRequests.first['kind'] == 'approval'
                            ? '任务需要你的授权'
                            : '任务有问题等待回答'
                      : '${sessionRequests.length} 项请求等待处理',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => navigate(
                  ApprovalsPage(
                    runtime: runtime,
                    requestId: sessionRequests.length == 1
                        ? sessionRequests.first['id'] as String
                        : null,
                    requestVersion: sessionRequests.length == 1
                        ? sessionRequests.first['version'] as int
                        : null,
                  ),
                ),
              ),
            ),
          ),
        if (submitError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              submitError!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.error, fontSize: 13),
            ),
          ),
      ],
    );
  }

  void activateSession(String id) {
    if (id == sessionId) return;
    sessionNavigationEpoch++;
    drafts[sessionId] = input.value;
    goalPlan.dispose();
    setState(() {
      sessionId = id;
      submittedAfterSeq = null;
      followSubmittedMessage = true;
      connectGoalPlan();
      input.value = drafts[id] ?? TextEditingValue.empty;
      _settleComposerMode();
    });
  }

  void newChat() {
    final id = runtime.newSession();
    localDraftSessions.add(id);
    activateSession(id);
  }

  /// 打开自动化任务页。全屏子页面经 [AppShellActions] 复用同一条动作。
  void openAutomations() {
    navigate(
      AutomationsPage(
        runtime: runtime,
        onNewTask: () {
          Navigator.of(context).popUntil((route) => route.isFirst);
          newChat();
        },
        onOpenSession: (id) {
          Navigator.of(context).popUntil((route) => route.isFirst);
          unawaited(loadConversation(id));
        },
      ),
      destination: 'automations',
    );
  }

  Future<void> prepareSkillDraft(String id) {
    if (!localDraftSessions.contains(id)) {
      return Future.error(StateError('会话已不可访问'));
    }
    return skillDraftPreparation.putIfAbsent(id, () async {
      try {
        await runtime.ensureSession(id);
        localDraftSessions.remove(id);
      } finally {
        skillDraftPreparation.remove(id);
      }
    });
  }

  Future<void> Function() prepareReferences(String id) =>
      () => localDraftSessions.contains(id)
      ? prepareSkillDraft(id)
      : runtime.ensureSession(id).then((_) {});

  Future<void> pickSkill() async {
    final id = sessionId;
    final skill = await Navigator.of(context).push<SessionSkill>(
      PocketRoute<SessionSkill>(
        builder: (_) => SessionSkillsPage(controller: skillsFor(id)),
      ),
    );
    if (!mounted || skill == null) return;
    insertSkill(id, skill);
  }

  SessionSkillsController skillsFor(String id) => skillCatalogs.putIfAbsent(
    id,
    () => SessionSkillsController(
      runtime,
      id,
      prepareDraft: localDraftSessions.contains(id)
          ? () => prepareSkillDraft(id)
          : null,
    )..start(),
  );

  Future<void> openSkillReference(String id, String name) async {
    final owner = runtime;
    final connection = owner.connectionGeneration;
    final navigation = sessionNavigationEpoch;
    final catalog = skillsFor(id);
    await catalog.load();
    if (!mounted ||
        sessionId != id ||
        navigation != sessionNavigationEpoch ||
        owner != runtime ||
        connection != runtime.connectionGeneration ||
        !runtime.ready) {
      return;
    }
    final skill = catalog.skills
        .where((entry) => entry.name == name)
        .firstOrNull;
    if (!catalog.current || skill?.path == null) {
      throw StateError('此技能的说明当前不可访问');
    }
    await Navigator.of(context).push<void>(
      PocketRoute<void>(
        builder: (_) => SessionDocumentPage(
          runtime: runtime,
          sessionId: id,
          path: skill!.path!,
        ),
      ),
    );
  }

  void insertSkill(String id, SessionSkill skill) {
    setState(() {
      final draft = id == sessionId
          ? input.value
          : drafts[id] ?? TextEditingValue.empty;
      final next = insertSessionSkill(draft, skill.name);
      drafts[id] = next;
      commandDrafts.remove(id);
      if (id == sessionId) input.value = next;
    });
    if (id == sessionId) inputFocus.requestFocus();
  }

  /// Insert one transcript message as a Markdown blockquote in the composer.
  void quoteMessage(String text) {
    final id = sessionId;
    setState(() {
      final draft = drafts[id] ?? input.value;
      final next = insertMessageQuote(draft, text);
      if (identical(next, draft)) return;
      drafts[id] = next;
      if (id == sessionId) input.value = next;
    });
    if (id == sessionId) inputFocus.requestFocus();
  }

  void pickCommand(Json command) {
    switch (builtinCommand(command) ?? command['clientAction']) {
      case 'file':
        unawaited(attachments.pick(sessionId));
      case 'skills':
        unawaited(pickSkill());
      case 'configure-models':
        navigate(ModelsPage(runtime: runtime));
      case 'model':
        navigate(SessionModelPage(runtime: runtime, sessionId: sessionId));
      case 'goal':
        inputFocus.unfocus();
        unawaited(goalPlan.refresh());
        unawaited(openChatGoal(context, goalPlan));
      case 'plan':
        inputFocus.unfocus();
        unawaited(goalPlan.refresh());
        unawaited(openChatPlanMode(context, goalPlan));
      case 'feedback':
        inputFocus.unfocus();
        navigate(SessionFeedbackPage(runtime: runtime, sessionId: sessionId));
      case 'permission':
        navigate(
          SessionPermissionPage(
            runtime: runtime,
            sessionId: sessionId,
            command: command,
          ),
        );
      case 'export':
        final session = runtime.sessions
            .where((item) => (item['header'] as Json)['id'] == sessionId)
            .firstOrNull;
        navigate(
          SessionExportPage(
            runtime: runtime,
            sessionId: sessionId,
            sessionTitle: session == null ? '新对话' : sessionTitle(session),
          ),
        );
      default:
        if (command['input'] == null) {
          unawaited(runDetached(command, sessionId));
        } else {
          setState(() => commandDrafts[sessionId] = command);
          inputFocus.requestFocus();
        }
    }
  }

  void pickTypedCommand(String id, Json command) {
    if (id != sessionId ||
        !RegExp(r'^\s*/[^\s]*$').hasMatch(input.text) ||
        commandDrafts[id] != null) {
      return;
    }
    // The typed trigger is consumed only after a user picks a visible row.
    // The same command action handles selection from the + menu and here.
    input.clear();
    drafts.remove(id);
    pickCommand(command);
  }

  Future<void> runDetached(Json command, String id) async {
    if (submissions.contains(id)) {
      setState(() => errors[id] = '当前提交尚未确认，请稍后再执行指令。');
      return;
    }
    setState(() {
      submissions.add(id);
      errors.remove(id);
    });
    try {
      final response = await runtime.call('session.command', {
        'sessionId': id,
        'line': '/${command['name']}',
        'attachmentIds': [],
      }) as Json?;
      if (response == null) throw StateError('指令已不可用，请重新打开会话菜单。');
      if (response['result']['kind'] == 'error' && mounted) {
        setState(() => errors[id] = '${response['result']['text']}');
      }
    } catch (failure) {
      if (mounted) setState(() => errors[id] = '指令执行结果未确认，请核对会话记录：$failure');
    } finally {
      if (mounted) setState(() => submissions.remove(id));
    }
  }

  Future<void> openTasks() async {
    final id = await openDestination<String>(
      context,
      destination: 'tasks',
      builder: (_) => TasksPage(runtime: runtime, sessionId: sessionId),
    );
    if (!mounted || id == null) return;
    activateSession(id);
    try {
      await runtime.openSession(id);
    } catch (error) {
      if (mounted) setState(() => errors[id] = '$error');
    }
  }

  Future<void> send() async {
    final text = input.text.trim();
    final sendingId = sessionId;
    final pickedCommand = commandDrafts[sendingId];
    var command = pickedCommand;
    var commandLine = command == null
        ? null
        : '/${command['name']}${text.isEmpty ? '' : ' $text'}';
    if (submissions.contains(sendingId)) return;
    if (!attachments.ready(sendingId)) {
      setState(() => errors[sendingId] = '附件尚未准备完成，请重试或移除失败项。');
      return;
    }
    final attachedIds = attachments.snapshotIds(sendingId);
    if (text.isEmpty && attachedIds.isEmpty && command == null) return;
    if (command != null &&
        attachedIds.isNotEmpty &&
        command['input']?['attachments'] != true) {
      final name = command['name'];
      setState(() => errors[sendingId] = '/$name 不接受附件，请先移除附件。');
      return;
    }
    drafts[sendingId] = input.value;
    final previousSubmittedAfterSeq = submittedAfterSeq;
    final previousFollowSubmittedMessage = followSubmittedMessage;
    setState(() {
      submissions.add(sendingId);
      errors.remove(sendingId);
    });
    try {
      if (command == null && text.startsWith('/')) {
        final catalog = await loadComposerCatalog(runtime, sendingId);
        final typed = typedComposerCommand(text, catalog);
        if (typed != null) {
          command = typed.descriptor;
          commandLine = typed.line;
          final action = builtinCommand(command) ?? command['clientAction'];
          if (typed.bare &&
              [
                'file',
                'model',
                'permission',
                'export',
                'goal',
                'plan',
                'feedback',
              ].contains(action)) {
            if (attachedIds.isNotEmpty &&
                action != 'file' &&
                action != 'export') {
              throw StateError('/${command['name']} 不接受附件，请先移除附件。');
            }
            if (!mounted) return;
            if (sessionId != sendingId) throw StateError('请返回原会话继续此操作，原草稿已保留。');
            if (input.text.trim() == text) {
              input.clear();
              drafts.remove(sendingId);
              _settleComposerMode();
            }
            pickCommand(command);
            return;
          }
          if (attachedIds.isNotEmpty &&
              command['input']?['attachments'] != true) {
            throw StateError('/${command['name']} 不接受附件，请先移除附件。');
          }
        }
      }
      if (command != null) {
        final response = await runtime.call('session.command', {
          'sessionId': sendingId,
          'line': commandLine,
          'attachmentIds': attachedIds,
        }) as Json?;
        if (response == null) throw StateError('这条指令已不可用，请重新打开会话菜单。');
        if (response['result']['kind'] == 'error') {
          if (mounted) {
            setState(() => errors[sendingId] = '${response['result']['text']}');
          }
          return;
        }
      } else {
        if (mounted && sessionId == sendingId) {
          final events = runtime.timelines[sendingId] ?? const <Json>[];
          setState(() {
            submittedAfterSeq = events.isEmpty ? -1 : events.last['seq'] as int;
            followSubmittedMessage = true;
            scrollRequest++;
            followPending = false;
          });
          inputFocus.unfocus();
        }
        if (attachedIds.isNotEmpty) {
          await runtime.sendAttachments(sendingId, text, attachedIds);
        } else {
          await runtime.send(sendingId, text);
        }
      }
      if (!mounted) return;
      localDraftSessions.remove(sendingId);
      final draft = sendingId == sessionId ? input.value : drafts[sendingId];
      if (draft?.text.trim() == text &&
          identical(commandDrafts[sendingId], pickedCommand)) {
        drafts.remove(sendingId);
        commandDrafts.remove(sendingId);
        if (sendingId == sessionId) {
          input.clear();
          _settleComposerMode();
        }
      }
      await attachments.consume(sendingId, attachedIds);
    } catch (error) {
      if (mounted) {
        final admitted = (runtime.timelines[sendingId] ?? const <Json>[]).any(
          (event) =>
              event['type'] == 'user/message' &&
              (event['seq'] as int) > (submittedAfterSeq ?? -1) &&
              event['data']?['source']?['kind'] == 'user',
        );
        if (command == null && sessionId == sendingId && !admitted) {
          submittedAfterSeq = previousSubmittedAfterSeq;
          followSubmittedMessage = previousFollowSubmittedMessage;
        }
        setState(
          () => errors[sendingId] = command == null
              ? '$error'
              : '指令执行结果未确认，草稿已保留，请先核对会话记录。\n$error',
        );
      }
    } finally {
      if (mounted) setState(() => submissions.remove(sendingId));
    }
  }

  Future<void> loadConversation(String id) async {
    activateSession(id);
    try {
      await runtime.openSession(id);
    } catch (error) {
      if (mounted) setState(() => errors[id] = '$error');
    }
  }

  Future<String?> forkConversationAt(
    String sourceId,
    int atSeq,
    int connectionGeneration,
  ) async {
    if (!mounted || sessionId != sourceId) return '会话已切换，请从原会话重新选择回复。';
    if (runtime.connectionGeneration != connectionGeneration) {
      return '连接已变化，请刷新原会话后重新选择回复。';
    }
    final library = runtime.library..start();
    if (!library.canWrite) return '会话目录尚未同步，请稍后重试。';
    final key = 'fork:$sourceId:$atSeq';
    if (!library.allowed(key)) {
      return library.actions[key]?.message ?? '此前的分支结果尚未确认，请先核对工作区与会话。';
    }
    final receipt = await library.mutate(key, 'sessionFork', {
      'sessionId': sourceId,
      'atSeq': atSeq,
      'increaseTitle': true,
    });
    if (receipt == null) {
      return library.actions[key]?.message ?? '分支结果尚未确认，请先核对工作区与会话。';
    }
    final childId = receipt['sessionId'];
    if (childId is! String || childId.isEmpty) {
      return '分支已创建，但无法读取新会话编号。请从工作区与会话打开。';
    }
    // The mutation is already confirmed. A failed or interrupted history read
    // must not turn it into a retryable fork or replace the source conversation.
    if (!mounted || sessionId != sourceId) {
      return '已创建分支会话 $childId，请从工作区与会话打开。';
    }
    final generation = runtime.connectionGeneration;
    try {
      await runtime.openSession(childId);
    } catch (_) {
      return '已创建分支会话 $childId，但暂时无法打开。请从工作区与会话打开。';
    }
    if (!mounted ||
        sessionId != sourceId ||
        runtime.connectionGeneration != generation ||
        !runtime.timelines.containsKey(childId)) {
      return '已创建分支会话 $childId，请从工作区与会话打开。';
    }
    activateSession(childId);
    return null;
  }

  void followReply(int count, Object? streaming) {
    final next = (sessionId, count, streaming);
    if (next == observedTimeline) return;
    final switching = observedTimeline?.$1 != sessionId;
    observedTimeline = next;
    if (submittedAfterSeq != null) return;
    if (userScrolling && !switching) return;
    final follows =
        switching ||
        followPending ||
        !messageScroll.hasClients ||
        messageScroll.position.extentAfter < 80;
    if (!follows) return;
    final request = ++scrollRequest;
    followPending = true;
    final observedSession = sessionId;
    var layouts = 0;
    var settled = 0;
    // Lazy variable-height rows refine the estimated end after each layout.
    // Follow that refinement, but yield immediately to a user's drag.
    void settle(Duration _) {
      if (!mounted ||
          sessionId != observedSession ||
          request != scrollRequest ||
          !messageScroll.hasClients) {
        if (request == scrollRequest) followPending = false;
        return;
      }
      final position = messageScroll.position;
      if (position.extentAfter <= .5) {
        settled++;
      } else {
        settled = 0;
        messageScroll.jumpTo(position.maxScrollExtent);
      }
      if (++layouts < 32 && settled < 2) {
        WidgetsBinding.instance.addPostFrameCallback(settle);
        WidgetsBinding.instance.ensureVisualUpdate();
      } else {
        followPending = false;
      }
    }

    WidgetsBinding.instance.addPostFrameCallback(settle);
  }

  void suggest(String text) {
    input.text = text;
    input.selection = TextSelection.collapsed(offset: text.length);
    inputFocus.requestFocus();
  }

  String sessionTitle(Json session) {
    final header = session['header'] as Json;
    final id = header['id'] as String;
    final events = runtime.timelines[id];
    if (events != null) {
      chatProjections.putIfAbsent(id, ChatProjection.new).reconcile(events);
    }
    return '${session['title'] ?? chatProjections[id]?.title ?? header['title'] ?? id}';
  }

  @override
  Widget build(BuildContext context) => RuntimeSelectionBuilder(
    runtime: runtime,
    select: () => (
      runtime.connectionGeneration,
      runtime.phase,
      runtime.error,
      runtime.provider,
      runtime.model,
      runtime.reasoningEffort,
      runtime.sessions,
      runtime.timelines[sessionId],
      runtime.timelines[sessionId]?.length,
      runtime.liveStructureOf(sessionId),
      runtime.streaming[sessionId],
      runtime.statuses[sessionId],
      runtime.sessionErrors[sessionId],
      runtime.interactions,
      runtime.interactionsError,
      runtime.historyWindows[sessionId],
      runtime.historyWindows[sessionId]?.loading,
      runtime.historyWindows[sessionId]?.hasMore,
    ),
    builder: (context, _) {
      synchronizeNotificationViewing();
      final viewedSessionId = sessionId;
      final viewedConnectionGeneration = runtime.connectionGeneration;
      final colors = Theme.of(context).colorScheme;
      final events = runtime.timelines[sessionId] ?? [];
      final hasSession =
          events.isNotEmpty ||
          runtime.sessions.any(
            (item) => (item['header'] as Json?)?['id'] == sessionId,
          );
      final projection = chatProjections.putIfAbsent(
        sessionId,
        ChatProjection.new,
      )..reconcile(events);
      final modelSelection =
          (modelProjection..reconcile(events)).next ??
          {'provider': runtime.provider, 'model': runtime.model};
      final stream = runtime.liveMessages[sessionId];
      final live = stream == null
          ? null
          : ChatLiveMessage(
              identity: stream['attemptId'] as String,
              content: stream['content'] as List<dynamic>,
              turn: stream['turn'] as int,
              step: stream['step'] as int,
              interrupted: stream['interrupted'] == true,
              unconfirmed: stream['unconfirmed'] == true,
            );
      final sessionError = runtime.sessionErrors[sessionId];
      final running = runtime.statuses[sessionId] == 'running';
      final stoppable = running && commandDrafts[sessionId] == null;
      final sessionRequests = runtime.interactions
          .where((request) => request['sessionId'] == sessionId)
          .toList();
      followReply(
        events.length,
        stream == null ? null : (stream['attemptId'], stream['revision']),
      );
      return PocketScaffold(
        scaffoldKey: scaffold,
        leading: GlassButton(
          icon: Icons.menu_rounded,
          label: '打开侧栏',
          onPressed: () => scaffold.currentState!.openDrawer(),
        ),
        title: Semantics(
          button: true,
          child: GestureDetector(
            onTap: () => navigate(
              SessionModelPage(runtime: runtime, sessionId: sessionId),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Pocket Harness',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                DefaultTextStyle.merge(
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                    overflow: TextOverflow.ellipsis,
                  ),
                  maxLines: 1,
                  child: runtime.ready
                      ? CurrentModelReleaseLabel(
                          runtime: runtime,
                          catalog: currentModelCatalog,
                          selection: modelSelection,
                        )
                      : Text(runtime.phase == 'failed' ? '服务需要处理' : '正在启动'),
                ),
              ],
            ),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GlassButton(
              icon: Icons.edit_square,
              label: '新对话',
              onPressed: newChat,
            ),
            if (hasSession) ...[
              const SizedBox(width: 4),
              ListenableBuilder(
                listenable: codingTools,
                builder: (context, _) => CommonPopupBox(
                  onOpen: inputFocus.unfocus,
                  popupBuilder: (_) => CommonPopupMenu(
                    items: [
                      CommonPopupMenuItem(
                        label: '会话轮次',
                        glyph: Icons.format_list_numbered_rounded,
                        onPressed: () => navigate(
                          ChatTurnNavigatorPage(
                            runtime: runtime,
                            sessionId: sessionId,
                          ),
                        ),
                      ),
                      CommonPopupMenuItem(
                        label: '会话资源',
                        glyph: Icons.folder_copy_outlined,
                        onPressed: () => navigate(
                          SessionResourcesPage(
                            runtime: runtime,
                            sessionId: sessionId,
                          ),
                        ),
                      ),
                      if (codingTools.enabled)
                        CommonPopupMenuItem(
                          label: '会话轨迹',
                          glyph: Icons.route_outlined,
                          onPressed: () => navigate(
                            SessionTrajectoryPage(
                              runtime: runtime,
                              sessionId: sessionId,
                            ),
                          ),
                        ),
                      if (projection.entries.any(
                        (entry) => !chatReadingEntry(entry),
                      ))
                        CommonPopupMenuItem(
                          label: '会话记录',
                          glyph: Icons.history_rounded,
                          onPressed: () =>
                              openChatRecords(context, projection.entries),
                        ),
                    ],
                  ),
                  targetBuilder: (open) => GlassButton(
                    icon: Icons.more_horiz_rounded,
                    label: '会话更多',
                    onPressed: open,
                  ),
                ),
              ),
            ],
          ],
        ),
        drawer: ChatSidebar(
          runtime: runtime,
          currentSessionId: sessionId,
          searchRequest: sidebarSearchRequest,
          onClose: () {
            inputFocus.unfocus();
            scaffold.currentState?.closeDrawer();
          },
          onNewChat: newChat,
          onSelectSession: (id) {
            if (mounted) unawaited(loadConversation(id));
          },
          onOpenTasks: () => unawaited(openTasks()),
          onOpenAutomations: openAutomations,
        ),
        onDrawerChanged: (open) {
          drawerOpen = open;
          synchronizeNotificationViewing();
        },

        // 推理面板开着时，点聊天区收起面板回到输入态（与远程会话页同一意图）；
        // 不用 GestureDetector，避免抢走消息自身的点击。
        body: Listener(
          onPointerDown: _composerMode == PocketComposerMode.picker
              ? (_) => _exitReasoningPanel(keepKeyboard: false)
              : null,
          child:
              projection.entries.isEmpty && live == null && sessionError == null
              ? PocketEmpty(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const PocketMark(size: 58),
                      const SizedBox(height: 25),
                      const Text(
                        '新对话',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -1,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 18),
                      SessionPresetChip(
                        key: ValueKey('session-preset-$sessionId'),
                        runtime: runtime,
                        sessionId: sessionId,
                      ),
                      const SizedBox(height: 22),
                      _Suggestion(
                        icon: Icons.description_outlined,
                        title: '读一份文件',
                        subtitle: '提取重点与待办',
                        onTap: () => navigate(FilesPage(runtime: runtime)),
                      ),
                      const SizedBox(height: 14),
                      _Suggestion(
                        icon: Icons.terminal_rounded,
                        title: '执行任务',
                        onTap: () => suggest('请检查当前应用工作目录中的文件，并说明你可以执行哪些任务。'),
                      ),
                      if (runtime.error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 18),
                          child: PocketButton.tonal(
                            onPressed: () =>
                                navigate(DiagnosticsPage(runtime: runtime)),
                            child: const Text('本地服务需要处理 · 查看详情'),
                          ),
                        ),
                    ],
                  ),
                )
              : NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification.depth != 0) return false;
                    if (notification is ScrollStartNotification &&
                        notification.dragDetails != null) {
                      scrollRequest++;
                      followPending = false;
                      userScrolling = true;
                      if (followSubmittedMessage) {
                        setState(() => followSubmittedMessage = false);
                      }
                    }
                    if (notification is ScrollEndNotification) {
                      userScrolling = false;
                    }
                    return false;
                  },
                  child: ChatTimeline(
                    runtime: runtime,
                    sessionId: sessionId,
                    events: runtime.timelines[sessionId] ?? const [],
                    projection: projection,
                    controller: messageScroll,
                    submittedAfterSeq: submittedAfterSeq,
                    followSubmittedMessage: followSubmittedMessage,
                    live: live,
                    liveListenable: runtime.liveOf(sessionId),
                    onLiveUpdate: () {
                      final value = runtime.liveMessages[sessionId];
                      followReply(
                        runtime.timelines[sessionId]?.length ?? 0,
                        value == null
                            ? null
                            : (value['attemptId'], value['revision']),
                      );
                    },
                    running: running,
                    onOpenSkill: (name) =>
                        openSkillReference(viewedSessionId, name),
                    onQuote: sessionId == viewedSessionId ? quoteMessage : null,
                    onBranch: (atSeq) => forkConversationAt(
                      viewedSessionId,
                      atSeq,
                      viewedConnectionGeneration,
                    ),
                    onOpenWorkflowChild: (address, label) async {
                      if (runtime.connectionGeneration !=
                              viewedConnectionGeneration ||
                          !runtime.ready ||
                          sessionId != viewedSessionId ||
                          address.parentSessionId != viewedSessionId) {
                        return;
                      }
                      await Navigator.push<void>(
                        context,
                        PocketRoute<void>(
                          builder: (_) => SubagentConversationPage(
                            runtime: runtime,
                            address: address,
                            label: label,
                          ),
                        ),
                      );
                    },
                    onOpenLink: (uri) => RuntimeController.channel
                        .invokeMethod<void>('openUrl', uri.toString()),
                    onOpenFile: (file) async {
                      await Navigator.push<void>(
                        context,
                        PocketRoute<void>(
                          builder: (_) => SessionDocumentPage(
                            runtime: widget.runtime,
                            sessionId: file.sessionId,
                            path: file.path,
                            line: file.line,
                          ),
                        ),
                      );
                    },
                    onOpenImage: (attachment) => showPocketSessionImage(
                      context,
                      widget.runtime,
                      sessionId,
                      attachment,
                    ),
                    onOpenAttachment: (attachment) => showPocketSessionFile(
                      context,
                      widget.runtime,
                      sessionId,
                      attachment,
                    ),
                    footer: sessionError == null
                        ? null
                        : PocketCard(
                            child: Padding(
                              padding: const EdgeInsets.all(18),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '本轮任务未完成',
                                    style: TextStyle(
                                      color: colors.error,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  SelectableText(sessionError),
                                  const SizedBox(height: 10),
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      PocketButton.tonal(
                                        onPressed: () => navigate(
                                          ModelsPage(runtime: runtime),
                                        ),
                                        child: const Text('模型与凭据'),
                                      ),
                                      PocketButton.tonal(
                                        onPressed: () => navigate(
                                          DiagnosticsPage(runtime: runtime),
                                        ),
                                        child: const Text('服务诊断'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ),
                ),
        ),
        bottom: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ChatGoalDock(controller: goalPlan),
            ChatPlanDock(controller: goalPlan),
            ChatTodoDock(
              sessionId: sessionId,
              events: runtime.timelines[sessionId] ?? const [],
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: input,
              builder: (context, value, _) {
                final commandDraft = commandDrafts[sessionId];
                final hasDraft =
                    value.text.trim().isNotEmpty ||
                    commandDraft != null ||
                    attachments.items(sessionId).isNotEmpty;
                final mode = _composerModeFor(hasDraft: hasDraft);
                final canSend =
                    runtime.ready &&
                    !submitting &&
                    !stoppable &&
                    attachments.ready(sessionId);
                return Listener(
                  // 缩小态点卡片（含输入框与卡片空白）时页面级补一次聚焦与 IME
                  // 请求：组件内部也有兜底，但真机上只靠 TextField 自身偶尔不弹
                  // 键盘（与远程会话页同一做法）。
                  onPointerDown: (_) => _onComposerPointerDown(),
                  child: PocketComposer(
                    key: const ValueKey('chat-composer'),
                    mode: mode,
                    controller: input,
                    focusNode: inputFocus,
                    // PocketScaffold 的 bottom 已让出左右 16、底部安全区 + 8，这里不再
                    // 叠加水平边距，底部只留 4（与安全区合计约 12，与远程页一致）。
                    margin: const EdgeInsets.fromLTRB(0, 12, 0, 4),
                    placeholder: commandDraft == null
                        ? '交给 Pocket Harness'
                        : '${commandDraft['input']?['hint'] ?? commandDescription(commandDraft)}',
                    onAdd: runtime.ready ? _openComposerCommands : null,
                    onPermissions: runtime.ready
                        ? () => unawaited(_openSessionPermissions())
                        : null,
                    onReasoning: runtime.ready ? _toggleReasoningPanel : null,
                    reasoningActive: mode == PocketComposerMode.picker,
                    onSend: canSend ? _sendDraft : null,
                    onStop: stoppable && !submitting && runtime.ready
                        ? () => unawaited(_cancelTask())
                        : null,
                    sending: submitting,
                    hasDraft: hasDraft,
                    sendKey: const ValueKey('chat-composer-send'),
                    stopKey: const ValueKey('chat-composer-stop'),
                    reasoning: mode == PocketComposerMode.picker
                        ? _reasoningPanel(modelSelection)
                        : null,
                    top: _composerTop(context, sessionRequests),
                  ),
                );
              },
            ),
          ],
        ),
      );
    },
  );
}

class _Suggestion extends StatelessWidget {
  const _Suggestion({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => PocketCard(
    onTap: onTap,
    child: PocketRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: const Icon(Icons.arrow_outward_rounded, size: 18),
    ),
  );
}
