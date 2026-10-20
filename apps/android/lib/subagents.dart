import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'chat_messages.dart';
import 'chat_projection.dart';
import 'models.dart';
import 'runtime.dart';
import 'subagents_data.dart';
import 'tasks.dart';
import 'ui.dart';

export 'subagents_data.dart' show SubagentAddress;

/// Direct-child catalog. Entering a branch reads its original catalog and does
/// not start the parent or child Agent.
class SubagentsPage extends StatefulWidget {
  const SubagentsPage({
    required this.runtime,
    required this.parentSessionId,
    this.parentTitle,
    super.key,
  });

  final RuntimeController runtime;
  final String parentSessionId;
  final String? parentTitle;

  @override
  State<SubagentsPage> createState() => _SubagentsPageState();
}

class _SubagentsPageState extends State<SubagentsPage>
    with WidgetsBindingObserver {
  List<Json> entries = [];
  int? nextOffset;
  bool loading = false, current = false, foreground = true;
  String? error;
  Timer? timer;
  int generation = 0;
  late String phase;
  Object? epoch;

  @override
  void initState() {
    super.initState();
    phase = widget.runtime.phase;
    epoch = widget.runtime.taskState['epoch'];
    WidgetsBinding.instance.addObserver(this);
    widget.runtime.addListener(runtimeChanged);
    unawaited(refresh());
    timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (foreground && ModalRoute.of(context)?.isCurrent == true) {
        unawaited(refresh());
      }
    });
  }

  void runtimeChanged() {
    if (phase == widget.runtime.phase &&
        epoch == widget.runtime.taskState['epoch']) {
      return;
    }
    phase = widget.runtime.phase;
    epoch = widget.runtime.taskState['epoch'];
    generation++;
    setState(() {
      current = false;
      loading = false;
    });
    if (widget.runtime.ready) unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) unawaited(refresh());
  }

  Future<void> refresh({bool more = false}) async {
    if (!widget.runtime.ready || loading || more && nextOffset == null) return;
    final attempt = generation;
    setState(() => loading = true);
    try {
      final targetCount = more ? 30 : entries.length.clamp(30, 1 << 30);
      final rows = <Json>[];
      var offset = more ? nextOffset! : 0;
      int? following;
      do {
        final limit = (targetCount - rows.length).clamp(1, 100);
        final result =
            await widget.runtime
                    .call('subagents.catalog', {
                      'parentSessionId': widget.parentSessionId,
                      'offset': offset,
                      'limit': limit,
                    })
                    .timeout(subagentRequestTimeout)
                as Json;
        if (!mounted || attempt != generation || !widget.runtime.ready) return;
        if (result['parentSessionId'] != widget.parentSessionId) {
          throw const FormatException('Mismatched catalog parent');
        }
        rows.addAll((result['entries'] as List).cast<Json>());
        following = result['nextOffset'] as int?;
        if (following != null && following <= offset) {
          throw const FormatException('Catalog pagination did not advance');
        }
        if (following == null || more || rows.length >= targetCount) break;
        offset = following;
      } while (true);
      setState(() {
        final byId = <String, Json>{
          if (more)
            for (final row in entries) row['id'] as String: row,
          for (final row in rows) row['id'] as String: row,
        };
        entries = byId.values.toList();
        nextOffset = following;
        current = true;
        error = null;
      });
    } catch (failure) {
      if (mounted && attempt == generation) {
        setState(() {
          current = false;
          error = '子 Agent 列表未能刷新。错误：${subagentFailureCode(failure)}';
        });
      }
    } finally {
      if (mounted && attempt == generation) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    widget.runtime.removeListener(runtimeChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('子 Agent'),
    trailing: GlassButton(
      icon: Icons.refresh_rounded,
      label: '刷新子 Agent 列表',
      onPressed: loading || !widget.runtime.ready ? null : refresh,
    ),
    body: PocketList(
      padding: const EdgeInsets.all(20),
      children: [
        PocketSection(
          title: widget.parentTitle ?? '父会话',
          children: [
            _SubagentNote(widget.parentSessionId),
            const _SubagentNote('列出此会话直接委派的子 Agent。查看列表与记录不会恢复执行。'),
          ],
        ),
        if (error != null) _notice(context, error!),
        if (!widget.runtime.ready) _notice(context, '服务尚未就绪；已有列表仅供参考。'),
        if (entries.isEmpty)
          PocketSection(
            children: [
              PocketRow(
                icon: current
                    ? Icons.account_tree_outlined
                    : Icons.sync_rounded,
                title: current
                    ? '此会话尚无子 Agent'
                    : error == null && widget.runtime.ready
                    ? '正在读取子 Agent'
                    : '子 Agent 列表尚未确认',
              ),
            ],
          ),
        for (final entry in entries)
          PocketSection(
            children: [
              PocketRow(
                key: ValueKey('subagent-${entry['id']}'),
                icon: Icons.account_tree_outlined,
                title: '${entry['label'] ?? entry['id']}',
                subtitle:
                    '${subagentModeLabel(entry['mode'] as String?)} · '
                    '${current
                        ? entry['running'] == true
                              ? '正在运行'
                              : '当前未运行'
                        : '上次状态'}',
                onTap: entry['address'] is Json
                    ? () async {
                        await Navigator.push<void>(
                          context,
                          PocketRoute<void>(
                            builder: (_) => SubagentConversationPage(
                              runtime: widget.runtime,
                              address: SubagentAddress.fromJson(
                                entry['address'] as Json,
                              ),
                              label: entry['label'] as String?,
                            ),
                          ),
                        );
                        if (mounted) unawaited(refresh());
                      }
                    : null,
              ),
              if (entry['address'] == null)
                const _SubagentNote('外部任务没有可打开的本地子会话地址。'),
            ],
          ),
        if (nextOffset != null)
          PocketButton.tonal(
            onPressed: loading || !widget.runtime.ready
                ? null
                : () => refresh(more: true),
            child: const Text('加载更多子 Agent'),
          ),
      ],
    ),
  );
}

class SubagentConversationPage extends StatefulWidget {
  const SubagentConversationPage({
    required this.runtime,
    required this.address,
    this.label,
    super.key,
  });

  final RuntimeController runtime;
  final SubagentAddress address;
  final String? label;

  @override
  State<SubagentConversationPage> createState() =>
      _SubagentConversationPageState();
}

class _SubagentConversationPageState extends State<SubagentConversationPage>
    with WidgetsBindingObserver {
  late final SubagentConversation conversation;
  final projection = ChatProjection();
  final scroll = ScrollController();
  final input = TextEditingController();
  Timer? timer;
  bool foreground = true;
  bool userScrolling = false, readingEarlier = false, followPending = false;
  int scrollRequest = 0;
  (int?, int, Object?)? observedTimeline;

  @override
  void initState() {
    super.initState();
    conversation = SubagentConversation(widget.runtime, widget.address)
      ..addListener(changed);
    widget.runtime.addListener(changed);
    WidgetsBinding.instance.addObserver(this);
    unawaited(conversation.refresh());
    timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (foreground && ModalRoute.of(context)?.isCurrent == true) {
        unawaited(conversation.refresh());
      }
    });
  }

  void changed() {
    if (!mounted) return;
    if (input.text != conversation.draft) {
      input.value = TextEditingValue(
        text: conversation.draft,
        selection: TextSelection.collapsed(offset: conversation.draft.length),
      );
    }
    setState(() => projection.reconcile(conversation.events));
    followReply();
  }

  void followReply() {
    final next = (
      conversation.events.lastOrNull?['seq'] as int?,
      projection.entries.length,
      live?.content,
    );
    if (next == observedTimeline) return;
    final initial = observedTimeline == null || observedTimeline!.$1 == null;
    observedTimeline = next;
    if (readingEarlier || userScrolling) return;
    if (!initial &&
        !followPending &&
        scroll.hasClients &&
        scroll.position.extentAfter >= 80) {
      return;
    }
    final request = ++scrollRequest;
    followPending = true;
    var layouts = 0, settled = 0;
    // Match the shared chat's variable-height lazy-list end refinement.
    void settle(Duration _) {
      if (!mounted || request != scrollRequest || !scroll.hasClients) {
        if (request == scrollRequest) followPending = false;
        return;
      }
      if (scroll.position.extentAfter <= .5) {
        settled++;
      } else {
        settled = 0;
        scroll.jumpTo(scroll.position.maxScrollExtent);
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

  Future<void> loadEarlier() async {
    final first = conversation.events.firstOrNull?['seq'];
    readingEarlier = true;
    scrollRequest++;
    followPending = false;
    await conversation.loadOlder();
    if (!mounted) return;
    readingEarlier = false;
    if (first != conversation.events.firstOrNull?['seq']) {
      // The action sits after the current window. Take the reader to the
      // newly requested earlier window instead of leaving it off-screen.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients) {
          scroll.jumpTo(scroll.position.minScrollExtent);
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) unawaited(conversation.refresh());
  }

  Future<void> info() async {
    await Navigator.push<void>(
      context,
      PocketRoute<void>(
        builder: (_) => SubagentDetailsPage(
          conversation: conversation,
          label: widget.label,
        ),
      ),
    );
    if (mounted) unawaited(conversation.refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.runtime.removeListener(changed);
    conversation.removeListener(changed);
    conversation.dispose();
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  ChatLiveMessage? get live {
    final value = widget.runtime.liveMessages[widget.address.childSessionId];
    if (value == null) return null;
    return ChatLiveMessage(
      identity: value['attemptId'] as String,
      content: value['content'] as List,
      turn: value['turn'] as int,
      step: value['step'] as int,
      interrupted: value['interrupted'] == true,
      unconfirmed:
          !conversation.current ||
          !widget.runtime.ready ||
          value['unconfirmed'] == true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = conversation;
    final editable =
        state.canPrompt || state.draft.isNotEmpty || state.submission != null;
    return ModelDraftGuard(
      // An unresolved submission is retained with this runtime across routes;
      // leaving is not a discard or an instruction to replay it.
      hasEdits: () => state.draft.isNotEmpty && state.submission == null,
      busy: state.sending || state.interrupting,
      child: PocketScaffold(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.label ?? '子 Agent',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              state.current
                  ? state.capabilities['running'] == true
                        ? '正在运行'
                        : '当前未运行'
                  : '状态待确认',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
        trailing: GlassButton(
          icon: Icons.refresh_rounded,
          label: '刷新子会话',
          onPressed: state.loading || !widget.runtime.ready
              ? null
              : state.refresh,
        ),
        body: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollStartNotification &&
                notification.dragDetails != null) {
              userScrolling = true;
              scrollRequest++;
              followPending = false;
            } else if (notification is ScrollEndNotification) {
              userScrolling = false;
            }
            return false;
          },
          child: ChatTimeline(
            sessionId: state.address.key,
            projection: projection,
            controller: scroll,
            live: live,
            onOpenLink: (uri) => RuntimeController.channel.invokeMethod<void>(
              'openUrl',
              uri.toString(),
            ),
            footer: Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (state.events.isEmpty)
                    _SubagentNote(state.current ? '尚无可显示的会话记录。' : '会话记录尚未确认。'),
                  if (state.error != null) _notice(context, state.error!),
                  if (state.historyReset)
                    const _SubagentNote('已重新读取最近记录，可继续加载更早的会话内容。'),
                  if (state.hasMore)
                    PocketButton.tonal(
                      key: const Key('subagent-load-older'),
                      onPressed:
                          state.loading || state.loadingOlder || !state.current
                          ? null
                          : loadEarlier,
                      child: Text(state.loadingOlder ? '正在读取较早记录' : '加载更早记录'),
                    ),
                ],
              ),
            ),
          ),
        ),
        bottom: GlassSurface(
          radius: 28,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    GlassButton(
                      icon: Icons.account_tree_outlined,
                      label: '父子关系与任务记录',
                      onPressed: info,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        state.canPrompt
                            ? '子 Agent · ${subagentModeLabel(state.address.mode)}'
                            : subagentReadOnlyExplanation(
                                !state.current
                                    ? null
                                    : state.capabilities['readOnlyReason']
                                          as String?,
                              ),
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    if (state.canInterrupt || state.stopping)
                      GlassButton(
                        key: const Key('subagent-stop'),
                        icon: Icons.stop_rounded,
                        label: state.stopping ? '等待停止确认' : '停止子 Agent 当前回合',
                        onPressed:
                            state.canInterrupt &&
                                !state.interrupting &&
                                !state.stopping
                            ? state.interrupt
                            : null,
                      ),
                  ],
                ),
                if (state.actionMessage != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Text(
                      state.actionMessage!,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                if (editable) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('subagent-draft'),
                          controller: input,
                          minLines: 1,
                          maxLines: 4,
                          onChanged: state.edit,
                          decoration: const InputDecoration(
                            hintText: '给子 Agent 的消息',
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                          ),
                        ),
                      ),
                      GlassButton(
                        key: const Key('subagent-send'),
                        icon: Icons.arrow_upward_rounded,
                        label: '发送给子 Agent',
                        solid: true,
                        onPressed: state.canSend ? state.send : null,
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final mode in ['queue', 'steer'])
                        PocketChoice(
                          key: ValueKey('subagent-delivery-$mode'),
                          label: Text(mode == 'queue' ? '排队' : '打断当前回合'),
                          selected: state.delivery == mode,
                          onSelected: state.sending || state.submission != null
                              ? null
                              : (_) => state.selectDelivery(mode),
                        ),
                    ],
                  ),
                  if (state.uncertain)
                    PocketButton.tonal(
                      key: const Key('subagent-check-submission'),
                      onPressed: state.loading || !widget.runtime.ready
                          ? null
                          : state.refresh,
                      child: const Text('核对发送状态'),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SubagentDetailsPage extends StatefulWidget {
  const SubagentDetailsPage({
    required this.conversation,
    this.label,
    super.key,
  });
  final SubagentConversation conversation;
  final String? label;

  @override
  State<SubagentDetailsPage> createState() => _SubagentDetailsPageState();
}

class _SubagentDetailsPageState extends State<SubagentDetailsPage>
    with WidgetsBindingObserver {
  Timer? timer;
  bool foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.conversation.refresh());
    });
    timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (foreground && ModalRoute.of(context)?.isCurrent == true) {
        unawaited(widget.conversation.refresh());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) unawaited(widget.conversation.refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.conversation,
    builder: (context, _) {
      final state = widget.conversation;
      final pending = (state.task['pending'] as List? ?? []).cast<Json>();
      final history = (state.task['history'] as List? ?? []).cast<Json>();
      return PocketScaffold(
        title: const Text('子 Agent 信息'),
        trailing: GlassButton(
          icon: Icons.refresh_rounded,
          label: '刷新子 Agent 信息',
          onPressed: state.loading || !state.runtime.ready
              ? null
              : state.refresh,
        ),
        body: PocketList(
          padding: const EdgeInsets.all(20),
          children: [
            PocketSection(
              title: widget.label ?? '子 Agent',
              children: [
                _SubagentNote('父会话：${state.address.parentSessionId}'),
                _SubagentNote('子会话：${state.address.childSessionId}'),
                _SubagentNote('模式：${subagentModeLabel(state.address.mode)}'),
                if (!state.current) const _SubagentNote('当前状态未确认，下方保留上次读取的记录。'),
                PocketRow(
                  icon: Icons.account_tree_outlined,
                  title: '查看其下级子 Agent',
                  onTap: () => Navigator.push<void>(
                    context,
                    PocketRoute<void>(
                      builder: (_) => SubagentsPage(
                        runtime: state.runtime,
                        parentSessionId: state.address.childSessionId,
                        parentTitle: widget.label,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (state.error != null) _notice(context, state.error!),
            PocketSection(
              title: '待处理输入',
              children: [
                if (pending.isEmpty)
                  _SubagentNote(state.current ? '当前没有待处理输入。' : '待处理输入尚未确认。'),
                for (final item in pending)
                  PocketRow(
                    icon: Icons.schedule_rounded,
                    title: '${item['prompt'] ?? '输入'}',
                    subtitle: taskStatusLabel(item['status'] as String?),
                  ),
                const _SubagentNote('停止当前回合会保留排队输入。此页查看队列不会恢复子 Agent。'),
              ],
            ),
            PocketSection(
              title: '最近任务记录',
              children: [
                if (history.isEmpty) const _SubagentNote('没有已读取的任务结果。'),
                for (final item in history)
                  PocketRow(
                    icon: Icons.history_rounded,
                    title: item['kind'] == 'turn'
                        ? '第 ${item['turn']} 回合 · ${taskStatusLabel(item['status'] as String?)}'
                        : '${item['label'] ?? item['kind']} · ${taskStatusLabel(item['status'] as String?)}',
                    subtitle: taskFailure(item).isEmpty
                        ? null
                        : taskFailure(item),
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

class _SubagentNote extends StatelessWidget {
  const _SubagentNote(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
    child: SelectableText(text, style: Theme.of(context).textTheme.bodyMedium),
  );
}

Widget _notice(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.all(12),
  child: Text(
    text,
    style: TextStyle(color: Theme.of(context).colorScheme.error),
  ),
);
