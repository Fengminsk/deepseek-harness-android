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
    handleNavigation();
  }

  @override
  void didUpdateWidget(ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != runtime) {
      oldWidget.runtime.removeListener(handleNavigation);
      runtime.addListener(handleNavigation);
      handleNavigation();
    }
  }

  void handleNavigation() {
    if (!mounted ||
        navigationScheduled ||
        !runtime.ready ||
        runtime.navigationRequest == null) {
      return;
    }
    navigationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigationScheduled = false;
      if (!mounted || !runtime.ready) return;
      final request = runtime.navigationRequest;
      if (request == null) return;
      runtime.consumeNavigation();
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
    input.dispose();
    inputFocus.dispose();
    messageScroll.dispose();
    super.dispose();
  }

  void navigate(Widget page) =>
      Navigator.push(context, PocketRoute<void>(builder: (_) => page));
  void activateSession(String id) {
    drafts[sessionId] = input.value;
    setState(() {
      sessionId = id;
      input.value = drafts[id] ?? TextEditingValue.empty;
    });
  }

  void newChat() => activateSession(runtime.newSession());

  Future<void> openTasks() async {
    final id = await Navigator.push<String>(
      context,
      PocketRoute<String>(builder: (_) => TasksPage(runtime: runtime)),
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
    if (text.isEmpty || submissions.contains(sendingId)) return;
    drafts[sendingId] = input.value;
    setState(() {
      submissions.add(sendingId);
      errors.remove(sendingId);
    });
    try {
      await runtime.send(sendingId, text);
      if (!mounted) return;
      final draft = sendingId == sessionId ? input.value : drafts[sendingId];
      if (draft?.text.trim() == text) {
        drafts.remove(sendingId);
        if (sendingId == sessionId) input.clear();
      }
    } catch (error) {
      if (mounted) setState(() => errors[sendingId] = '$error');
    } finally {
      if (mounted) setState(() => submissions.remove(sendingId));
    }
  }

  Future<void> selectSession(String id) async {
    Navigator.pop(context);
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
      final visible = events
          .where(
            (event) => [
              'user/message',
              'assistant/message',
              'tool/call',
              'tool/result',
              'turn/end',
            ].contains(event['type']),
          )
          .toList();
      final streaming = runtime.streaming[sessionId];
      final running = runtime.statuses[sessionId] == 'running';
      final sessionRequests = runtime.interactions
          .where((request) => request['sessionId'] == sessionId)
          .toList();
      followReply(visible.length, streaming);
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
            onTap: () => navigate(ModelSettings(runtime: runtime)),
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
                      ? runtime.model
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

        body: visible.isEmpty && streaming == null
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
                  for (final event in visible) EventCard(event: event),
                  if (streaming != null && streaming.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: SelectableText(
                        streaming,
                        style: const TextStyle(height: 1.6),
                      ),
                    ),
                ],
              ),
        bottom: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                    GlassButton(
                      icon: Icons.add_rounded,
                      label: '授权文件',
                      onPressed: () => navigate(FilesPage(runtime: runtime)),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(
                        controller: input,
                        focusNode: inputFocus,
                        minLines: 1,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          hintText: '交给 Pocket Harness',
                          hintStyle: TextStyle(fontSize: 15),
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
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
                          : running
                          ? Icons.stop_rounded
                          : Icons.arrow_upward_rounded,
                      label: running ? '停止任务' : '发送',
                      solid: true,
                      onPressed: !runtime.ready || submitting
                          ? null
                          : running
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
  const EventCard({required this.event, super.key});
  final Json event;
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
      final text = textOf(
        user ? data['content'] : (data['message'] as Json)['content'],
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
          child: SelectableText(
            text,
            style: const TextStyle(fontSize: 16, height: 1.6),
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
    return PocketDisclosure(
      title: type == 'tool/call' ? '${data['name']}' : '工具结果',
      child: SelectableText(const JsonEncoder.withIndent('  ').convert(data)),
    );
  }
}
