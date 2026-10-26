import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'chat_changes.dart';
import 'runtime.dart';
import 'session_browser.dart';
import 'session_document.dart';
import 'session_files.dart';
import 'session_terminal.dart';
import 'skills.dart';
import 'tasks.dart';
import 'ui.dart';
import 'workspace_changes.dart';

enum _ResourceKind { guide, files, changes, skills, tasks, browser, terminal }

const _resourceTitles = <_ResourceKind, String>{
  _ResourceKind.guide: '资源',
  _ResourceKind.files: '文件',
  _ResourceKind.changes: '文件改动',
  _ResourceKind.skills: '技能',
  _ResourceKind.tasks: '后台任务',
  _ResourceKind.browser: '浏览器',
  _ResourceKind.terminal: '终端',
};

class _ResourceLayout {
  const _ResourceLayout(this.tabs, this.selected);
  final List<_ResourceKind> tabs;
  final _ResourceKind selected;
}

// Only page kinds and selection survive a route re-entry. A RuntimeController
// owns the weak key; no URL, file bytes, process identity, or Agent state is saved.
final _resourceLayouts = Expando<Map<String, _ResourceLayout>>();

/// Session-scoped mobile tabs for existing resources. Selecting a tab mounts
/// its reader once and keeps it mounted until the tab is removed. Opening the
/// workspace never creates a terminal, browser request, or Agent turn.
class SessionResourcesPage extends StatefulWidget {
  const SessionResourcesPage({
    super.key,
    required this.runtime,
    required this.sessionId,
  });

  final RuntimeController runtime;
  final String sessionId;

  @override
  State<SessionResourcesPage> createState() => _SessionResourcesPageState();
}

class _SessionResourcesPageState extends State<SessionResourcesPage> {
  late List<_ResourceKind> _tabs;
  late _ResourceKind _selected;
  final _mounted = <_ResourceKind>{};
  final _tabKeys = {for (final kind in _ResourceKind.values) kind: GlobalKey()};

  @override
  void initState() {
    super.initState();
    _restore();
    _reveal(_selected);
  }

  void _restore() {
    final saved = _resourceLayouts[widget.runtime]?[widget.sessionId];
    _tabs = [...?saved?.tabs];
    if (!_tabs.contains(_ResourceKind.guide)) {
      _tabs.insert(0, _ResourceKind.guide);
    }
    _selected = saved != null && _tabs.contains(saved.selected)
        ? saved.selected
        : _ResourceKind.guide;
    _mounted
      ..clear()
      ..add(_ResourceKind.guide)
      ..add(_selected);
  }

  void _save() {
    final layouts =
        _resourceLayouts[widget.runtime] ?? <String, _ResourceLayout>{};
    layouts[widget.sessionId] = _ResourceLayout(List.of(_tabs), _selected);
    _resourceLayouts[widget.runtime] = layouts;
  }

  @override
  void didUpdateWidget(SessionResourcesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime == widget.runtime &&
        oldWidget.sessionId == widget.sessionId) {
      return;
    }
    _restore();
  }

  void _select(_ResourceKind kind) {
    setState(() {
      if (!_tabs.contains(kind)) _tabs.add(kind);
      _mounted.add(kind);
      _selected = kind;
    });
    _save();
    _reveal(kind);
  }

  void _reveal(_ResourceKind kind) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selected != kind) return;
      final context = _tabKeys[kind]?.currentContext;
      if (context != null) {
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: const Duration(milliseconds: 180),
        );
      }
    });
  }

  void _close(_ResourceKind kind) {
    if (kind == _ResourceKind.guide) return;
    setState(() {
      final index = _tabs.indexOf(kind);
      _tabs.remove(kind);
      _mounted.remove(kind);
      if (_selected == kind) {
        _selected = _tabs[index > 0 ? index - 1 : 0];
      }
    });
    _save();
    _reveal(_selected);
  }

  @override
  void dispose() {
    _save();
    super.dispose();
  }

  Future<void> _openDocument(BuildContext context, String id, String path) =>
      Navigator.of(context).push<void>(
        PocketRoute<void>(
          builder: (_) => SessionDocumentPage(
            runtime: widget.runtime,
            sessionId: id,
            path: path,
          ),
        ),
      );

  Widget _page(_ResourceKind kind) => switch (kind) {
    _ResourceKind.guide => PocketScaffold(
      title: const Text('会话资源'),
      body: PocketList(
        children: [
          PocketSection(
            children: [
              for (final kind in _ResourceKind.values.skip(1))
                PocketRow(
                  key: ValueKey('resource-${kind.name}'),
                  icon: switch (kind) {
                    _ResourceKind.files => Icons.folder_open_outlined,
                    _ResourceKind.changes => Icons.difference_outlined,
                    _ResourceKind.skills => Icons.auto_stories_outlined,
                    _ResourceKind.tasks => Icons.play_circle_outline_rounded,
                    _ResourceKind.browser => Icons.public_rounded,
                    _ResourceKind.terminal => Icons.terminal_rounded,
                    _ResourceKind.guide => Icons.apps_rounded,
                  },
                  title: _resourceTitles[kind]!,
                  onTap: () => _select(kind),
                ),
            ],
          ),
        ],
      ),
    ),
    _ResourceKind.files => SessionFilesPage(
      runtime: widget.runtime,
      sessionId: widget.sessionId,
      onOpenDocument: _openDocument,
    ),
    _ResourceKind.changes => SessionChangesPage(
      runtime: widget.runtime,
      sessionId: widget.sessionId,
    ),
    _ResourceKind.skills => SessionResourceSkillsPage(
      runtime: widget.runtime,
      sessionId: widget.sessionId,
    ),
    _ResourceKind.tasks => TasksPage(
      runtime: widget.runtime,
      sessionId: widget.sessionId,
    ),
    _ResourceKind.browser => SessionBrowserPage(runtime: widget.runtime),
    _ResourceKind.terminal => SessionTerminalsPage(
      runtime: widget.runtime,
      sessionId: widget.sessionId,
    ),
  };

  Widget _tab(_ResourceKind kind) {
    final selected = _selected == kind;
    return Padding(
      key: _tabKeys[kind],
      padding: const EdgeInsets.only(left: 8),
      child: Semantics(
        button: true,
        selected: selected,
        label: '${_resourceTitles[kind]}标签',
        child: GlassSurface(
          radius: 24,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                key: ValueKey('resource-tab-${kind.name}'),
                onTap: () => _select(kind),
                borderRadius: BorderRadius.circular(24),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 12,
                  ),
                  child: Text(
                    _resourceTitles[kind]!,
                    maxLines: 1,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? Theme.of(context).colorScheme.onSurface
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              if (kind != _ResourceKind.guide)
                IconButton(
                  key: ValueKey('resource-close-${kind.name}'),
                  tooltip: kind == _ResourceKind.terminal
                      ? '收起终端视图，进程继续运行'
                      : '关闭${_resourceTitles[kind]}标签',
                  onPressed: () => _close(kind),
                  icon: const Icon(Icons.close_rounded, size: 17),
                  style: IconButton.styleFrom(
                    fixedSize: const Size.square(44),
                    minimumSize: const Size.square(44),
                    maximumSize: const Size.square(44),
                    shape: const CircleBorder(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope(
      canPop: _selected == _ResourceKind.guide,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selected != _ResourceKind.guide) {
          _select(_ResourceKind.guide);
        }
      },
      child: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Column(
          children: [
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeBottom: true,
                child: IndexedStack(
                  index: _tabs.indexOf(_selected),
                  children: [
                    for (final kind in _tabs)
                      KeyedSubtree(
                        key: ValueKey(
                          'resource-page-${widget.sessionId}-${kind.name}',
                        ),
                        child: _mounted.contains(kind)
                            ? _page(kind)
                            : const SizedBox.shrink(),
                      ),
                  ],
                ),
              ),
            ),
            if (!keyboardOpen)
              SafeArea(
                top: false,
                child: SizedBox(
                  height: 64,
                  child: SingleChildScrollView(
                    key: const ValueKey('resource-tabs'),
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(right: 12),
                    child: Row(
                      children: [for (final kind in _tabs) _tab(kind)],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Reads finished-turn change announcements from this Session's original log.
/// A Host summary, rather than prose or a current workspace scan, supplies files.
class SessionChangesPage extends StatefulWidget {
  const SessionChangesPage({
    super.key,
    required this.runtime,
    required this.sessionId,
  });

  final RuntimeController runtime;
  final String sessionId;

  @override
  State<SessionChangesPage> createState() => _SessionChangesPageState();
}

class _SessionChangesPageState extends State<SessionChangesPage> {
  final _projection = ChatChangesProjection();
  List<Json> _events = const [];
  late WorkspaceChangesController _changes;
  bool _reading = false;
  String? _error;
  int _readEpoch = 0;

  @override
  void initState() {
    super.initState();
    _changes = WorkspaceChangesController(
      runtime: widget.runtime,
      sessionId: widget.sessionId,
    )..addListener(_changed);
    widget.runtime.addListener(_changed);
    unawaited(_read());
  }

  @override
  void didUpdateWidget(SessionChangesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime == widget.runtime &&
        oldWidget.sessionId == widget.sessionId) {
      return;
    }
    oldWidget.runtime.removeListener(_changed);
    _changes.removeListener(_changed);
    _changes.dispose();
    _changes = WorkspaceChangesController(
      runtime: widget.runtime,
      sessionId: widget.sessionId,
    )..addListener(_changed);
    widget.runtime.addListener(_changed);
    _events = const [];
    _projection.reconcile(_events);
    unawaited(_read());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _read() async {
    final epoch = ++_readEpoch;
    final runtime = widget.runtime;
    final sessionId = widget.sessionId;
    setState(() {
      _reading = runtime.ready;
      _error = null;
    });
    if (!runtime.ready) return;
    try {
      final events = await runtime.readCompleteSession(sessionId);
      if (mounted &&
          epoch == _readEpoch &&
          runtime == widget.runtime &&
          sessionId == widget.sessionId) {
        _events = events;
      }
    } catch (_) {
      if (mounted &&
          epoch == _readEpoch &&
          runtime == widget.runtime &&
          sessionId == widget.sessionId) {
        setState(() => _error = '无法读取会话记录，请重试。');
      }
    } finally {
      if (mounted &&
          epoch == _readEpoch &&
          runtime == widget.runtime &&
          sessionId == widget.sessionId) {
        setState(() => _reading = false);
      }
    }
  }

  @override
  void dispose() {
    _readEpoch++;
    widget.runtime.removeListener(_changed);
    _changes.removeListener(_changed);
    _changes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _projection.reconcile(_events);
    final entries = _projection.entries;
    return PocketScaffold(
      title: const Text('文件改动'),
      trailing: GlassButton(
        icon: Icons.refresh_rounded,
        label: '刷新文件改动',
        onPressed: _reading || !widget.runtime.ready ? null : _read,
      ),
      body: PocketList(
        children: [
          if (!widget.runtime.ready)
            const _ResourceNote('服务暂不可用，已显示上次读取的记录。')
          else if (_reading && entries.isEmpty)
            const _ResourceNote('正在读取会话记录…'),
          if (_error != null) _ResourceNote(_error!),
          if (!_changes.preferenceConfirmed && widget.runtime.ready)
            const _ResourceNote('正在核对文件改动设置…')
          else if (!_changes.enabled)
            const _ResourceNote('在设置中开启开发者工具后可查看文件改动。')
          else if (!_reading && entries.isEmpty && _error == null)
            const _ResourceNote('此会话还没有已记录的文件改动。'),
          if (_changes.enabled)
            for (final entry in entries)
              ChatChangesCard(
                key: ValueKey('resource-change-${entry.turn}'),
                controller: _changes,
                change: entry,
                enabled: true,
              ),
        ],
      ),
    );
  }
}

/// A read-only Session skill catalog. Picking a skill here never sends it to a
/// composer; skill documents use the original Session file reader.
class SessionResourceSkillsPage extends StatefulWidget {
  const SessionResourceSkillsPage({
    super.key,
    required this.runtime,
    required this.sessionId,
  });

  final RuntimeController runtime;
  final String sessionId;

  @override
  State<SessionResourceSkillsPage> createState() =>
      _SessionResourceSkillsPageState();
}

class _SessionResourceSkillsPageState extends State<SessionResourceSkillsPage> {
  late SessionSkillsController _catalog;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _catalog = SessionSkillsController(widget.runtime, widget.sessionId)
      ..addListener(_changed)
      ..start();
  }

  @override
  void didUpdateWidget(SessionResourceSkillsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime == widget.runtime &&
        oldWidget.sessionId == widget.sessionId) {
      return;
    }
    _catalog.removeListener(_changed);
    _catalog.dispose();
    _attach();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _catalog.removeListener(_changed);
    _catalog.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('技能'),
    trailing: GlassButton(
      icon: Icons.refresh_rounded,
      label: '刷新技能',
      onPressed: _catalog.loading || !widget.runtime.ready
          ? null
          : _catalog.load,
    ),
    body: PocketList(
      children: [
        if (!_catalog.current)
          _ResourceNote(
            _catalog.error ?? (_catalog.loading ? '正在读取技能…' : '等待本地服务。'),
          ),
        if (_catalog.current && _catalog.skills.isEmpty)
          const _ResourceNote('此会话暂无可用技能。'),
        if (_catalog.skills.isNotEmpty)
          PocketSection(
            children: [
              for (final skill in _catalog.skills)
                PocketRow(
                  key: ValueKey('resource-skill-${skill.name}'),
                  icon: Icons.auto_stories_outlined,
                  title: skill.name,
                  subtitle: skill.description,
                  onTap: skill.path == null
                      ? null
                      : () => Navigator.of(context).push<void>(
                          PocketRoute<void>(
                            builder: (_) => SessionDocumentPage(
                              runtime: widget.runtime,
                              sessionId: widget.sessionId,
                              path: skill.path!,
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

class _ResourceNote extends StatelessWidget {
  const _ResourceNote(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}
