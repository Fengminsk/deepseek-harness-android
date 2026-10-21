import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'account.dart';
import 'approvals.dart';
import 'export.dart';
import 'files.dart';
import 'flclash/popup.dart';
import 'library.dart';
import 'library_data.dart';
import 'runtime.dart';
import 'settings.dart';
import 'subagents.dart';
import 'ui.dart';

/// The library owns observations and receipts; this drawer owns presentation.
class ChatSidebar extends StatefulWidget {
  const ChatSidebar({
    super.key,
    required this.runtime,
    required this.currentSessionId,
    required this.onClose,
    required this.onNewChat,
    required this.onSelectSession,
    required this.onOpenTasks,
    required this.onOpenAutomations,
  });

  final RuntimeController runtime;
  final String currentSessionId;
  final VoidCallback onClose, onNewChat, onOpenTasks, onOpenAutomations;
  final ValueChanged<String> onSelectSession;

  @override
  State<ChatSidebar> createState() => _ChatSidebarState();
}

class _ChatSidebarState extends State<ChatSidebar> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searchOpen = false;
  String? _notice, _noticeSession;
  late LibraryController _library;
  late Listenable _updates;

  @override
  void initState() {
    super.initState();
    _observe();
  }

  void _observe() {
    _library = widget.runtime.library;
    _updates = Listenable.merge([widget.runtime, _library]);
    _library.start();
  }

  @override
  void didUpdateWidget(ChatSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      _notice = _noticeSession = null;
      _observe();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) _search.clear();
    });
    if (_searchOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _searchOpen) _searchFocus.requestFocus();
      });
    } else {
      _searchFocus.unfocus();
    }
  }

  void _leave(VoidCallback action) {
    if (!mounted) return;
    _searchFocus.unfocus();
    widget.onClose();
    action();
  }

  void _page(Widget page) {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    _leave(
      () => unawaited(
        navigator.push<void>(PocketRoute<void>(builder: (_) => page)),
      ),
    );
  }

  Future<void> _browse(Widget page) async {
    if (!mounted) return;
    // Closing a Drawer can unmount its subtree. The selected session belongs to
    // the chat page, so capture its callback before navigating away.
    final navigator = Navigator.of(context);
    final selected = widget.onSelectSession;
    _searchFocus.unfocus();
    widget.onClose();
    final id = await navigator.push<String>(
      PocketRoute<String>(builder: (_) => page),
    );
    if (navigator.mounted && id != null) selected(id);
  }

  List<Json> _sessions() {
    if (_library.fresh || _library.sessions.isNotEmpty) {
      return _library.sessions
          .where(
            (row) =>
                row['origin'] != 'subagent' &&
                !_library.archivedSessionIds.contains(row['sessionId']),
          )
          .toList();
    }
    // Before the library baseline arrives, retain the last sidebar observation.
    // It supplies display data, never authority for a library mutation.
    return [
      for (final row in widget.runtime.sessions)
        if (row['header']?['id'] is String &&
            row['header']?['origin'] != 'subagent' &&
            row['archived'] != true)
          {
            ...row,
            'sessionId': row['header']['id'],
            'projections': {
              'values': {'title': row['title'] ?? row['header']['title']},
            },
          },
    ];
  }

  void _details(String id) =>
      unawaited(_browse(LibrarySessionPage(library: _library, sessionId: id)));

  Future<void> _mutate(String id, {required bool archive}) async {
    final key = '${archive ? 'archive' : 'pin'}:$id';
    if (!_library.allowed(key) || _library.session(id) == null) return;
    final pinned = _library.pinnedSessionIds.contains(id);
    setState(() {
      _notice = archive
          ? '正在归档…'
          : pinned
          ? '正在取消置顶…'
          : '正在置顶…';
      _noticeSession = id;
    });
    await _library.mutate(key, archive ? 'sessionArchive' : 'sessionPin', {
      'sessionId': id,
      if (archive) ...{
        'archived': true,
        'stopActivity': false,
      } else
        'pinned': !pinned,
    });
    if (!mounted) return;
    final action = _library.actions[key];
    setState(() {
      _notice = action?.state == 'confirmed'
          ? archive
                ? '已归档对话，可在工作区与会话中恢复。'
                : pinned
                ? '已取消置顶。'
                : '已置顶对话。'
          : action?.message ?? '操作尚未确认，请查看会话详情。';
    });
    if (action?.state == 'needs-stop') _details(id);
  }

  void _sessionAction(_SessionAction action, Json row) {
    if (!mounted) return;
    final id = row['sessionId'] as String;
    switch (action) {
      case _SessionAction.pin:
        unawaited(_mutate(id, archive: false));
      case _SessionAction.rename:
        _page(LibraryRenamePage(library: _library, id: id));
      case _SessionAction.archive:
        unawaited(_mutate(id, archive: true));
      case _SessionAction.details:
        _details(id);
      case _SessionAction.export:
        _page(
          SessionExportPage(
            runtime: widget.runtime,
            sessionId: id,
            sessionTitle: librarySessionTitle(row),
          ),
        );
    }
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 22, 14, 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );

  Widget _destination(
    String title,
    IconData icon,
    VoidCallback action, {
    Widget? trailing,
    Key? key,
  }) => PocketTile(
    key: key,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    leading: Icon(icon),
    title: Text(title),
    trailing: trailing,
    onTap: action,
  );

  Widget _message(String text, {String? sessionId, bool refresh = false}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
        child: Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text, key: const ValueKey('sidebar-message')),
              if (refresh)
                PocketButton.tonal(
                  onPressed: _library.loading
                      ? null
                      : () => unawaited(_library.refresh(reconnect: true)),
                  child: const Text('重新同步'),
                )
              else if (sessionId != null)
                PocketButton.tonal(
                  onPressed: () => _details(sessionId),
                  child: const Text('查看详情'),
                ),
            ],
          ),
        ),
      );

  Widget _searchField() => !_searchOpen
      ? const SizedBox(width: double.infinity)
      : Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 10),
          child: TextField(
            key: const ValueKey('sidebar-search'),
            controller: _search,
            focusNode: _searchFocus,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              hintText: '搜索会话与工作区',
              prefixIcon: Icon(Icons.search_rounded, size: 20),
            ),
          ),
        );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _updates,
    builder: (context, _) {
      final query = _search.text.trim().toLowerCase();
      final allRows = _sessions();
      final rows = allRows
          .where(
            (row) => librarySessionTitle(row).toLowerCase().contains(query),
          )
          .toList();
      final knownIds = _library.sessions.map((row) => row['sessionId']).toSet();
      final pinned = [
        for (final id in _library.pinnedSessionIds)
          for (final row in rows)
            if (row['sessionId'] == id) row,
      ];
      final recent = rows.where((row) => !pinned.contains(row)).toList()
        ..sort(
          (a, b) => ((b['updatedAt'] as num?) ?? 0).compareTo(
            (a['updatedAt'] as num?) ?? 0,
          ),
        );
      final workspaces = _library.workspaces.where(
        (row) => '${row['title'] ?? ''}'.toLowerCase().contains(query),
      );
      final issue = _library.actions.values
          .where(
            (action) => const {
              'unconfirmed',
              'partial',
              'needs-stop',
            }.contains(action.state),
          )
          .lastOrNull;
      final notice = _notice ?? issue?.message;
      final noticeId = _noticeSession ?? issue?.params['sessionId'] as String?;
      final current = allRows
          .where((row) => row['sessionId'] == widget.currentSessionId)
          .firstOrNull;
      final running = widget.runtime.statuses.values
          .where((status) => status == 'running')
          .length;

      Widget session(Json row) {
        final id = row['sessionId'] as String;
        return _SessionRow(
          key: ValueKey('sidebar-session:$id'),
          title: librarySessionTitle(row),
          selected: id == widget.currentSessionId,
          pinned:
              _library.pinnedSessionIds.contains(id) && knownIds.contains(id),
          canPin: knownIds.contains(id) && _library.allowed('pin:$id'),
          // Opening the original editor also recovers its retained draft.
          // The editor itself gates saving on synchronization and receipt state.
          canRename: knownIds.contains(id),
          canArchive: knownIds.contains(id) && _library.allowed('archive:$id'),
          onSelect: () => _leave(() => widget.onSelectSession(id)),
          onAction: (action) => _sessionAction(action, row),
        );
      }

      return Drawer(
        width: math.min(380, MediaQuery.sizeOf(context).width * .9),
        elevation: 0,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(right: Radius.circular(28)),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 12, 10),
                child: Row(
                  children: [
                    const PocketMark(size: 25),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Pocket Harness',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    GlassButton(
                      key: const ValueKey('sidebar-search-toggle'),
                      icon: _searchOpen
                          ? Icons.close_rounded
                          : Icons.search_rounded,
                      label: _searchOpen ? '关闭搜索' : '搜索对话',
                      onPressed: _toggleSearch,
                    ),
                  ],
                ),
              ),
              if (MediaQuery.disableAnimationsOf(context))
                _searchField()
              else
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  alignment: Alignment.topCenter,
                  child: _searchField(),
                ),
              Expanded(
                child: ListView(
                  key: const ValueKey('sidebar-scroll'),
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 20),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: PocketButton.tonal(
                        key: const ValueKey('sidebar-new-chat'),
                        onPressed: () => _leave(widget.onNewChat),
                        child: const Row(
                          children: [
                            Icon(Icons.edit_square, size: 21),
                            SizedBox(width: 12),
                            Flexible(child: Text('新对话')),
                          ],
                        ),
                      ),
                    ),
                    _destination(
                      '后台任务',
                      Icons.play_circle_outline_rounded,
                      () => _leave(widget.onOpenTasks),
                      trailing: running == 0 ? null : Text('$running'),
                    ),
                    _destination(
                      '工作区与会话',
                      Icons.folder_copy_outlined,
                      () => unawaited(
                        _browse(LibraryPage(runtime: widget.runtime)),
                      ),
                    ),
                    CommonPopupBox(
                      key: const ValueKey('sidebar-more'),
                      placement: PopupPlacement.overAnchorStart,
                      targetBuilder: (open) => _destination(
                        '更多',
                        Icons.more_horiz_rounded,
                        open,
                        trailing: widget.runtime.interactions.isEmpty
                            ? null
                            : Text(
                                '${widget.runtime.interactions.length} 项待处理',
                              ),
                      ),
                      popupBuilder: (_) => CommonPopupMenu(
                        items: [
                          CommonPopupMenuItem(
                            label: '我的文件',
                            glyph: Icons.folder_open_rounded,
                            onPressed: () =>
                                _page(FilesPage(runtime: widget.runtime)),
                          ),
                          CommonPopupMenuItem(
                            label: '自动化任务',
                            glyph: Icons.schedule_rounded,
                            onPressed: () => _leave(widget.onOpenAutomations),
                          ),
                          CommonPopupMenuItem(
                            label: '授权与提问',
                            glyph: Icons.pending_actions_rounded,
                            onPressed: () =>
                                _page(ApprovalsPage(runtime: widget.runtime)),
                          ),
                          if (current != null) ...[
                            CommonPopupMenuItem(
                              label: '当前会话的子 Agent',
                              glyph: Icons.account_tree_outlined,
                              onPressed: () => _page(
                                SubagentsPage(
                                  runtime: widget.runtime,
                                  parentSessionId: widget.currentSessionId,
                                ),
                              ),
                            ),
                            CommonPopupMenuItem(
                              label: '导出当前对话',
                              glyph: Icons.ios_share_rounded,
                              onPressed: () => _sessionAction(
                                _SessionAction.export,
                                current,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (_library.readError != null)
                      _message('会话列表同步失败，已保留上次内容。', refresh: true)
                    else if (!_library.loading &&
                        !_library.synchronized &&
                        rows.isNotEmpty)
                      _message('会话列表尚未同步，管理操作暂不可用。', refresh: true),
                    if (notice != null) _message(notice, sessionId: noticeId),
                    if (workspaces.isNotEmpty) ...[
                      _label('工作区'),
                      for (final workspace in workspaces.take(3))
                        _destination(
                          workspace['title'] as String? ?? '未命名工作区',
                          Icons.folder_outlined,
                          () => unawaited(
                            _browse(
                              LibraryWorkspacePage(
                                library: _library,
                                workspaceId: workspace['workspaceId'] as String,
                              ),
                            ),
                          ),
                          key: ValueKey(
                            'sidebar-workspace:${workspace['workspaceId']}',
                          ),
                        ),
                      if (workspaces.length > 3)
                        _destination(
                          '全部工作区',
                          Icons.arrow_forward_rounded,
                          () => unawaited(
                            _browse(LibraryPage(runtime: widget.runtime)),
                          ),
                        ),
                    ],
                    if (pinned.isNotEmpty) ...[
                      _label('置顶'),
                      ...pinned.map(session),
                    ],
                    _label(query.isEmpty ? '最近对话' : '搜索结果'),
                    ...recent.map(session),
                    if (rows.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 16,
                        ),
                        child: Text(
                          query.isEmpty ? '你的对话会保存在这里' : '没有匹配的会话',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                key: const ValueKey('sidebar-footer'),
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: PocketTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        leading: const Icon(Icons.account_circle_outlined),
                        title: const Text('账号'),
                        onTap: () =>
                            _page(AccountPage(runtime: widget.runtime)),
                      ),
                    ),
                    GlassButton(
                      key: const ValueKey('sidebar-settings'),
                      icon: Icons.tune_rounded,
                      label: '设置',
                      onPressed: () =>
                          _page(SettingsPage(runtime: widget.runtime)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

enum _SessionAction { pin, rename, archive, details, export }

class _SessionRow extends StatefulWidget {
  const _SessionRow({
    super.key,
    required this.title,
    required this.selected,
    required this.pinned,
    required this.canPin,
    required this.canRename,
    required this.canArchive,
    required this.onSelect,
    required this.onAction,
  });
  final String title;
  final bool selected, pinned, canPin, canRename, canArchive;
  final VoidCallback onSelect;
  final ValueChanged<_SessionAction> onAction;

  @override
  State<_SessionRow> createState() => _SessionRowState();
}

class _SessionRowState extends State<_SessionRow> {
  bool _opening = false;

  Future<void> _menu() async {
    if (_opening) return;
    final box = context.findRenderObject();
    final navigator = Navigator.of(context);
    final overlay = navigator.context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final anchor =
        box.localToGlobal(
          Offset.zero,
          ancestor: overlay is RenderBox ? overlay : null,
        ) &
        box.size;
    _opening = true;
    unawaited(HapticFeedback.mediumImpact());
    _SessionAction? selected;
    final route = CommonPopupRoute<void>(
      anchorOf: () => anchor,
      placement: PopupPlacement.overAnchorStart,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      builder: (_) => CommonPopupMenu(
        items: [
          CommonPopupMenuItem(
            label: widget.pinned ? '取消置顶' : '置顶',
            glyph: Icons.push_pin_outlined,
            onPressed: widget.canPin
                ? () => selected = _SessionAction.pin
                : null,
          ),
          CommonPopupMenuItem(
            label: '重命名',
            glyph: Icons.edit_outlined,
            onPressed: widget.canRename
                ? () => selected = _SessionAction.rename
                : null,
          ),
          CommonPopupMenuItem(
            label: '归档',
            glyph: Icons.archive_outlined,
            onPressed: widget.canArchive
                ? () => selected = _SessionAction.archive
                : null,
          ),
          CommonPopupMenuItem(
            label: '查看详情',
            glyph: Icons.info_outline_rounded,
            onPressed: () => selected = _SessionAction.details,
          ),
          CommonPopupMenuItem(
            label: '导出',
            glyph: Icons.ios_share_rounded,
            onPressed: () => selected = _SessionAction.export,
          ),
        ],
      ),
    );
    try {
      await navigator.push<void>(route);
      await route.completed;
      if (mounted && selected != null) widget.onAction(selected!);
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
    selected: widget.selected,
    onLongPress: _menu,
    hint: '长按管理会话',
    child: GestureDetector(
      excludeFromSemantics: true,
      onLongPress: _menu,
      onSecondaryTap: _menu,
      child: ElasticPress(
        child: PocketTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 10,
          ),
          selected: widget.selected,
          title: Text(
            widget.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: widget.pinned
              ? const Icon(Icons.push_pin_rounded, size: 16)
              : null,
          onTap: widget.onSelect,
        ),
      ),
    ),
  );
}
