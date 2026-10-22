import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'chat_secret_mask.dart';
import 'runtime.dart';
import 'session_trajectory_data.dart';
import 'ui.dart';

/// An opt-in, read-only view of the original Session event ledger. Opening a
/// saved Session requests its complete history through the existing read path.
class SessionTrajectoryPage extends StatefulWidget {
  const SessionTrajectoryPage({
    super.key,
    required this.runtime,
    required this.sessionId,
  });

  final RuntimeController runtime;
  final String sessionId;

  @override
  State<SessionTrajectoryPage> createState() => _SessionTrajectoryPageState();
}

class _SessionTrajectoryPageState extends State<SessionTrajectoryPage> {
  final projection = SessionTrajectoryProjection();
  final search = TextEditingController();
  bool loading = true, includeLifecycle = false;
  String? loadError;
  String filter = '全部';
  int readEpoch = 0;

  @override
  void initState() {
    super.initState();
    widget.runtime.addListener(_changed);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(SessionTrajectoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime.removeListener(_changed);
      widget.runtime.addListener(_changed);
    }
    if (oldWidget.runtime != widget.runtime ||
        oldWidget.sessionId != widget.sessionId) {
      unawaited(_load());
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final epoch = ++readEpoch;
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      if (!widget.runtime.ready) {
        throw StateError('服务尚未连接，请稍后重试。');
      }
      final before = widget.runtime.timelines[widget.sessionId];
      await widget.runtime.openSession(widget.sessionId);
      if (!mounted || epoch != readEpoch) return;
      final after = widget.runtime.timelines[widget.sessionId];
      if (after == null || identical(after, before)) {
        throw StateError('会话读取被另一项操作取代，完整记录尚未确认。请重试。');
      }
      projection.reconcile(after);
      setState(() => loading = false);
    } catch (error) {
      if (!mounted || epoch != readEpoch) return;
      setState(() {
        loading = false;
        loadError = '$error';
      });
    }
  }

  @override
  void dispose() {
    readEpoch++;
    widget.runtime.removeListener(_changed);
    search.dispose();
    super.dispose();
  }

  void _inspect(TrajectoryRecord record) {
    final linked = record.requestSeq;
    TrajectoryRecord? request;
    if (linked != null) {
      for (final row in projection.records) {
        if (row.seq == linked) {
          request = row;
          break;
        }
      }
    }
    Navigator.of(context).push<void>(
      PocketRoute<void>(
        builder: (_) => _TrajectoryInspector(
          runtime: widget.runtime,
          record: record,
          request: request,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    projection.reconcile(
      widget.runtime.timelines[widget.sessionId] ?? const [],
    );
    if (loading || loadError != null) {
      return PocketScaffold(
        title: const Text('会话轨迹'),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: loading
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('无法读取完整会话记录'),
                      const SizedBox(height: 8),
                      Text(loadError!, textAlign: TextAlign.center),
                      const SizedBox(height: 18),
                      PocketButton(
                        onPressed: () => unawaited(_load()),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
          ),
        ),
      );
    }
    final query = search.text.trim().toLowerCase();
    final rows = projection.records
        .where((record) {
          if (!includeLifecycle && record.kind == TrajectoryKind.lifecycle) {
            return false;
          }
          if (filter == '请求' &&
              record.kind != TrajectoryKind.request &&
              record.kind != TrajectoryKind.assistant &&
              record.kind != TrajectoryKind.attempt) {
            return false;
          }
          if (filter == '工具' && record.kind != TrajectoryKind.tool) {
            return false;
          }
          if (filter == '消息' &&
              record.kind != TrajectoryKind.user &&
              record.kind != TrajectoryKind.context &&
              record.kind != TrajectoryKind.assistant) {
            return false;
          }
          if (query.isEmpty) return true;
          return record.title.toLowerCase().contains(query) ||
              (record.summary?.toLowerCase().contains(query) ?? false) ||
              '${record.turn ?? ''}.${record.step ?? ''}'.contains(query);
        })
        .toList(growable: false);
    return PocketScaffold(
      title: const Text('会话轨迹'),
      body: PocketList.builder(
        itemCount: rows.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) return _header(context, rows.length);
          final record = rows[index - 1];
          return _TrajectoryTile(
            key: ValueKey(record.key),
            record: record,
            onTap: () => _inspect(record),
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, int visibleCount) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TrajectoryOverview(
          records: projection.records,
          start: projection.firstTime,
          end: projection.lastTime,
          onSelected: _inspect,
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Text(
            '${projection.records.length} 条事件记录 · 显示 $visibleCount 条',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ),
        if (projection.cumulative.countedTotal > 0) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Text(
              '累计 ${projection.cumulative.countedTotal} tokens · 输入 ${projection.cumulative.input} · 输出 ${projection.cumulative.output}',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ),
        ],
        const SizedBox(height: 20),
        TextField(
          controller: search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: '搜索记录类型、步骤或名称',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清除搜索',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      search.clear();
                      setState(() {});
                    },
                  ),
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final choice in const ['全部', '消息', '请求', '工具']) ...[
                ChoiceChip(
                  label: Text(choice),
                  selected: filter == choice,
                  onSelected: (_) => setState(() => filter = choice),
                ),
                const SizedBox(width: 7),
              ],
              FilterChip(
                label: const Text('生命周期'),
                selected: includeLifecycle,
                onSelected: (value) => setState(() => includeLifecycle = value),
              ),
            ],
          ),
        ),
        const SizedBox(height: 15),
      ],
    );
  }
}

class _TrajectoryOverview extends StatelessWidget {
  const _TrajectoryOverview({
    required this.records,
    required this.start,
    required this.end,
    required this.onSelected,
  });
  final List<TrajectoryRecord> records;
  final int? start, end;
  final ValueChanged<TrajectoryRecord> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return GlassSurface(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 17, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('时间线', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            SizedBox(
              height: 35,
              width: double.infinity,
              child: GestureDetector(
                onTapDown: (details) {
                  if (records.isEmpty || start == null || end == null) return;
                  final box = context.findRenderObject();
                  final width = box is RenderBox ? box.size.width - 36 : 1.0;
                  final ratio =
                      (details.localPosition.dx / math.max(width, 1.0)).clamp(
                        0.0,
                        1.0,
                      );
                  final target = start! + ((end! - start!) * ratio).round();
                  TrajectoryRecord? closest;
                  for (final record in records) {
                    if (closest == null ||
                        (record.time - target).abs() <
                            (closest.time - target).abs()) {
                      closest = record;
                    }
                  }
                  if (closest != null) onSelected(closest);
                },
                child: CustomPaint(
                  painter: _TrajectoryPainter(
                    records: records,
                    start: start,
                    end: end,
                    base: colors.outlineVariant,
                    accent: colors.primary,
                    message: colors.secondary,
                    error: colors.error,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              start == null || end == null
                  ? '没有已加载的事件'
                  : '${_clock(start!)} — ${_clock(end!)}',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrajectoryPainter extends CustomPainter {
  _TrajectoryPainter({
    required this.records,
    required this.start,
    required this.end,
    required this.base,
    required this.accent,
    required this.message,
    required this.error,
  });
  final List<TrajectoryRecord> records;
  final int? start, end;
  final Color base, accent, message, error;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.height / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, center - 2, size.width, 4),
        const Radius.circular(3),
      ),
      Paint()..color = base,
    );
    if (start == null || end == null || size.width <= 0) return;
    final span = math.max(end! - start!, 1);
    for (final record in records) {
      if (record.kind == TrajectoryKind.lifecycle) continue;
      final x = ((record.time - start!) / span * size.width).clamp(
        0.0,
        size.width,
      );
      final finish = record.endTime;
      final endX = finish == null
          ? x
          : ((finish - start!) / span * size.width).clamp(x, size.width);
      final paint = Paint()
        ..color = record.error
            ? error
            : record.kind == TrajectoryKind.user ||
                  record.kind == TrajectoryKind.assistant
            ? message
            : accent;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, center - 9, math.max(endX - x, 2), 18),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_TrajectoryPainter old) =>
      !identical(records, old.records) ||
      start != old.start ||
      end != old.end ||
      base != old.base ||
      accent != old.accent ||
      message != old.message ||
      error != old.error;
}

class _TrajectoryTile extends StatelessWidget {
  const _TrajectoryTile({super.key, required this.record, required this.onTap});
  final TrajectoryRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final location = [
      if (record.turn != null) '第 ${record.turn} 轮',
      if (record.step != null) '步骤 ${record.step}',
      '#${record.seq}',
    ].join(' · ');
    final extra = [
      _clock(record.time),
      location,
      if (record.durationMs != null) '${record.durationMs} ms',
      if (record.usage != null) '${record.usage!.countedTotal} tokens',
      if (record.summary != null) record.summary!,
    ].join(' · ');
    return Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 3,
          ),
          leading: Icon(
            _icon(record.kind),
            color: record.error ? colors.error : colors.primary,
          ),
          title: Text(
            record.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(extra, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        ),
        Divider(
          height: 1,
          indent: 55,
          color: colors.outlineVariant.withValues(alpha: .4),
        ),
      ],
    );
  }
}

class _TrajectoryInspector extends StatelessWidget {
  const _TrajectoryInspector({
    required this.runtime,
    required this.record,
    this.request,
  });
  final RuntimeController runtime;
  final TrajectoryRecord record;
  final TrajectoryRecord? request;

  @override
  Widget build(BuildContext context) {
    final fields = <String>[
      '事件 #${record.seq}',
      if (record.turn != null) '第 ${record.turn} 轮',
      if (record.step != null) '步骤 ${record.step}',
      _clock(record.time),
      if (record.durationMs != null) '持续 ${record.durationMs} ms',
      if (record.interrupted) '未完成',
      if (record.error) '失败',
    ];
    final requestRow = request;
    final input = _recordInput(record);
    final output = _recordOutput(record);
    return PocketScaffold(
      title: Text(record.title),
      body: PocketList(
        children: [
          PocketSection(
            title: '记录',
            children: [
              PocketRow(icon: _icon(record.kind), title: fields.join(' · ')),
              if (record.summary != null)
                PocketRow(icon: Icons.notes_rounded, title: record.summary!),
            ],
          ),
          if (record.usage != null)
            PocketSection(
              title: '模型用量',
              children: [
                PocketRow(
                  icon: Icons.data_usage_rounded,
                  title: '本次 ${record.usage!.countedTotal} tokens',
                  subtitle: _usageLine(record.usage!),
                ),
                if (record.cumulativeUsage != null)
                  PocketRow(
                    icon: Icons.stacked_line_chart_rounded,
                    title:
                        '截至此处累计 ${record.cumulativeUsage!.countedTotal} tokens',
                    subtitle: _usageLine(record.cumulativeUsage!),
                  ),
              ],
            ),
          if (requestRow != null)
            PocketSection(
              title: '关联请求',
              children: [
                PocketRow(
                  icon: Icons.arrow_back_rounded,
                  title: '模型请求 #${requestRow.seq}',
                  onTap: () => Navigator.of(context).push<void>(
                    PocketRoute<void>(
                      builder: (_) => _TrajectoryInspector(
                        runtime: runtime,
                        record: requestRow,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          if (input != null && input.isNotEmpty)
            PocketSection(
              title: '输入',
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: _MaskedText(runtime: runtime, source: input),
                ),
              ],
            ),
          if (output != null && output.isNotEmpty)
            PocketSection(
              title: '输出',
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: _MaskedText(runtime: runtime, source: output),
                ),
              ],
            ),
          for (final event in record.events)
            PocketSection(
              title: record.events.length == 1 ? '事件内容' : '事件 #${event['seq']}',
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: PocketDisclosure(
                    title: '查看原始记录',
                    child: _RawEvent(runtime: runtime, event: event),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _MaskedText extends StatelessWidget {
  const _MaskedText({required this.runtime, required this.source});
  final RuntimeController runtime;
  final String source;

  @override
  Widget build(BuildContext context) {
    return ChatSecretMask(
      runtime: runtime,
      text: source,
      builder: (context, ranges) {
        final buffer = StringBuffer();
        var offset = 0;
        for (final range in ranges) {
          buffer.write(source.substring(offset, range.start));
          buffer.write(range.masked);
          offset = range.end;
        }
        buffer.write(source.substring(offset));
        return Text(
          buffer.toString(),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.5,
          ),
        );
      },
    );
  }
}

/// Serializing a large stream is deferred until the raw disclosure opens.
class _RawEvent extends StatelessWidget {
  const _RawEvent({required this.runtime, required this.event});
  final RuntimeController runtime;
  final Json event;

  @override
  Widget build(BuildContext context) => _MaskedText(
    runtime: runtime,
    source: const JsonEncoder.withIndent('  ').convert(event),
  );
}

String? _recordInput(TrajectoryRecord record) {
  final event = record.events.first;
  final type = event['type'];
  final data = event['data'];
  if (data is! Map) return null;
  if (type == 'tool/call') return data['arguments'] as String?;
  if (type == 'request/header') {
    final header = data['header'];
    return header == null
        ? null
        : const JsonEncoder.withIndent('  ').convert(header);
  }
  if (type == 'user/message') return _contentText(data['content']);
  if (type == 'developer/message' || type == 'system/message') {
    final message = data['message'];
    return message is Map ? _contentText(message['content']) : null;
  }
  return null;
}

String? _recordOutput(TrajectoryRecord record) {
  final event = record.events.last;
  final type = event['type'];
  final data = event['data'];
  if (data is! Map) return null;
  if (type == 'assistant/message' || type == 'tool/result') {
    final message = data['message'];
    return message is Map ? _contentText(message['content']) : null;
  }
  return null;
}

String? _contentText(dynamic content) {
  if (content is! List) return null;
  final parts = <String>[];
  for (final block in content) {
    if (block is! Map) continue;
    if (block['text'] is String) {
      parts.add(block['text'] as String);
    } else if (block['type'] is String) {
      parts.add('[${block['type']}]');
    }
  }
  return parts.isEmpty ? null : parts.join('\n\n');
}

String _usageLine(TrajectoryUsage usage) => [
  '输入 ${usage.input}',
  '输出 ${usage.output}',
  if (usage.cacheRead > 0) '缓存读取 ${usage.cacheRead}',
  if (usage.cacheWrite > 0) '缓存写入 ${usage.cacheWrite}',
  if (usage.reasoning > 0) '推理 ${usage.reasoning}',
].join(' · ');

String _clock(int milliseconds) {
  final value = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  String two(int component) => component.toString().padLeft(2, '0');
  return '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}

IconData _icon(TrajectoryKind kind) => switch (kind) {
  TrajectoryKind.user => Icons.person_outline_rounded,
  TrajectoryKind.context => Icons.article_outlined,
  TrajectoryKind.request => Icons.cloud_outlined,
  TrajectoryKind.assistant => Icons.auto_awesome_rounded,
  TrajectoryKind.attempt => Icons.sync_problem_rounded,
  TrajectoryKind.tool => Icons.terminal_rounded,
  TrajectoryKind.compaction => Icons.compress_rounded,
  TrajectoryKind.lifecycle => Icons.timeline_rounded,
  TrajectoryKind.other => Icons.more_horiz_rounded,
};
