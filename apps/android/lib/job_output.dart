import 'runtime.dart';

/// Mirrors DSH job.follow frames without consuming the Agent's output cursor.
class JobOutput {
  static const renderTailLimit = 128 * 1024;
  Json? job;
  String text = '';
  int? cursor;
  bool gapBefore = false;
  bool settled = false;

  void apply(Json frame) {
    switch (frame['type']) {
      case 'opened':
        job = frame['job'] as Json;
        final from = frame['from'] as int;
        final earliest = (job!['output'] as Json)['earliest'] as int;
        gapBefore = gapBefore || from < earliest || (text.isEmpty && from > 0);
        cursor = from;
        settled = false;
      case 'output':
        final chunks = (frame['chunks'] as List).cast<Json>();
        text += chunks.map((chunk) => chunk['text'] as String).join();
        gapBefore =
            gapBefore ||
            frame['lossy'] == true ||
            chunks.any((chunk) => chunk['gapBefore'] == true);
        if (text.length > renderTailLimit) {
          var cut = text.length - renderTailLimit;
          final unit = text.codeUnitAt(cut);
          if (unit >= 0xdc00 && unit <= 0xdfff) cut++;
          text = text.substring(cut);
          gapBefore = true;
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
