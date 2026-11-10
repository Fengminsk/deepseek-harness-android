import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'runtime.dart';

/// One visible route owns a prepare-then-launch request; leaving cancels it.
class ExternalFileOpenController with WidgetsBindingObserver {
  static final Random _random = Random.secure();
  String? _active;
  bool _disposed = false;

  ExternalFileOpenController() {
    WidgetsBinding.instance.addObserver(this);
  }

  /// ModalRoute.of subscribes the owning page to isCurrent changes. A request
  /// invalidated while another route covers the page must stay invalid even
  /// after the user returns to it.
  void observeRoute(BuildContext context) {
    if (ModalRoute.of(context)?.isCurrent != true) cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) cancel();
  }

  static String _requestId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> open(
    BuildContext context, {
    String? root,
    String? sessionId,
    required String path,
  }) async {
    assert(root == null || sessionId == null);
    final id = await _prepare(context, root: root, sessionId: sessionId, path: path);
    if (id == null) return;
    try {
      await RuntimeController.channel.invokeMethod<void>(
        'file.launchPrepared',
        {'requestId': id},
      );
    } catch (failure) {
      if (!context.mounted) {
        cancel();
        return;
      }
      if (!_owns(context, id)) {
        cancel();
        return;
      }
      final message = failure is PlatformException
          ? failure.message ?? '无法交给其他应用打开，请重试。'
          : '无法交给其他应用打开，请重试。';
      _notify(context, message);
    } finally {
      if (_active == id) _active = null;
    }
  }

  /// Save the addressed file through the system picker without changing its bytes.
  ///
  /// @returns `saved`, `cancelled`, or `unconfirmed` when the native outcome is
  ///   unknown; a failure message is shown before returning `unconfirmed`.
  Future<String> save(
    BuildContext context, {
    String? root,
    String? sessionId,
    required String path,
  }) async {
    assert(root == null || sessionId == null);
    final id = await _prepare(context, root: root, sessionId: sessionId, path: path);
    if (id == null) return 'cancelled';
    try {
      final raw = await RuntimeController.channel.invokeMethod<String>(
        'file.savePrepared',
        {'requestId': id},
      );
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is! Json || decoded['status'] is! String) {
        throw const FormatException('保存结果尚未确认');
      }
      return decoded['status'] as String;
    } on PlatformException catch (failure) {
      if (!context.mounted) return 'unconfirmed';
      _notify(context, failure.message ?? '保存未完成，请检查所选位置。');
      return 'unconfirmed';
    } catch (_) {
      if (!context.mounted) return 'unconfirmed';
      _notify(context, '保存结果尚未确认，请检查所选位置是否留下了不完整文件。');
      return 'unconfirmed';
    } finally {
      if (_active == id) _active = null;
    }
  }

  /// Put the addressed image on the clipboard.
  ///
  /// @returns true when the clipboard accepted it; a message is shown on failure.
  Future<bool> copyImage(
    BuildContext context, {
    String? root,
    String? sessionId,
    required String path,
  }) async {
    assert(root == null || sessionId == null);
    final id = await _prepare(context, root: root, sessionId: sessionId, path: path);
    if (id == null) return false;
    try {
      await RuntimeController.channel.invokeMethod<void>(
        'file.copyPrepared',
        {'requestId': id},
      );
      return true;
    } on PlatformException catch (failure) {
      if (!context.mounted) return false;
      _notify(context, failure.message ?? '无法复制图片，请重试。');
      return false;
    } catch (_) {
      if (!context.mounted) return false;
      _notify(context, '无法复制图片，请重试。');
      return false;
    } finally {
      if (_active == id) _active = null;
    }
  }

  /// Stage the addressed file and return its request id, or null when this
  /// route no longer owns the request.
  Future<String?> _prepare(
    BuildContext context, {
    String? root,
    String? sessionId,
    required String path,
  }) async {
    if (_disposed || ModalRoute.of(context)?.isCurrent != true) return null;
    cancel();
    final id = _requestId();
    _active = id;
    final arguments = <String, Object?>{'requestId': id, 'path': path};
    if (root != null) arguments['root'] = root;
    if (sessionId != null) arguments['sessionId'] = sessionId;
    try {
      await RuntimeController.channel.invokeMethod<void>(
        sessionId != null
            ? 'file.openSession'
            : root == null
            ? 'file.openWorkspace'
            : 'file.openDocument',
        arguments,
      );
    } catch (failure) {
      if (!context.mounted) {
        cancel();
        return null;
      }
      if (!_owns(context, id)) {
        cancel();
        return null;
      }
      final message = failure is PlatformException
          ? failure.message ?? '无法准备文件，请重试。'
          : '无法准备文件，请重试。';
      _notify(context, message);
      if (_active == id) _active = null;
      return null;
    }
    if (!context.mounted) {
      cancel();
      return null;
    }
    if (!_owns(context, id)) {
      cancel();
      return null;
    }
    return id;
  }

  bool _owns(BuildContext context, String id) =>
      _active == id &&
      !_disposed &&
      context.mounted &&
      ModalRoute.of(context)?.isCurrent == true;

  void _notify(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void cancel() {
    final id = _active;
    _active = null;
    if (id == null) return;
    unawaited(
      RuntimeController.channel
          .invokeMethod<bool>('file.cancelOpen', {'requestId': id})
          .then((_) {}, onError: (Object _) {}),
    );
  }

  void dispose() {
    _disposed = true;
    cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}

/// Text stays readable in the built-in reader; other formats go to an installed app.
bool fileLikelyText(String name, {String? mimeType}) {
  if (mimeType?.startsWith('text/') == true ||
      mimeType == 'application/json' ||
      mimeType == 'application/xml') {
    return true;
  }
  final extension = name.toLowerCase().split('.').last;
  return {
    'txt',
    'md',
    'markdown',
    'log',
    'json',
    'jsonl',
    'yaml',
    'yml',
    'xml',
    'csv',
    'tsv',
    'html',
    'css',
    'js',
    'jsx',
    'ts',
    'tsx',
    'dart',
    'kt',
    'java',
    'py',
    'sh',
    'bash',
    'c',
    'h',
    'cpp',
    'hpp',
    'rs',
    'go',
    'sql',
    'toml',
    'ini',
    'properties',
    'gradle',
    'gitignore',
    'env',
  }.contains(extension);
}
