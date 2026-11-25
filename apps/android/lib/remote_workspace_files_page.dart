// 电脑文件：只读浏览那台已连接电脑上的工作区文件。
//
// 页面外观沿用本地文件浏览的 [FileBrowserChrome]（返回上级、面包屑、浮动头部），
// 数据来自注入的 [RemoteDshFilesSource]：生产实现是 `RemoteDshLiveSource`
// （`workspace.files.list` / `workspace.files.read`），测试可以注入替身，因此本页
// 不认识门面方法名，也不发任何写请求。
//
// 能力门控按协议 §10.2：数据源报告的能力不是「可用」时，整页只显示原因，不出现
// 能点但没用的入口。目录分页用 `nextOffset` 续读；文本文件在独立的全屏目的地里
// 分段读取，`加载更多` 继续读下一段，读完后按钮消失。

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'file_browser_chrome.dart';
import 'design/popup.dart';
import 'design/typography.dart';
import 'remote_dsh_live_source.dart';
import 'ui.dart';

/// 电脑文件页。
///
/// [source] 提供目录列表与文本读取；[initialPath] 用于从其它地方直接落到某个子
/// 目录（当前只有测试与后续搜索入口使用）。页面不持有连接，也不负责重连：连接
/// 断开后的失败会以可重试的错误提示展示。
class RemoteWorkspaceFilesPage extends StatefulWidget {
  const RemoteWorkspaceFilesPage({
    super.key,
    required this.source,
    this.initialPath = '',
  });

  /// 本页作为全屏目的地的标识（见 [openDestination]）。
  static const String routeDestination = 'remote-workspace-files';

  /// 只读文件数据来源。
  final RemoteDshFilesSource source;

  /// 打开时所在的相对路径；'' 表示工作区根目录。
  final String initialPath;

  @override
  State<RemoteWorkspaceFilesPage> createState() =>
      _RemoteWorkspaceFilesPageState();
}

class _RemoteWorkspaceFilesPageState extends State<RemoteWorkspaceFilesPage> {
  final _scroll = ScrollController();

  /// 能力状态在页面打开时取一次：连接变化后新的失败会以错误提示出现。
  late final RemoteDshCapability _capability = widget.source.filesCapability;

  late String _path = widget.initialPath;

  List<RemoteDshFileEntry> _entries = const <RemoteDshFileEntry>[];
  String? _root;
  String? _version;
  String? _error;
  int? _nextOffset;
  bool _truncated = false;
  bool _loading = false;
  bool _loadingMore = false;
  bool _loaded = false;

  /// 目录/页面的代际：切换目录或重读后，迟到的旧结果直接丢弃。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (_capability.isAvailable) unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    _scroll.dispose();
    super.dispose();
  }

  /// 读取目录；[more] 为 true 时用上一页的 `nextOffset` 与 `version` 续页。
  Future<void> _load({bool more = false}) async {
    if (_loading || !_capability.isAvailable) return;
    if (more && (_nextOffset == null || _version == null)) return;
    final attempt = _generation;
    final requestedPath = _path;
    final requestedOffset = more ? _nextOffset! : 0;
    final requestedVersion = more ? _version : null;
    setState(() {
      _loading = true;
      _loadingMore = more;
      if (!more) _error = null;
    });
    try {
      final page = await widget.source.listDirectory(
        path: requestedPath,
        offset: requestedOffset,
        version: requestedVersion,
      );
      if (!mounted || attempt != _generation) return;
      if (page.path != requestedPath ||
          page.offset != requestedOffset ||
          (requestedVersion != null && page.version != requestedVersion)) {
        throw PlatformException(
          code: 'remote/bad-response',
          message: '电脑返回的目录分页对不上，请刷新后重试。',
        );
      }
      setState(() {
        _entries = _directoryFirst(<RemoteDshFileEntry>[
          if (more) ..._entries,
          ...page.entries,
        ]);
        _root = page.root;
        _version = page.version;
        _nextOffset = page.nextOffset;
        _truncated = page.truncated;
        _loaded = true;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || attempt != _generation) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = _messageOf(error);
      });
    }
  }

  /// 目录项目排在文件前面，组内保持电脑给出的顺序。
  static List<RemoteDshFileEntry> _directoryFirst(
    List<RemoteDshFileEntry> entries,
  ) {
    final directories = <RemoteDshFileEntry>[];
    final files = <RemoteDshFileEntry>[];
    for (final entry in entries) {
      (entry.isDirectory ? directories : files).add(entry);
    }
    return <RemoteDshFileEntry>[...directories, ...files];
  }

  /// 进入子目录：清空旧状态、回到顶部并重新读取。
  void _navigate(String path) {
    if (path == _path) return;
    _generation++;
    setState(() {
      _path = path;
      _entries = const <RemoteDshFileEntry>[];
      _root = null;
      _version = null;
      _nextOffset = null;
      _truncated = false;
      _error = null;
      _loading = false;
      _loadingMore = false;
      _loaded = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    unawaited(_load());
  }

  /// 返回上一级目录；已经在根目录时离开本页。
  void _back() {
    if (_path.isEmpty) {
      Navigator.maybePop(context);
      return;
    }
    final parts = _path.split('/');
    _navigate(parts.take(parts.length - 1).join('/'));
  }

  /// 点按一个项目：目录下一层，文件打开只读文本查看器。
  void _open(RemoteDshFileEntry entry) {
    if (!entry.openable) return;
    if (entry.isDirectory) {
      _navigate(entry.path);
      return;
    }
    unawaited(
      openDestination<void>(
        context,
        destination: RemoteWorkspaceTextPage.destinationFor(entry.path),
        dragBack: false,
        builder: (_) => RemoteWorkspaceTextPage(
          source: widget.source,
          path: entry.path,
          name: entry.name,
        ),
      ),
    );
  }

  /// 文件菜单：刷新与位置信息；本页没有任何写操作。
  Future<void> _showMenu(BuildContext anchor) async {
    if (_loading) return;
    final selected = await showFileBrowserMenu(anchor, <CommonPopupMenuItem>[
      CommonPopupMenuItem(
        label: '刷新文件列表',
        glyph: Icons.refresh_rounded,
        onPressed: _capability.isAvailable ? () {} : null,
      ),
      CommonPopupMenuItem(
        label: '位置信息',
        glyph: Icons.info_outline_rounded,
        onPressed: () {},
      ),
    ]);
    if (!mounted) return;
    if (selected == 0) unawaited(_load());
    if (selected == 1) _showLocation();
  }

  /// 说明入口只读、根目录在哪：本页不提供上传、新建或删除。
  void _showLocation() {
    final root = _root;
    unawaited(
      Navigator.of(context).push<void>(
        PocketRoute<void>(
          builder: (_) => PocketScaffold(
            title: const Text('位置信息'),
            body: PocketList(
              children: <Widget>[
                PocketSection(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: SelectableText(
                        '这台电脑上的只读文件入口。\n\n'
                        '${root ?? '根目录：连接后显示'}\n'
                        '${_path.isEmpty ? '' : '当前相对路径：$_path\n'}'
                        '这里只能查看与读取，不能新建、修改或删除电脑上的文件。',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 可展示的中文说明：门面失败一律是 `PlatformException`（`_pocket_error.message`
  /// 已经是可直接展示的句子）。
  static String _messageOf(Object error) {
    if (error is PlatformException) {
      final message = error.message?.trim();
      if (message != null && message.isNotEmpty) return message;
    }
    return '读取电脑文件失败，请检查连接后重试。';
  }

  /// 头部标题：当前目录名；根目录用入口名。
  String get _title => _path.isEmpty ? '电脑文件' : _path.split('/').last;

  /// 头部的计数文案：已读多少项、是否还有下一页。
  String get _count {
    if (_version == null) {
      return _loading ? '正在读取…' : '尚未读取';
    }
    final more = _nextOffset != null || _truncated;
    return '${more ? '已载入' : '共'} ${_entries.length} 项';
  }

  @override
  Widget build(BuildContext context) {
    final capability = _capability;
    if (!capability.isAvailable) {
      return PocketScaffold(
        title: const Text('电脑文件'),
        body: PocketEmpty(
          child: _FilesNotice(
            icon: Icons.computer_rounded,
            title: '这台电脑不支持浏览文件',
            message: capability.reason ?? '这台电脑没有声明文件浏览能力。',
          ),
        ),
      );
    }
    return PopScope(
      canPop: _path.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _path.isNotEmpty) _back();
      },
      child: FileBrowserChrome(
        title: _title,
        count: _count,
        breadcrumbs: _breadcrumbs(),
        controller: _scroll,
        onBack: _back,
        onMore: (anchor) => unawaited(_showMenu(anchor)),
        children: <Widget>[
          if (_error != null)
            _FilesError(
              message: _error!,
              onRetry: _loading ? null : () => unawaited(_load()),
            ),
          if (_loading && !_loadingMore) const _FilesNote('正在读取目录…'),
          if (_loaded && _entries.isEmpty && !_loading)
            const FileBrowserEmpty(
              message: '此目录为空。',
              hint: '电脑上的这个目录里还没有文件或子目录。',
            ),
          for (final entry in _entries) _entry(entry),
          if (_nextOffset != null)
            PocketButton.tonal(
              key: const ValueKey('remote-files-load-more'),
              onPressed: _loading ? null : () => unawaited(_load(more: true)),
              child: Text(_loadingMore ? '正在加载…' : '加载更多'),
            ),
          if (_truncated) const _FilesNote('目录项目数达到电脑的读取上限，当前列表不完整。'),
        ],
      ),
    );
  }

  List<FileBreadcrumb> _breadcrumbs() {
    if (_path.isEmpty) {
      return <FileBreadcrumb>[const FileBreadcrumb('电脑文件', null)];
    }
    final parts = _path.split('/');
    return <FileBreadcrumb>[
      FileBreadcrumb('电脑文件', () => _navigate('')),
      for (var index = 0; index < parts.length; index++)
        FileBreadcrumb(
          parts[index],
          index == parts.length - 1
              ? null
              : () => _navigate(parts.take(index + 1).join('/')),
        ),
    ];
  }

  Widget _entry(RemoteDshFileEntry entry) {
    final detail = !entry.openable && entry.blockedReason != null
        ? _blockedReasonLabel(entry.blockedReason)
        : <String>[
            if (!entry.isDirectory) _bytesLabel(entry.bytes),
            fileModifiedDate(entry.modifiedAt),
          ].where((part) => part.isNotEmpty).join('  |  ');
    return FileBrowserEntry(
      key: ValueKey<String>(
        'remote-file:${entry.path.isEmpty ? entry.name : entry.path}',
      ),
      name: entry.name,
      directory: entry.isDirectory,
      blocked: !entry.openable,
      detail: detail,
      onTap: entry.openable ? () => _open(entry) : null,
    );
  }
}

/// 只读文本查看器：按字节偏移分段读一个电脑上的文件，`加载更多` 续读。
///
/// 它是文件列表内部的目的地（标识含文件路径），同样走 [openDestination]：同一
/// 文件不会在栈上叠两层。非文本文件由电脑拒绝，这里显示专门的说明而不是一个
/// 空白页。
class RemoteWorkspaceTextPage extends StatefulWidget {
  const RemoteWorkspaceTextPage({
    super.key,
    required this.source,
    required this.path,
    this.name,
  });

  /// 文件查看器的目的地标识前缀。
  static String destinationFor(String path) => 'remote-workspace-file:$path';

  /// 只读文件数据来源。
  final RemoteDshFilesSource source;

  /// 相对工作区根目录的文件路径。
  final String path;

  /// 文件名；电脑没给时用路径最后一段。
  final String? name;

  @override
  State<RemoteWorkspaceTextPage> createState() =>
      _RemoteWorkspaceTextPageState();
}

class _RemoteWorkspaceTextPageState extends State<RemoteWorkspaceTextPage> {
  String _text = '';
  String? _root;
  String? _version;
  String? _error;
  String? _nonText;
  int? _bytes;
  int? _nextOffset;
  bool _eof = true;
  bool _loaded = false;
  bool _loading = false;

  /// 读取代际：重新从头读取作废在途的续页结果。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  /// 读取一段；[more] 为 true 时用上一段返回的偏移与版本续读。
  Future<void> _load({bool more = false}) async {
    if (_loading) return;
    if (more && (_nextOffset == null || _version == null || _eof)) return;
    final attempt = _generation;
    final offset = more ? _nextOffset! : 0;
    setState(() {
      _loading = true;
      if (!more) {
        _error = null;
        _nonText = null;
      }
    });
    try {
      final page = await widget.source.readFile(
        path: widget.path,
        offset: offset,
        version: more ? _version : null,
      );
      if (!mounted || attempt != _generation) return;
      if (page.path != widget.path ||
          page.offset != offset ||
          (more && page.version != _version)) {
        throw PlatformException(
          code: 'remote/bad-response',
          message: '电脑返回的文件分页对不上，请重新打开文件。',
        );
      }
      setState(() {
        _text = more ? '$_text${page.text}' : page.text;
        _root = page.root;
        _version = page.version;
        _bytes = page.bytes;
        _nextOffset = page.nextOffset;
        _eof = page.eof;
        _loaded = true;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || attempt != _generation) return;
      final message = _messageOf(error);
      setState(() {
        _loading = false;
        if (!more && _isNonTextFailure(error)) {
          _nonText = message;
          _error = null;
        } else {
          _error = message;
        }
      });
    }
  }

  /// 重新从头读取：丢弃已读内容，避免把旧版本接在新版本后面。
  void _reload() {
    if (_loading) return;
    _generation++;
    setState(() {
      _text = '';
      _root = null;
      _version = null;
      _bytes = null;
      _nextOffset = null;
      _eof = true;
      _loaded = false;
      _error = null;
      _nonText = null;
    });
    unawaited(_load());
  }

  /// 电脑拒绝读取文本时的可展示说明。
  static String _messageOf(Object error) {
    if (error is PlatformException) {
      final message = error.message?.trim();
      if (message != null && message.isNotEmpty) return message;
    }
    return '读取文件内容失败，请检查连接后重试。';
  }

  /// `workspace-files/not-text` 是电脑对非文本文件的稳定错误码。
  static bool _isNonTextFailure(Object error) =>
      error is PlatformException && error.code == 'workspace-files/not-text';

  @override
  Widget build(BuildContext context) {
    final name = widget.name?.trim();
    final title = name == null || name.isEmpty
        ? widget.path.split('/').last
        : name;
    return PocketScaffold(
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: GlassButton(
        key: const ValueKey('remote-file-reload'),
        icon: Icons.refresh_rounded,
        label: '从头重新读取',
        onPressed: _loading ? null : _reload,
      ),
      bottom: _loaded && !_eof
          ? PocketButton(
              key: const ValueKey('remote-file-load-more'),
              onPressed: _loading ? null : () => unawaited(_load(more: true)),
              child: Text(_loading ? '正在加载…' : '加载更多'),
            )
          : null,
      body: PocketList(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          if (_root != null)
            _FilesNote('${_root ?? '电脑上的工作区'}\n${widget.path}'),
          if (_loading && !_loaded) const _FilesNote('正在读取文件…'),
          if (_nonText != null)
            _FilesNotice(
              icon: Icons.description_outlined,
              title: '这个文件不能作为文本预览',
              message: _nonText!,
            ),
          if (_error != null)
            _FilesError(
              message: _error!,
              onRetry: _loading ? null : () => unawaited(_load()),
            ),
          if (_loaded) _FilesNote(_pageSummary),
          if (_loaded) SelectableText(_text.isEmpty ? '文件为空。' : _text),
        ],
      ),
    );
  }

  /// 已读进度的说明：总字节、当前第几段、是否到文件末尾。
  String get _pageSummary {
    final bytes = _bytes;
    final size = bytes == null ? '' : '${_bytesLabel(bytes)} · ';
    return '$size已读 ${_text.length} 个字符${_eof ? ' · 文件末尾' : ''}';
  }
}

/// 空态、错误与只读说明共用的居中提示。
class _FilesNotice extends StatelessWidget {
  const _FilesNotice({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 40, color: colors.onSurfaceVariant),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: AppTextStyle.title3.of(context, emphasized: true),
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: AppTextStyle.footnote
              .of(context)
              .copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 读取失败提示：宿主 `_pocket_error.message` 原样展示，并给出重试入口。
class _FilesError extends StatelessWidget {
  const _FilesError({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PocketSection(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.cloud_off_rounded, color: colors.error, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(
                  message,
                  style: AppTextStyle.footnote.of(context),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
          child: Align(
            alignment: Alignment.centerLeft,
            child: PocketButton.tonal(
              key: const ValueKey('remote-files-retry'),
              onPressed: onRetry,
              child: const Text('重试读取'),
            ),
          ),
        ),
      ],
    );
  }
}

/// 一行说明文字。
class _FilesNote extends StatelessWidget {
  const _FilesNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    child: SelectableText(text),
  );
}

/// 电脑给出的不可打开原因码对应的中文说明。
String _blockedReasonLabel(String? reason) => switch (reason) {
  'symlink' => '符号链接，不在此入口的读取范围内',
  'not-regular-file' => '不是普通文件或目录',
  'unsupported-name' => '名称无法通过相对路径访问',
  _ => '暂时无法打开',
};

/// 文件大小文案；电脑没给大小时返回空串。
String _bytesLabel(int? bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1048576).toStringAsFixed(1)} MB';
}
