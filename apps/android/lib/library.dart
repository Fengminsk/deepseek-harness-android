import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'library_data.dart';
import 'runtime.dart';
import 'ui.dart';

Future<void> _openChild(BuildContext context, Widget page) async {
  final sessionId = await Navigator.push<String>(
    context,
    PocketRoute<String>(builder: (_) => page),
  );
  if (context.mounted && sessionId != null) Navigator.pop(context, sessionId);
}

Widget _sync(LibraryController library) => PocketSection(
  children: [
    PocketRow(
      icon: library.synchronized
          ? Icons.sync_rounded
          : Icons.sync_problem_rounded,
      title: library.synchronizationLabel,
      subtitle: library.readError,
    ),
  ],
);

Widget _action(LibraryController library, String key) {
  final action = library.actions[key];
  if (action == null) return const SizedBox.shrink();
  return PocketRow(
    key: ValueKey('result-$key'),
    icon: action.state == 'confirmed' || action.state == 'observed'
        ? Icons.check_circle_outline_rounded
        : Icons.info_outline_rounded,
    title: action.state == 'pending' ? '等待原服务确认' : action.message ?? '操作结果尚未确认',
    subtitle: action.state == 'unconfirmed'
        ? '保留当前结果并刷新核对。重新进入此页面不会重试该请求。'
        : null,
  );
}

Widget _refresh(LibraryController library) => GlassButton(
  icon: Icons.refresh_rounded,
  label: '刷新管理目录',
  onPressed: library.loading || library.writing
      ? null
      : () => library.refresh(reconnect: true),
);

Widget _sessionRow(
  BuildContext context,
  LibraryController library,
  String sessionId,
) {
  final session = library.session(sessionId);
  final updatedAt = session?['updatedAt'];
  final at = updatedAt is num
      ? DateTime.fromMillisecondsSinceEpoch(updatedAt.toInt())
      : null;
  String two(int value) => value.toString().padLeft(2, '0');
  final time = at == null
      ? null
      : '${at.year}/${two(at.month)}/${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
  final workspace = library.workspaceFor(sessionId)?['title'];
  return PocketRow(
    key: ValueKey('library-session-$sessionId'),
    icon: library.archivedSessionIds.contains(sessionId)
        ? Icons.archive_outlined
        : library.pinnedSessionIds.contains(sessionId)
        ? Icons.push_pin_outlined
        : Icons.chat_bubble_outline_rounded,
    title: session == null ? '会话信息尚未读取' : librarySessionTitle(session),
    subtitle: [
      if (session?['running'] == true) '正在运行',
      if (session?['blank'] == true) '空白会话',
      if (workspace is String && workspace.isNotEmpty) workspace,
      ?time,
    ].join(' · '),
    onTap: session == null
        ? null
        : () => _openChild(
            context,
            LibrarySessionPage(library: library, sessionId: sessionId),
          ),
  );
}

/// Native management entry; the returned identity is opened by the chat host.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.runtime});
  final RuntimeController runtime;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late final library = widget.runtime.library;
  String selected = '工作区';

  @override
  void initState() {
    super.initState();
    library.start();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: library,
    builder: (context, _) {
      final recent = [...library.sessions]
        ..sort(
          (a, b) => ((b['updatedAt'] as num?) ?? 0).compareTo(
            (a['updatedAt'] as num?) ?? 0,
          ),
        );
      final ids = switch (selected) {
        '置顶' => library.pinnedSessionIds,
        '已归档' => library.archivedSessionIds,
        _ =>
          recent
              .map((row) => row['sessionId'] as String)
              .where((id) => !library.archivedSessionIds.contains(id))
              .toList(),
      };
      return PocketScaffold(
        title: const Text('工作区与会话'),
        trailing: _refresh(library),
        body: PocketList(
          children: [
            _sync(library),
            Wrap(
              spacing: 8,
              children: [
                for (final name in ['工作区', '近期', '置顶', '已归档'])
                  PocketChoice(
                    label: Text(name),
                    selected: selected == name,
                    onSelected: (_) => setState(() => selected = name),
                  ),
              ],
            ),
            if (selected == '工作区') ...[
              PocketButton(
                key: const ValueKey('library-add-workspace'),
                onPressed: library.defaultDirectory == null
                    ? null
                    : () => _openChild(
                        context,
                        LibraryCreateWorkspacePage(library: library),
                      ),
                child: const Text('添加工作区'),
              ),
              PocketSection(
                title: '工作区目录',
                children: [
                  if (library.workspaces.isEmpty)
                    const PocketRow(
                      icon: Icons.folder_open_rounded,
                      title: '尚无已读取的工作区',
                    ),
                  for (final workspace in library.workspaces)
                    PocketRow(
                      key: ValueKey('workspace-${workspace['workspaceId']}'),
                      icon: Icons.folder_outlined,
                      title: workspace['title'] as String,
                      subtitle: workspace['path'] as String,
                      onTap: () => _openChild(
                        context,
                        LibraryWorkspacePage(
                          library: library,
                          workspaceId: workspace['workspaceId'] as String,
                        ),
                      ),
                    ),
                ],
              ),
            ] else
              PocketSection(
                title: selected,
                children: [
                  if (ids.isEmpty)
                    const PocketRow(
                      icon: Icons.chat_bubble_outline_rounded,
                      title: '此列表暂无会话',
                    ),
                  for (final id in ids) _sessionRow(context, library, id),
                ],
              ),
          ],
        ),
      );
    },
  );
}

class LibraryWorkspacePage extends StatelessWidget {
  const LibraryWorkspacePage({
    super.key,
    required this.library,
    required this.workspaceId,
  });
  final LibraryController library;
  final String workspaceId;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: library,
    builder: (context, _) {
      final workspace = library.workspace(workspaceId);
      final key = 'session-create:$workspaceId';
      final created = library.actions[key]?.result['sessionId'];
      final ids = (workspace?['sessionIds'] as List? ?? [])
          .cast<String>()
          .where((id) => !library.archivedSessionIds.contains(id));
      return PocketScaffold(
        title: Text(workspace?['title'] as String? ?? '工作区'),
        trailing: _refresh(library),
        body: PocketList(
          children: [
            _sync(library),
            PocketSection(
              title: '工作区',
              children: [
                PocketRow(
                  icon: Icons.folder_open_rounded,
                  title: '工作目录',
                  subtitle: workspace?['path'] as String? ?? '目录信息未确认',
                ),
                PocketRow(
                  icon: Icons.edit_outlined,
                  title: '重命名工作区',
                  onTap: workspace == null
                      ? null
                      : () => Navigator.push<void>(
                          context,
                          PocketRoute<void>(
                            builder: (_) => LibraryRenamePage(
                              library: library,
                              id: workspaceId,
                              workspace: true,
                            ),
                          ),
                        ),
                ),
                PocketRow(
                  icon: Icons.swap_vert_rounded,
                  title: '调整工作区顺序',
                  onTap: workspace == null
                      ? null
                      : () => Navigator.push<void>(
                          context,
                          PocketRoute<void>(
                            builder: (_) => LibraryOrderPage(
                              library: library,
                              workspaceId: workspaceId,
                            ),
                          ),
                        ),
                ),
                _action(library, key),
                if (created is String)
                  PocketRow(
                    icon: Icons.open_in_new_rounded,
                    title: '打开已创建的会话',
                    subtitle: created,
                    onTap: () => Navigator.pop(context, created),
                  ),
              ],
            ),
            PocketButton(
              key: const ValueKey('workspace-new-session'),
              onPressed: workspace == null || !library.allowed(key)
                  ? null
                  : () async {
                      final receipt = await library.mutate(
                        key,
                        'sessionCreate',
                        {'workspaceId': workspaceId},
                      );
                      if (context.mounted && receipt != null) {
                        Navigator.pop(context, receipt['sessionId'] as String);
                      }
                    },
              child: const Text('在此工作区开始新对话'),
            ),
            PocketSection(
              title: '会话',
              children: [
                if (ids.isEmpty)
                  const PocketRow(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: '此工作区暂无未归档会话',
                  ),
                for (final id in ids) _sessionRow(context, library, id),
              ],
            ),
          ],
        ),
      );
    },
  );
}

class LibrarySessionPage extends StatelessWidget {
  const LibrarySessionPage({
    super.key,
    required this.library,
    required this.sessionId,
  });
  final LibraryController library;
  final String sessionId;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: library,
    builder: (context, _) {
      final session = library.session(sessionId);
      final workspace = library.workspaceFor(sessionId);
      final archived = library.archivedSessionIds.contains(sessionId);
      final pinned = library.pinnedSessionIds.contains(sessionId);
      final archiveKey = 'archive:$sessionId';
      final archive = library.actions[archiveKey];
      final forkKey = 'fork:$sessionId';
      final forkId = library.actions[forkKey]?.result['sessionId'];
      return PocketScaffold(
        title: Text(session == null ? '会话管理' : librarySessionTitle(session)),
        trailing: _refresh(library),
        body: PocketList(
          children: [
            _sync(library),
            PocketSection(
              title: '会话信息',
              children: [
                PocketRow(
                  icon: Icons.folder_outlined,
                  title: '工作目录',
                  subtitle: session?['cwd'] as String?,
                ),
                PocketDisclosure(
                  title: '会话标识',
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(sessionId),
                  ),
                ),
                PocketRow(
                  icon: Icons.open_in_new_rounded,
                  title: '打开会话',
                  onTap: session == null
                      ? null
                      : () => Navigator.pop(context, sessionId),
                ),
                PocketRow(
                  icon: Icons.edit_outlined,
                  title: '重命名会话',
                  onTap: session == null
                      ? null
                      : () => Navigator.push<void>(
                          context,
                          PocketRoute<void>(
                            builder: (_) => LibraryRenamePage(
                              library: library,
                              id: sessionId,
                            ),
                          ),
                        ),
                ),
                PocketRow(
                  icon: Icons.push_pin_outlined,
                  title: pinned ? '取消置顶' : '置顶会话',
                  subtitle: archived ? '恢复归档后可置顶' : null,
                  onTap: archived || !library.allowed('pin:$sessionId')
                      ? null
                      : () => library.mutate('pin:$sessionId', 'sessionPin', {
                          'sessionId': sessionId,
                          'pinned': !pinned,
                        }),
                ),
                _action(library, 'pin:$sessionId'),
                if (workspace != null)
                  PocketRow(
                    icon: Icons.swap_vert_rounded,
                    title: '调整工作区内顺序',
                    subtitle: '仅调整当前工作区内的顺序，不移动工作目录。',
                    onTap: () => Navigator.push<void>(
                      context,
                      PocketRoute<void>(
                        builder: (_) => LibraryOrderPage(
                          library: library,
                          workspaceId: workspace['workspaceId'] as String,
                          sessionId: sessionId,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            PocketSection(
              title: '归档',
              children: [
                const PocketRow(
                  icon: Icons.archive_outlined,
                  title: '归档保留会话内容',
                  subtitle: '归档后可在“已归档”中恢复。若仍有活动，先核对再决定是否停止。',
                ),
                _action(library, archiveKey),
                if (archive?.state == 'needs-stop') ...[
                  for (final entry
                      in (archive!.details['activity'] as List? ?? [])
                          .whereType<Json>())
                    PocketRow(
                      icon: Icons.pending_actions_rounded,
                      title: switch (entry['kind']) {
                        'turn' => '正在执行的会话回合',
                        'subagent' => '活动子 Agent',
                        'job' => '后台作业',
                        'schedule' => '活动自动化任务',
                        _ => '活动类型：${entry['kind']}',
                      },
                      subtitle: entry['items'] is List
                          ? '${(entry['items'] as List).length} 项活动，详情可展开查看'
                          : null,
                    ),
                  PocketDisclosure(
                    title: '查看原服务报告的活动',
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        const JsonEncoder.withIndent('  ').convert(
                          archive.details['activity'] ?? archive.details,
                        ),
                      ),
                    ),
                  ),
                  const PocketRow(
                    icon: Icons.warning_amber_rounded,
                    title: '停止活动会影响当前任务',
                    subtitle:
                        '确认后请求停止当前回合、子 Agent、后台作业或自动化任务，再归档；归档回执不表示这些活动已经停止。',
                  ),
                  PocketButton(
                    key: const ValueKey('confirm-stop-and-archive'),
                    onPressed: !library.allowed(archiveKey)
                        ? null
                        : () => library.mutate(archiveKey, 'sessionArchive', {
                            'sessionId': sessionId,
                            'archived': true,
                            'stopActivity': true,
                          }),
                    child: const Text('确认停止活动并归档'),
                  ),
                ] else
                  PocketButton.tonal(
                    key: const ValueKey('session-archive'),
                    onPressed: !library.allowed(archiveKey)
                        ? null
                        : () => library.mutate(archiveKey, 'sessionArchive', {
                            'sessionId': sessionId,
                            'archived': !archived,
                            'stopActivity': false,
                          }),
                    child: Text(archived ? '恢复归档会话' : '归档会话'),
                  ),
              ],
            ),
            PocketSection(
              title: '从会话继续',
              children: [
                const PocketRow(
                  icon: Icons.fork_right_rounded,
                  title: '分叉会话',
                  subtitle: '由原服务选择最新已完成的会话前缀，新会话不包含正在生成的部分。',
                ),
                _action(library, forkKey),
                if (forkId is String)
                  PocketRow(
                    icon: Icons.open_in_new_rounded,
                    title: '打开分叉会话',
                    subtitle: forkId,
                    onTap: () => Navigator.pop(context, forkId),
                  ),
                PocketButton(
                  key: const ValueKey('session-fork'),
                  onPressed: !library.allowed(forkKey)
                      ? null
                      : () async {
                          final receipt = await library.mutate(
                            forkKey,
                            'sessionFork',
                            {'sessionId': sessionId},
                          );
                          if (context.mounted && receipt != null) {
                            Navigator.pop(
                              context,
                              receipt['sessionId'] as String,
                            );
                          }
                        },
                  child: const Text('创建分叉会话'),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

class LibraryRenamePage extends StatefulWidget {
  const LibraryRenamePage({
    super.key,
    required this.library,
    required this.id,
    this.workspace = false,
  });
  final LibraryController library;
  final String id;
  final bool workspace;

  @override
  State<LibraryRenamePage> createState() => _LibraryRenamePageState();
}

class _LibraryRenamePageState extends State<LibraryRenamePage> {
  late final key =
      '${widget.workspace ? 'workspace' : 'session'}-rename:${widget.id}';
  late final TextEditingController field;
  String get current => widget.workspace
      ? (widget.library.workspace(widget.id)?['title'] as String? ?? '')
      : (widget.library.session(widget.id)?['projections']?['values']?['title']
                as String? ??
            '');

  @override
  void initState() {
    super.initState();
    widget.library.draftBases.putIfAbsent(key, () => current);
    field = TextEditingController(
      text: widget.library.drafts.putIfAbsent(key, () => current),
    );
  }

  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.library,
    builder: (context, _) {
      final conflict =
          current != widget.library.draftBases[key] &&
          current != field.text.trim();
      return PocketScaffold(
        title: Text(widget.workspace ? '重命名工作区' : '重命名会话'),
        trailing: _refresh(widget.library),
        body: PocketList(
          children: [
            _sync(widget.library),
            PocketSection(
              title: '名称',
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: TextField(
                    key: const ValueKey('library-title'),
                    controller: field,
                    enabled: !widget.library.writing,
                    decoration: const InputDecoration(labelText: '名称'),
                    onChanged: (value) =>
                        setState(() => widget.library.drafts[key] = value),
                  ),
                ),
                if (conflict) ...[
                  PocketRow(
                    icon: Icons.info_outline_rounded,
                    title: '名称已在其他入口改变，草稿保留',
                    subtitle: '当前名称：$current',
                  ),
                  PocketButton.tonal(
                    onPressed: () => setState(
                      () => widget.library.draftBases[key] = current,
                    ),
                    child: const Text('以当前名称为依据，保留草稿'),
                  ),
                ],
                _action(widget.library, key),
              ],
            ),
            PocketButton(
              key: const ValueKey('save-library-title'),
              onPressed:
                  field.text.trim().isEmpty ||
                      conflict ||
                      !widget.library.allowed(key)
                  ? null
                  : () async {
                      final title = field.text.trim();
                      final receipt = await widget.library.mutate(
                        key,
                        widget.workspace ? 'workspaceRename' : 'sessionRename',
                        {
                          if (widget.workspace)
                            'workspaceId': widget.id
                          else
                            'sessionId': widget.id,
                          'title': title,
                        },
                      );
                      if (receipt != null && mounted) {
                        setState(() => widget.library.draftBases[key] = title);
                      }
                    },
              child: const Text('保存名称'),
            ),
          ],
        ),
      );
    },
  );
}

class LibraryOrderPage extends StatefulWidget {
  const LibraryOrderPage({
    super.key,
    required this.library,
    required this.workspaceId,
    this.sessionId,
  });
  final LibraryController library;
  final String workspaceId;
  final String? sessionId;

  @override
  State<LibraryOrderPage> createState() => _LibraryOrderPageState();
}

class _LibraryOrderPageState extends State<LibraryOrderPage> {
  String? before;
  bool selected = false;
  late final key = 'order:${widget.sessionId ?? widget.workspaceId}';

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.library,
    builder: (context, _) {
      final isSession = widget.sessionId != null;
      final rows = isSession
          ? (widget.library.workspace(widget.workspaceId)?['sessionIds']
                        as List? ??
                    [])
                .cast<String>()
                .where((id) => id != widget.sessionId)
                .map(
                  (id) => (
                    id,
                    widget.library.session(id) == null
                        ? id
                        : librarySessionTitle(widget.library.session(id)!),
                  ),
                )
                .toList()
          : widget.library.workspaces
                .where((row) => row['workspaceId'] != widget.workspaceId)
                .map(
                  (row) =>
                      (row['workspaceId'] as String, row['title'] as String),
                )
                .toList();
      return PocketScaffold(
        title: Text(isSession ? '工作区内排序' : '工作区排序'),
        trailing: _refresh(widget.library),
        body: PocketList(
          children: [
            _sync(widget.library),
            PocketSection(
              title: '选择位置',
              children: [
                if (isSession)
                  const PocketRow(
                    icon: Icons.folder_outlined,
                    title: '仅调整当前工作区内顺序',
                    subtitle: '不会移动到其他工作区，也不会更改工作目录。',
                  ),
                for (final row in rows)
                  PocketRow(
                    key: ValueKey('order-before-${row.$1}'),
                    icon: Icons.vertical_align_top_rounded,
                    title: '放到“${row.$2}”之前',
                    trailing: selected && before == row.$1
                        ? const Icon(Icons.check_rounded)
                        : null,
                    onTap: widget.library.writing
                        ? null
                        : () => setState(() {
                            selected = true;
                            before = row.$1;
                          }),
                  ),
                PocketRow(
                  icon: Icons.vertical_align_bottom_rounded,
                  title: '放到末尾',
                  trailing: selected && before == null
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: widget.library.writing
                      ? null
                      : () => setState(() {
                          selected = true;
                          before = null;
                        }),
                ),
                _action(widget.library, key),
              ],
            ),
            PocketButton(
              key: const ValueKey('save-library-order'),
              onPressed: !selected || !widget.library.allowed(key)
                  ? null
                  : () => widget.library.mutate(
                      key,
                      isSession ? 'sessionReorder' : 'workspaceReorder',
                      {
                        'workspaceId': widget.workspaceId,
                        if (isSession) 'sessionId': widget.sessionId,
                        if (before != null)
                          if (isSession)
                            'beforeSessionId': before
                          else
                            'beforeWorkspaceId': before,
                      },
                    ),
              child: const Text('应用顺序'),
            ),
          ],
        ),
      );
    },
  );
}

class LibraryCreateWorkspacePage extends StatefulWidget {
  const LibraryCreateWorkspacePage({super.key, required this.library});
  final LibraryController library;

  @override
  State<LibraryCreateWorkspacePage> createState() =>
      _LibraryCreateWorkspacePageState();
}

class _LibraryCreateWorkspacePageState
    extends State<LibraryCreateWorkspacePage> {
  late final draft = widget.library.workspaceDraft;
  late final name = TextEditingController(text: draft.name);
  String? error;
  static const directoryKey = 'directory-create';
  static const registrationKey = 'workspace-register';

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> createDirectory() async {
    final segment = name.text.trim();
    if (segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        RegExp(r'[/\\\x00-\x1f]').hasMatch(segment)) {
      setState(() => error = '只填写单层文件夹名，不包含路径分隔符或“..”。');
      return;
    }
    setState(() => error = null);
    await widget.library.mutate(directoryKey, 'directoryCreate', {
      'path': widget.library.defaultDirectory,
      'name': segment,
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.library,
    builder: (context, _) {
      final path = draft.adoptDefault
          ? widget.library.defaultDirectory
          : draft.directory;
      final registered = draft.registered;
      return PocketScaffold(
        title: const Text('添加工作区'),
        trailing: _refresh(widget.library),
        body: PocketList(
          children: [
            _sync(widget.library),
            Wrap(
              spacing: 8,
              children: [
                for (final existing in [false, true])
                  PocketChoice(
                    label: Text(existing ? '登记默认目录' : '新建文件夹'),
                    selected: draft.adoptDefault == existing,
                    onSelected:
                        widget.library.writing ||
                            draft.directory != null ||
                            registered != null ||
                            widget.library.actions[directoryKey]?.blocksRetry ==
                                true ||
                            widget
                                    .library
                                    .actions[registrationKey]
                                    ?.blocksRetry ==
                                true
                        ? null
                        : (_) => setState(() => draft.adoptDefault = existing),
                  ),
              ],
            ),
            PocketSection(
              title: draft.adoptDefault ? '现有默认目录' : '第一步 · 创建文件夹',
              children: [
                PocketRow(
                  icon: Icons.folder_outlined,
                  title: '应用私有默认目录',
                  subtitle: widget.library.defaultDirectory ?? '目录未确认',
                ),
                if (!draft.adoptDefault) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    child: TextField(
                      key: const ValueKey('workspace-directory-name'),
                      controller: name,
                      enabled:
                          draft.directory == null &&
                          !widget.library.writing &&
                          widget.library.actions[directoryKey]?.blocksRetry !=
                              true,
                      decoration: const InputDecoration(labelText: '单层文件夹名称'),
                      onChanged: (value) => draft.name = value,
                    ),
                  ),
                  if (error != null)
                    PocketRow(icon: Icons.info_outline_rounded, title: error!),
                  _action(widget.library, directoryKey),
                  if (draft.directory == null)
                    PocketButton(
                      key: const ValueKey('create-workspace-directory'),
                      onPressed: !widget.library.allowed(directoryKey)
                          ? null
                          : createDirectory,
                      child: const Text('创建文件夹'),
                    )
                  else
                    PocketRow(
                      icon: Icons.check_circle_outline_rounded,
                      title: '文件夹已创建',
                      subtitle: draft.directory,
                    ),
                ],
              ],
            ),
            PocketSection(
              title: draft.adoptDefault ? '登记工作区' : '第二步 · 登记工作区',
              children: [
                PocketRow(
                  icon: Icons.folder_special_outlined,
                  title: path ?? '先完成文件夹创建',
                  subtitle: '登记仅关联已存在的目录，不会删除或移动文件。',
                ),
                _action(widget.library, registrationKey),
                if (registered == null)
                  PocketButton(
                    key: const ValueKey('register-workspace'),
                    onPressed:
                        path == null || !widget.library.allowed(registrationKey)
                        ? null
                        : () => widget.library.mutate(
                            registrationKey,
                            'workspaceCreate',
                            {'path': path},
                          ),
                    child: const Text('将此目录登记为工作区'),
                  )
                else ...[
                  PocketRow(
                    icon: Icons.check_circle_outline_rounded,
                    title: '已确认工作区',
                    subtitle: registered['title'] as String?,
                    onTap: () => _openChild(
                      context,
                      LibraryWorkspacePage(
                        library: widget.library,
                        workspaceId: registered['workspaceId'] as String,
                      ),
                    ),
                  ),
                  PocketButton.tonal(
                    onPressed: () => setState(() {
                      draft
                        ..name = ''
                        ..directory = null
                        ..registered = null
                        ..adoptDefault = false;
                      name.clear();
                      widget.library.actions.remove(directoryKey);
                      widget.library.actions.remove(registrationKey);
                    }),
                    child: const Text('添加另一个工作区'),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
    },
  );
}
