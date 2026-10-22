import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:dynamic_color/dynamic_color.dart';

import 'runtime.dart';
import 'files.dart';
import 'ui.dart';
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
import 'session_document.dart';
import 'models.dart';
import 'account.dart';
import 'settings.dart';
import 'flclash/popup.dart';
import 'automations.dart';
import 'chat_projection.dart';
import 'chat_messages.dart';
import 'chat_sidebar.dart';
import 'agent_presets.dart';
import 'skills.dart';
import 'chat_references.dart';
import 'chat_deliverables.dart';
import 'chat_goal.dart';
import 'chat_plan.dart';
import 'chat_goal_plan_state.dart';
import 'chat_reading.dart';
import 'chat_shortcuts.dart';
import 'resource_hub.dart';
import 'session_trajectory.dart';
import 'subagents.dart';

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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(appearance.load());
    unawaited(runtime.start().catchError(runtime.fail));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    runtime.dispose();
    appearance.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(runtime.resume());
  }

  @override
  Widget build(BuildContext context) => AppearanceScope(
    controller: appearance,
    child: ListenableBuilder(
      listenable: appearance,
      builder: (context, _) => DynamicColorBuilder(
        builder: (light, dark) => MaterialApp(
          title: 'Pocket Harness',
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
          builder: (context, child) => MediaQuery(
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
                child: child!,
              ),
            ),
          ),
          home: ChatPage(runtime: runtime),
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

class _ChatPageState extends State<ChatPage> {
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
  late AttachmentDrafts attachments;
  late ChatGoalPlanController goalPlan;
  final messageScroll = ScrollController();
  bool navigationScheduled = false;
  bool drawerOpen = false;
  (String?, int)? notificationViewing;
  (String, int, Object?)? observedTimeline;
  int scrollRequest = 0;
  bool followPending = false;
  bool userScrolling = false;
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
      sessionNavigationEpoch++;
      goalPlan.dispose();
      connectGoalPlan();
      for (final catalog in skillCatalogs.values) {
        catalog.dispose();
      }
      skillCatalogs.clear();
      skillDraftPreparation.clear();
      chatProjections.clear();
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
  }

  @override
  void dispose() {
    keyboardShortcuts.dispose();
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

  void navigate(Widget page) =>
      Navigator.push(context, PocketRoute<void>(builder: (_) => page));

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

  void activateSession(String id) {
    if (id == sessionId) return;
    sessionNavigationEpoch++;
    drafts[sessionId] = input.value;
    goalPlan.dispose();
    setState(() {
      sessionId = id;
      connectGoalPlan();
      input.value = drafts[id] ?? TextEditingValue.empty;
    });
  }

  void newChat() {
    final id = runtime.newSession();
    localDraftSessions.add(id);
    activateSession(id);
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
    final id = await Navigator.push<String>(
      context,
      PocketRoute<String>(
        builder: (_) => TasksPage(runtime: runtime, sessionId: sessionId),
      ),
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
      } else if (attachedIds.isNotEmpty) {
        await runtime.sendAttachments(sendingId, text, attachedIds);
      } else {
        await runtime.send(sendingId, text);
      }
      if (!mounted) return;
      localDraftSessions.remove(sendingId);
      final draft = sendingId == sessionId ? input.value : drafts[sendingId];
      if (draft?.text.trim() == text &&
          identical(commandDrafts[sendingId], pickedCommand)) {
        drafts.remove(sendingId);
        commandDrafts.remove(sendingId);
        if (sendingId == sessionId) input.clear();
      }
      await attachments.consume(sendingId, attachedIds);
    } catch (error) {
      if (mounted) {
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
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: runtime,
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
      final modelLabel = nextSessionModel(events)?['model'] ?? runtime.model;
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
                Text(
                  runtime.ready
                      ? modelLabel
                      : runtime.phase == 'failed'
                      ? '服务需要处理'
                      : '正在启动',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
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
              CommonPopupBox(
                onOpen: inputFocus.unfocus,
                popupBuilder: (_) => CommonPopupMenu(
                  items: [
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
          onOpenAutomations: () => navigate(
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
          ),
        ),
        onDrawerChanged: (open) {
          drawerOpen = open;
          synchronizeNotificationViewing();
        },

        body: projection.entries.isEmpty && live == null && sessionError == null
            ? PocketEmpty(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const PocketMark(size: 58),
                    const SizedBox(height: 25),
                    const Text(
                      '把想法，交给行动。',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -1,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '你的随身 Agent，就在这台手机里。',
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.onSurfaceVariant,
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
                      subtitle: '从一个小任务开始',
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
                  live: live,
                  running: running,
                  onOpenSkill: (name) =>
                      openSkillReference(viewedSessionId, name),
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
        bottom: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ChatGoalDock(controller: goalPlan),
            ChatPlanDock(controller: goalPlan),
            ChatTodoDock(
              sessionId: sessionId,
              events: runtime.timelines[sessionId] ?? const [],
            ),
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
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Text(
                  submitError!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.error, fontSize: 13),
                ),
              ),
            GlassSurface(
              key: const ValueKey('chat-composer'),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    CommonPopupBox(
                      placement: PopupPlacement.overAnchorStart,
                      onOpen: inputFocus.unfocus,
                      popupBuilder: (popupContext) => ComposerCommands(
                        runtime: runtime,
                        sessionId: sessionId,
                        deferActivation:
                            !localDraftSessions.contains(sessionId) &&
                            ![
                              'idle',
                              'running',
                              'waiting',
                            ].contains(runtime.statuses[sessionId]),
                        maxHeight:
                            (MediaQuery.sizeOf(popupContext).height -
                                    MediaQuery.paddingOf(popupContext)
                                        .vertical -
                                    MediaQuery.viewInsetsOf(popupContext)
                                        .bottom -
                                    40)
                                .clamp(100.0, 520.0),
                        onPick: pickCommand,
                      ),
                      targetBuilder: (open) => GlassButton(
                        icon: Icons.add_rounded,
                        label: '添加与指令',
                        onPressed: runtime.ready ? open : null,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('chat-composer-input'),
                        controller: input,
                        focusNode: inputFocus,
                        minLines: 1,
                        maxLines: 5,
                        textAlignVertical: TextAlignVertical.center,
                        style: const TextStyle(fontSize: 15, height: 1.4),
                        decoration: InputDecoration(
                          hintText: commandDrafts[sessionId] == null
                              ? '交给 Pocket Harness'
                              : '${commandDrafts[sessionId]!['input']?['hint'] ?? commandDescription(commandDrafts[sessionId]!)}',
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 2,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    GlassButton(
                      icon: submitting
                          ? Icons.more_horiz_rounded
                          : stoppable
                          ? Icons.stop_rounded
                          : Icons.arrow_upward_rounded,
                      label: stoppable ? '停止任务' : '发送',
                      solid: true,
                      onPressed:
                          !runtime.ready ||
                              submitting ||
                              (!stoppable && !attachments.ready(sessionId))
                          ? null
                          : stoppable
                          ? () async {
                              try {
                                await runtime.call('session.cancel', {
                                  'sessionId': sessionId,
                                });
                              } catch (error) {
                                if (mounted) {
                                  setState(() => submitError = '$error');
                                }
                              }
                            }
                          : send,
                    ),
                  ],
                ),
              ),
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
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title, subtitle;
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
