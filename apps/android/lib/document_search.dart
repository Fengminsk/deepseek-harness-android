import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'package:dsh_android/files.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';

/// SAF literal search over one existing grant; selecting more files is a separate action.
class DocumentSearchPage extends StatefulWidget {
  const DocumentSearchPage({
    super.key,
    required this.runtime,
    required this.root,
    this.path = '',
    required this.name,
  });
  final RuntimeController runtime;
  final String root, path, name;
  @override
  State<DocumentSearchPage> createState() => _DocumentSearchPageState();
}

class _DocumentSearchPageState extends State<DocumentSearchPage> {
  final query = TextEditingController();
  String? requestId, error, notice, resultQuery;
  Json? result;
  bool caseSensitive = false,
      running = false,
      cancelling = false,
      leaving = false;
  bool resultCurrent = false;
  int operation = 0;
  late int connection;
  late String phase;

  @override
  void initState() {
    super.initState();
    connection = widget.runtime.connectionGeneration;
    phase = widget.runtime.phase;
    widget.runtime.addListener(runtimeChanged);
  }

  void runtimeChanged() {
    if (connection == widget.runtime.connectionGeneration &&
        phase == widget.runtime.phase) {
      return;
    }
    connection = widget.runtime.connectionGeneration;
    phase = widget.runtime.phase;
    operation++;
    setState(() {
      requestId = null;
      running = false;
      cancelling = false;
      leaving = false;
      resultCurrent = false;
      error = null;
      notice = '连接已变化，上一轮搜索状态尚未核实；这不表示搜索已停止。查询已保留，不会自动重新搜索。';
    });
  }

  static String newId() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<bool> stop(String id) async {
    final ack = await widget.runtime.call('documents.search.cancel', {
      'requestId': id,
    });
    if (ack is! Map || ack['cancelled'] != true) {
      throw StateError('文件提供方仍在停止搜索，尚未确认取消完成');
    }
    return true;
  }

  Future<void> search() async {
    if (requestId != null || cancelling || !widget.runtime.ready) return;
    final text = query.text;
    if (text.isEmpty ||
        text.length > 256 ||
        text.contains(RegExp(r'[\r\n\x00]'))) {
      setState(() => error = '请输入 1–256 个单行字符。');
      return;
    }
    final id = newId();
    final attempt = ++operation;
    bool current() => mounted && attempt == operation;
    setState(() {
      requestId = id;
      running = true;
      error = null;
      notice = null;
      result = null;
      resultQuery = text;
    });
    try {
      final value = await widget.runtime.call('documents.search', {
        'requestId': id,
        'root': widget.root,
        'path': widget.path,
        'query': text,
        'caseSensitive': caseSensitive,
      });
      if (!current() || requestId != id || cancelling) return;
      if (value is! Json ||
          value['matches'] is! List ||
          value['complete'] is! bool) {
        throw const FormatException('搜索返回了无法识别的结果');
      }
      setState(() {
        result = value;
        resultCurrent = true;
        requestId = null;
      });
    } catch (failure) {
      if (!current() || requestId != id || cancelling) return;
      var description = '搜索未完成，查询内容已保留。$failure';
      try {
        await stop(id);
      } catch (stopFailure) {
        description += '\n停止尚未确认，请重试停止：$stopFailure';
        if (current() && requestId == id && !cancelling) {
          setState(() => error = description);
        }
        return;
      }
      if (current() && requestId == id && !cancelling) {
        setState(() {
          requestId = null;
          error = description;
        });
      }
    } finally {
      if (current()) setState(() => running = false);
    }
  }

  Future<void> cancel({bool pop = false}) async {
    if (cancelling) return;
    final id = requestId;
    final attempt = operation;
    bool current() => mounted && attempt == operation;
    if (id == null) {
      if (pop) Navigator.of(context).pop();
      return;
    }
    setState(() {
      cancelling = true;
      error = null;
    });
    try {
      await stop(id);
      if (!current()) return;
      setState(() {
        requestId = null;
        running = false;
        notice = '搜索已取消，没有完成整个范围的检查。';
        leaving = pop;
      });
      if (pop) {
        // PopScope must publish the completed cancellation before allowing pop.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (current() && leaving) Navigator.of(context).pop();
        });
      }
    } catch (failure) {
      if (current()) setState(() => error = '尚未确认搜索已停止，请重试停止。\n$failure');
    } finally {
      if (current()) setState(() => cancelling = false);
    }
  }

  @override
  void dispose() {
    operation++;
    widget.runtime.removeListener(runtimeChanged);
    final id = requestId;
    if (id != null) {
      // Normal back navigation awaits cancellation. External route disposal has
      // no UI; Binder disconnect is the second cleanup path if this RPC fails.
      unawaited(stop(id).catchError((Object failure) => false));
    }
    query.dispose();
    super.dispose();
  }

  static String reason(String code) => switch (code) {
    'file_bytes' => '文件超过单文件字节上限',
    'total_bytes' => '达到总读取字节上限',
    'matches' => '达到匹配行数上限',
    'files' => '达到文件数量上限',
    'entries' => '达到目录项目数量上限',
    'depth' => '达到目录深度上限',
    'duration' => '达到搜索时间上限',
    'binary' => '包含二进制内容',
    'not_utf8' => '不是有效 UTF-8 文本',
    'changed' => '搜索期间文件已变化，请重试',
    'unavailable' => '文件已移动、删除或提供方暂不可用',
    'virtual_document' => '此虚拟文档不提供直接文本读取',
    'ambiguous_name' => '存在同名文件，无法唯一定位',
    'unsupported_name' => '名称无法通过当前相对路径表示',
    'path_length' => '子项目路径过长，请重新授权更近的子目录',
    'duplicate_document' => '提供方重复返回了同一文档',
    _ => code,
  };

  void openMatch(String path) {
    if (!resultCurrent || !widget.runtime.ready || requestId != null) return;
    // Match paths are already relative to the grant, including the search
    // subdirectory. The reader resolves the current persisted grant again.
    unawaited(
      Navigator.of(context).push<void>(
        PocketRoute<void>(
          builder: (_) => TextFilePage(
            runtime: widget.runtime,
            root: widget.root,
            path: path,
            name: path.isEmpty ? widget.name : path.split('/').last,
          ),
        ),
      ),
    );
  }

  Widget matchRow(Json match) {
    final path = match['path'];
    final canOpen = resultCurrent && widget.runtime.ready && path is String;
    return PocketTile(
      leading: const Icon(Icons.description_outlined),
      title: Text('${path == '' ? widget.name : path}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('第 ${match['lineNumber']} 行'),
          const SizedBox(height: 4),
          Text('${match['line']}'),
          if (match['previewTruncated'] == true) const Text('此行较长，仅显示匹配附近的片段。'),
        ],
      ),
      trailing: canOpen ? const Icon(Icons.chevron_right_rounded) : null,
      onTap: canOpen ? () => openMatch(path) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final matches = (result?['matches'] as List? ?? []).cast<Json>();
    final skipped = (result?['skipped'] as List? ?? []).cast<Json>();
    final limits = result?['limits'] as Json?;
    return PopScope(
      canPop: leaving || (requestId == null && !cancelling),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(cancel(pop: true));
      },
      child: PocketScaffold(
        title: const Text('搜索授权文本'),
        body: PocketList(
          children: [
            PocketSection(
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '范围：${widget.name}${widget.path.isEmpty ? '' : ' / ${widget.path}'}',
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '按字面查找 UTF-8 文本，不使用正则表达式。目录会包含子目录；不支持的文件和未完成的范围会明确列出。',
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: query,
                        decoration: const InputDecoration(labelText: '查找文字'),
                        onSubmitted: (_) => unawaited(search()),
                      ),
                      PocketSwitchRow(
                        title: const Text('区分大小写'),
                        value: caseSensitive,
                        onChanged: (value) =>
                            setState(() => caseSensitive = value),
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          PocketButton(
                            onPressed:
                                requestId != null ||
                                    cancelling ||
                                    !widget.runtime.ready
                                ? null
                                : search,
                            child: Text(running ? '正在搜索…' : '搜索'),
                          ),
                          if (requestId != null || cancelling)
                            PocketButton.tonal(
                              onPressed: cancelling ? null : () => cancel(),
                              child: Text(cancelling ? '正在停止…' : '停止搜索'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (error != null || notice != null)
              Padding(
                padding: const EdgeInsets.all(20),
                child: SelectableText(error ?? notice!),
              ),
            if (result != null) ...[
              if (!resultCurrent)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('下方保留上次搜索结果，当前文件状态尚未核实。'),
                ),
              PocketSection(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('“$resultQuery” · ${matches.length} 条匹配行'),
                        const SizedBox(height: 8),
                        Text(
                          result!['complete'] == true
                              ? matches.isEmpty
                                    ? '本次范围已查完，没有匹配。'
                                    : '本次范围已查完。'
                              : '本次只完成了部分检查，不能据此判断其余文件没有匹配。',
                        ),
                        if (result!['stoppedReason'] != null)
                          Text(reason('${result!['stoppedReason']}')),
                        Text(
                          '尝试扫描 ${result!['scannedFiles']} 个文件，读取 ${result!['bytesRead']} 字节。',
                        ),
                        if (limits != null)
                          Text(
                            '本次上限：单文件 ${limits['fileBytes']} 字节，总计 ${limits['totalBytes']} 字节，'
                            '${limits['maxFiles']} 个文件、${limits['maxEntries']} 个目录项目、'
                            '${limits['maxDepth']} 层、${limits['maxMatches']} 条匹配行、${limits['maxDurationMs']} 毫秒。',
                          ),
                        const SizedBox(height: 8),
                        const Text('搜索会核对提供方返回的文件信息；结果不是文件系统快照。'),
                        if (matches.isNotEmpty)
                          const Text('点开结果可从头阅读当前文件；搜索行号不会自动定位。'),
                      ],
                    ),
                  ),
                ],
              ),
              if (matches.isNotEmpty)
                PocketSection(
                  title: '匹配内容',
                  children: matches.map(matchRow).toList(),
                ),
              if (skipped.isNotEmpty)
                PocketDisclosure(
                  title:
                      '${result!['skippedCount'] ?? skipped.length} 个项目未完成检查',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (result!['skippedTruncated'] == true)
                        const Text('这里只列出前 100 个未完成项目，请缩小范围重试。'),
                      for (final item in skipped)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: SelectableText(
                            '${item['path'] == '' ? widget.name : item['path']}：${reason('${item['reason']}')}',
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
