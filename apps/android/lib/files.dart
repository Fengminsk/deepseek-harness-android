import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';
import 'document_search.dart';

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
  String? error, confirmRevoke, notice;
  bool loading = false, choosing = false, revoking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !choosing && !revoking) {
      unawaited(load());
    }
  }

  Future<void> load() async {
    if (loading) return;
    setState(() => loading = true);
    try {
      final result = await widget.runtime.call(
        widget.root == null ? 'documents.roots' : 'documents.list',
        widget.root == null ? {} : {'root': widget.root, 'path': widget.path},
      );
      if (mounted) {
        setState(() {
          items = (result as List).cast<Json>();
          error = null;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => error = '无法读取授权文件，请重试或重新授权。\n$failure');
    } finally {
      if (mounted) setState(() => loading = false);
    }
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
    if (revoking || loading) return;
    setState(() => revoking = true);
    try {
      final result = await widget.runtime.call('documents.revoke', {
        'root': id,
      });
      if (result is! Map || result['revoked'] != true) {
        throw StateError('尚未确认授权已撤销，请刷新后重试');
      }
      if (!mounted) return;
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
      if (mounted) setState(() => error = '未能确认撤销结果，请刷新后重试。\n$failure');
    } finally {
      if (mounted) setState(() => revoking = false);
    }
  }

  Future<void> select(Json entry) async {
    final isGrant = widget.root == null;
    final root = isGrant ? entry['id'] as String : widget.root!;
    final path = isGrant
        ? ''
        : [if (widget.path.isNotEmpty) widget.path, entry['name']].join('/');
    await Navigator.push(
      context,
      PocketRoute<void>(
        builder: (_) => entry['directory'] == true
            ? FilesPage(runtime: widget.runtime, root: root, path: path)
            : TextFilePage(
                runtime: widget.runtime,
                root: root,
                path: path,
                name: entry['name'] as String,
              ),
      ),
    );
    if (mounted) await load();
  }

  void search(String root, String path, String name) {
    Navigator.of(context).push(
      PocketRoute<void>(
        builder: (_) => DocumentSearchPage(
          runtime: widget.runtime,
          root: root,
          path: path,
          name: name,
        ),
      ),
    );
  }

  Widget grant(Json entry) {
    final id = entry['id'] as String;
    final confirming = confirmRevoke == id;
    final available = entry['available'] != false;
    return PocketSection(
      children: [
        PocketRow(
          icon: entry['directory'] == true
              ? Icons.folder_outlined
              : Icons.description_outlined,
          title: '${entry['name']}',
          subtitle: available
              ? entry['directory'] == true
                    ? '目录 · 只读授权'
                    : '文件 · 只读授权'
              : '${entry['error'] ?? '授权项目暂不可用，请重试或重新授权。'}',
          onTap: available && !revoking ? () => select(entry) : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (confirming)
                const Text('撤销后，App 和 Agent 将无法继续通过此授权读取内容。已读取的内容不会被删除。'),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: confirming
                    ? [
                        PocketButton.tonal(
                          onPressed: revoking
                              ? null
                              : () => setState(() => confirmRevoke = null),
                          child: const Text('保留授权'),
                        ),
                        PocketButton(
                          onPressed: revoking || loading
                              ? null
                              : () => revoke(id),
                          child: Text(revoking ? '正在撤销' : '确认撤销'),
                        ),
                      ]
                    : [
                        if (available)
                          PocketButton.tonal(
                            key: ValueKey('search-$id'),
                            onPressed: loading || revoking
                                ? null
                                : () => search(id, '', '${entry['name']}'),
                            child: const Text('搜索文字'),
                          ),
                        if (!available)
                          PocketButton.tonal(
                            onPressed: loading ? null : load,
                            child: const Text('重试访问'),
                          ),
                        PocketButton.tonal(
                          key: ValueKey('revoke-$id'),
                          onPressed: revoking || loading
                              ? null
                              : () => setState(() => confirmRevoke = id),
                          child: const Text('撤销授权'),
                        ),
                      ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: Text(widget.path.isEmpty ? '授权文件' : widget.path),
    trailing: GlassButton(
      icon: Icons.refresh_rounded,
      label: '刷新授权文件',
      onPressed: loading || revoking ? null : load,
    ),
    bottom: widget.root != null
        ? null
        : Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            children: [
              PocketButton(
                glass: true,
                onPressed: choosing || revoking || loading
                    ? null
                    : () => choose(false),
                child: const Text('选择文件'),
              ),
              PocketButton.tonal(
                glass: true,
                onPressed: choosing || revoking || loading
                    ? null
                    : () => choose(true),
                child: const Text('授权目录'),
              ),
            ],
          ),
    body: PocketList(
      padding: const EdgeInsets.all(16),
      children: [
        if (notice != null)
          Padding(
            padding: const EdgeInsets.all(20),
            child: SelectableText(notice!),
          ),
        if (widget.root != null)
          PocketRow(
            icon: Icons.search_rounded,
            title: '搜索此目录的文字',
            subtitle: '包括已授权范围内的子目录',
            onTap: () => search(widget.root!, widget.path, '已授权目录'),
          ),
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
                  onPressed: loading ? null : load,
                  child: const Text('重试读取'),
                ),
              ),
            ],
          ),
        if (loading)
          const Padding(padding: EdgeInsets.all(20), child: Text('正在读取授权文件…')),
        if (items?.isEmpty == true && !loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('这里还没有文件。可以选择一个文件，或授权一个目录。'),
          ),
        for (final entry in items ?? <Json>[])
          if (widget.root == null)
            grant(entry)
          else
            PocketTile(
              leading: Icon(
                entry['directory'] == true
                    ? Icons.folder_outlined
                    : Icons.description_outlined,
              ),
              title: Text('${entry['name']}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => select(entry),
            ),
      ],
    ),
  );
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

  @override
  void initState() {
    super.initState();
    unawaited(load(0, 0));
  }

  /// Only a completed page changes navigation. Re-reading earlier pages keeps memory bounded.
  Future<void> load(int targetIndex, int offset) async {
    if (loading) return;
    setState(() {
      loading = true;
      retryIndex = targetIndex;
      retryOffset = offset;
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
      if (!mounted) return;
      setState(() {
        text = content;
        index = targetIndex;
        more = hasMore;
        error = null;
        starts.removeRange(targetIndex + 1, starts.length);
        if (hasMore) starts.add(next);
      });
      if (scroll.hasClients) scroll.jumpTo(0);
    } catch (failure) {
      if (mounted) setState(() => error = '读取未完成，已显示的内容仍保留。\n$failure');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
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
          onPressed: loading ? null : () => load(0, 0),
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
                onPressed: loading || index == 0
                    ? null
                    : () => load(index - 1, starts[index - 1]),
                child: const Text('上一段'),
              ),
              PocketButton(
                glass: true,
                onPressed: loading || !more
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
                  onPressed: loading
                      ? null
                      : () => load(retryIndex, retryOffset),
                  child: const Text('重试读取'),
                ),
              ),
            ],
          ),
        if (text != null) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text('第 ${index + 1} 段${more ? '' : ' · 文件末尾'}'),
          ),
          SelectableText(text!.isEmpty ? '文件为空。' : text!),
        ],
      ],
    ),
  );
}
