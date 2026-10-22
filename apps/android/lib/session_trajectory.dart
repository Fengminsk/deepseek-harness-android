import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'chat_secret_mask.dart';
import 'image_preview.dart';
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
          sessionId: widget.sessionId,
          record: record,
          request: request,
          records: projection.records,
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

class _TrajectoryInspector extends StatefulWidget {
  const _TrajectoryInspector({
    required this.runtime,
    required this.sessionId,
    required this.record,
    required this.records,
    this.request,
  });
  final RuntimeController runtime;
  final String sessionId;
  final TrajectoryRecord record;
  final List<TrajectoryRecord> records;
  final TrajectoryRecord? request;

  @override
  State<_TrajectoryInspector> createState() => _TrajectoryInspectorState();
}

class _TrajectoryInspectorState extends State<_TrajectoryInspector> {
  late final _images = _TrajectoryImageStore(widget.runtime, widget.sessionId);

  @override
  void initState() {
    super.initState();
    widget.runtime.addListener(_connectionChanged);
  }

  void _connectionChanged() {
    if (_images.syncGeneration() && mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.runtime.removeListener(_connectionChanged);
    _images.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _images.syncGeneration();
    final runtime = widget.runtime;
    final sessionId = widget.sessionId;
    final record = widget.record;
    final records = widget.records;
    final fields = <String>[
      '事件 #${record.seq}',
      if (record.turn != null) '第 ${record.turn} 轮',
      if (record.step != null) '步骤 ${record.step}',
      _clock(record.time),
      if (record.durationMs != null) '持续 ${record.durationMs} ms',
      if (record.interrupted) '未完成',
      if (record.error) '失败',
    ];
    final requestRow = widget.request;
    final input = _recordInput(record);
    final output = _recordOutput(record);
    final attachments = _recordAttachments(record);
    final timing = _assistantTiming(record, records);
    final imageGeneration = _images.generation;
    final items = <Widget>[
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
                title: '截至此处累计 ${record.cumulativeUsage!.countedTotal} tokens',
                subtitle: _usageLine(record.cumulativeUsage!),
              ),
          ],
        ),
      if (timing != null)
        PocketSection(
          title: '生成时序',
          children: [
            PocketRow(
              icon: Icons.hourglass_top_rounded,
              title: '首 token 延迟',
              subtitle: timing.ttftMs == null ? '未记录' : '${timing.ttftMs} ms',
            ),
            PocketRow(
              icon: Icons.timer_outlined,
              title: '生成用时',
              subtitle: timing.generationMs == null
                  ? '未记录'
                  : '${timing.generationMs} ms',
            ),
            PocketRow(
              icon: Icons.speed_rounded,
              title: '吞吐量',
              subtitle: timing.tokensPerSecond == null
                  ? '未记录'
                  : '${timing.tokensPerSecond!.toStringAsFixed(1)} tokens/s',
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
                    sessionId: sessionId,
                    record: requestRow,
                    records: records,
                  ),
                ),
              ),
            ),
          ],
        ),
      if (attachments.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
          child: Text(
            '附件',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      for (var index = 0; index < attachments.length; index++)
        _TrajectoryAttachmentTile(
          key: ValueKey(
            'attachment:$index:${attachments[index].reference['attachmentId']}',
          ),
          attachment: attachments[index],
          first: index == 0,
          last: index == attachments.length - 1,
          generation: imageGeneration,
          thumbnail: () => _images.thumbnail(attachments[index]),
          onRelease: () => _images.release(attachments[index], imageGeneration),
          onOpen: () => Navigator.of(context).push<void>(
            PocketRoute<void>(
              builder: (_) => PocketImagePreview(
                source: PocketImageSource(
                  name: attachments[index].name,
                  load: () => _images.fullImage(attachments[index]),
                ),
              ),
            ),
          ),
        ),
      if (attachments.isNotEmpty) const SizedBox(height: 28),
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
    ];
    return PocketScaffold(
      title: Text(record.title),
      body: PocketList.builder(
        itemCount: items.length,
        itemBuilder: (_, index) => items[index],
      ),
    );
  }
}

/// Attachment order follows the recorded content blocks, including repeated
/// references. Only recorded image references reach the Session image loader.
typedef _TrajectoryAttachment = ({
  bool image,
  Json reference,
  String name,
  String metadata,
});

List<_TrajectoryAttachment> _recordAttachments(TrajectoryRecord record) {
  final event = record.kind == TrajectoryKind.tool
      ? record.events.last
      : record.events.first;
  final data = event['data'];
  if (data is! Map) return const [];
  final content = event['type'] == 'user/message'
      ? data['content']
      : data['message'] is Map
      ? (data['message'] as Map)['content']
      : null;
  if (content is! List) return const [];
  final attachments = <_TrajectoryAttachment>[];
  var imageIndex = 0;
  for (final block in content) {
    if (block is! Map) continue;
    final type = block['type'];
    if (type != 'image' && type != 'file') continue;
    final reference = block['attachment'];
    if (reference is! Json || reference['attachmentId'] is! String) {
      continue;
    }
    final image = type == 'image';
    if (image) imageIndex++;
    final name =
        reference['name'] is String && (reference['name'] as String).isNotEmpty
        ? reference['name'] as String
        : image
        ? '图片 $imageIndex'
        : '文件附件';
    final pieces = <String>[
      if (image && reference['mediaType'] is String)
        reference['mediaType'] as String,
      if (!image && name.contains('.')) name.split('.').last.toUpperCase(),
      if (reference['bytes'] is int && (reference['bytes'] as int) >= 0)
        _fileSize(reference['bytes'] as int),
      if (image && reference['width'] is int && reference['height'] is int)
        '${reference['width']} × ${reference['height']}',
    ];
    attachments.add((
      image: image,
      reference: reference,
      name: name,
      metadata: pieces.join(' · '),
    ));
  }
  return attachments;
}

String _fileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

/// A visible row holds only a small thumbnail. The inspector keeps at most two
/// 20 MiB source payloads and sixteen <=128px thumbnails, and starts at most
/// two thumbnail reads per connection generation. Off-screen rows are not
/// constructed by the outer lazy list, so they cannot enqueue image reads.
typedef _QueuedThumbnail = ({
  int generation,
  _TrajectoryAttachment attachment,
  Completer<Uint8List> completer,
});

class _TrajectoryImageStore {
  _TrajectoryImageStore(this.runtime, this.sessionId)
    : _generation = runtime.connectionGeneration;
  final RuntimeController runtime;
  final String sessionId;
  final _queue = Queue<_QueuedThumbnail>();
  final _pending = <String, Future<Uint8List>>{};
  final _listeners = <String, int>{};
  final _thumbnails = <String, Uint8List>{};
  final _raw = <String, PocketImagePayload>{};
  final _failures = <String, Object>{};
  var _active = 0;
  var _disposed = false;
  int _generation;
  int get generation => _generation;

  bool syncGeneration() {
    final current = runtime.connectionGeneration;
    if (current == _generation || _disposed) return false;
    _generation = current;
    while (_queue.isNotEmpty) {
      _queue.removeFirst().completer.completeError(
        StateError('服务连接已变化，请重新读取图片。'),
      );
    }
    _pending.clear();
    _listeners.clear();
    _thumbnails.clear();
    _raw.clear();
    _failures.clear();
    // Old requests may still settle; they cannot consume this generation's
    // two read slots or write its caches.
    _active = 0;
    return true;
  }

  Future<Uint8List> thumbnail(_TrajectoryAttachment attachment) {
    syncGeneration();
    if (_disposed) return Future.error(StateError('轨迹检查页已关闭。'));
    final id = attachment.reference['attachmentId'] as String;
    final listenerKey = '$_generation:$id';
    _listeners[listenerKey] = (_listeners[listenerKey] ?? 0) + 1;
    final cached = _thumbnails.remove(id);
    if (cached != null) {
      _thumbnails[id] = cached;
      return Future.value(cached);
    }
    final failure = _failures[id];
    if (failure != null) return Future.error(failure);
    final pending = _pending[id];
    if (pending != null) return pending;
    final completer = Completer<Uint8List>();
    _pending[id] = completer.future;
    _queue.add((
      generation: _generation,
      attachment: attachment,
      completer: completer,
    ));
    scheduleMicrotask(_pump);
    return completer.future;
  }

  void release(_TrajectoryAttachment attachment, int generation) {
    if (generation != _generation) return;
    final id = attachment.reference['attachmentId'] as String;
    final listenerKey = '$generation:$id';
    final remaining = (_listeners[listenerKey] ?? 1) - 1;
    if (remaining > 0) {
      _listeners[listenerKey] = remaining;
      return;
    }
    _listeners.remove(listenerKey);
    // Once a row leaves ListView's mounted window, an unstarted request no
    // longer belongs in the queue. Active reads remain bounded to two.
    final retained = Queue<_QueuedThumbnail>();
    while (_queue.isNotEmpty) {
      final job = _queue.removeFirst();
      if (job.generation == generation &&
          job.attachment.reference['attachmentId'] == id) {
        _pending.remove(id);
        job.completer.completeError(StateError('缩略图已离开可见区域。'));
      } else {
        retained.add(job);
      }
    }
    _queue.addAll(retained);
  }

  void _pump() {
    syncGeneration();
    while (!_disposed && _active < 2 && _queue.isNotEmpty) {
      final next = _queue.removeFirst();
      _active++;
      unawaited(_run(next));
    }
  }

  Future<void> _run(_QueuedThumbnail job) async {
    final id = job.attachment.reference['attachmentId'] as String;
    try {
      final payload = await PocketImageSource.session(
        runtime,
        sessionId,
        job.attachment.reference,
      ).load();
      syncGeneration();
      if (_disposed || job.generation != _generation) {
        throw StateError('服务连接已变化，请重新读取图片。');
      }
      final bytes = await _makeTrajectoryThumbnail(payload);
      syncGeneration();
      if (_disposed || job.generation != _generation) {
        throw StateError('服务连接已变化，请重新读取图片。');
      }
      _raw.remove(id);
      _raw[id] = payload;
      while (_raw.length > 2) {
        _raw.remove(_raw.keys.first);
      }
      _thumbnails.remove(id);
      _thumbnails[id] = bytes;
      while (_thumbnails.length > 16) {
        _thumbnails.remove(_thumbnails.keys.first);
      }
      job.completer.complete(bytes);
    } catch (error, stack) {
      if (!_disposed && job.generation == _generation) {
        _failures[id] = error;
      }
      if (!job.completer.isCompleted) job.completer.completeError(error, stack);
    } finally {
      if (job.generation == _generation) {
        if (identical(_pending[id], job.completer.future)) {
          _pending.remove(id);
        }
        _active--;
        _pump();
      }
    }
  }

  Future<PocketImagePayload> fullImage(_TrajectoryAttachment attachment) async {
    syncGeneration();
    if (_disposed) throw StateError('轨迹检查页已关闭。');
    final generation = _generation;
    final id = attachment.reference['attachmentId'] as String;
    _failures.remove(id);
    final pending = _pending[id];
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        // The full-screen viewer is an explicit user retry.
      }
    }
    syncGeneration();
    if (generation != _generation) {
      throw StateError('服务连接已变化，请重新读取图片。');
    }
    final cached = _raw.remove(id);
    if (cached != null) {
      _raw[id] = cached;
      return cached;
    }
    final payload = await PocketImageSource.session(
      runtime,
      sessionId,
      attachment.reference,
    ).load();
    syncGeneration();
    if (_disposed || generation != _generation) {
      throw StateError('服务连接已变化，请重新读取图片。');
    }
    _raw[id] = payload;
    while (_raw.length > 2) {
      _raw.remove(_raw.keys.first);
    }
    return payload;
  }

  void dispose() {
    _disposed = true;
    while (_queue.isNotEmpty) {
      final next = _queue.removeFirst();
      next.completer.completeError(StateError('轨迹检查页已关闭。'));
    }
    _pending.clear();
    _listeners.clear();
    _thumbnails.clear();
    _raw.clear();
    _failures.clear();
  }
}

Future<Uint8List> _makeTrajectoryThumbnail(PocketImagePayload payload) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(payload.bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? decoded;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (payload.width != descriptor.width ||
        payload.height != descriptor.height) {
      throw const FormatException('图片实际尺寸与附件信息不匹配。');
    }
    final scale = math.min(
      1.0,
      math.min(128 / descriptor.width, 128 / descriptor.height),
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * scale).round()),
      targetHeight: math.max(1, (descriptor.height * scale).round()),
    );
    decoded = (await codec.getNextFrame()).image;
    final encoded = await decoded.toByteData(format: ui.ImageByteFormat.png);
    if (encoded == null) throw const FormatException('无法生成图片缩略图。');
    return encoded.buffer.asUint8List();
  } finally {
    decoded?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

class _TrajectoryAttachmentTile extends StatefulWidget {
  const _TrajectoryAttachmentTile({
    super.key,
    required this.attachment,
    required this.first,
    required this.last,
    required this.generation,
    required this.thumbnail,
    required this.onRelease,
    required this.onOpen,
  });
  final _TrajectoryAttachment attachment;
  final bool first, last;
  final int generation;
  final Future<Uint8List> Function() thumbnail;
  final VoidCallback onRelease;
  final VoidCallback onOpen;

  @override
  State<_TrajectoryAttachmentTile> createState() =>
      _TrajectoryAttachmentTileState();
}

class _TrajectoryAttachmentTileState extends State<_TrajectoryAttachmentTile> {
  Future<Uint8List>? _thumbnail;

  @override
  void initState() {
    super.initState();
    if (widget.attachment.image) _thumbnail = widget.thumbnail();
  }

  @override
  void didUpdateWidget(_TrajectoryAttachmentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.generation != widget.generation ||
        oldWidget.attachment.reference['attachmentId'] !=
            widget.attachment.reference['attachmentId']) {
      if (oldWidget.attachment.image) oldWidget.onRelease();
      _thumbnail = widget.attachment.image ? widget.thumbnail() : null;
    }
  }

  @override
  void dispose() {
    if (widget.attachment.image) widget.onRelease();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.vertical(
      top: Radius.circular(widget.first ? 24 : 0),
      bottom: Radius.circular(widget.last ? 24 : 0),
    );
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            leading: _thumbnail == null
                ? const Icon(Icons.insert_drive_file_outlined)
                : SizedBox(
                    width: 56,
                    height: 56,
                    child: FutureBuilder<Uint8List>(
                      future: _thumbnail,
                      builder: (context, snapshot) {
                        final bytes = snapshot.data;
                        if (bytes == null) {
                          return Icon(
                            snapshot.hasError
                                ? Icons.broken_image_outlined
                                : Icons.image_outlined,
                          );
                        }
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.memory(
                            bytes,
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.broken_image_outlined),
                          ),
                        );
                      },
                    ),
                  ),
            title: Text(
              widget.attachment.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: widget.attachment.metadata.isEmpty
                ? null
                : Text(widget.attachment.metadata),
            onTap: widget.attachment.image ? widget.onOpen : null,
          ),
          if (!widget.last) const Divider(height: 1, indent: 88, endIndent: 16),
        ],
      ),
    );
  }
}

typedef _AssistantTiming = ({
  int? ttftMs,
  int? generationMs,
  double? tokensPerSecond,
});

_AssistantTiming? _assistantTiming(
  TrajectoryRecord record,
  List<TrajectoryRecord> records,
) {
  if (record.kind != TrajectoryKind.assistant &&
      record.kind != TrajectoryKind.attempt) {
    return null;
  }
  final completed = record.events.first['time'];
  if (completed is! int) {
    return (ttftMs: null, generationMs: null, tokensPerSecond: null);
  }
  // The original trajectory retains a Step's first token across retries.
  final priorAttempts = records.where(
    (other) =>
        other.kind == TrajectoryKind.attempt &&
        other.seq < record.seq &&
        other.turn == record.turn &&
        other.step == record.step &&
        record.turn != null &&
        record.step != null,
  );
  final times = [
    for (final attempt in priorAttempts)
      ?_streamFirstTokenTime(attempt.events.first['data']),
    ?_streamFirstTokenTime(record.events.first['data']),
  ];
  final first = times.isEmpty ? null : times.reduce(math.min);
  final start = record.endTime == null ? null : record.time;
  final validFirst =
      first != null && first <= completed && (start == null || first >= start)
      ? first
      : null;
  final generation = validFirst == null ? null : completed - validFirst;
  final outputTokens = record.usage?.output;
  return (
    ttftMs: start == null || validFirst == null ? null : validFirst - start,
    generationMs: generation,
    tokensPerSecond:
        generation == null || generation <= 0 || outputTokens == null
        ? null
        : outputTokens * 1000 / generation,
  );
}

int? _streamFirstTokenTime(dynamic data) {
  final stream = data is Map ? data['stream'] : null;
  if (stream is! List) return null;
  for (final item in stream) {
    if (item is! Map) continue;
    if (item['type'] == 'chunk') {
      final chunk = item['chunk'];
      final time = item['time'];
      if (chunk is! Map || time is! int) continue;
      final type = chunk['type'];
      if ((type == 'text-delta' || type == 'reasoning-delta') &&
          chunk['text'] is String &&
          (chunk['text'] as String).isNotEmpty) {
        return time;
      }
      if (type == 'tool-call-delta' &&
          ((chunk['argumentsDelta'] is String &&
                  (chunk['argumentsDelta'] as String).isNotEmpty) ||
              chunk['name'] is String)) {
        return time;
      }
      continue;
    }
    final type = item['type'];
    if (type != 'text-chunks' &&
        type != 'reasoning-chunks' &&
        type != 'tool-call-chunks') {
      continue;
    }
    final time0 = item['time0'];
    final parts = type == 'tool-call-chunks' ? item['args'] : item['texts'];
    final deltas = item['dt'];
    if (time0 is! int || parts is! List || deltas is! List) continue;
    if (type == 'tool-call-chunks' && item['name'] is String) return time0;
    var time = time0;
    for (var index = 0; index < parts.length; index++) {
      if (index > 0) {
        final delta = index - 1 < deltas.length ? deltas[index - 1] : null;
        if (delta is! int || delta < 0) break;
        time += delta;
      }
      if (parts[index] is String && (parts[index] as String).isNotEmpty) {
        return time;
      }
    }
  }
  return null;
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
