import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'account.dart';
import 'approvals.dart';
import 'entry_motion.dart';
import 'export.dart';
import 'files.dart';
import 'flclash/popup.dart';
import 'library.dart';
import 'library_data.dart';
import 'runtime.dart';
import 'settings.dart';
import 'session_document.dart';
import 'session_files.dart';
import 'session_search.dart';
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
    this.searchRequest = 0,
  });

  final RuntimeController runtime;
  final String currentSessionId;
  final VoidCallback onClose, onNewChat, onOpenTasks, onOpenAutomations;
  final ValueChanged<String> onSelectSession;
  final int searchRequest;

  @override
  State<ChatSidebar> createState() => _ChatSidebarState();
}

class _ChatSidebarState extends State<ChatSidebar> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searchOpen = false;
  String? _notice, _noticeSession;
  final _archiveRows = <String, _ArchiveRow>{};
  final _archivedLocally = <String>{};
  late LibraryController _library;
  late Listenable _updates;

  @override
  void initState() {
    super.initState();
    _observe();
    if (widget.searchRequest > 0) {
      _searchOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _searchOpen) _searchFocus.requestFocus();
      });
    }
  }

  void _observe() {
    _library = widget.runtime.library;
    _updates = Listenable.merge([widget.runtime, _library]);
    _library.start();
  }

  @override
  void didUpdateWidget(ChatSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchRequest != widget.searchRequest) {
      _openSearch();
    }
    if (oldWidget.runtime != widget.runtime) {
      _notice = _noticeSession = null;
      _archiveRows.clear();
      _archivedLocally.clear();
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

  void _openSearch() {
    if (!_searchOpen) setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searchOpen) _searchFocus.requestFocus();
    });
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
    // A confirmed receipt can precede the catalog refresh. Keep its row only
    // for the exit animation, then hide it until the catalog catches up.
    _archivedLocally.removeWhere(_library.archivedSessionIds.contains);
    final List<Json> rows;
    if (_library.fresh || _library.sessions.isNotEmpty) {
      rows = _library.sessions
          .where(
            (row) =>
                row['origin'] != 'subagent' &&
                !_library.archivedSessionIds.contains(row['sessionId']) &&
                !_archivedLocally.contains(row['sessionId']),
          )
          .toList();
    } else {
      // Before the library baseline arrives, retain the last sidebar observation.
      // It supplies display data, never authority for a library mutation.
      rows = [
        for (final row in widget.runtime.sessions)
          if (row['header']?['id'] is String &&
              row['header']?['origin'] != 'subagent' &&
              row['archived'] != true &&
              !_archivedLocally.contains(row['header']['id']))
            {
              ...row,
              'sessionId': row['header']['id'],
              'projections': {
                'values': {'title': row['title'] ?? row['header']['title']},
              },
            },
      ];
    }
    for (final entry in _archiveRows.entries) {
      final state = _library.actions['archive:${entry.key}']?.state;
      // The receipt notification arrives before mutate() finishes its follow-up
      // catalog read. Start feedback now; a slow refresh must not freeze it.
      if (state == 'confirmed' || state == 'observed') {
        entry.value.removing = true;
      }
      if (!rows.any((row) => row['sessionId'] == entry.key)) {
        rows.insert(math.min(entry.value.index, rows.length), entry.value.row);
      }
    }
    return rows;
  }

  void _finishArchive(String id) {
    if (!mounted || _archiveRows[id]?.removing != true) return;
    setState(() {
      _archiveRows.remove(id);
      if (!_library.archivedSessionIds.contains(id)) _archivedLocally.add(id);
    });
  }

  void _details(String id) =>
      unawaited(_browse(LibrarySessionPage(library: _library, sessionId: id)));

  void _searchContents() => unawaited(
    _browse(
      SessionSearchPage(
        runtime: widget.runtime,
        initialQuery: _search.text.trim(),
      ),
    ),
  );

  Future<void> _mutate(String id, {required bool archive}) async {
    final key = '${archive ? 'archive' : 'pin'}:$id';
    if (!_library.allowed(key) || _library.session(id) == null) return;
    final library = _library;
    final rows = _sessions();
    final index = rows.indexWhere((row) => row['sessionId'] == id);
    if (index < 0) return;
    final pinned = _library.pinnedSessionIds.contains(id);
    setState(() {
      if (archive) {
        _archiveRows[id] = _ArchiveRow(
          row: Map.of(rows[index]),
          index: index,
          pinnedIndex: _library.pinnedSessionIds.indexOf(id),
        );
      }
      _notice = archive
          ? null
          : pinned
          ? '正在取消置顶…'
          : '正在置顶…';
      _noticeSession = archive ? null : id;
    });
    await library.mutate(key, archive ? 'sessionArchive' : 'sessionPin', {
      'sessionId': id,
      if (archive) ...{
        'archived': true,
        'stopActivity': false,
      } else
        'pinned': !pinned,
    });
    if (!mounted || !identical(_library, library)) return;
    final action = library.actions[key];
    setState(() {
      final confirmed =
          action?.state == 'confirmed' ||
          (archive && action?.state == 'observed');
      if (archive) {
        if (confirmed) {
          _archiveRows[id]?.removing = true;
        } else {
          _archiveRows.remove(id);
        }
      }
      _notice = confirmed
          ? archive
                ? null
                : pinned
                ? '已取消置顶。'
                : '已置顶对话。'
          : action?.message ?? '操作尚未确认，请查看会话详情。';
      _noticeSession = _notice == null ? null : id;
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
      : TextField(
          key: const ValueKey('sidebar-search'),
          controller: _search,
          focusNode: _searchFocus,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _searchContents(),
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: '搜索会话与工作区',
            prefixIcon: Icon(Icons.search_rounded, size: 20),
          ),
        );

  Widget _header() => Row(
    key: const ValueKey('sidebar-header'),
    children: [
      Expanded(
        child: GlassSurface(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                const PocketMark(size: 23),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Pocket Harness',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(width: 10),
      GlassButton(
        key: const ValueKey('sidebar-search-toggle'),
        icon: _searchOpen ? Icons.close_rounded : Icons.search_rounded,
        label: _searchOpen ? '关闭搜索' : '搜索对话',
        onPressed: _toggleSearch,
      ),
    ],
  );

  Widget _footer() => Row(
    key: const ValueKey('sidebar-footer'),
    children: [
      PocketButton.tonal(
        key: const ValueKey('sidebar-settings'),
        glass: true,
        onPressed: () => _page(SettingsPage(runtime: widget.runtime)),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tune_rounded, size: 21),
            SizedBox(width: 10),
            Text('设置'),
          ],
        ),
      ),
      const SizedBox(width: 10),
      GlassButton(
        key: const ValueKey('sidebar-new-chat'),
        icon: Icons.edit_square,
        label: '新对话',
        onPressed: () => _leave(widget.onNewChat),
      ),
      const Spacer(),
      _SidebarAvatar(
        url: _avatarUrl(),
        onPressed: () => _page(AccountPage(runtime: widget.runtime)),
      ),
    ],
  );

  String? _avatarUrl() {
    final account = widget.runtime.accountSnapshot;
    final profile = account?.profile;
    if (account?.signedIn != true || profile?['status'] != 'ready') return null;
    final value = profile?['value'];
    final url = value is Map ? value['avatarUrl'] : null;
    return url is String && url.trim().isNotEmpty ? url : null;
  }

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
      final pinnedIds = [..._library.pinnedSessionIds];
      for (final entry in _archiveRows.entries) {
        final index = entry.value.pinnedIndex;
        if (index >= 0 && !pinnedIds.contains(entry.key)) {
          pinnedIds.insert(math.min(index, pinnedIds.length), entry.key);
        }
      }
      final pinned = [
        for (final id in pinnedIds)
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
        return _ArchiveTransition(
          key: ValueKey('sidebar-presence:$id'),
          removing: _archiveRows[id]?.removing == true,
          onRemoved: () => _finishArchive(id),
          child: _SessionRow(
            key: ValueKey('sidebar-session:$id'),
            title: librarySessionTitle(row),
            selected: id == widget.currentSessionId,
            pinned: pinnedIds.contains(id) && knownIds.contains(id),
            canPin: knownIds.contains(id) && _library.allowed('pin:$id'),
            // Opening the original editor also recovers its retained draft.
            // The editor itself gates saving on synchronization and receipt state.
            canRename: knownIds.contains(id),
            canArchive:
                knownIds.contains(id) && _library.allowed('archive:$id'),
            onSelect: () => _leave(() => widget.onSelectSession(id)),
            onAction: (action) => _sessionAction(action, row),
          ),
        );
      }

      return Drawer(
        width: math.min(380, MediaQuery.sizeOf(context).width * .9),
        elevation: 0,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadiusDirectional.horizontal(
            end: Radius.circular(28),
          ),
        ),
        child: _SidebarFrame(
          searchOpen: _searchOpen,
          header: _header(),
          searchField: _searchField(),
          footer: _footer(),
          bodyBuilder: (scrollPadding) => ListView(
            key: const ValueKey('sidebar-scroll'),
            padding: scrollPadding,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              if (_searchOpen)
                _destination(
                  '搜索对话内容',
                  Icons.manage_search_rounded,
                  _searchContents,
                  key: const ValueKey('sidebar-search-content'),
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
                () => unawaited(_browse(LibraryPage(runtime: widget.runtime))),
              ),
              _SidebarMore(
                pending: widget.runtime.interactions.length,
                children: [
                  _destination(
                    '我的文件',
                    Icons.folder_open_rounded,
                    () => _page(FilesPage(runtime: widget.runtime)),
                    key: const ValueKey('sidebar-more-files'),
                  ),
                  _destination(
                    '自动化任务',
                    Icons.schedule_rounded,
                    () => _leave(widget.onOpenAutomations),
                    key: const ValueKey('sidebar-more-automations'),
                  ),
                  _destination(
                    '授权与提问',
                    Icons.pending_actions_rounded,
                    () => _page(ApprovalsPage(runtime: widget.runtime)),
                    key: const ValueKey('sidebar-more-approvals'),
                    trailing: widget.runtime.interactions.isEmpty
                        ? null
                        : Text('${widget.runtime.interactions.length}'),
                  ),
                  if (current != null) ...[
                    _destination(
                      '会话文件',
                      Icons.folder_open_outlined,
                      () => _page(
                        SessionFilesPage(
                          runtime: widget.runtime,
                          sessionId: widget.currentSessionId,
                          onOpenDocument: (context, sessionId, path) async {
                            await Navigator.of(context).push<void>(
                              PocketRoute(
                                builder: (_) => SessionDocumentPage(
                                  runtime: widget.runtime,
                                  sessionId: sessionId,
                                  path: path,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      key: const ValueKey('sidebar-more-session-files'),
                    ),
                    _destination(
                      '当前会话的子 Agent',
                      Icons.account_tree_outlined,
                      () => _page(
                        SubagentsPage(
                          runtime: widget.runtime,
                          parentSessionId: widget.currentSessionId,
                        ),
                      ),
                      key: const ValueKey('sidebar-more-subagents'),
                    ),
                    _destination(
                      '导出当前对话',
                      Icons.ios_share_rounded,
                      () => _sessionAction(_SessionAction.export, current),
                      key: const ValueKey('sidebar-more-export'),
                    ),
                  ],
                ],
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
              if (pinned.isNotEmpty) ...[_label('置顶'), ...pinned.map(session)],
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
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _ArchiveRow {
  _ArchiveRow({
    required this.row,
    required this.index,
    required this.pinnedIndex,
  });
  final Json row;
  final int index, pinnedIndex;
  bool removing = false;
}

/// A service-confirmed archive fades where it was, then releases its space.
/// Pending or rejected requests keep the same fully visible, keyed row.
class _ArchiveTransition extends StatefulWidget {
  const _ArchiveTransition({
    super.key,
    required this.removing,
    required this.onRemoved,
    required this.child,
  });
  final bool removing;
  final VoidCallback onRemoved;
  final Widget child;
  @override
  State<_ArchiveTransition> createState() => _ArchiveTransitionState();
}

class _ArchiveTransitionState extends State<_ArchiveTransition>
    with SingleTickerProviderStateMixin {
  late final _controller =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 320),
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed) _finish();
      });
  late final _opacity = Tween<double>(begin: 1, end: 0).animate(
    CurvedAnimation(parent: _controller, curve: const Interval(0, .65)),
  );
  late final _size = Tween<double>(begin: 1, end: 0).animate(
    CurvedAnimation(
      parent: _controller,
      curve: const Interval(.35, 1, curve: Curves.easeInOutCubic),
    ),
  );
  bool _finished = false;

  void _finish() {
    if (_finished) return;
    _finished = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.removing) widget.onRemoved();
    });
  }

  void _sync() {
    if (!widget.removing) {
      _controller.reset();
      _finished = false;
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
      _finish();
    } else {
      _controller.forward();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_ArchiveTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.removing != oldWidget.removing) _sync();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: widget.removing,
    child: ExcludeSemantics(
      excluding: widget.removing,
      child: SizeTransition(
        sizeFactor: _size,
        alignment: AlignmentDirectional.topStart,
        child: FadeTransition(opacity: _opacity, child: widget.child),
      ),
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

/// Secondary destinations are part of the drawer's scrolling content. Each
/// row opens in sequence using the shared blur appearance and its own extent.
class _SidebarMore extends StatefulWidget {
  const _SidebarMore({required this.pending, required this.children});
  final int pending;
  final List<Widget> children;
  @override
  State<_SidebarMore> createState() => _SidebarMoreState();
}

class _SidebarMoreState extends State<_SidebarMore>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late final _controller = AnimationController(vsync: this);
  bool _expanded = false;
  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncDuration();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = _expanded ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(_SidebarMore oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncDuration();
  }

  void _syncDuration() {
    _controller.duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Duration(milliseconds: 260 + (widget.children.length - 1) * 35);
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final duration = 260 + (widget.children.length - 1) * 35;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              expanded: _expanded,
              child: PocketTile(
                key: const ValueKey('sidebar-more'),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                leading: const Icon(Icons.more_horiz_rounded),
                title: const Text('更多'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.pending > 0) ...[
                      Semantics(
                        label: '${widget.pending} 项待处理',
                        excludeSemantics: true,
                        child: Text('${widget.pending}'),
                      ),
                      const SizedBox(width: 6),
                    ],
                    RotationTransition(
                      turns: Tween<double>(
                        begin: 0,
                        end: .5,
                      ).animate(_controller),
                      child: const Icon(Icons.expand_more_rounded, size: 20),
                    ),
                  ],
                ),
                onTap: _toggle,
              ),
            ),
            if (_expanded || !_controller.isDismissed)
              for (var index = 0; index < widget.children.length; index++)
                _moreRow(index, duration),
          ],
        );
      },
    );
  }

  Widget _moreRow(int index, int duration) {
    final animation = _controller.drive(
      CurveTween(
        curve: Interval(
          index * 35 / duration,
          (index * 35 + 260) / duration,
          curve: PocketEntryMotion.curve,
        ),
      ),
    );
    return IgnorePointer(
      ignoring: !_expanded || animation.value < .5,
      child: ExcludeSemantics(
        excluding: !_expanded || animation.value < .5,
        child: SizeTransition(
          key: ValueKey('sidebar-more-reveal:$index'),
          sizeFactor: animation,
          alignment: AlignmentDirectional.topStart,
          child: PocketBlurTransition(
            animation: animation,
            child: widget.children[index],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

/// Insets keep the first and last rows reachable; the viewport itself extends
/// underneath the floating controls, including while the keyboard is visible.
class _SidebarFrame extends StatelessWidget {
  const _SidebarFrame({
    required this.searchOpen,
    required this.header,
    required this.searchField,
    required this.footer,
    required this.bodyBuilder,
  });
  final bool searchOpen;
  final Widget header, searchField, footer;
  final Widget Function(EdgeInsets padding) bodyBuilder;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final line = media.textScaler.scale(17) * 22 / 17;
    final chromeHeight = math.max(48.0, line + 24);
    final footerHeight = math.max(56.0, line + 34);
    final fieldHeight = math.max(56.0, line + 34);
    final color = Theme.of(context).colorScheme.surface;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Scaffold may already resize a drawer; only consume the keyboard
        // portion that still overlaps these actual layout constraints.
        final keyboard = math.max(
          0.0,
          constraints.maxHeight - (media.size.height - media.viewInsets.bottom),
        );
        final bottom = keyboard + media.padding.bottom;
        final top = media.padding.top + 14;
        return TweenAnimationBuilder<double>(
          tween: Tween(end: searchOpen ? fieldHeight + 12 : 0),
          duration: media.disableAnimations
              ? Duration.zero
              : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          builder: (context, searchExtent, _) {
            final contentTop = top + chromeHeight + searchExtent;
            return Stack(
              fit: StackFit.expand,
              children: [
                bodyBuilder(
                  EdgeInsets.fromLTRB(
                    10 + media.padding.left,
                    contentTop + 14,
                    10 + media.padding.right,
                    bottom + footerHeight + 26,
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: contentTop + 24,
                  child: _SidebarFade(color: color),
                ),
                Positioned(
                  top: top,
                  left: 14 + media.padding.left,
                  right: 14 + media.padding.right,
                  height: chromeHeight,
                  child: header,
                ),
                if (searchExtent > 0)
                  Positioned(
                    top: top + chromeHeight + 12,
                    left: 14 + media.padding.left,
                    right: 14 + media.padding.right,
                    height: math.max(0, searchExtent - 12),
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.topCenter,
                        minHeight: fieldHeight,
                        maxHeight: fieldHeight,
                        child: searchField,
                      ),
                    ),
                  ),
                Positioned(
                  bottom: keyboard,
                  left: 0,
                  right: 0,
                  height: media.padding.bottom + footerHeight + 36,
                  child: _SidebarFade(color: color, bottom: true),
                ),
                Positioned(
                  bottom: bottom + 10,
                  left: 14 + media.padding.left,
                  right: 14 + media.padding.right,
                  height: footerHeight,
                  child: footer,
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _SidebarFade extends StatelessWidget {
  const _SidebarFade({required this.color, this.bottom = false});
  final Color color;
  final bool bottom;
  @override
  Widget build(BuildContext context) =>
      FloatingEdgeScrim(backgroundColor: color, overhang: 24, bottom: bottom);
}

class _SidebarAvatar extends StatelessWidget {
  const _SidebarAvatar({required this.onPressed, this.url});
  final VoidCallback onPressed;
  final String? url;
  @override
  Widget build(BuildContext context) => GlassButton.custom(
    key: const ValueKey('sidebar-account'),
    label: '账号',
    onPressed: onPressed,
    icon: ClipOval(
      child: SizedBox.square(
        dimension: 30,
        child: url == null
            ? const Icon(Icons.person_outline_rounded)
            : Image.network(
                url!,
                fit: BoxFit.cover,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.person_outline_rounded),
              ),
      ),
    ),
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

  Future<void> _menu([Offset? globalPosition]) async {
    if (_opening) return;
    final box = context.findRenderObject();
    final navigator = Navigator.of(context);
    final overlay = navigator.context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final globalAnchor =
        globalPosition ?? box.localToGlobal(box.size.center(Offset.zero));
    final point = overlay is RenderBox
        ? overlay.globalToLocal(globalAnchor)
        : globalAnchor;
    final anchor = Rect.fromCenter(center: point, width: 1, height: 1);
    _opening = true;
    unawaited(HapticFeedback.mediumImpact());
    _SessionAction? selected;
    final route = CommonPopupRoute<void>(
      anchorOf: () => anchor,
      placement: PopupPlacement.belowPoint,
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
      onLongPressStart: (details) => _menu(details.globalPosition),
      onSecondaryTapDown: (details) => _menu(details.globalPosition),
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
