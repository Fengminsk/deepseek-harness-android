import 'runtime.dart';

/// One retained output run. A gap belongs to the text immediately after it.
class JobOutputPart {
  const JobOutputPart(this.text, {this.channel, this.gapBefore = false});

  final String text;
  final String? channel;
  final bool gapBefore;
}

/// Mirrors DSH job.follow frames without consuming the Agent's output cursor.
class JobOutput {
  static const renderTailLimit = 128 * 1024;
  static const renderPartLimit = 512;
  static const gapMarker = '\n⋯ 部分输出已丢失 ⋯\n';
  Json? job;
  String text = '';
  final List<JobOutputPart> parts = [];
  int? cursor;
  bool gapBefore = false;
  bool settled = false;
  bool _pendingGap = false;

  /// Copyable output includes an explicit marker wherever retained runs are discontinuous.
  String get copyText => parts
      .map((part) => '${part.gapBefore ? gapMarker : ''}${part.text}')
      .join();

  void _append(String value, String? channel, bool gap) {
    if (value.isEmpty) return;
    final last = parts.isEmpty ? null : parts.last;
    if (!gap && last != null && last.channel == channel) {
      parts[parts.length - 1] = JobOutputPart(
        '${last.text}$value',
        channel: channel,
        gapBefore: last.gapBefore,
      );
    } else {
      parts.add(JobOutputPart(value, channel: channel, gapBefore: gap));
    }
    text += value;
    if (gap) gapBefore = true;
    _trim();
  }

  void _trim() {
    final characterCut = text.length > renderTailLimit
        ? text.length - renderTailLimit
        : 0;
    var partCut = 0;
    while (parts.length > renderPartLimit) {
      partCut += parts.first.text.length;
      parts.removeAt(0);
    }
    var cut = characterCut > partCut ? characterCut : partCut;
    if (cut == 0) return;
    if (cut > text.length) cut = text.length;
    if (cut < text.length) {
      final unit = text.codeUnitAt(cut);
      if (unit >= 0xdc00 && unit <= 0xdfff) cut++;
    }
    text = text.substring(cut);
    var remaining = cut - partCut;
    while (parts.isNotEmpty && remaining >= parts.first.text.length) {
      remaining -= parts.first.text.length;
      parts.removeAt(0);
    }
    if (parts.isNotEmpty) {
      final first = parts.first;
      parts[0] = JobOutputPart(
        first.text.substring(remaining),
        channel: first.channel,
        gapBefore: true,
      );
    } else {
      _pendingGap = true;
    }
    gapBefore = true;
  }

  void apply(Json frame) {
    switch (frame['type']) {
      case 'opened':
        job = frame['job'] as Json;
        final from = frame['from'] as int;
        final earliest = (job!['output'] as Json)['earliest'] as int;
        final missing =
            from < earliest ||
            (text.isEmpty && from > 0) ||
            (cursor != null && from > cursor!);
        gapBefore = gapBefore || missing;
        _pendingGap = _pendingGap || missing;
        cursor = from;
        settled = false;
      case 'output':
        final chunks = (frame['chunks'] as List).cast<Json>();
        _pendingGap = _pendingGap || frame['lossy'] == true;
        if (frame['lossy'] == true) gapBefore = true;
        for (final chunk in chunks) {
          final gap = _pendingGap || chunk['gapBefore'] == true;
          _append(chunk['text'] as String, chunk['channel'] as String?, gap);
          if ((chunk['text'] as String).isNotEmpty) _pendingGap = false;
        }
        cursor = frame['next'] as int;
      case 'status':
        job = frame['job'] as Json;
        settled = true;
      default:
        throw FormatException('Unsupported job frame: ${frame['type']}');
    }
  }
}

String jobStatusLabel(String status) => switch (status) {
  'running' => '运行中',
  'stopping' => '正在停止',
  'completed' => '已完成',
  'killed' => '已停止',
  'failed' => '执行失败',
  _ => status,
};
