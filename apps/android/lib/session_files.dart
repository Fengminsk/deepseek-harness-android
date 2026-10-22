import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'file_browser_chrome.dart';
import 'flclash/popup.dart';
import 'runtime.dart';
import 'ui.dart';

const _requestTimeout = Duration(seconds: 30);

/// DSH sorts directories first, then names naturally without case sensitivity.
int compareSessionFileNames(String left, String right) {
  final parts = RegExp(r'[0-9]+|[^0-9]+');
  final a = parts.allMatches(left.toLowerCase()).map((m) => m[0]!).toList();
  final b = parts.allMatches(right.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < a.length && i < b.length; i++) {
    final number = RegExp(r'^[0-9]');
    int order;
    if (number.hasMatch(a[i]) && number.hasMatch(b[i])) {
      final x = a[i].replaceFirst(RegExp(r'^0+'), '');
      final y = b[i].replaceFirst(RegExp(r'^0+'), '');
      order = x.length.compareTo(y.length);
      if (order == 0) order = x.compareTo(y);
    } else {
      order = a[i].compareTo(b[i]);
    }
    if (order != 0) return order;
  }
  return a.length.compareTo(b.length);
}

String _fileFailure(Object failure) => switch (failure) {
  PlatformException(code: 'workspace-file/not-found') => '此目录已不存在。',
  PlatformException(code: 'workspace-file/outside-workspace') =>
    '此目录不在当前会话的工作区内。',
  PlatformException(code: 'workspace-file/not-directory') => '此位置已不再是文件夹。',
  PlatformException(code: 'session/not-found') => '此会话已不存在或不可访问。',
  TimeoutException() => '读取超时，请重试。',
  _ => '暂时无法读取会话文件，请重试。',
};

/// Reads the original header-based Session file scope. No create/resume calls,
/// private-directory substitution, attachment import, or filesystem mutations.
class SessionFilesController extends ChangeNotifier {
  SessionFilesController(this.runtime, this.sessionId);
  final RuntimeController runtime;
  final String sessionId;
  String? root, error, watchNotice;
  String path = '';
  List<Json> entries = [];
  bool loading = false, current = false, truncated = false, noWorkspace = false;
  bool automatic = true;
  bool _started = false, _disposed = false, _dirty = false;
  int _generation = 0;
  int _readEpoch = 0;
  late int _connection;
  late String _phase;
  StreamSubscription<Json>? _watch;

  String? get absolutePath => root == null
      ? null
      : path.isEmpty
      ? root
      : '${root!.replaceFirst(RegExp(r'[/\\]+$'), '')}/$path';
  String childPath(String name) => path.isEmpty ? name : '$path/$name';
  bool get canOpen => current && runtime.ready;

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  Future<dynamic> _api(String namespace, String method, Json args) => runtime
      .call('api.call', {
        'namespace': namespace,
        'method': method,
        'args': args,
      })
      .timeout(_requestTimeout);

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _connection = runtime.connectionGeneration;
    _phase = runtime.phase;
    runtime.addListener(_runtimeChanged);
    unawaited(reconnect());
  }

  void _runtimeChanged() {
    if (_connection == runtime.connectionGeneration &&
        _phase == runtime.phase) {
      return;
    }
    _connection = runtime.connectionGeneration;
    _phase = runtime.phase;
    unawaited(reconnect());
  }

  void _retireWatch() {
    final previous = _watch;
    _watch = null;
    if (previous != null) unawaited(previous.cancel());
  }

  /// Session.list reads cold headers too; its cwd is also the original Web tree
  /// root. A missing cwd is a no-workspace state, never an invented fallback.
  Future<void> reconnect() async {
    final generation = ++_generation;
    _retireWatch();
    _dirty = false;
    loading = runtime.ready;
    current = false;
    noWorkspace = false;
    watchNotice = null;
    error = null;
    _publish();
    if (!runtime.ready || _disposed) return;
    try {
      final raw = await _api('session', 'list', {
        '_request': <String, dynamic>{},
      });
      if (!_accept(generation)) return;
      if (raw is! Json || raw['items'] is! List) {
        throw const FormatException('Invalid session list');
      }
      final sessions = (raw['items'] as List).cast<Json>();
      final session = sessions.where((row) => row['sessionId'] == sessionId);
      if (session.isEmpty) {
        throw PlatformException(code: 'session/not-found');
      }
      final nextRoot = session.first['cwd'];
      if (nextRoot != null && (nextRoot is! String || nextRoot.isEmpty)) {
        throw const FormatException('Invalid Session cwd');
      }
      if (root != nextRoot) {
        path = '';
        entries = [];
        truncated = false;
      }
      root = nextRoot as String?;
      noWorkspace = root == null;
      loading = false;
      _publish();
      if (noWorkspace) return;
      _observe(generation);
      await refresh();
    } catch (failure) {
      if (!_accept(generation)) return;
      loading = false;
      error = _fileFailure(failure);
      _publish();
    }
  }

  bool _accept(int generation) =>
      !_disposed && generation == _generation && runtime.ready;

  void _observe(int generation) {
    final target = absolutePath;
    if (target == null || !_accept(generation)) return;
    _watch = runtime
        .watchApi(
          'workspaceFiles',
          'changes',
          args: {'workspaceFileScopeId': sessionId, 'path': target},
        )
        .listen(
          (frame) {
            if (!_accept(generation)) return;
            if (frame['type'] == 'opening' || frame['type'] == 'disconnected') {
              if (frame['type'] == 'disconnected') {
                _readEpoch++;
                current = false;
                loading = false;
              }
              watchNotice = '目录变化尚未同步。';
              _publish();
              return;
            }
            if (frame['type'] == 'end') {
              _watchLost(generation);
              return;
            }
            if (frame['type'] != 'item') return;
            final value = frame['value'];
            if (value is! Json ||
                !['ready', 'change'].contains(value['kind'])) {
              _watchLost(generation);
              return;
            }
            watchNotice = null;
            // Relist even for a repeated directory version: child metadata may
            // change without changing the directory's own version.
            _dirty = true;
            if (value['kind'] == 'ready' || automatic) unawaited(refresh());
            _publish();
          },
          onError: (Object failure) => _watchLost(generation),
          onDone: () => _watchLost(generation),
        );
  }

  void _watchLost(int generation) {
    if (!_accept(generation)) return;
    watchNotice = '自动更新不可用，可手动刷新目录。';
    _publish();
  }

  Future<void> refresh() async {
    if (_disposed || !runtime.ready || root == null) return;
    if (loading) {
      _dirty = true;
      return;
    }
    final generation = _generation, target = absolutePath!, read = ++_readEpoch;
    bool acceptsRead() => _accept(generation) && read == _readEpoch;
    loading = true;
    _publish();
    try {
      do {
        _dirty = false;
        final raw = await _api('workspaceFiles', 'list', {
          'workspaceFileScopeId': sessionId,
          'path': target,
        });
        if (!acceptsRead()) return;
        if (raw is! Json ||
            raw['path'] is! String ||
            raw['entries'] is! List ||
            raw['truncated'] is! bool) {
          throw const FormatException('Invalid workspace listing');
        }
        final rows = (raw['entries'] as List).cast<Json>().toList();
        final names = <String>{};
        for (final row in rows) {
          final name = row['name'];
          if (name is! String ||
              name.isEmpty ||
              name == '.' ||
              name == '..' ||
              name.contains('/') ||
              !names.add(name) ||
              !['directory', 'file', 'other'].contains(row['type']) ||
              row['size'] != null &&
                  (row['size'] is! int || (row['size'] as int) < 0)) {
            throw const FormatException('Invalid workspace entry');
          }
        }
        final originalOrder = {
          for (var index = 0; index < rows.length; index++)
            rows[index]['name']: index,
        };
        rows.sort((a, b) {
          final group = (a['type'] == 'directory' ? 0 : 1).compareTo(
            b['type'] == 'directory' ? 0 : 1,
          );
          if (group != 0) return group;
          final order = compareSessionFileNames(
            a['name'] as String,
            b['name'] as String,
          );
          return order == 0
              ? originalOrder[a['name']]!.compareTo(originalOrder[b['name']]!)
              : order;
        });
        entries = rows;
        truncated = raw['truncated'] as bool;
        current = true;
        error = null;
        _publish();
      } while (_dirty && automatic && acceptsRead());
    } catch (failure) {
      if (!acceptsRead()) return;
      current = false;
      error = _fileFailure(failure);
      _publish();
    } finally {
      if (acceptsRead()) {
        loading = false;
        _publish();
      }
    }
  }

  void navigate(String target) {
    if (_disposed || root == null || target == path) return;
    final generation = ++_generation;
    _retireWatch();
    path = target;
    entries = [];
    current = false;
    loading = false;
    truncated = false;
    error = null;
    watchNotice = null;
    _dirty = false;
    _publish();
    if (!runtime.ready) return;
    _observe(generation);
    unawaited(refresh());
  }

  void setAutomatic(bool value) {
    automatic = value;
    _publish();
    if (value && _dirty) unawaited(refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _retireWatch();
    runtime.removeListener(_runtimeChanged);
    super.dispose();
  }
}

typedef OpenSessionDocument = Future<void> Function(
  BuildContext context,
  String sessionId,
  String path,
);

class SessionFilesPage extends StatefulWidget {
  const SessionFilesPage({
    required this.runtime,
    required this.sessionId,
    required this.onOpenDocument,
    super.key,
  });
  final RuntimeController runtime;
  final String sessionId;
  final OpenSessionDocument onOpenDocument;

  @override
  State<SessionFilesPage> createState() => _SessionFilesPageState();
}

class _SessionFilesPageState extends State<SessionFilesPage>
    with WidgetsBindingObserver {
  late SessionFilesController _model;
  final _scroll = ScrollController();
  final _positions = <String, double>{};
  double? _restore;
  bool _menuOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attach();
  }

  void _attach() {
    _model = SessionFilesController(widget.runtime, widget.sessionId);
    _model.addListener(_changed);
    _model.start();
  }

  @override
  void didUpdateWidget(SessionFilesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime == widget.runtime &&
        oldWidget.sessionId == widget.sessionId) {
      return;
    }
    _model.removeListener(_changed);
    _model.dispose();
    _positions.clear();
    _restore = 0;
    _attach();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_restore != null && _model.current) {
      final offset = _restore!, owner = _model, path = _model.path;
      _restore = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            owner == _model &&
            path == _model.path &&
            _scroll.hasClients) {
          _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_model.reconnect());
  }

  void _navigate(String target) {
    if (_scroll.hasClients) {
      _positions[_model.path] = _scroll.offset;
      _scroll.jumpTo(0);
    }
    _restore = _positions[target] ?? 0;
    _model.navigate(target);
  }

  void _back() {
    if (_model.path.isEmpty) {
      Navigator.maybePop(context);
    } else {
      final parts = _model.path.split('/');
      _navigate(parts.take(parts.length - 1).join('/'));
    }
  }

  Future<void> _open(Json row) async {
    if (!_model.canOpen) return;
    final target = _model.childPath(row['name'] as String);
    if (row['type'] == 'directory') {
      _navigate(target);
      return;
    }
    final owner = _model;
    await widget.onOpenDocument(context, widget.sessionId, target);
    if (mounted && owner == _model) unawaited(owner.refresh());
  }

  Future<void> _menu(BuildContext anchor) async {
    if (_menuOpen) return;
    _menuOpen = true;
    final owner = _model;
    final selected = await showFileBrowserMenu(anchor, [
      CommonPopupMenuItem(
        label: '刷新目录',
        glyph: Icons.refresh_rounded,
        onPressed: widget.runtime.ready ? () {} : null,
      ),
      CommonPopupMenuItem(
        label: _model.automatic ? '暂停自动更新' : '恢复自动更新',
        glyph: _model.automatic
            ? Icons.pause_circle_outline_rounded
            : Icons.play_circle_outline_rounded,
        onPressed: () {},
      ),
      CommonPopupMenuItem(
        label: '位置信息',
        glyph: Icons.info_outline_rounded,
        onPressed: _model.root == null ? null : () {},
      ),
    ]);
    _menuOpen = false;
    if (!mounted || owner != _model) return;
    if (selected == 0) unawaited(_model.reconnect());
    if (selected == 1) _model.setAutomatic(!_model.automatic);
    if (selected == 2) {
      await Navigator.of(context).push<void>(
        PocketRoute(
          builder: (_) => PocketScaffold(
            title: const Text('位置信息'),
            body: PocketList(
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(_model.absolutePath!),
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
    WidgetsBinding.instance.removeObserver(this);
    _model.removeListener(_changed);
    _model.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final path = _model.path,
        parts = path.isEmpty ? <String>[] : path.split('/');
    return PopScope(
      canPop: path.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: FileBrowserChrome(
        title: path.isEmpty ? '会话文件' : parts.last,
        count: _model.noWorkspace
            ? '未设置工作目录'
            : _model.current || _model.entries.isNotEmpty
            ? '${_model.truncated ? '已显示' : '共'} ${_model.entries.length} 项${_model.current ? '' : ' · 待刷新'}'
            : _model.loading
            ? '正在读取…'
            : '尚未读取',
        breadcrumbs: [
          FileBreadcrumb(
            _model.root ?? '会话文件',
            path.isEmpty ? null : () => _navigate(''),
          ),
          for (var i = 0; i < parts.length; i++)
            FileBreadcrumb(
              parts[i],
              i == parts.length - 1
                  ? null
                  : () => _navigate(parts.take(i + 1).join('/')),
            ),
        ],
        controller: _scroll,
        onBack: _back,
        onMore: _menu,
        children: [
          if (!widget.runtime.ready) const _Note('服务已断开，显示上次读取的目录。'),
          if (_model.error != null) ...[
            _Note(_model.error!),
            PocketButton.tonal(
              onPressed: widget.runtime.ready && !_model.loading
                  ? _model.reconnect
                  : null,
              child: const Text('重试'),
            ),
          ],
          if (_model.watchNotice != null) _Note(_model.watchNotice!),
          if (!_model.automatic) const _Note('自动更新已暂停。'),
          if (_model.loading && _model.entries.isEmpty) const _Note('正在读取目录…'),
          if (_model.noWorkspace)
            const FileBrowserEmpty(message: '此会话未设置工作目录。')
          else if (_model.current && _model.entries.isEmpty && !_model.loading)
            const FileBrowserEmpty(),
          for (final row in _model.entries)
            FileBrowserEntry(
              key: ValueKey(
                'session-file-${widget.sessionId}-${_model.childPath(row['name'] as String)}',
              ),
              name: row['name'] as String,
              directory: row['type'] == 'directory',
              blocked: row['type'] == 'other',
              detail: row['type'] == 'other'
                  ? '此类型无法打开'
                  : row['type'] == 'file'
                  ? _size(row['size'] as int?)
                  : '',
              onTap: _model.canOpen && row['type'] != 'other'
                  ? () => _open(row)
                  : null,
            ),
          if (_model.truncated) const _Note('目录项目超过服务的读取上限，当前列表不完整。'),
        ],
      ),
    );
  }
}

String _size(int? bytes) => bytes == null
    ? ''
    : bytes < 1024
    ? '$bytes B'
    : bytes < 1048576
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / 1048576).toStringAsFixed(1)} MB';

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Text(
      text,
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}
