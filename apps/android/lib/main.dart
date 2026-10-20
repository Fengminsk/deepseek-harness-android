import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:dynamic_color/dynamic_color.dart';

import 'runtime.dart';
import 'settings.dart';
import 'files.dart';
import 'ui.dart';
import 'appearance.dart';
import 'approvals.dart';
import 'tasks.dart';
import 'diagnostics.dart';
import 'export.dart';
import 'attachments.dart';
import 'composer_commands.dart';
import 'session_models.dart';
import 'session_model_projection.dart';
import 'models.dart';
import 'account.dart';
import 'flclash/popup.dart';
import 'automations.dart';
import 'tool_activity.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PocketHarnessApp());
}

class PocketHarnessApp extends StatefulWidget {
  const PocketHarnessApp({super.key});
  @override
  State<PocketHarnessApp> createState() => _PocketHarnessAppState();
}

class _PocketHarnessAppState extends State<PocketHarnessApp> {
  final runtime = RuntimeController();
  final appearance = AppearanceController();
  @override
  void initState() {
    super.initState();
    unawaited(appearance.load());
    unawaited(runtime.start().catchError(runtime.fail));
  }

  @override
  void dispose() {
    runtime.dispose();
    appearance.dispose();
    super.dispose();
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
  late String sessionId = widget.runtime.newSession();
  String search = '';
  final drafts = <String, TextEditingValue>{};
  final errors = <String, String>{};
  final submissions = <String>{};
  final commandDrafts = <String, Json>{};
  final toolActivities = <String, ToolActivityProjection>{};
  late AttachmentDrafts attachments;
  String? lastRuntimePhase;
  final messageScroll = ScrollController();
  bool navigationScheduled = false;
  (String, int, String?)? observedTimeline;
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
    runtime.addListener(handleNavigation);
    attachments = AttachmentDrafts(runtime)..addListener(attachmentChanged);
    lastRuntimePhase = runtime.phase;
    handleNavigation();
  }

  @override
  void didUpdateWidget(ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != runtime) {
      toolActivities.clear();
      oldWidget.runtime.removeListener(handleNavigation);
      attachments.removeListener(attachmentChanged);
      attachments.dispose();
      attachments = AttachmentDrafts(runtime)..addListener(attachmentChanged);
      lastRuntimePhase = runtime.phase;
      runtime.addListener(handleNavigation);
      handleNavigation();
    }
  }

  void handleNavigation() {
    if (lastRuntimePhase == 'ready' && !runtime.ready) {
      attachments.invalidateReceipts();
    }
    lastRuntimePhase = runtime.phase;
    if (!mounted ||
        navigationScheduled ||
        (!runtime.ready && runtime.navigationRequest?['route'] != 'account') ||
        runtime.navigationRequest == null) {
      return;
    }
    navigationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigationScheduled = false;
      if (!mounted) return;
      final request = runtime.navigationRequest;
      if (request == null ||
          (!runtime.ready && request['route'] != 'account')) {
        return;
      }
      runtime.consumeNavigation();
      if (request['route'] == 'account') {
        scaffold.currentState?.closeDrawer();
        inputFocus.unfocus();
        navigate(AccountPage(runtime: runtime));
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
  void attachmentChanged() {
    if (mounted) setState(() {});
  }

  void activateSession(String id) {
    drafts[sessionId] = input.value;
    setState(() {
      sessionId = id;
      input.value = drafts[id] ?? TextEditingValue.empty;
    });
  }

  void newChat() => activateSession(runtime.newSession());

  void pickCommand(Json command) {
    switch (builtinCommand(command) ?? command['clientAction']) {
      case 'file':
        unawaited(attachments.pick(sessionId));
      case 'configure-models':
        navigate(ModelsPage(runtime: runtime));
      case 'model':
        navigate(SessionModelPage(runtime: runtime, sessionId: sessionId));
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
              ['file', 'model', 'permission', 'export'].contains(action)) {
            if (attachedIds.isNotEmpty &&
                (action == 'model' || action == 'permission')) {
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

  Future<void> selectSession(String id) async {
    Navigator.pop(context);
    await loadConversation(id);
  }

  Future<void> loadConversation(String id) async {
    activateSession(id);
    try {
      await runtime.openSession(id);
    } catch (error) {
      if (mounted) setState(() => errors[id] = '$error');
    }
  }

  void followReply(int count, String? streaming) {
    final next = (sessionId, count, streaming);
    if (next == observedTimeline) return;
    final switching = observedTimeline?.$1 != sessionId;
    observedTimeline = next;
    final follows =
        switching ||
        !messageScroll.hasClients ||
        messageScroll.position.extentAfter < 80;
    if (!follows) return;
    final observedSession = sessionId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          sessionId != observedSession ||
          !messageScroll.hasClients) {
        return;
      }
      messageScroll.jumpTo(messageScroll.position.maxScrollExtent);
    });
  }

  void suggest(String text) {
    input.text = text;
    input.selection = TextSelection.collapsed(offset: text.length);
    inputFocus.requestFocus();
  }

  String sessionTitle(Json session) {
    final header = session['header'] as Json;
    return '${session['title'] ?? header['title'] ?? header['id']}';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: runtime,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final events = runtime.timelines[sessionId] ?? [];
      final tools = toolActivities.putIfAbsent(
        sessionId,
        ToolActivityProjection.new,
      )..reconcile(events);
      final toolsByAnchor = tools.byAnchorSeq;
      final consumedTools = tools.consumedSeqs;
      final commandRuns = {
        for (final event in events.where((e) => e['type'] == 'command/run'))
          event['data']['commandId']: event,
      };
      final commandResults = {
        for (final event in events.where((e) => e['type'] == 'command/done'))
          event['data']['commandId']: event['data'] as Json,
      };
      final modelLabel = nextSessionModel(events)?['model'] ?? runtime.model;
      final visible = events.where((event) {
        if (toolsByAnchor.containsKey(event['seq'])) return true;
        if (consumedTools.contains(event['seq'])) return false;
        return [
              'user/message',
              'assistant/message',
              'tool/call',
              'tool/result',
              'turn/end',
              'command/run',
              'command/done',
            ].contains(event['type']) &&
            (event['type'] != 'command/done' ||
                !commandRuns.containsKey(event['data']['commandId']));
      }).toList();
      final streaming = runtime.streaming[sessionId];
      final sessionError = runtime.sessionErrors[sessionId];
      final running = runtime.statuses[sessionId] == 'running';
      final stoppable = running && commandDrafts[sessionId] == null;
      final sessionRequests = runtime.interactions
          .where((request) => request['sessionId'] == sessionId)
          .toList();
      followReply(events.length, streaming);
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
        trailing: GlassButton(
          icon: Icons.edit_square,
          label: '新对话',
          onPressed: newChat,
        ),
        drawer: Drawer(
          width: MediaQuery.sizeOf(context).width * .86,
          backgroundColor: colors.surface,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.horizontal(right: Radius.circular(28)),
          ),
          child: SafeArea(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(24, 28, 24, 22),
                        child: Row(
                          children: [
                            PocketMark(size: 32),
                            SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Pocket Harness',
                                style: TextStyle(
                                  fontSize: 21,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: TextField(
                          onChanged: (text) => setState(() => search = text),
                          decoration: const InputDecoration(
                            hintText: '搜索对话',
                            prefixIcon: Icon(Icons.search_rounded, size: 20),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      PocketTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 26,
                        ),
                        leading: const Icon(Icons.edit_square, size: 22),
                        title: const Text('新对话'),
                        onTap: () {
                          Navigator.pop(context);
                          newChat();
                        },
                      ),
                      PocketTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 26,
                        ),
                        leading: const Icon(
                          Icons.folder_open_rounded,
                          size: 22,
                        ),
                        title: const Text('我的文件'),
                        onTap: () {
                          Navigator.pop(context);
                          navigate(FilesPage(runtime: runtime));
                        },
                      ),
                      PocketTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 26,
                        ),
                        leading: const Icon(
                          Icons.play_circle_outline_rounded,
                          size: 22,
                        ),
                        title: const Text('后台任务'),
                        trailing:
                            runtime.statuses.values.any(
                              (value) => value == 'running',
                            )
                            ? Text(
                                '${runtime.statuses.values.where((value) => value == 'running').length}',
                              )
                            : null,
                        onTap: () {
                          Navigator.pop(context);
                          unawaited(openTasks());
                        },
                      ),
                      PocketTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 26,
                        ),
                        leading: const Icon(Icons.schedule_rounded, size: 22),
                        title: const Text('自动化任务'),
                        onTap: () {
                          Navigator.pop(context);
                          navigate(
                            AutomationsPage(
                              runtime: runtime,
                              onNewTask: () {
                                Navigator.of(context)
                                    .popUntil((route) => route.isFirst);
                                newChat();
                              },
                              onOpenSession: (id) {
                                Navigator.of(context)
                                    .popUntil((route) => route.isFirst);
                                unawaited(loadConversation(id));
                              },
                            ),
                          );
                        },
                      ),
                      if (runtime.sessions.any(
                        (item) => (item['header'] as Json)['id'] == sessionId,
                      ))
                        PocketTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 26,
                          ),
                          leading: const Icon(
                            Icons.ios_share_rounded,
                            size: 22,
                          ),
                          title: const Text('导出当前对话'),
                          onTap: () {
                            Navigator.pop(context);
                            final session = runtime.sessions.firstWhere(
                              (item) =>
                                  (item['header'] as Json)['id'] == sessionId,
                            );
                            navigate(
                              SessionExportPage(
                                runtime: runtime,
                                sessionId: sessionId,
                                sessionTitle: sessionTitle(session),
                              ),
                            );
                          },
                        ),
                      if (runtime.interactions.isNotEmpty)
                        PocketTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 26,
                          ),
                          leading: const Icon(
                            Icons.pending_actions_rounded,
                            size: 22,
                          ),
                          title: const Text('授权与提问'),
                          trailing: Text('${runtime.interactions.length}'),
                          onTap: () {
                            Navigator.pop(context);
                            navigate(ApprovalsPage(runtime: runtime));
                          },
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(26, 28, 24, 10),
                        child: Text(
                          '最近对话',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SliverList.list(
                  children: [
                    if (runtime.sessions.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 26,
                          vertical: 12,
                        ),
                        child: Text(
                          '你的对话会保存在这里',
                          style: TextStyle(fontSize: 14, color: colors.outline),
                        ),
                      ),
                    for (final session in runtime.sessions.where(
                      (item) =>
                          sessionTitle(item)
                              .toLowerCase()
                              .contains(search.toLowerCase()),
                    ))
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: PocketTile(
                          selected:
                              (session['header'] as Json)['id'] == sessionId,
                          title: Text(
                            sessionTitle(session),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15),
                          ),
                          onTap: () => selectSession(
                            '${(session['header'] as Json)['id']}',
                          ),
                        ),
                      ),
                  ],
                ),
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 24),
                        child: Divider(),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                        child: PocketTile(
                          leading: Icon(
                            Icons.tune_rounded,
                            color: colors.onSurface,
                          ),
                          title: const Text('设置'),
                          subtitle: const Text(
                            '模型、Agent 与设备',
                            style: TextStyle(fontSize: 12),
                          ),
                          trailing: const Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            navigate(SettingsPage(runtime: runtime));
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        body: visible.isEmpty && streaming == null && sessionError == null
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
                    const SizedBox(height: 30),
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
            : PocketList(
                controller: messageScroll,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                children: [
                  for (final event in visible)
                    if (toolsByAnchor[event['seq']] case final activity?)
                      ToolActivityCard(
                        key: ValueKey('tool-$sessionId-${activity.identity}'),
                        activity: activity,
                      )
                    else
                      EventCard(
                        event: event,
                        commandResult: event['type'] == 'command/run'
                            ? commandResults[event['data']['commandId']]
                            : null,
                      ),
                  if (streaming != null && streaming.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: SelectableText(
                        streaming,
                        style: const TextStyle(height: 1.6),
                      ),
                    ),
                  if (sessionError != null)
                    PocketCard(
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
                                  onPressed: () =>
                                      navigate(ModelsPage(runtime: runtime)),
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
                ],
              ),
        bottom: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    CommonPopupBox(
                      placement: PopupPlacement.overAnchorStart,
                      onOpen: inputFocus.unfocus,
                      popupBuilder: (popupContext) => ComposerCommands(
                        runtime: runtime,
                        sessionId: sessionId,
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
                        controller: input,
                        focusNode: inputFocus,
                        minLines: 1,
                        maxLines: 5,
                        decoration: InputDecoration(
                          hintText: commandDrafts[sessionId] == null
                              ? '交给 Pocket Harness'
                              : '${commandDrafts[sessionId]!['input']?['hint'] ?? commandDescription(commandDrafts[sessionId]!)}',
                          hintStyle: const TextStyle(fontSize: 15),
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

class EventCard extends StatelessWidget {
  const EventCard({required this.event, this.commandResult, super.key});
  final Json event;
  final Json? commandResult;
  static String textOf(dynamic content) => content is List
      ? content
            .whereType<Json>()
            .where((block) => block['type'] == 'text')
            .map((block) => block['text'] ?? '')
            .join('\n')
      : '';
  @override
  Widget build(BuildContext context) {
    final data = event['data'] as Json;
    final type = event['type'];
    if (type == 'user/message' || type == 'assistant/message') {
      final user = type == 'user/message';
      final content = user
          ? data['content']
          : (data['message'] as Json)['content'];
      final text = textOf(content);
      final attachments = (content as List).whereType<Json>().where(
        (block) => block['type'] == 'file' || block['type'] == 'image',
      );
      return Align(
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * (user ? .8 : 1),
          ),
          margin: const EdgeInsets.symmetric(vertical: 10),
          padding: EdgeInsets.symmetric(
            horizontal: user ? 18 : 0,
            vertical: 14,
          ),
          decoration: BoxDecoration(
            color: user ? Theme.of(context).colorScheme.surfaceContainer : null,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final block in attachments)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        block['type'] == 'image'
                            ? Icons.image_outlined
                            : Icons.attach_file_rounded,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '${block['attachment']?['name'] ?? (block['type'] == 'image' ? '图片附件' : '文件附件')}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              if (text.isNotEmpty)
                SelectableText(
                  text,
                  style: const TextStyle(fontSize: 16, height: 1.6),
                ),
            ],
          ),
        ),
      );
    }
    if (type == 'turn/end') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '任务状态：${data['reason']}',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      );
    }
    if (type == 'command/done' || type == 'command/run') {
      final result = type == 'command/done' ? data : commandResult;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              type == 'command/run'
                  ? '/${data['name']}${data['args'] ?? ''}'
                  : '会话指令',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 8),
            SelectableText(
              result == null
                  ? '指令执行中…'
                  : '${result['text'] ?? (result['kind'] == 'error' ? '指令执行失败' : '指令已完成')}',
              style: TextStyle(
                color: result?['kind'] == 'error'
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
            ),
          ],
        ),
      );
    }
    return PocketDisclosure(
      title: type == 'tool/call' ? '${data['name']}' : '工具结果',
      child: SelectableText(const JsonEncoder.withIndent('  ').convert(data)),
    );
  }
}
