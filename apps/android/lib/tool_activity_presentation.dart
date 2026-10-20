import 'runtime.dart';
import 'tool_activity_data.dart';

class ToolActivityPresentation {
  ToolActivityPresentation(this.kind, this.fields);
  final String kind;
  final Map<String, String> fields;

  factory ToolActivityPresentation.from(ToolActivity activity) {
    final args = activity.args;
    final result = activity.resultValue;
    final fields = <String, String>{};
    final name = activity.name;
    if (name == 'android_shell' ||
        name == 'bash' ||
        name == 'pwsh' ||
        name == 'terminal_send') {
      final command = args?[name == 'terminal_send' ? 'text' : 'command'];
      if (command is String) fields['命令'] = command;
      if (args?['workdir'] is String) {
        fields['工作目录（请求值）'] = args!['workdir'] as String;
      }
      if (activity.meta is Json && (activity.meta as Json)['cwd'] is String) {
        fields['工作目录（记录值）'] = (activity.meta as Json)['cwd'] as String;
      }
      if (name == 'android_shell' && result is Json) {
        if (result['stdout'] is String) {
          fields['stdout'] = result['stdout'] as String;
        }
        if (result['stderr'] is String) {
          fields['stderr'] = result['stderr'] as String;
        }
        fields['退出码'] = result['exitCode'] is num
            ? '${result['exitCode']}'
            : '未知或未取得';
        if (result['signal'] is String) {
          fields['终止信号'] = result['signal'] as String;
        }
        if (result['timedOut'] is bool) {
          fields['超时'] = result['timedOut'] == true ? '是' : '否';
        } else if (result['timeoutStatus'] == 'unconfirmed') {
          fields['超时'] = '未确认，无法确认截止时进程是否仍在运行';
        }
        if (result['cancelled'] is bool) {
          fields['取消'] = result['cancelled'] == true ? '是' : '否';
        }
        if (result['truncated'] == true) fields['输出范围'] = '运行时已截断输出，未保留部分不可恢复。';
      } else if (activity.hasResult && activity.resultText.isNotEmpty) {
        // Only show explicit shell status markers. Generic/persistent/spilled
        // output without one does not establish an exit code.
        fields['输出'] = activity.resultText;
        final exit = RegExp(r'\n\[exit code: (-?\d+|null)\]$')
            .firstMatch(activity.resultText);
        final signal = RegExp(r'\n\[killed by signal: ([^\]\n]+)\]$')
            .firstMatch(activity.resultText);
        if (exit != null) {
          fields['退出码'] = exit.group(1) == 'null' ? '未取得' : exit.group(1)!;
        }
        if (signal != null) fields['终止信号'] = signal.group(1)!;
      }
      return ToolActivityPresentation('shell', fields);
    }
    if (name == 'android_files') {
      if (args?['action'] is String) fields['文件操作'] = args!['action'] as String;
      if (args?['path'] is String) fields['相对路径'] = args!['path'] as String;
      if (args?['root'] is String) fields['授权项目'] = args!['root'] as String;
      if (result is Json) {
        if (result['text'] is String) fields['读取内容'] = result['text'] as String;
        if (result['offset'] is num) fields['起始偏移'] = '${result['offset']}';
        if (result['nextOffset'] is num) {
          fields['下次偏移'] = '${result['nextOffset']}';
        }
        if (result['truncated'] == true) fields['读取范围'] = '仅本次读取片段，后续内容需继续读取。';
      } else if (result is List) {
        fields['文件列表'] = result
            .whereType<Json>()
            .map(
              (entry) =>
                  '${entry['directory'] == true ? '目录' : '文件'} · ${entry['name'] ?? '名称未记录'}'
                  '${entry['available'] == false ? '（不可用）' : ''}',
            )
            .join('\n');
      }
      return ToolActivityPresentation('file', fields);
    }
    if (name == 'read' || name == 'grep' || name == 'glob') {
      final path = args?[name == 'read' ? 'file_path' : 'path'];
      if (path is String) fields['路径'] = path;
      if (args?['pattern'] is String) {
        fields['搜索表达式'] = args!['pattern'] as String;
      }
      if (args?['include'] is String) {
        fields['包含文件'] = args!['include'] as String;
      }
      final meta = activity.meta;
      if (meta is Json) {
        if (meta['path'] is String) fields['结果路径'] = meta['path'] as String;
        if (name == 'read' && meta['lines'] is List) {
          fields['读取内容'] = (meta['lines'] as List)
              .whereType<Json>()
              .where((line) => line['number'] is num && line['text'] is String)
              .map((line) => '${line['number']}: ${line['text']}')
              .join('\n');
          if (meta['totalLines'] is num) {
            fields['总行数'] = '${meta['totalLines']}';
          }
        }
        if (name == 'glob' && meta['paths'] is List) {
          fields['匹配路径'] = (meta['paths'] as List).whereType<String>().join(
            '\n',
          );
        }
        if (name == 'grep' && meta['files'] is List) {
          fields['匹配结果'] = (meta['files'] as List)
              .whereType<Json>()
              .map((file) {
                final matches = file['matches'];
                return '${file['path'] ?? '路径未记录'}\n${matches is List ? matches.whereType<Json>().map((line) => '${line['lineNumber']}: ${line['line']}').join('\n') : '匹配详情未记录'}';
              })
              .join('\n\n');
        }
        if (meta['total'] is num) fields['结果数'] = '${meta['total']}';
        if (meta['truncated'] == true) {
          fields['结果范围'] = '结果已截断，恢复位置如有提供可在完整原始详情查看。';
        }
      }
      if (activity.resultText.isNotEmpty &&
          !fields.containsKey('读取内容') &&
          !fields.containsKey('匹配路径') &&
          !fields.containsKey('匹配结果')) {
        fields['结果'] = activity.resultText;
      }
      return ToolActivityPresentation(
        name == 'read' ? 'file' : 'search',
        fields,
      );
    }
    return ToolActivityPresentation('other', fields);
  }
}

String toolActivityStatus(ToolActivity activity) => switch (activity.phase) {
  ToolActivityPhase.pending => '等待工具结果',
  ToolActivityPhase.completed => '已返回结果',
  ToolActivityPhase.failed => '调用失败',
  ToolActivityPhase.interrupted => '已中断',
  ToolActivityPhase.unknown => '调用信息不完整',
};
