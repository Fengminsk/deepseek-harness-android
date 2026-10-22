import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'chat_changes.dart';
import 'runtime.dart';
import 'session_document.dart';
import 'session_files.dart';
import 'skills.dart';
import 'tasks.dart';
import 'ui.dart';
import 'workspace_changes.dart';

/// Mobile navigation for resources belonging to one existing DSH Session.
/// Opening this page only reads the Session; it never creates or resumes work.
class SessionResourcesPage extends StatelessWidget {
  const SessionResourcesPage({
    super.key,
    required this.runtime,
    required this.sessionId,
  });

  final RuntimeController runtime;
  final String sessionId;

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push<void>(PocketRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('会话资源'),
    body: PocketList(
      children: [
        PocketSection(
          children: [
            PocketRow(
              key: const ValueKey('resource-files'),
              icon: Icons.folder_open_outlined,
              title: '文件',
              onTap: () => _open(
                context,
                SessionFilesPage(
                  runtime: runtime,
                  sessionId: sessionId,
                  onOpenDocument: (context, id, path) =>
                      Navigator.of(context).push<void>(
                        PocketRoute<void>(
                          builder: (_) => SessionDocumentPage(
                            runtime: runtime,
                            sessionId: id,
                            path: path,
                          ),
                        ),
                      ),
                ),
              ),
            ),
            PocketRow(
              key: const ValueKey('resource-changes'),
              icon: Icons.difference_outlined,
              title: '文件改动',
              onTap: () => _open(
                context,
                SessionChangesPage(runtime: runtime, sessionId: sessionId),
              ),
            ),
            PocketRow(
              key: const ValueKey('resource-skills'),
              icon: Icons.auto_stories_outlined,
              title: '技能',
              onTap: () => _open(
                context,
                SessionResourceSkillsPage(
                  runtime: runtime,
                  sessionId: sessionId,
                ),
              ),
            ),
            PocketRow(
              key: const ValueKey('resource-tasks'),
              icon: Icons.play_circle_outline_rounded,
              title: '后台任务',
              onTap: () => _open(
                context,
                TasksPage(runtime: runtime, sessionId: sessionId),
              ),
            ),
          ],
        ),
      ],
    ),
  );
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
    _projection.reconcile(const []);
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
      await runtime.openSession(sessionId);
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
    _projection.reconcile(
      widget.runtime.timelines[widget.sessionId] ?? const [],
    );
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
