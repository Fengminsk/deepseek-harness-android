import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';
import 'file_browser_chrome.dart';
import 'external_file_action.dart';
import 'flclash/popup.dart';

String workspaceFileFailure(Object error) => error is PlatformException
    ? error.message ?? '读取未完成，请刷新后重试。错误：${error.code}'
    : error is TimeoutException
    ? '读取超时，已显示内容保留。请刷新后重试。'
    : '返回内容未能确认，已显示内容保留。请刷新后重试。';

String workspaceFileSize(int? bytes) => bytes == null
    ? ''
    : bytes < 1024
    ? '$bytes B'
    : bytes < 1048576
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / 1048576).toStringAsFixed(1)} MB';

String workspaceSkipReason(String? reason) => switch (reason) {
  'symlink' => '符号链接不在此入口的读取范围内',
  'not-text' => '非 UTF-8 文本或包含二进制内容',
  'file-bytes' => '超过单个搜索文件的字节预算',
  'total-bytes' => '达到搜索总字节预算',
  'entries' => '达到搜索项目数量预算',
  'files' => '达到搜索文件数量预算',
  'matches' => '达到搜索结果数量预算',
  'depth' => '达到搜索目录深度预算',
  'duration' => '达到搜索时间预算',
  'not-found' => '路径已不存在',
  'changed' => '读取期间内容或路径已变化',
  'unsupported-name' => '名称不能通过此相对路径入口访问',
  'not-regular-file' => '不是普通文件或目录',
  'outside-workspace' => '路径不在 App 私有工作区内',
  _ => '暂时无法读取',
};

Future<Json> _call(
  RuntimeController runtime,
  String method, [
  Json params = const {},
  Duration timeout = const Duration(seconds: 30),
]) async {
  final value = await runtime
      .call('workspace.files.$method', params)
      .timeout(timeout);
  if (value is! Json) throw const FormatException('Invalid workspace response');
  return value;
}

/// Browses the runtime-provided workspace without accepting an arbitrary root.
class WorkspaceFilesPage extends StatefulWidget {
  const WorkspaceFilesPage({required this.runtime, this.path = '', super.key});
  final RuntimeController runtime;
  final String path;
  @override
  State<WorkspaceFilesPage> createState() => _WorkspaceFilesPageState();
}

class _WorkspaceFilesPageState extends State<WorkspaceFilesPage>
    with WidgetsBindingObserver {
  final externalOpen = ExternalFileOpenController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    externalOpen.observeRoute(context);
  }

  List<Json> entries = [];
  String? root, version, error;
  int? nextOffset;
  bool loading = false, current = false, truncated = false, menuOpen = false;
  int generation = 0;
  late String phase;
  late int connection;
  late String path = widget.path;
  final scroll = ScrollController();
  final positions = <String, double>{};
  final loadedCounts = <String, int>{};

  @override
  void initState() {
    super.initState();
    phase = widget.runtime.phase;
    connection = widget.runtime.connectionGeneration;
    widget.runtime.addListener(runtimeChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(load());
  }

  void runtimeChanged() {
    if (phase == widget.runtime.phase &&
        connection == widget.runtime.connectionGeneration) {
      return;
    }
    phase = widget.runtime.phase;
    connection = widget.runtime.connectionGeneration;
    generation++;
    setState(() {
      current = false;
      loading = false;
    });
    if (widget.runtime.ready) unawaited(load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(load());
  }

  Future<void> load({bool more = false, double? restoreOffset}) async {
    if (loading ||
        !widget.runtime.ready ||
        more && (!current || nextOffset == null)) {
      return;
    }
    final attempt = generation, requestedPath = path;
    final requestedOffset = more ? nextOffset! : 0;
    final requestedVersion = version;
    final targetCount = more
        ? 0
        : max(loadedCounts[requestedPath] ?? 0, entries.length);
    setState(() => loading = true);
    try {
      var result = await _call(widget.runtime, 'list', {
        'path': requestedPath,
        'offset': requestedOffset,
        if (more) 'version': requestedVersion,
      });
      if (!mounted || attempt != generation) return;
      if (result['path'] != requestedPath ||
          result['root'] is! String ||
          result['version'] is! String ||
          result['offset'] != requestedOffset ||
          more && result['version'] != requestedVersion) {
        throw const FormatException('Unexpected directory');
      }
      final rows = List<Json>.from((result['entries'] as List).cast<Json>());
      var next = result['nextOffset'] as int?;
      if (next != null && next <= requestedOffset) {
        throw const FormatException('Invalid directory continuation');
      }
      final directoryVersion = result['version'];
      final directoryRoot = result['root'];
      while (!more && next != null && rows.length < targetCount) {
        final continuation = next;
        result = await _call(widget.runtime, 'list', {
          'path': requestedPath,
          'offset': continuation,
          'version': directoryVersion,
        });
        if (!mounted || attempt != generation) return;
        if (result['path'] != requestedPath ||
            result['root'] != directoryRoot ||
            result['version'] != directoryVersion ||
            result['offset'] != continuation) {
          throw const FormatException(
            'Directory changed while restoring position',
          );
        }
        rows.addAll((result['entries'] as List).cast<Json>());
        next = result['nextOffset'] as int?;
        if (next != null && next <= continuation) {
          throw const FormatException('Invalid directory continuation');
        }
      }
      setState(() {
        entries = [if (more) ...entries, ...rows];
        loadedCounts[requestedPath] = entries.length;
        root = result['root'] as String;
        version = result['version'] as String;
        nextOffset = next;
        truncated = result['truncated'] == true;
        current = true;
        error = null;
      });
      if (restoreOffset != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && attempt == generation && scroll.hasClients) {
            scroll.jumpTo(
              restoreOffset.clamp(0, scroll.position.maxScrollExtent),
            );
          }
        });
      }
    } catch (failure) {
      if (mounted && attempt == generation) {
        setState(() {
          current = false;
          error = workspaceFileFailure(failure);
        });
      }
    } finally {
      if (mounted && attempt == generation) setState(() => loading = false);
    }
  }

  void navigate(String target) {
    externalOpen.cancel();
    if (scroll.hasClients) positions[path] = scroll.offset;
    if (current) loadedCounts[path] = entries.length;
    generation++;
    setState(() {
      path = target;
      entries = [];
      version = null;
      nextOffset = null;
      error = null;
      current = false;
      loading = false;
      truncated = false;
    });
    if (scroll.hasClients) scroll.jumpTo(0);
    unawaited(load(restoreOffset: positions[path] ?? 0));
  }

  void back() {
    if (path.isEmpty) {
      Navigator.maybePop(context);
      return;
    }
    navigate(path.split('/').take(path.split('/').length - 1).join('/'));
  }

  Future<void> open(Json row) async {
    if (!current || !widget.runtime.ready) return;
    final target = row['path'] as String?;
    if (target == null || row['blockedReason'] != null) return;
    if (row['kind'] == 'directory') {
      navigate(target);
      return;
    }
    if (!fileLikelyText(
      '${row['name']}',
      mimeType: row['mediaType'] as String?,
    )) {
      await externalOpen.open(context, path: target);
      return;
    }
    await Navigator.of(context).push(
      PocketRoute<void>(
        builder: (_) =>
            WorkspaceTextPage(runtime: widget.runtime, path: target),
      ),
    );
    if (mounted) unawaited(load());
  }

  void search() => Navigator.push<void>(
    context,
    PocketRoute<void>(
      builder: (_) => WorkspaceSearchPage(runtime: widget.runtime, path: path),
    ),
  );

  Future<void> menu(BuildContext anchor) async {
    if (menuOpen) return;
    menuOpen = true;
    final attempt = generation;
    final selected = await showFileBrowserMenu(anchor, [
      CommonPopupMenuItem(
        label: '刷新工作区目录',
        glyph: Icons.refresh_rounded,
        onPressed: loading || !widget.runtime.ready ? null : () {},
      ),
      CommonPopupMenuItem(
        label: '位置信息',
        glyph: Icons.info_outline_rounded,
        onPressed: () {},
      ),
    ]);
    menuOpen = false;
    if (!mounted || attempt != generation) return;
    if (selected == 0) unawaited(load());
    if (selected == 1) {
      Navigator.push<void>(
        context,
        PocketRoute<void>(
          builder: (_) => PocketScaffold(
            title: const Text('位置信息'),
            body: PocketList(
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    '${root ?? '连接服务后显示实际路径'}${path.isEmpty ? '' : '\n$path'}\n\n此入口浏览 App 的工作区文件。符号链接不跟随，设备上的其他文件需要先授权。',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    externalOpen.dispose();
    generation++;
    widget.runtime.removeListener(runtimeChanged);
    WidgetsBinding.instance.removeObserver(this);
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: path.isEmpty,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) back();
    },
    child: FileBrowserChrome(
      title: path.isEmpty ? 'App 私有文件' : path.split('/').last,
      count: version == null
          ? (loading ? '正在读取…' : '尚未读取')
          : '${nextOffset != null || truncated ? '已载入' : '共'} ${entries.length} 项${!current ? ' · 待刷新' : ''}',
      breadcrumbs: [
        FileBreadcrumb('App 私有文件', path.isEmpty ? null : () => navigate('')),
        if (path.isNotEmpty)
          for (var i = 0; i < path.split('/').length; i++)
            FileBreadcrumb(
              path.split('/')[i],
              i == path.split('/').length - 1
                  ? null
                  : () => navigate(path.split('/').take(i + 1).join('/')),
            ),
      ],
      controller: scroll,
      onBack: back,
      onMore: menu,
      onSearch: widget.runtime.ready ? search : null,
      children: [
        if (!current && entries.isNotEmpty) const _Note('显示上次读取的目录，当前状态未确认。'),
        if (!widget.runtime.ready) const _Note('运行时尚未连接，稍后重试。'),
        if (error != null) _ErrorNotice(error!, onRetry: loading ? null : load),
        if (loading) const _Note('正在读取工作区…'),
        if (current && entries.isEmpty && !loading) const FileBrowserEmpty(),
        for (final row in entries)
          FileBrowserEntry(
            key: ValueKey(
              'workspace-entry-${row['path'] ?? '$path/${row['name']}'}',
            ),
            name: '${row['name']}',
            directory: row['kind'] == 'directory',
            blocked: row['blockedReason'] != null,
            mediaType: row['mediaType'] as String?,
            detail: row['blockedReason'] != null
                ? workspaceSkipReason(row['blockedReason'] as String?)
                : [
                    if (row['kind'] != 'directory')
                      workspaceFileSize(row['bytes'] as int?),
                    fileModifiedDate(row['modifiedAt']),
                  ].where((part) => part.isNotEmpty).join('  |  '),
            onTap:
                current &&
                    widget.runtime.ready &&
                    row['path'] is String &&
                    row['blockedReason'] == null
                ? () => open(row)
                : null,
          ),
        if (nextOffset != null)
          PocketButton.tonal(
            onPressed: loading || !current ? null : () => load(more: true),
            child: const Text('更多目录项目'),
          ),
        if (truncated) const _Note('目录项目达到读取预算，当前列表不完整。可使用目录搜索并查看其扫描范围。'),
      ],
    ),
  );
}

class WorkspaceTextPage extends StatefulWidget {
  const WorkspaceTextPage({
    required this.runtime,
    required this.path,
    this.offset = 0,
    this.version,
    super.key,
  });
  final RuntimeController runtime;
  final String path;
  final int offset;
  final String? version;
  @override
  State<WorkspaceTextPage> createState() => _WorkspaceTextPageState();
}

class _WorkspaceTextPageState extends State<WorkspaceTextPage> {
  final externalOpen = ExternalFileOpenController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    externalOpen.observeRoute(context);
  }

  final scroll = ScrollController();
  late final List<int> starts = [widget.offset];
  String? text, error, version, root;
  int index = 0, bytes = 0, retryIndex = 0, retryOffset = 0;
  bool loading = false, eof = true, retryReset = false;
  bool current = false, retryPreserveScroll = false;
  bool openingExternal = false;
  int generation = 0;
  late String phase;
  late int connection;

  @override
  void initState() {
    super.initState();
    phase = widget.runtime.phase;
    connection = widget.runtime.connectionGeneration;
    version = widget.version;
    widget.runtime.addListener(runtimeChanged);
    unawaited(load(0, widget.offset));
  }

  void runtimeChanged() {
    if (phase == widget.runtime.phase &&
        connection == widget.runtime.connectionGeneration) {
      return;
    }
    phase = widget.runtime.phase;
    connection = widget.runtime.connectionGeneration;
    generation++;
    setState(() {
      loading = false;
      current = false;
      error = '连接已变化，已显示的内容尚未核实。请重新确认当前段或从头读取。';
      retryIndex = 0;
      retryOffset = starts[index];
      retryReset = true;
      retryPreserveScroll = true;
    });
  }

  Future<void> load(
    int targetIndex,
    int offset, {
    bool reset = false,
    bool preserveScroll = false,
  }) async {
    if (loading || !widget.runtime.ready) return;
    final attempt = generation;
    setState(() {
      loading = true;
      retryIndex = targetIndex;
      retryOffset = offset;
      retryReset = reset;
      retryPreserveScroll = preserveScroll;
    });
    try {
      final result = await _call(widget.runtime, 'read', {
        'path': widget.path,
        'offset': offset,
        if (!reset && version != null) 'version': version,
      });
      if (!mounted || attempt != generation) return;
      final next = result['nextOffset'] as int;
      final end = result['eof'] as bool;
      if (result['path'] != widget.path ||
          result['offset'] != offset ||
          next < offset ||
          !end && next == offset ||
          result['version'] is! String) {
        throw const FormatException('Invalid file continuation');
      }
      setState(() {
        text = result['text'] as String;
        version = result['version'] as String;
        root = result['root'] as String;
        bytes = result['bytes'] as int;
        index = targetIndex;
        eof = end;
        error = null;
        current = true;
        if (reset) {
          starts.clear();
          starts.add(offset);
        }
        starts.removeRange(targetIndex + 1, starts.length);
        if (!end) starts.add(next);
      });
      if (!preserveScroll && scroll.hasClients) scroll.jumpTo(0);
    } catch (failure) {
      if (mounted && attempt == generation) {
        setState(() => error = workspaceFileFailure(failure));
      }
    } finally {
      if (mounted && attempt == generation) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    externalOpen.dispose();
    generation++;
    widget.runtime.removeListener(runtimeChanged);
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: Text(
      widget.path.split('/').last,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GlassButton(
          icon: Icons.open_in_new_rounded,
          label: '在其他应用中打开',
          onPressed: openingExternal
              ? null
              : () async {
                  setState(() => openingExternal = true);
                  await externalOpen.open(context, path: widget.path);
                  if (mounted) setState(() => openingExternal = false);
                },
        ),
        GlassButton(
          icon: Icons.refresh_rounded,
          label: '从头重新读取工作区文件',
          onPressed: loading || !widget.runtime.ready
              ? null
              : () => load(0, 0, reset: true),
        ),
      ],
    ),
    bottom: text == null
        ? null
        : Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            children: [
              PocketButton.tonal(
                glass: true,
                onPressed:
                    loading || !current || !widget.runtime.ready || index == 0
                    ? null
                    : () => load(index - 1, starts[index - 1]),
                child: const Text('上一段'),
              ),
              PocketButton(
                glass: true,
                onPressed: loading || !current || !widget.runtime.ready || eof
                    ? null
                    : () => load(index + 1, starts[index + 1]),
                child: const Text('下一段'),
              ),
            ],
          ),
    body: PocketList(
      controller: scroll,
      padding: const EdgeInsets.all(20),
      children: [
        PocketSection(
          children: [
            _Note('${root ?? 'App 私有工作区'}\n${widget.path}'),
            if (text != null)
              _Note(
                '${workspaceFileSize(bytes)} · 第 ${index + 1} 段'
                '${starts.first > 0 ? '（从指定位置开始）' : ''}${eof ? ' · 文件末尾' : ''}${current ? '' : ' · 尚未核实'}',
              ),
            PocketRow(
              icon: Icons.search_rounded,
              title: '搜索此文件的内容',
              onTap: !widget.runtime.ready
                  ? null
                  : () => Navigator.push<void>(
                      context,
                      PocketRoute<void>(
                        builder: (_) => WorkspaceSearchPage(
                          runtime: widget.runtime,
                          path: widget.path,
                          contentOnly: true,
                        ),
                      ),
                    ),
            ),
          ],
        ),
        if (loading) const _Note('正在读取文件…'),
        if (error != null)
          _ErrorNotice(
            error!,
            retryLabel: !current && text != null ? '重新确认当前段' : '重试读取',
            onRetry: loading || !widget.runtime.ready
                ? null
                : () => load(
                    retryIndex,
                    retryOffset,
                    reset: retryReset,
                    preserveScroll: retryPreserveScroll,
                  ),
          ),
        if (text != null) SelectableText(text!.isEmpty ? '文件为空。' : text!),
      ],
    ),
  );
}

class WorkspaceSearchPage extends StatefulWidget {
  const WorkspaceSearchPage({
    required this.runtime,
    this.path = '',
    this.contentOnly = false,
    super.key,
  });
  final RuntimeController runtime;
  final String path;
  final bool contentOnly;
  @override
  State<WorkspaceSearchPage> createState() => _WorkspaceSearchPageState();
}

class _WorkspaceSearchPageState extends State<WorkspaceSearchPage> {
  final query = TextEditingController();
  late String mode = widget.contentOnly ? 'content' : 'name';
  String? requestId, error, notice, submittedQuery;
  Json? result;
  bool caseSensitive = false, cancelling = false, leaving = false;
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
      cancelling = false;
      leaving = false;
      resultCurrent = false;
      error = null;
      notice = '连接已变化，上一轮搜索状态尚未核实；这不表示搜索已停止。查询已保留，不会自动重新搜索。';
    });
  }

  String newId() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> search() async {
    if (requestId != null || !widget.runtime.ready) return;
    final text = query.text;
    if (text.isEmpty ||
        text.length > 256 ||
        RegExp(r'[\r\n\x00]').hasMatch(text)) {
      setState(() => error = '请输入 1–256 个单行字符。');
      return;
    }
    final id = newId(), selectedMode = mode;
    final attempt = ++operation;
    bool current() => mounted && attempt == operation;
    final sensitive = caseSensitive;
    setState(() {
      requestId = id;
      error = null;
      notice = null;
      submittedQuery = text;
    });
    try {
      final info = await _call(widget.runtime, 'info');
      if (!current() || requestId != id || cancelling) return;
      final duration =
          (info['limits'] as Json)['search']['maxDurationMs'] as int;
      final response = await _call(widget.runtime, 'search', {
        'requestId': id,
        'path': widget.path,
        'query': text,
        'mode': selectedMode,
        'caseSensitive': sensitive,
      }, Duration(milliseconds: duration + 5000));
      if (!current() || requestId != id || cancelling) return;
      if (response['matches'] is! List ||
          response['skipped'] is! List ||
          response['complete'] is! bool) {
        throw const FormatException('Invalid search result');
      }
      setState(() {
        result = response;
        resultCurrent = true;
        requestId = null;
      });
    } catch (failure) {
      if (!current() || requestId != id || cancelling) return;
      final description = workspaceFileFailure(failure);
      try {
        await stop(id);
        if (current() && requestId == id && !cancelling) {
          setState(() {
            requestId = null;
            error = description;
          });
        }
      } catch (stopFailure) {
        if (current() && requestId == id && !cancelling) {
          setState(() => error = '$description\n停止尚未确认，请重试停止搜索。');
        }
      }
    }
  }

  Future<void> stop(String id) async {
    final ack = await _call(widget.runtime, 'search.cancel', {
      'requestId': id,
    }, const Duration(seconds: 10));
    if (ack['cancelled'] != true) {
      throw const FormatException('Unconfirmed stop');
    }
  }

  Future<void> cancel({bool pop = false}) async {
    if (cancelling) return;
    final id = requestId;
    final attempt = operation;
    bool current() => mounted && attempt == operation;
    if (id == null) {
      if (pop) Navigator.pop(context);
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
        notice = '搜索已停止，未完成整个范围的检查。';
        leaving = pop;
      });
      if (pop) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (current() && leaving) Navigator.pop(context);
        });
      }
    } catch (failure) {
      if (current()) setState(() => error = '停止尚未确认，请重试停止搜索。');
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
      unawaited(
        stop(id).catchError((Object failure) {
          // A forced route disposal cannot show errors. Runtime bounds and
          // service close retain ownership even if this final request fails.
        }),
      );
    }
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matches = (result?['matches'] as List? ?? []).cast<Json>();
    final skipped = (result?['skipped'] as List? ?? []).cast<Json>();
    return PopScope(
      canPop: leaving || requestId == null && !cancelling,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(cancel(pop: true));
      },
      child: PocketScaffold(
        title: const Text('搜索工作区'),
        body: PocketList(
          padding: const EdgeInsets.all(20),
          children: [
            PocketSection(
              children: [
                _Note('范围：${widget.path.isEmpty ? 'App 私有工作区' : widget.path}'),
                const _Note('按字面匹配，不使用正则表达式。符号链接不跟随；未完成的范围会单独列出。'),
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: TextField(
                    key: const Key('workspace-search-query'),
                    controller: query,
                    decoration: const InputDecoration(labelText: '查找文字'),
                    onSubmitted: (_) => unawaited(search()),
                  ),
                ),
                if (!widget.contentOnly)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final value in ['name', 'content'])
                          PocketChoice(
                            label: Text(value == 'name' ? '文件名' : '文本内容'),
                            selected: mode == value,
                            onSelected: requestId != null
                                ? null
                                : (_) => setState(() => mode = value),
                          ),
                      ],
                    ),
                  ),
                PocketSwitchRow(
                  title: const Text('区分大小写'),
                  value: caseSensitive,
                  onChanged: requestId != null
                      ? null
                      : (value) => setState(() => caseSensitive = value),
                ),
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      PocketButton(
                        key: const Key('workspace-start-search'),
                        onPressed:
                            requestId != null ||
                                cancelling ||
                                !widget.runtime.ready
                            ? null
                            : search,
                        child: Text(requestId == null ? '搜索' : '正在搜索…'),
                      ),
                      if (requestId != null)
                        PocketButton.tonal(
                          key: const Key('workspace-stop-search'),
                          onPressed: cancelling ? null : () => cancel(),
                          child: Text(cancelling ? '正在停止…' : '停止搜索'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (error != null) _Note(error!),
            if (notice != null) _Note(notice!),
            if (requestId != null && result != null)
              const _Note('下方保留上一次完成的结果。'),
            if (result != null && !resultCurrent)
              const _Note('下方保留上次搜索结果，当前文件状态尚未核实。'),
            if (result != null) ...[
              PocketSection(
                children: [
                  _Note('“${result!['query']}” · ${matches.length} 项结果'),
                  _Note(
                    result!['complete'] == true
                        ? '已完成本次范围的检查。'
                        : '搜索范围未全部检查，不能据此判断其他位置没有匹配。',
                  ),
                  if (result!['stoppedBy'] != null)
                    _Note(workspaceSkipReason(result!['stoppedBy'] as String?)),
                ],
              ),
              for (final hit in matches)
                PocketSection(
                  children: [
                    PocketRow(
                      icon: hit['kind'] == 'directory'
                          ? Icons.folder_outlined
                          : Icons.description_outlined,
                      title: '${hit['path']}',
                      subtitle: hit['line'] == null
                          ? '名称匹配'
                          : '第 ${hit['line']} 行 · ${hit['preview']}',
                      onTap:
                          !resultCurrent ||
                              !widget.runtime.ready ||
                              !['file', 'directory'].contains(hit['kind'])
                          ? null
                          : () => Navigator.push<void>(
                              context,
                              PocketRoute<void>(
                                builder: (_) => hit['kind'] == 'directory'
                                    ? WorkspaceFilesPage(
                                        runtime: widget.runtime,
                                        path: hit['path'] as String,
                                      )
                                    : WorkspaceTextPage(
                                        runtime: widget.runtime,
                                        path: hit['path'] as String,
                                        offset: hit['offset'] as int? ?? 0,
                                        version: hit['version'] as String?,
                                      ),
                              ),
                            ),
                    ),
                  ],
                ),
              if (skipped.isNotEmpty)
                PocketSection(
                  title: '未检查的项目',
                  children: [
                    for (final item in skipped)
                      PocketRow(
                        icon: Icons.info_outline_rounded,
                        title: '${item['path']}',
                        subtitle: workspaceSkipReason(
                          item['reason'] as String?,
                        ),
                      ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    child: SelectableText(text),
  );
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice(this.text, {this.onRetry, this.retryLabel = '重试读取'});
  final String text;
  final String retryLabel;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => PocketSection(
    children: [
      _Note(text),
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
        child: PocketButton.tonal(onPressed: onRetry, child: Text(retryLabel)),
      ),
    ],
  );
}
