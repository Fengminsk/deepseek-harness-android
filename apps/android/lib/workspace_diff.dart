import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'file_browser_chrome.dart';
import 'flclash/popup.dart';
import 'session_document.dart';
import 'ui.dart';
import 'workspace_changes.dart';
import 'workspace_change_widgets.dart';

/// Reads the original turn-start/turn-end comparison. Opening the current file
/// is a separate, explicitly labelled SessionDocumentPage navigation.
class WorkspaceDiffPage extends StatefulWidget {
  const WorkspaceDiffPage({
    required this.controller,
    required this.seq,
    required this.turn,
    this.initialIndex = 0,
    super.key,
  });
  final WorkspaceChangesController controller;
  final int seq, turn, initialIndex;
  @override
  State<WorkspaceDiffPage> createState() => _WorkspaceDiffPageState();
}

class _WorkspaceDiffPageState extends State<WorkspaceDiffPage> {
  late ValueListenable<WorkspaceRead<WorkspaceChangesSummary>> _summary;
  ValueListenable<WorkspaceRead<WorkspaceFileDiff>>? _diff;
  VoidCallback? _release;
  int? _index;
  late int _preferredIndex = widget.initialIndex;
  bool _wrap = true, _menuOpen = false;
  final _scroll = ScrollController();
  final _horizontal = ScrollController();
  final _positions = <int, double>{};

  @override
  void initState() {
    super.initState();
    _connect();
  }

  void _connect() {
    if (!widget.controller.retired) {
      widget.controller.addListener(_summaryChanged);
    }
    _summary = widget.controller.summary(widget.seq);
    _summary.addListener(_summaryChanged);
    _synchronizeFile();
    unawaited(widget.controller.loadSummary(widget.seq));
  }

  @override
  void didUpdateWidget(WorkspaceDiffPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.seq != widget.seq ||
        oldWidget.turn != widget.turn) {
      _summary.removeListener(_summaryChanged);
      oldWidget.controller.removeListener(_summaryChanged);
      _detach();
      _positions.clear();
      _preferredIndex = widget.initialIndex;
      _connect();
    }
  }

  WorkspaceChangesSummary? get _currentSummary {
    final state = _summary.value;
    final value = state.value;
    return widget.controller.enabled &&
            state.phase == WorkspaceReadPhase.ready &&
            value?.turn == widget.turn
        ? value
        : null;
  }

  WorkspaceChangedFile? get _file {
    final summary = _currentSummary, index = _index;
    return summary != null && index != null && index < summary.files.length
        ? summary.files[index]
        : null;
  }

  void _summaryChanged() {
    if (!mounted) return;
    _synchronizeFile();
    setState(() {});
  }

  void _synchronizeFile() {
    final summary = _currentSummary;
    if (summary == null || summary.files.isEmpty) {
      _detach();
      return;
    }
    final index = _preferredIndex >= 0 && _preferredIndex < summary.files.length
        ? _preferredIndex
        : 0;
    if (_index == index && _diff != null) return;
    _detach();
    _index = index;
    _diff = widget.controller.diff(widget.seq, index);
    _diff!.addListener(_diffChanged);
    _release = widget.controller.retainDiff(widget.seq, index);
    unawaited(widget.controller.loadDiff(widget.seq, index));
  }

  void _diffChanged() {
    if (mounted) setState(() {});
  }

  void _detach() {
    _diff?.removeListener(_diffChanged);
    _diff = null;
    _release?.call();
    _release = null;
    _index = null;
  }

  Future<void> _selectFile() async {
    final summary = _currentSummary;
    if (summary == null || summary.files.length < 2) return;
    final connection = widget.controller.runtime.connectionGeneration;
    final index = await Navigator.of(context).push<int>(
      PocketRoute(
        builder: (_) => _ChangedFilesPage(summary: summary, selected: _index),
      ),
    );
    if (!mounted ||
        index == null ||
        connection != widget.controller.runtime.connectionGeneration ||
        !identical(summary, _currentSummary)) {
      return;
    }
    if (_index != null && _scroll.hasClients) {
      _positions[_index!] = _scroll.offset;
    }
    setState(() {
      _preferredIndex = index;
      _synchronizeFile();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _index != index) return;
      if (_scroll.hasClients) {
        _scroll.jumpTo(
          (_positions[index] ?? 0).clamp(0, _scroll.position.maxScrollExtent),
        );
      }
      if (_horizontal.hasClients) _horizontal.jumpTo(0);
    });
  }

  Future<void> _menu(BuildContext anchor) async {
    if (_menuOpen) return;
    _menuOpen = true;
    final selectedFile = _file;
    final seq = widget.seq;
    final controller = widget.controller;
    final generation = controller.runtime.connectionGeneration;
    final choice = await showFileBrowserMenu(anchor, [
      CommonPopupMenuItem(
        label: _wrap ? '关闭自动换行' : '自动换行',
        glyph: Icons.wrap_text_rounded,
        onPressed: () {},
      ),
      CommonPopupMenuItem(
        label: '打开当前文件',
        glyph: Icons.open_in_new_rounded,
        onPressed: selectedFile == null || !controller.runtime.ready
            ? null
            : () {},
      ),
    ]);
    _menuOpen = false;
    if (!mounted ||
        controller != widget.controller ||
        seq != widget.seq ||
        generation != controller.runtime.connectionGeneration) {
      return;
    }
    if (choice == 0) setState(() => _wrap = !_wrap);
    if (choice == 1 && selectedFile != null && identical(selectedFile, _file)) {
      await Navigator.of(context).push<void>(
        PocketRoute(
          builder: (_) => SessionDocumentPage(
            runtime: controller.runtime,
            sessionId: controller.sessionId,
            path: selectedFile.path,
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _summary.removeListener(_summaryChanged);
    widget.controller.removeListener(_summaryChanged);
    _detach();
    _scroll.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final file = _file, summary = _currentSummary;
    final comparison = _diff?.value;
    final selected = comparison?.value;
    // Malformed/mismatched replies cannot relabel one file with another diff.
    final state = selected != null && file != null && selected.path != file.path
        ? const WorkspaceRead<WorkspaceFileDiff>(WorkspaceReadPhase.error)
        : comparison;
    return PocketScaffold(
      title: Text('第 ${widget.turn} 轮改动'),
      trailing: Builder(
        builder: (anchor) => GlassButton(
          icon: Icons.more_horiz_rounded,
          label: '差异选项',
          onPressed: () => _menu(anchor),
        ),
      ),
      body: file == null
          ? PocketList(
              children: [
                _DiffStatus(
                  label: widget.controller.retired
                      ? '会话已离开，无法继续读取改动'
                      : !widget.controller.enabled
                      ? widget.controller.preferenceConfirmed
                            ? '开发者工具已关闭'
                            : '正在核对开发者工具设置…'
                      : switch (_summary.value.phase) {
                          WorkspaceReadPhase.idle ||
                          WorkspaceReadPhase.loading => '正在读取改动…',
                          WorkspaceReadPhase.waiting => '等待服务连接',
                          _ => '这轮改动的内容已不可用',
                        },
                ),
              ],
            )
          : WorkspaceDiffBody(
              state: state ?? const WorkspaceRead(WorkspaceReadPhase.loading),
              wrap: _wrap,
              controller: _scroll,
              horizontalController: _horizontal,
              header: PocketSection(
                children: [
                  PocketTile(
                    leading: const Icon(Icons.difference_outlined),
                    title: Text(file.display),
                    subtitle: WorkspaceChangeCounts(
                      added: file.added,
                      deleted: file.deleted,
                      binary: file.binary,
                      oversized: file.oversized,
                    ),
                    trailing: summary!.files.length > 1
                        ? const Icon(Icons.unfold_more_rounded)
                        : null,
                    onTap: summary.files.length > 1 ? _selectFile : null,
                  ),
                ],
              ),
              retry: () =>
                  unawaited(widget.controller.loadDiff(widget.seq, _index!)),
            ),
    );
  }
}

class _ChangedFilesPage extends StatelessWidget {
  const _ChangedFilesPage({required this.summary, required this.selected});
  final WorkspaceChangesSummary summary;
  final int? selected;
  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('更改的文件'),
    body: PocketList(
      children: [
        PocketSection(
          divided: true,
          children: [
            for (var index = 0; index < summary.files.length; index++)
              WorkspaceChangedFileTile(
                file: summary.files[index],
                selected: index == selected,
                onTap: () => Navigator.of(context).pop(index),
              ),
          ],
        ),
        if (summary.total > summary.files.length)
          _DiffStatus(
            label: '显示 ${summary.files.length} 个文件，共 ${summary.total} 个',
          ),
      ],
    ),
  );
}

/// Lazy unified rows retain both source line numbers while wrapping. Long lines
/// can instead scroll horizontally; headers float above this same viewport.
class WorkspaceDiffBody extends StatefulWidget {
  const WorkspaceDiffBody({
    required this.state,
    required this.retry,
    this.wrap = true,
    this.header,
    this.controller,
    this.horizontalController,
    super.key,
  });
  final WorkspaceRead<WorkspaceFileDiff> state;
  final VoidCallback retry;
  final bool wrap;
  final Widget? header;
  final ScrollController? controller, horizontalController;
  @override
  State<WorkspaceDiffBody> createState() => _WorkspaceDiffBodyState();
}

class _WorkspaceDiffBodyState extends State<WorkspaceDiffBody> {
  WorkspaceFileDiff? _source;
  List<Object> _rows = const [];
  bool _truncated = false;
  (WorkspaceFileDiff?, TextStyle, TextScaler)? _measured;
  double _codeWidth = 0;

  void _prepare(WorkspaceFileDiff? diff) {
    if (identical(_source, diff)) return;
    _source = diff;
    final rendered = workspaceRenderedHunks(diff?.hunks ?? const []);
    _truncated = rendered.truncated;
    _rows = [
      for (final hunk in rendered.hunks) ...[
        hunk.header,
        ...workspaceHunkRows(hunk),
      ],
    ];
    _measured = null;
  }

  double _measure(TextStyle style, TextScaler scale) {
    final stamp = (_source, style, scale);
    if (_measured == stamp) return _codeWidth;
    _measured = stamp;
    var width = 0.0;
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: scale,
      maxLines: 1,
    );
    for (final row in _rows) {
      if (row is! WorkspaceDiffLine) continue;
      painter.text = TextSpan(text: row.text, style: style);
      painter.layout();
      width = math.max(width, painter.width);
    }
    painter.dispose();
    _codeWidth = width.ceilToDouble() + 2;
    return _codeWidth;
  }

  @override
  Widget build(BuildContext context) {
    final diff = widget.state.value;
    _prepare(diff);
    final notices = <Widget>[
      if (widget.header != null) widget.header!,
      if (widget.state.phase != WorkspaceReadPhase.ready)
        _DiffStatus(
          label: switch (widget.state.phase) {
            WorkspaceReadPhase.missing => '这轮改动的内容已不可用',
            WorkspaceReadPhase.error => '无法读取改动',
            WorkspaceReadPhase.waiting => '等待服务连接',
            _ => '正在读取改动…',
          },
          retry: widget.state.phase == WorkspaceReadPhase.error
              ? widget.retry
              : null,
        )
      else if (diff?.kind == WorkspaceDiffKind.binary)
        const _DiffStatus(label: '二进制文件，无法显示改动')
      else if (diff?.kind == WorkspaceDiffKind.oversized)
        const _DiffStatus(label: '文件过大，无法显示改动')
      else if (diff != null) ...[
        if (!diff.before)
          const _DiffStatus(label: '本轮新建的文件')
        else if (!diff.after)
          const _DiffStatus(label: '本轮删除的文件')
        else if (diff.hunks.isEmpty)
          const _DiffStatus(label: '两侧内容相同'),
        if (diff.coarse) const _DiffStatus(label: '逐行对比超时，按整个文件替换显示'),
        if (_truncated) const _DiffStatus(label: '只显示前 5000 行'),
      ],
    ];
    final lines =
        diff?.kind == WorkspaceDiffKind.text &&
            widget.state.phase == WorkspaceReadPhase.ready
        ? _rows
        : const <Object>[];
    final style = TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.6,
      color: Theme.of(context).colorScheme.onSurface,
    );
    final scale = MediaQuery.textScalerOf(context);
    final numberWidth = math.max(34.0, scale.scale(10) * 5.4);
    final gutter = numberWidth * 2 + 24;
    return LayoutBuilder(
      builder: (context, box) {
        final contentWidth = widget.wrap
            ? box.maxWidth
            : math.max(box.maxWidth, _measure(style, scale) + gutter + 32);
        final list = SizedBox(
          width: contentWidth,
          child: PocketList.builder(
            controller: widget.controller,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: notices.length + lines.length,
            itemBuilder: (context, index) {
              if (index < notices.length) {
                return Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: box.maxWidth - 32,
                    child: notices[index],
                  ),
                );
              }
              final row = lines[index - notices.length];
              if (row is String) {
                return Container(
                  key: ValueKey('hunk-$index'),
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Text(
                    row,
                    style: style.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              }
              return _DiffLine(
                key: ValueKey('line-$index'),
                row: row as WorkspaceDiffLine,
                style: style,
                numberWidth: numberWidth,
                wrap: widget.wrap,
              );
            },
          ),
        );
        return SelectionArea(
          child: widget.wrap
              ? list
              : SingleChildScrollView(
                  controller: widget.horizontalController,
                  scrollDirection: Axis.horizontal,
                  child: list,
                ),
        );
      },
    );
  }
}

class _DiffLine extends StatelessWidget {
  const _DiffLine({
    required this.row,
    required this.style,
    required this.numberWidth,
    required this.wrap,
    super.key,
  });
  final WorkspaceDiffLine row;
  final TextStyle style;
  final double numberWidth;
  final bool wrap;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final tint = switch (row.kind) {
      WorkspaceDiffLineKind.added =>
        dark ? const Color(0xff8dddac) : const Color(0xff176b3b),
      WorkspaceDiffLineKind.deleted =>
        dark ? const Color(0xffffaaa7) : const Color(0xffb32b29),
      WorkspaceDiffLineKind.context => colors.onSurfaceVariant,
    };
    Widget number(int? value) => SizedBox(
      width: numberWidth,
      child: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Text(
          value == null ? '' : '$value',
          textAlign: TextAlign.right,
          style: style.copyWith(color: colors.onSurfaceVariant),
        ),
      ),
    );
    return ColoredBox(
      color: row.kind == WorkspaceDiffLineKind.context
          ? Colors.transparent
          : tint.withValues(alpha: dark ? .12 : .09),
      child: Semantics(
        label: switch (row.kind) {
          WorkspaceDiffLineKind.added => '新增，第 ${row.newLine} 行',
          WorkspaceDiffLineKind.deleted => '删除，原第 ${row.oldLine} 行',
          WorkspaceDiffLineKind.context =>
            '原第 ${row.oldLine} 行，新第 ${row.newLine} 行',
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            number(row.oldLine),
            number(row.newLine),
            SizedBox(
              width: 20,
              child: Text(row.sign, style: style.copyWith(color: tint)),
            ),
            Expanded(
              child: Text(
                row.text.isEmpty ? ' ' : row.text,
                style: style,
                textDirection: TextDirection.ltr,
                softWrap: wrap,
                maxLines: wrap ? null : 1,
                overflow: TextOverflow.visible,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiffStatus extends StatelessWidget {
  const _DiffStatus({required this.label, this.retry});
  final String label;
  final VoidCallback? retry;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (retry != null) ...[
          const SizedBox(height: 12),
          PocketButton.tonal(onPressed: retry, child: const Text('重试')),
        ],
      ],
    ),
  );
}
