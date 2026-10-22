import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';
import 'confirmation.dart';
import 'document_search.dart';
import 'file_browser_chrome.dart';
import 'flclash/popup.dart';
import 'workspace_files.dart';

class FilesPage extends StatefulWidget {
  const FilesPage({
    required this.runtime,
    this.root,
    this.path = '',
    super.key,
  });
  final RuntimeController runtime;
  final String? root;
  final String path;
  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> with WidgetsBindingObserver {
  List<Json>? items;
  String? error, notice;
  Json? confirmRevoke;
  bool loading = false, choosing = false, revoking = false, menuOpen = false;
  bool current = false;
  int generation = 0;
  late int connection;
  late String phase;
  late String? activeRoot = widget.root;
  late String path = widget.path;
  String rootName = '授权目录';
  final scroll = ScrollController();
  final positions = <String, double>{};
  String get location => '${activeRoot ?? ''}:$path';
  String get directoryName => activeRoot == null
      ? '我的文件'
      : path.isEmpty
      ? rootName
      : path.split('/').last;

  @override
  void initState() {
    super.initState();
    connection = widget.runtime.connectionGeneration;
    phase = widget.runtime.phase;
    widget.runtime.addListener(runtimeChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(load());
  }

  void runtimeChanged() {
    if (connection == widget.runtime.connectionGeneration &&
        phase == widget.runtime.phase) {
      return;
    }
    connection = widget.runtime.connectionGeneration;
    phase = widget.runtime.phase;
    generation++;
    setState(() {
      current = false;
      loading = false;
      confirmRevoke = null;
    });
    if (widget.runtime.ready) unawaited(load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !choosing && !revoking) {
      unawaited(load());
    }
  }

  Future<void> load({double? restoreOffset}) async {
    if (loading || !widget.runtime.ready) return;
    final attempt = generation;
    final requestedRoot = activeRoot, requestedPath = path;
    setState(() => loading = true);
    try {
      final result = await widget.runtime.call(
        requestedRoot == null ? 'documents.roots' : 'documents.list',
        requestedRoot == null
            ? {}
            : {'root': requestedRoot, 'path': requestedPath},
      );
      if (mounted && attempt == generation) {
        setState(() {
          items = (result as List).cast<Json>();
          error = null;
          current = true;
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
      }
    } catch (failure) {
      if (mounted && attempt == generation) {
        setState(() {
          current = false;
          error = '无法读取授权文件，请重试或重新授权。\n$failure';
        });
      }
    } finally {
      if (mounted && attempt == generation) setState(() => loading = false);
    }
  }

  void navigate(String? root, String nextPath, {String? name}) {
    if (revoking || choosing) return;
    if (scroll.hasClients) positions[location] = scroll.offset;
    generation++;
    setState(() {
      activeRoot = root;
      path = nextPath;
      if (name != null) rootName = name;
      loading = false;
      current = false;
      items = null;
      error = null;
      notice = null;
      confirmRevoke = null;
    });
    if (scroll.hasClients) scroll.jumpTo(0);
    unawaited(load(restoreOffset: positions[location] ?? 0));
  }

  void back() {
    if (revoking) return;
    if (confirmRevoke != null) {
      if (!revoking) setState(() => confirmRevoke = null);
      return;
    }
    if (activeRoot == null) {
      Navigator.maybePop(context);
      return;
    }
    if (path.isEmpty) {
      navigate(null, '');
      return;
    }
    navigate(
      activeRoot,
      path.split('/').take(path.split('/').length - 1).join('/'),
    );
  }

  Future<void> choose(bool directory) async {
    if (choosing || revoking || loading) return;
    setState(() => choosing = true);
    try {
      final accepted = await RuntimeController.channel.invokeMethod<bool>(
        directory ? 'pickDirectory' : 'pickDocument',
      );
      if (mounted && accepted == true) await load();
    } catch (failure) {
      if (mounted) setState(() => error = '未能取得文件授权，请重新选择。\n$failure');
    } finally {
      if (mounted) setState(() => choosing = false);
    }
  }

  Future<void> revoke(String id) async {
    if (revoking || loading || !widget.runtime.ready || !current) return;
    final attempt = generation;
    setState(() => revoking = true);
    try {
      final result = await widget.runtime.call('documents.revoke', {
        'root': id,
      });
      if (result is! Map || result['revoked'] != true) {
        throw StateError('尚未确认授权已撤销，请刷新后重试');
      }
      if (!mounted || attempt != generation) return;
      setState(() {
        items?.removeWhere((entry) => entry['id'] == id);
        confirmRevoke = null;
        error = null;
        notice = result['searchesStopped'] == false
            ? '授权已撤销，已请求停止相关搜索。文件提供方尚未确认释放读取资源；这些搜索不会继续返回结果。'
            : null;
      });
      await load();
    } catch (failure) {
      if (mounted && attempt == generation) {
        setState(() => error = '未能确认撤销结果，请刷新后重试。\n$failure');
      }
    } finally {
      if (mounted) setState(() => revoking = false);
    }
  }

  Future<void> select(Json entry) async {
    if (!current ||
        !widget.runtime.ready ||
        revoking ||
        entry['available'] == false) {
      return;
    }
    final isGrant = activeRoot == null;
    final root = isGrant ? entry['id'] as String : activeRoot!;
    final target = isGrant
        ? ''
        : [if (path.isNotEmpty) path, entry['name']].join('/');
    if (entry['directory'] == true) {
      navigate(root, target, name: isGrant ? entry['name'] as String : null);
      return;
    }
    await Navigator.of(context).push(
      PocketRoute<void>(
        builder: (_) => TextFilePage(
          runtime: widget.runtime,
          root: root,
          path: target,
          name: entry['name'] as String,
        ),
      ),
    );
    if (mounted) unawaited(load());
  }

  void search(String root, String target, String name) {
    Navigator.of(context).push(
      PocketRoute<void>(
        builder: (_) => DocumentSearchPage(
          runtime: widget.runtime,
          root: root,
          path: target,
          name: name,
        ),
      ),
    );
  }

  Future<void> entryMenu(Json entry, Offset position) async {
    if (menuOpen || revoking || !current) return;
    menuOpen = true;
    final attempt = generation;
    final isGrant = activeRoot == null;
    final root = isGrant ? entry['id'] as String : activeRoot!;
    final target = isGrant
        ? ''
        : [if (path.isNotEmpty) path, entry['name']].join('/');
    final available = entry['available'] != false;
    final selected = await showFileBrowserMenu(context, [
      CommonPopupMenuItem(
        label: '打开',
        glyph: Icons.open_in_new_rounded,
        onPressed: available ? () {} : null,
      ),
      CommonPopupMenuItem(
        label: '搜索文字',
        glyph: Icons.search_rounded,
        onPressed: available ? () {} : null,
      ),
      CommonPopupMenuItem(
        label: '文件信息',
        glyph: Icons.info_outline_rounded,
        onPressed: () {},
      ),
      if (isGrant)
        CommonPopupMenuItem(
          label: '撤销授权',
          glyph: Icons.link_off_rounded,
          onPressed: () {},
        ),
    ], position: position);
    menuOpen = false;
    if (!mounted || attempt != generation || !current) return;
    switch (selected) {
      case 0:
        unawaited(select(entry));
      case 1:
        search(root, target, '${entry['name']}');
      case 2:
        info(
          '${entry['name']}',
          [
            if (target.isNotEmpty) target,
            entry['directory'] == true ? '目录 · 只读授权' : '文件 · 只读授权',
            if (!available) '${entry['error'] ?? '暂不可用'}',
          ].join('\n\n'),
        );
      case 3:
        setState(() => confirmRevoke = entry);
    }
  }

  void info(String title, String body) => Navigator.of(context).push(
    PocketRoute<void>(
      builder: (_) => PocketScaffold(
        title: Text(title),
        body: PocketList(
          children: [
            Padding(padding: const EdgeInsets.all(20), child: Text(body)),
          ],
        ),
      ),
    ),
  );

  Future<void> menu(BuildContext anchor, {bool add = false}) async {
    if (menuOpen) return;
    menuOpen = true;
    final attempt = generation;
    final selected = await showFileBrowserMenu(
      anchor,
      add
          ? [
              CommonPopupMenuItem(
                label: '选择文件',
                glyph: Icons.note_add_outlined,
                onPressed: choosing || loading ? null : () {},
              ),
              CommonPopupMenuItem(
                label: '授权目录',
                glyph: Icons.create_new_folder_outlined,
                onPressed: choosing || loading ? null : () {},
              ),
            ]
          : [
              CommonPopupMenuItem(
                label: '刷新授权文件',
                glyph: Icons.refresh_rounded,
                onPressed: loading || revoking || !widget.runtime.ready
                    ? null
                    : () {},
              ),
              CommonPopupMenuItem(
                label: '位置信息',
                glyph: Icons.info_outline_rounded,
                onPressed: () {},
              ),
            ],
    );
    menuOpen = false;
    if (!mounted || attempt != generation) return;
    if (add) {
      if (selected != null) unawaited(choose(selected == 1));
    } else if (selected == 0) {
      unawaited(load());
    } else if (selected == 1) {
      info(
        directoryName,
        activeRoot == null
            ? '工作区保存 Agent 使用和生成的文件。设备位置只显示你已授权的文件与目录。长按项目可以搜索或管理授权。'
            : '此位置来自 Android 文件授权。\n\n${path.isEmpty ? rootName : path}\n\nApp 与 Agent 只能读取授权范围，撤销授权不会删除文件。',
      );
    }
  }

  @override
  void dispose() {
    generation++;
    widget.runtime.removeListener(runtimeChanged);
    WidgetsBinding.instance.removeObserver(this);
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final crumbs = <FileBreadcrumb>[
      FileBreadcrumb(
        '我的文件',
        activeRoot == null ? null : () => navigate(null, ''),
      ),
      if (activeRoot != null)
        FileBreadcrumb(
          rootName,
          path.isEmpty ? null : () => navigate(activeRoot, ''),
        ),
      if (path.isNotEmpty)
        for (var i = 0; i < path.split('/').length; i++)
          FileBreadcrumb(
            path.split('/')[i],
            i == path.split('/').length - 1
                ? null
                : () => navigate(
                    activeRoot,
                    path.split('/').take(i + 1).join('/'),
                  ),
          ),
    ];
    return PopScope(
      canPop: activeRoot == null && confirmRevoke == null && !revoking,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) back();
      },
      child: PocketConfirmationLayer(
        confirmation: confirmRevoke == null
            ? null
            : PocketConfirmation(
                title: '撤销“${confirmRevoke!['name']}”的授权？',
                message: error ?? 'App 和 Agent 将无法继续通过此授权读取内容。已读取的内容和原文件不会被删除。',
                secondaryLabel: '保留授权',
                onSecondary: revoking
                    ? null
                    : () => setState(() => confirmRevoke = null),
                primaryLabel: revoking ? '正在撤销' : '确认撤销',
                onPrimary: revoking || loading || !current
                    ? null
                    : () => revoke(confirmRevoke!['id'] as String),
              ),
        child: Builder(
          builder: (pageContext) => FileBrowserChrome(
            title: directoryName,
            count: items == null
                ? (loading ? '正在读取…' : '尚未读取')
                : activeRoot == null
                ? '共 ${items!.length + 1} 个位置'
                : '共 ${items!.length} 项',
            breadcrumbs: crumbs,
            controller: scroll,
            onBack: back,
            onAdd: activeRoot == null
                ? (anchor) => menu(anchor, add: true)
                : null,
            onSearch: activeRoot == null || !current
                ? null
                : () => search(activeRoot!, path, directoryName),
            onMore: menu,
            children: [
              if (!current && items != null)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('显示上次读取的授权列表，当前状态尚未核实。'),
                ),
              if (!widget.runtime.ready)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('运行时尚未连接，连接恢复后重新读取。'),
                ),
              if (activeRoot == null)
                FileBrowserEntry(
                  name: 'App 私有文件',
                  detail: 'Pocket Harness',
                  directory: true,
                  onTap: () => Navigator.of(context).push(
                    PocketRoute<void>(
                      builder: (_) =>
                          WorkspaceFilesPage(runtime: widget.runtime),
                    ),
                  ),
                ),
              if (notice != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(notice!),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(error!),
                      PocketButton.tonal(
                        onPressed: loading ? null : load,
                        child: const Text('重试读取'),
                      ),
                    ],
                  ),
                ),
              if (loading)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('正在读取授权文件…'),
                ),
              if (current && items?.isEmpty == true && !loading)
                FileBrowserEmpty(
                  message: activeRoot == null ? '还没有设备文件' : '此目录为空。',
                  hint: activeRoot == null ? '点击上方加号添加文件或目录' : null,
                ),
              for (final entry in items ?? <Json>[])
                FileBrowserEntry(
                  key: ValueKey(
                    'file-entry-${activeRoot == null ? entry['id'] : '$activeRoot/$path/${entry['name']}'}',
                  ),
                  name: '${entry['name']}',
                  directory: entry['directory'] == true,
                  mediaType: entry['mediaType'] as String?,
                  detail: entry['available'] == false
                      ? '${entry['error'] ?? '暂不可用'}'
                      : [
                          if (entry['directory'] != true)
                            workspaceFileSize(entry['size'] as int?),
                          fileModifiedDate(entry['modifiedAt']),
                        ].where((part) => part.isNotEmpty).join('  |  '),
                  blocked: entry['available'] == false,
                  onTap:
                      current &&
                          widget.runtime.ready &&
                          !revoking &&
                          entry['available'] != false
                      ? () => select(entry)
                      : null,
                  onLongPress: current && !revoking
                      ? (position) => entryMenu(entry, position)
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class TextFilePage extends StatefulWidget {
  const TextFilePage({
    required this.runtime,
    required this.root,
    required this.path,
    this.name,
    super.key,
  });
  final RuntimeController runtime;
  final String root, path;
  final String? name;
  @override
  State<TextFilePage> createState() => _TextFilePageState();
}

class _TextFilePageState extends State<TextFilePage> {
  final scroll = ScrollController();
  final starts = <int>[0];
  String? text, error;
  int index = 0, retryIndex = 0, retryOffset = 0;
  bool more = false, loading = false;
  bool current = false, retryReset = false, retryPreserveScroll = false;
  int generation = 0;
  late int connection;
  late String phase;

  @override
  void initState() {
    super.initState();
    connection = widget.runtime.connectionGeneration;
    phase = widget.runtime.phase;
    widget.runtime.addListener(runtimeChanged);
    unawaited(load(0, 0));
  }

  void runtimeChanged() {
    if (connection == widget.runtime.connectionGeneration &&
        phase == widget.runtime.phase) {
      return;
    }
    connection = widget.runtime.connectionGeneration;
    phase = widget.runtime.phase;
    generation++;
    setState(() {
      current = false;
      loading = false;
      error = '连接已变化，已显示的内容尚未核实。请重新确认当前段或从头读取。';
      retryIndex = 0;
      retryOffset = starts[index];
      retryReset = true;
      retryPreserveScroll = true;
    });
  }

  /// Only a completed page changes navigation. Re-reading earlier pages keeps memory bounded.
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
      final result = await widget.runtime.call('documents.read', {
        'root': widget.root,
        'path': widget.path,
        'offset': offset,
      }) as Json;
      final next = result['nextOffset'] as int;
      final hasMore = result['truncated'] == true;
      final content = result['text'] as String;
      if (result['offset'] != offset ||
          next < offset ||
          (hasMore && next == offset)) {
        throw const FormatException('文件分段信息无效，请重新打开文件');
      }
      if (!mounted || attempt != generation) return;
      setState(() {
        text = content;
        index = targetIndex;
        more = hasMore;
        error = null;
        current = true;
        if (reset) {
          starts.clear();
          starts.add(offset);
        }
        starts.removeRange(targetIndex + 1, starts.length);
        if (hasMore) starts.add(next);
      });
      if (!preserveScroll && scroll.hasClients) scroll.jumpTo(0);
    } catch (failure) {
      if (mounted && attempt == generation) {
        setState(() => error = '读取未完成，已显示的内容仍保留。\n$failure');
      }
    } finally {
      if (mounted && attempt == generation) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    generation++;
    widget.runtime.removeListener(runtimeChanged);
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: Text(widget.name ?? (widget.path.isEmpty ? '文件内容' : widget.path)),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GlassButton(
          icon: Icons.search_rounded,
          label: '搜索此文件的文字',
          onPressed: () => Navigator.of(context).push(
            PocketRoute<void>(
              builder: (_) => DocumentSearchPage(
                runtime: widget.runtime,
                root: widget.root,
                path: widget.path,
                name: widget.name ?? '已授权文件',
              ),
            ),
          ),
        ),
        GlassButton(
          icon: Icons.refresh_rounded,
          label: '重新从头读取',
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
                onPressed: loading || !current || !widget.runtime.ready || !more
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
        if (loading) const Text('正在读取文件…'),
        if (error != null)
          PocketSection(
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: SelectableText(error!),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: PocketButton.tonal(
                  onPressed: loading || !widget.runtime.ready
                      ? null
                      : () => load(
                          retryIndex,
                          retryOffset,
                          reset: retryReset,
                          preserveScroll: retryPreserveScroll,
                        ),
                  child: Text(!current && text != null ? '重新确认当前段' : '重试读取'),
                ),
              ),
            ],
          ),
        if (text != null) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              '第 ${index + 1} 段${starts.first > 0 ? '（从上次阅读位置开始）' : ''}${more ? '' : ' · 文件末尾'}${current ? '' : ' · 尚未核实'}',
            ),
          ),
          SelectableText(text!.isEmpty ? '文件为空。' : text!),
        ],
      ],
    ),
  );
}
