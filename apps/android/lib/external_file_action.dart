import 'dart:async';
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
    if (_disposed || ModalRoute.of(context)?.isCurrent != true) return;
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
      if (_active != id ||
          _disposed ||
          !context.mounted ||
          ModalRoute.of(context)?.isCurrent != true) {
        cancel();
        return;
      }
      await RuntimeController.channel.invokeMethod<void>(
        'file.launchPrepared',
        {'requestId': id},
      );
    } catch (failure) {
      if (_active != id ||
          _disposed ||
          !context.mounted ||
          ModalRoute.of(context)?.isCurrent != true) {
        cancel();
        return;
      }
      final message = failure is PlatformException
          ? failure.message ?? '无法交给其他应用打开，请重试。'
          : '无法交给其他应用打开，请重试。';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (_active == id) _active = null;
    }
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
