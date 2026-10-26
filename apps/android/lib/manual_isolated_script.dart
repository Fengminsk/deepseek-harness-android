import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'isolated_approval_page.dart';
import 'manual_run_response_gate.dart';
import 'runtime.dart';
import 'ui.dart';

/// A user-initiated developer tool. A model or a runtime JSON-RPC call cannot create its grant.
class ManualIsolatedScriptPage extends StatefulWidget {
  const ManualIsolatedScriptPage({required this.runtime, super.key});
  final RuntimeController runtime;
  @override
  State<ManualIsolatedScriptPage> createState() =>
      _ManualIsolatedScriptPageState();
}

class _ManualIsolatedScriptPageState extends State<ManualIsolatedScriptPage> {
  List<Map<String, dynamic>> workspaces = [], sessions = [];
  Map<String, dynamic>? workspace, session, status;
  String? file, host, error;
  bool writable = false, busy = false;
  String program = 'async (input, host) => ({ ok: true })';
  String inputJson = '{}';
  Timer? poller;
  final responses = ManualRunResponseGate();
  bool statusRefreshPending = false;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void dispose() {
    poller?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    final generation = responses.begin();
    poller?.cancel();
    try {
      final latest = await manual('isolatedManual.status', {'runId': ''});
      if (!mounted || !responses.accepts(generation)) return;
      setState(() => status = latest['stage'] == 'none' ? null : latest);
      if (status != null &&
          !['terminal', 'denied', 'unconfirmed'].contains(status!['stage'])) {
        beginPolling();
      }
    } catch (_) {
      if (mounted && responses.accepts(generation)) {
        setState(() => error = '上次运行状态暂不可确认');
      }
    }
    try {
      final raw = await widget.runtime.call('library.catalog') as Map;
      final privateRoot = raw['defaultDirectory'] as String? ?? '';
      final nextWorkspaces = (raw['workspaces'] as List)
          .cast<Map<String, dynamic>>()
          .where((row) {
            final path = row['path'];
            return privateRoot.isNotEmpty &&
                path is String &&
                (path == privateRoot || path.startsWith('$privateRoot/'));
          })
          .toList();
      final nextSessions = (raw['sessions'] as List)
          .cast<Map<String, dynamic>>();
      if (!mounted || !responses.accepts(generation)) return;
      setState(() {
        workspaces = nextWorkspaces;
        sessions = nextSessions;
        error = null;
      });
    } catch (_) {
      if (mounted && responses.accepts(generation)) {
        setState(() => error = '工作区暂不可确认，请刷新后重试');
      }
    }
  }

  Future<Map<String, dynamic>> manual(
    String method,
    Map<String, dynamic> args,
  ) async {
    final raw = await RuntimeController.channel
        .invokeMethod<String>(method, args)
        .timeout(const Duration(seconds: 15));
    if (raw == null) throw const FormatException('运行状态无效');
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  void beginPolling() {
    poller?.cancel();
    poller = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(refreshStatus()),
    );
  }

  Future<void> refreshStatus() async {
    if (statusRefreshPending) return;
    final id = status?['runId'];
    if (id is! String) return;
    statusRefreshPending = true;
    final generation = responses.generation;
    final ticket = responses.nextStatusTicket();
    try {
      final next = await manual('isolatedManual.status', {'runId': id});
      if (!mounted ||
          !responses.acceptsStatus(
            generation,
            ticket,
            id,
            status?['runId'] as String?,
          )) {
        return;
      }
      if (['terminal', 'denied'].contains(status?['stage']) &&
          next['stage'] != status?['stage']) {
        return;
      }
      setState(() => status = next);
      if (['terminal', 'denied', 'unconfirmed'].contains(next['stage'])) {
        poller?.cancel();
      }
    } catch (_) {
      if (mounted &&
          responses.acceptsStatus(
            generation,
            ticket,
            id,
            status?['runId'] as String?,
          )) {
        setState(() => error = '运行状态未确认。请刷新回执，不要重新提交。');
        poller?.cancel();
      }
    } finally {
      statusRefreshPending = false;
    }
  }

  Future<T?> open<T>(Widget page) =>
      Navigator.push<T>(context, PocketRoute<T>(builder: (_) => page));

  String sessionTitle(Map<String, dynamic> row) {
    final projections = row['projections'];
    final values = projections is Map ? projections['values'] : null;
    final title = values is Map ? values['title'] : null;
    return (title ?? row['title'] ?? row['sessionId']).toString();
  }

  Future<void> chooseWorkspace() async {
    final next = await open<Map<String, dynamic>>(
      _ManualChoicePage(
        title: '选择工作区',
        rows: workspaces,
        titleOf: (row) =>
            row['title'] as String? ?? row['path'] as String? ?? '工作区',
        subtitleOf: (row) => row['path'] as String? ?? '',
      ),
    );
    if (next != null && mounted) {
      setState(() {
        workspace = next;
        session = null;
        file = null;
        writable = false;
      });
    }
  }

  Future<void> chooseSession() async {
    final ids = (workspace?['sessionIds'] as List? ?? []).cast<String>();
    final eligible = workspace == null
        ? sessions
        : sessions.where((row) => ids.contains(row['sessionId'])).toList();
    final next = await open<Map<String, dynamic>>(
      _ManualChoicePage(
        title: '选择会话',
        rows: eligible,
        titleOf: sessionTitle,
        subtitleOf: (row) => (row['cwd'] ?? '').toString(),
      ),
    );
    if (next != null && mounted) setState(() => session = next);
  }

  Future<void> chooseFile() async {
    final selected = workspace;
    if (selected == null) return;
    final filePath = await open<String>(
      _ManualFilePage(
        runtime: widget.runtime,
        workspacePath: selected['path'] as String,
      ),
    );
    if (filePath != null && mounted) setState(() => file = filePath);
  }

  Future<void> editText({
    required String title,
    required String value,
    required ValueChanged<String> save,
    bool multiline = true,
    bool readOnly = false,
  }) async {
    final next = await open<String>(
      _ManualTextPage(
        title: title,
        initial: value,
        multiline: multiline,
        readOnly: readOnly,
      ),
    );
    if (next != null && mounted) setState(() => save(next));
  }

  Future<void> run() async {
    if (busy || session == null) return;
    final generation = responses.begin();
    poller?.cancel();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final next = await manual('isolatedManual.prepare', {
        'sessionId': session!['sessionId'],
        'workspaceId': file == null ? '' : workspace?['workspaceId'] ?? '',
        'file': file ?? '',
        'writable': writable,
        'host': host ?? '',
        'program': program,
        'inputJson': inputJson,
        'deadlineMillis': 5000,
      });
      if (!mounted || !responses.accepts(generation)) return;
      setState(() => status = next);
      beginPolling();
      final requestId = next['requestId'];
      if (requestId is String && next['stage'] == 'awaiting-approval') {
        final rows =
            await widget.runtime.call('runtime.isolatedApprovals.list') as List;
        if (!mounted || !responses.accepts(generation)) return;
        final review = rows
            .map(IsolatedApprovalReview.parse)
            .where((item) => item.requestId == requestId && !item.active)
            .first;
        if (mounted && responses.accepts(generation)) {
          await open<void>(
            IsolatedApprovalDetailPage(runtime: widget.runtime, review: review),
          );
          await refreshStatus();
        }
      }
    } catch (_) {
      if (mounted && responses.accepts(generation)) {
        setState(() => error = '提交状态未确认。请刷新运行记录，不要直接重复执行。');
      }
    } finally {
      if (mounted && responses.accepts(generation)) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> cancel() async {
    final id = status?['runId'];
    if (id is! String) return;
    try {
      await manual('isolatedManual.cancel', {'runId': id});
      await refreshStatus();
    } catch (_) {
      if (mounted) setState(() => error = '取消结果未确认，请刷新运行回执');
    }
  }

  Widget runState() {
    final current = status;
    if (current == null) return const SizedBox.shrink();
    final receipt = current['receipt'] as Map?;
    final stage = current['stage'];
    String title = switch (stage) {
      'awaiting-approval' => '等待本次授权',
      'running' => '隔离脚本运行中',
      'cancelling' => '正在取消',
      'denied' => '已拒绝本次授权',
      'unconfirmed' => '运行结果待核对',
      'terminal' => switch (receipt?['state']) {
        'COMPLETED' => '已完成',
        'CANCELLED' => '已取消',
        'TIMED_OUT' => '运行超时',
        _ => '运行已结束',
      },
      _ => '正在准备隔离运行',
    };
    return PocketSection(
      title: '最近一次运行',
      divided: true,
      children: [
        PocketRow(
          icon: Icons.receipt_long_outlined,
          title: title,
          subtitle: current['runId']?.toString(),
        ),
        if (receipt?['state'] == 'COMPLETED' &&
            receipt?['outputJson'] is String)
          PocketRow(
            icon: Icons.description_outlined,
            title: '查看结果',
            subtitle: '仅终态回执确认后显示',
            onTap: () => unawaited(
              editText(
                title: '运行结果',
                value: receipt!['outputJson'] as String,
                save: (_) {},
                readOnly: true,
              ),
            ),
          ),
        if (receipt?['detail'] is String)
          PocketRow(
            icon: Icons.info_outline,
            title: '运行详情',
            subtitle: receipt!['detail'] as String,
          ),
        if (stage == 'running' || stage == 'awaiting-approval')
          PocketRow(
            icon: Icons.stop_circle_outlined,
            title: '取消本次运行',
            onTap: cancel,
          ),
        if (stage == 'unconfirmed')
          const PocketRow(
            icon: Icons.report_outlined,
            title: '不可自动重试',
            subtitle: '进程或回执不确定时，请先检查工作文件。',
          ),
        if (stage == 'unconfirmed')
          PocketRow(
            icon: Icons.refresh_rounded,
            title: '重新读取回执',
            onTap: refreshStatus,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('手动隔离脚本'),
    body: PocketList(
      children: [
        PocketSection(
          title: '运行身份',
          divided: true,
          children: [
            PocketRow(
              icon: Icons.folder_outlined,
              title: '工作区',
              subtitle: workspace?['title']?.toString() ?? '选择已登记工作区',
              onTap: chooseWorkspace,
            ),
            PocketRow(
              icon: Icons.chat_bubble_outline,
              title: '会话',
              subtitle: session == null
                  ? '选择本次运行所关联的会话'
                  : sessionTitle(session!),
              onTap: chooseSession,
            ),
          ],
        ),
        PocketSection(
          title: '本次能力 · 默认关闭',
          divided: true,
          children: [
            PocketRow(
              icon: Icons.insert_drive_file_outlined,
              title: '文件或目录',
              subtitle: file ?? '不访问文件',
              onTap: chooseFile,
            ),
            if (file != null)
              PocketRow(
                icon: Icons.edit_outlined,
                title: '文件权限',
                subtitle: file!.endsWith('/')
                    ? (writable ? '可读取与编辑此目录内文件' : '只读取此目录内文件')
                    : (writable ? '可读取与编辑这一个文件' : '只读取这一个文件'),
                onTap: () => setState(() => writable = !writable),
              ),
            if (file != null)
              PocketRow(
                icon: Icons.close,
                title: '移除访问授权',
                onTap: () => setState(() {
                  file = null;
                  writable = false;
                }),
              ),
            PocketRow(
              icon: Icons.public_outlined,
              title: '联网主机',
              subtitle: host ?? '关闭',
              onTap: () => editText(
                title: '精确 HTTPS 主机',
                value: host ?? '',
                multiline: false,
                save: (value) =>
                    host = value.trim().isEmpty ? null : value.trim(),
              ),
            ),
          ],
        ),
        PocketSection(
          title: '脚本',
          divided: true,
          children: [
            PocketRow(
              icon: Icons.code_rounded,
              title: '脚本内容',
              subtitle: '仅本次运行；在独立页面编辑',
              onTap: () => editText(
                title: '脚本内容',
                value: program,
                save: (value) => program = value,
              ),
            ),
            PocketRow(
              icon: Icons.data_object_outlined,
              title: '输入数据',
              subtitle: '默认空对象',
              onTap: () => editText(
                title: '输入数据',
                value: inputJson,
                save: (value) => inputJson = value,
              ),
            ),
          ],
        ),
        if (error != null)
          PocketSection(
            children: [
              PocketRow(icon: Icons.error_outline, title: error!),
              PocketRow(icon: Icons.refresh, title: '刷新状态', onTap: load),
            ],
          ),
        runState(),
        PocketButton(
          onPressed: busy || session == null ? null : run,
          child: Text(busy ? '正在核对' : '检查并运行一次'),
        ),
      ],
    ),
  );
}

class _ManualChoicePage extends StatelessWidget {
  const _ManualChoicePage({
    required this.title,
    required this.rows,
    required this.titleOf,
    required this.subtitleOf,
  });
  final String title;
  final List<Map<String, dynamic>> rows;
  final String Function(Map<String, dynamic>) titleOf, subtitleOf;
  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: Text(title),
    body: PocketList(
      children: [
        PocketSection(
          divided: true,
          children: [
            if (rows.isEmpty)
              const PocketRow(icon: Icons.inbox_outlined, title: '没有可选项目'),
            for (final row in rows)
              PocketRow(
                icon: Icons.check_circle_outline,
                title: titleOf(row),
                subtitle: subtitleOf(row),
                onTap: () => Navigator.pop(context, row),
              ),
          ],
        ),
      ],
    ),
  );
}

class _ManualTextPage extends StatefulWidget {
  const _ManualTextPage({
    required this.title,
    required this.initial,
    required this.multiline,
    required this.readOnly,
  });
  final String title, initial;
  final bool multiline, readOnly;
  @override
  State<_ManualTextPage> createState() => _ManualTextPageState();
}

class _ManualTextPageState extends State<_ManualTextPage> {
  late final controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: Text(widget.title),
    body: PocketList(
      children: [
        PocketSection(
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: widget.readOnly
                  ? Text(widget.initial)
                  : TextField(
                      controller: controller,
                      maxLines: widget.multiline ? null : 1,
                      minLines: widget.multiline ? 8 : 1,
                      onTapOutside: (_) => FocusScope.of(context).unfocus(),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                      ),
                    ),
            ),
          ],
        ),
        if (!widget.readOnly)
          PocketButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('完成'),
          ),
      ],
    ),
  );
}

class _ManualFilePage extends StatefulWidget {
  const _ManualFilePage({required this.runtime, required this.workspacePath});
  final RuntimeController runtime;
  final String workspacePath;
  @override
  State<_ManualFilePage> createState() => _ManualFilePageState();
}

class _ManualFilePageState extends State<_ManualFilePage> {
  List<Map<String, dynamic>> entries = [];
  String path = '', prefix = '', root = '';
  String? version, error;
  int? nextOffset;
  bool loading = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(initialise());
  }

  Future<void> initialise() async {
    try {
      final info = await widget.runtime.call('workspace.files.info') as Map;
      final actualRoot = info['root'] as String;
      final target = widget.workspacePath;
      if (target != actualRoot && !target.startsWith('$actualRoot/')) {
        throw const FormatException('工作区不是 App 私有工作区');
      }
      if (!mounted) return;
      root = actualRoot;
      prefix = target == actualRoot
          ? ''
          : target.substring(actualRoot.length + 1);
      path = prefix;
      await load();
    } catch (_) {
      if (mounted) setState(() => error = '此工作区无法选择隔离文件');
    }
  }

  Future<void> load({bool more = false}) async {
    if (loading || more && nextOffset == null) return;
    final attempt = generation;
    final requested = path;
    final offset = more ? nextOffset! : 0;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final raw = await widget.runtime.call('workspace.files.list', {
        'path': requested,
        'offset': offset,
        if (more) 'version': version,
      }) as Map;
      if (!mounted || attempt != generation) return;
      if (raw['path'] != requested ||
          raw['root'] != root ||
          raw['offset'] != offset ||
          more && raw['version'] != version) {
        throw const FormatException('目录已变化');
      }
      setState(() {
        entries = [
          if (more) ...entries,
          ...(raw['entries'] as List).cast<Map<String, dynamic>>(),
        ];
        version = raw['version'] as String;
        nextOffset = raw['nextOffset'] as int?;
      });
    } catch (_) {
      if (mounted && attempt == generation) {
        setState(() => error = '目录已变化，请刷新后重新选择');
      }
    } finally {
      if (mounted && attempt == generation) setState(() => loading = false);
    }
  }

  void browse(String next) {
    generation++;
    setState(() {
      path = next;
      entries = [];
      version = null;
      nextOffset = null;
      loading = false;
      error = null;
    });
    unawaited(load());
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('选择文件或目录'),
    body: PocketList(
      children: [
        PocketSection(
          children: [
            PocketRow(
              icon: Icons.folder_open_outlined,
              title: path == prefix ? '工作区' : path.substring(prefix.length + 1),
              subtitle: '可授权此目录或选择单个文件；链接不可授权',
            ),
            if (path != prefix)
              PocketRow(
                icon: Icons.folder_special_outlined,
                title: '授权此目录',
                subtitle: '包含此目录下的文件，操作仍逐次校验',
                onTap: () {
                  final relative = path.substring(prefix.length + 1);
                  Navigator.pop(context, '$relative/');
                },
              ),
            if (path != prefix)
              PocketRow(
                icon: Icons.arrow_upward,
                title: '上一级',
                onTap: () {
                  final slash = path.lastIndexOf('/');
                  browse(
                    slash < prefix.length ? prefix : path.substring(0, slash),
                  );
                },
              ),
          ],
        ),
        if (error != null)
          PocketSection(
            children: [
              PocketRow(
                icon: Icons.error_outline,
                title: error!,
                onTap: () => load(),
              ),
            ],
          ),
        PocketSection(
          divided: true,
          children: [
            for (final entry in entries)
              PocketRow(
                icon: entry['kind'] == 'directory'
                    ? Icons.folder_outlined
                    : Icons.insert_drive_file_outlined,
                title: entry['name'] as String? ?? '',
                subtitle: entry['blockedReason'] == null ? null : '不可选择',
                onTap:
                    entry['blockedReason'] != null ||
                        !['directory', 'file'].contains(entry['kind'])
                    ? null
                    : () {
                        final selected = entry['path'] as String;
                        if (entry['kind'] == 'directory') {
                          browse(selected);
                        } else {
                          final relative = prefix.isEmpty
                              ? selected
                              : selected.substring(prefix.length + 1);
                          Navigator.pop(context, relative);
                        }
                      },
              ),
            if (nextOffset != null)
              PocketRow(
                icon: Icons.more_horiz,
                title: loading ? '正在读取' : '显示更多',
                onTap: loading ? null : () => unawaited(load(more: true)),
              ),
            if (entries.isEmpty && !loading && error == null)
              const PocketRow(
                icon: Icons.folder_off_outlined,
                title: '此目录没有可选文件',
              ),
          ],
        ),
      ],
    ),
  );
}
