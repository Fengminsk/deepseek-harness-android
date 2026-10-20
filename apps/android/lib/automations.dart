import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'automations_data.dart';
import 'runtime.dart';
import 'ui.dart';

class AutomationsPage extends StatefulWidget {
  const AutomationsPage({
    required this.runtime,
    required this.onNewTask,
    required this.onOpenSession,
    super.key,
  });
  final RuntimeController runtime;
  final VoidCallback onNewTask;
  final ValueChanged<String> onOpenSession;

  @override
  State<AutomationsPage> createState() => _AutomationsPageState();
}

class _AutomationsPageState extends State<AutomationsPage> {
  late final catalog = AutomationsController(widget.runtime);
  String search = '', filter = 'all';

  @override
  void initState() {
    super.initState();
    catalog.addListener(changed);
    catalog.start();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    catalog.removeListener(changed);
    catalog.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = search.trim().toLowerCase();
    final rows = catalog.records.where(
      (row) =>
          (filter == 'all' || row['status'] == filter) &&
          [
            'title',
            'prompt',
            'sessionId',
          ].any((key) => (row[key] as String).toLowerCase().contains(query)),
    );
    return PocketScaffold(
      title: const Text('自动化任务'),
      trailing: GlassButton(
        icon: Icons.refresh_rounded,
        label: '刷新任务列表',
        onPressed: catalog.loading ? null : catalog.refresh,
      ),
      body: PocketList(
        padding: const EdgeInsets.all(20),
        children: [
          PocketSection(
            children: [
              const AutomationNotice('在对话中说明需要执行的内容与时间，由 Agent 创建定时任务。'),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: PocketButton(
                  onPressed: widget.onNewTask,
                  child: const Text('新建任务对话'),
                ),
              ),
            ],
          ),
          TextField(
            decoration: const InputDecoration(
              labelText: '搜索任务',
              hintText: '名称、指令或会话',
            ),
            onChanged: (text) => setState(() => search = text),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final entry in const {
                'all': '全部',
                'active': '进行中',
                'inactive': '已结束',
              }.entries)
                PocketChoice(
                  label: Text(entry.value),
                  selected: filter == entry.key,
                  onSelected: (_) => setState(() => filter = entry.key),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (!widget.runtime.ready)
            const AutomationNotice('等待本地服务就绪。保留上次读取的任务。'),
          if (catalog.error != null) AutomationNotice(catalog.error!),
          if (catalog.loading) const AutomationNotice('正在读取任务……'),
          if (catalog.settled && !catalog.loading && rows.isEmpty)
            AutomationNotice(
              catalog.records.isEmpty ? '还没有定时任务。' : '没有符合当前筛选条件的任务。',
            ),
          for (final row in rows)
            PocketSection(
              children: [
                PocketRow(
                  icon: Icons.schedule_rounded,
                  title: row['title'] as String,
                  subtitle:
                      '${row['status'] == 'active' ? '进行中' : '已结束'}'
                      '\n${automationRule(row)}'
                      '${row['status'] == 'active' ? '\n下次：${row['scheduledAt']}' : ''}',
                  onTap: () => Navigator.push(
                    context,
                    PocketRoute<void>(
                      builder: (_) => AutomationDetailPage(
                        catalog: catalog,
                        record: row,
                        onOpenSession: widget.onOpenSession,
                      ),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class AutomationDetailPage extends StatefulWidget {
  const AutomationDetailPage({
    required this.catalog,
    required this.record,
    required this.onOpenSession,
    super.key,
  });
  final AutomationsController catalog;
  final Json record;
  final ValueChanged<String> onOpenSession;
  @override
  State<AutomationDetailPage> createState() => _AutomationDetailPageState();
}

class _AutomationDetailPageState extends State<AutomationDetailPage> {
  final scroll = ScrollController();
  late final draft = AutomationDraft(widget.record);
  late final fields = {
    for (final key in [
      'title',
      'prompt',
      'date',
      'time',
      'zone',
      'seconds',
      'expression',
    ])
      key: TextEditingController(text: draft.values[key]),
  };
  bool busy = false, confirmingDelete = false, deleted = false;
  bool discardReview = false, leaving = false;
  String? error, notice;
  AutomationsController get catalog => widget.catalog;
  Json? get current => catalog.find(widget.record['id'] as String);
  bool get currentRead =>
      catalog.settled && !catalog.loading && catalog.error == null;
  bool get missing => currentRead && current == null;
  bool get stale =>
      currentRead && current != null && !sameAutomation(draft.base, current!);
  bool get editable =>
      !busy &&
      !deleted &&
      !missing &&
      catalog.runtime.ready &&
      (current ?? draft.base)['status'] == 'active';

  @override
  void initState() {
    super.initState();
    for (final entry in fields.entries) {
      entry.value.addListener(() {
        draft.values[entry.key] = entry.value.text;
        if (mounted) setState(() {});
      });
    }
    catalog.addListener(changed);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void syncFields() {
    for (final entry in fields.entries) {
      entry.value.text = draft.values[entry.key]!;
    }
  }

  void showOutcome() {
    FocusScope.of(context).unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scroll.hasClients) {
        unawaited(
          scroll.animateTo(
            0,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          ),
        );
      }
    });
  }

  Future<void> save() async {
    if (!editable || !draft.dirty) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      final result = await catalog.update(draft.request());
      if (!mounted) return;
      if (result['code'] != null) {
        error = automationError(result['code'] as String);
      } else {
        // A catalog refresh can already show a newer committed record.
        final saved =
            (catalog.error == null ? current : null) ??
            {...draft.base, ...(result['record'] as Json)};
        draft.reset(saved);
        syncFields();
        notice = '已保存任务。';
      }
    } catch (failure) {
      if (mounted) {
        error = failure is FormatException
            ? failure.message
            : '未能确认保存结果。草稿已保留，请刷新并比较任务后重试。';
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        showOutcome();
      }
    }
  }

  Future<void> remove() async {
    if (busy || deleted || !catalog.runtime.ready) return;
    setState(() {
      busy = true;
      confirmingDelete = false;
      error = null;
    });
    try {
      final result = await catalog.delete(widget.record);
      if (!mounted) return;
      if (result['deleted'] == true || result['code'] == 'schedule_not_found') {
        deleted = true;
        notice = result['deleted'] == true ? '任务已删除。' : '任务已不存在。';
      } else {
        error = automationError('${result['code']}');
      }
    } catch (_) {
      if (mounted) error = '未能确认删除结果。保留当前内容，请刷新列表确认。';
    } finally {
      if (mounted) {
        setState(() => busy = false);
        showOutcome();
      }
    }
  }

  void rebase() {
    if (current == null) return;
    draft.rebase(current!);
    syncFields();
    setState(() {
      error = null;
      notice = '已采用当前记录作为比较依据，保留你修改的内容。请检查后保存。';
    });
  }

  void leave() {
    setState(() => leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Widget input(String key, String label, {String? hint, int lines = 1}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: TextField(
          key: ValueKey('automation-$key'),
          controller: fields[key],
          enabled: editable,
          minLines: lines,
          maxLines: lines == 1 ? 1 : 10,
          decoration: InputDecoration(labelText: label, hintText: hint),
        ),
      );

  @override
  void dispose() {
    catalog.removeListener(changed);
    scroll.dispose();
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kind = draft.values['kind'];
    final canOpenSession = catalog.runtime.sessions.any(
      (session) =>
          (session['header'] as Json)['id'] == widget.record['sessionId'],
    );
    return PopScope<Object?>(
      canPop: leaving,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || busy) return;
        if (!draft.dirty) {
          leave();
        } else {
          setState(() => discardReview = true);
        }
      },
      child: Stack(
        children: [
          PocketScaffold(
            title: const Text('任务详情'),
            trailing: GlassButton(
              icon: Icons.refresh_rounded,
              label: '刷新当前任务',
              onPressed: catalog.loading || busy ? null : catalog.refresh,
            ),
            body: PocketList(
              controller: scroll,
              padding: const EdgeInsets.all(20),
              children: [
                if (notice != null) AutomationNotice(notice!),
                if (error != null) AutomationNotice(error!),
                if (catalog.error != null) AutomationNotice(catalog.error!),
                if (!catalog.runtime.ready)
                  const AutomationNotice('本地服务未就绪。草稿保留，暂不能保存。'),
                if (missing && !deleted)
                  const AutomationNotice('最新列表中已无此任务。保留当前草稿供查看。'),
                if ((current ?? draft.base)['status'] == 'inactive')
                  const AutomationNotice('任务已结束，不能修改。投递记录仍可查看。'),
                if (stale && !deleted)
                  PocketSection(
                    title: '当前记录已变化',
                    children: [
                      const AutomationNotice('输入内容未被覆盖。比较服务中的记录，再决定是否继续编辑。'),
                      AutomationNotice(
                        '服务中的名称：${current!['title']}\n'
                        '服务中的指令：${current!['prompt']}\n'
                        '服务中的规则：${automationRule(current!)}\n'
                        '原比较记录：${const JsonEncoder.withIndent('  ').convert(automationSnapshot(draft.base))}',
                      ),
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: PocketButton.tonal(
                          onPressed: editable ? rebase : null,
                          child: const Text('保留草稿，采用当前比较记录'),
                        ),
                      ),
                    ],
                  ),
                PocketSection(
                  title: '任务内容',
                  children: [
                    input('title', '任务名称'),
                    input('prompt', '任务指令', lines: 3),
                  ],
                ),
                PocketSection(
                  title: '执行规则',
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final entry in const {
                            'at': '单次',
                            'every': '固定间隔',
                            'daily': '每天',
                            'weekly': '每周',
                            'cron': 'Cron',
                          }.entries)
                            PocketChoice(
                              label: Text(entry.value),
                              selected: kind == entry.key,
                              onSelected: editable
                                  ? (_) => setState(
                                      () => draft.values['kind'] = entry.key,
                                    )
                                  : null,
                            ),
                        ],
                      ),
                    ),
                    if (kind == 'at') input('date', '日期', hint: 'YYYY-MM-DD'),
                    if (kind == 'at' || kind == 'daily' || kind == 'weekly')
                      input('time', '时间', hint: 'HH:mm:ss.SSS'),
                    if (kind != 'every')
                      input('zone', 'IANA 时区', hint: 'UTC 或 Asia/Shanghai'),
                    if (kind == 'at')
                      const AutomationNotice(
                        '单次任务以 UTC 显示已保存的时刻；修改时按上方明确指定的时区解释。',
                      ),
                    if (kind == 'every')
                      input('seconds', '间隔秒数', hint: '至少 60 秒'),
                    if (kind == 'cron') ...[
                      input('expression', 'Cron 表达式', hint: '分 时 日 月 星期'),
                      const AutomationNotice('使用原版五字段 Cron 规则，时区与有效性由本地服务校验。'),
                    ],
                    if (kind == 'weekly')
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (var day = 1; day <= 7; day++)
                              PocketChoice(
                                label: Text(
                                  const [
                                    '一',
                                    '二',
                                    '三',
                                    '四',
                                    '五',
                                    '六',
                                    '日',
                                  ][day - 1],
                                ),
                                selected: draft.values['weekdays']!
                                    .split(',')
                                    .contains('$day'),
                                onSelected: editable
                                    ? (_) {
                                        final days = draft.values['weekdays']!
                                            .split(',')
                                            .map(int.parse)
                                            .toSet();
                                        if (!days.remove(day)) {
                                          days.add(day);
                                        } else if (days.isEmpty) {
                                          days.add(day);
                                        }
                                        final ordered = days.toList()..sort();
                                        setState(
                                          () => draft.values['weekdays'] =
                                              ordered.join(','),
                                        );
                                      }
                                    : null,
                              ),
                          ],
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                      child: PocketButton(
                        onPressed: editable && draft.dirty ? save : null,
                        child: Text(busy ? '正在处理……' : '保存任务'),
                      ),
                    ),
                  ],
                ),
                PocketSection(
                  title: '任务来源与记录',
                  children: [
                    PocketRow(
                      icon: Icons.forum_outlined,
                      title: '原会话',
                      subtitle:
                          '${widget.record['sessionId']}'
                          '${canOpenSession ? '' : '\n原会话当前不可用'}',
                      onTap: canOpenSession && !draft.dirty && !busy
                          ? () => widget.onOpenSession(
                              widget.record['sessionId'] as String,
                            )
                          : null,
                    ),
                    PocketRow(
                      icon: Icons.history_rounded,
                      title: '投递记录',
                      subtitle: '查看已写入会话收件箱的提醒，不代表模型执行完成',
                      onTap: deleted
                          ? null
                          : () => Navigator.push(
                              context,
                              PocketRoute<void>(
                                builder: (_) => AutomationHistoryPage(
                                  catalog: catalog,
                                  record: widget.record,
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
                if (!deleted && !missing)
                  PocketSection(
                    title: '删除任务',
                    children: [
                      const AutomationNotice(
                        '删除后不再产生新的提醒，并移除该任务的投递记录。已排队的会话消息保留。',
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                        child: Wrap(
                          spacing: 12,
                          children: [
                            if (confirmingDelete) ...[
                              PocketButton.tonal(
                                onPressed: () =>
                                    setState(() => confirmingDelete = false),
                                child: const Text('保留任务'),
                              ),
                              PocketButton(
                                onPressed: busy || !catalog.runtime.ready
                                    ? null
                                    : remove,
                                child: const Text('确认删除任务'),
                              ),
                            ] else
                              PocketButton.tonal(
                                onPressed: busy || !catalog.runtime.ready
                                    ? null
                                    : () => setState(
                                        () => confirmingDelete = true,
                                      ),
                                child: const Text('删除任务'),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          if (discardReview) ...[
            const Positioned.fill(
              child: ModalBarrier(dismissible: false, color: Color(0x55000000)),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: PocketSection(
                  title: '离开当前编辑？',
                  children: [
                    const AutomationNotice('尚未保存的草稿会丢弃。'),
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Wrap(
                        spacing: 12,
                        children: [
                          PocketButton(
                            onPressed: () =>
                                setState(() => discardReview = false),
                            child: const Text('继续编辑'),
                          ),
                          PocketButton.tonal(
                            onPressed: leave,
                            child: const Text('放弃草稿并离开'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class AutomationHistoryPage extends StatefulWidget {
  const AutomationHistoryPage({
    required this.catalog,
    required this.record,
    super.key,
  });
  final AutomationsController catalog;
  final Json record;
  @override
  State<AutomationHistoryPage> createState() => _AutomationHistoryPageState();
}

class _AutomationHistoryPageState extends State<AutomationHistoryPage> {
  late final history = AutomationHistory(widget.catalog, widget.record);
  @override
  void initState() {
    super.initState();
    history.addListener(changed);
    history.start();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    history.removeListener(changed);
    history.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('投递记录'),
    trailing: GlassButton(
      icon: Icons.refresh_rounded,
      label: '刷新投递记录',
      onPressed: widget.catalog.runtime.ready ? () => history.load() : null,
    ),
    body: PocketList(
      padding: const EdgeInsets.all(20),
      children: [
        const AutomationNotice('以下是已持久保存的收件箱投递回执，不是模型执行结果。'),
        if (!widget.catalog.runtime.ready)
          const AutomationNotice('等待本地服务恢复。保留已读取的记录。'),
        if (history.loading) const AutomationNotice('正在读取投递记录……'),
        if (history.error != null) ...[
          AutomationNotice(history.error!),
          PocketButton.tonal(
            onPressed: history.loading ? null : history.retry,
            child: const Text('重试读取'),
          ),
        ],
        if (history.page != null && history.records.isEmpty)
          const AutomationNotice('尚无保存的投递记录。'),
        for (final record in history.records)
          PocketSection(
            title: '${record['scheduledAt']}',
            children: [
              AutomationNotice('投递时间：${record['deliveredAt']}'),
              AutomationNotice(record['prompt'] as String? ?? '旧回执未保存当时的指令。'),
            ],
          ),
        if (history.page?['nextBefore'] != null && history.error == null)
          PocketButton.tonal(
            onPressed: history.loading
                ? null
                : () => history.load(
                    before: history.page!['nextBefore'] as String,
                  ),
            child: const Text('加载更早记录'),
          ),
        if (history.page?['earlierRecordsUnavailable'] == true)
          const AutomationNotice('部分更早记录可能不可用，不会推测或补造历史。'),
        if (history.page?['earlierRecordsPruned'] == true)
          AutomationNotice(
            '更早记录已按保留规则清理：'
            '${history.page!['retention']['days']} 天、最多 '
            '${history.page!['retention']['records']} 条。',
          ),
      ],
    ),
  );
}

class AutomationNotice extends StatelessWidget {
  const AutomationNotice(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(20), child: SelectableText(text));
}
