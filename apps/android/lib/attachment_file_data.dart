import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'runtime.dart';

class AttachmentFileReference {
  const AttachmentFileReference({
    required this.sessionId,
    required this.attachmentId,
    required this.name,
  });

  factory AttachmentFileReference.fromMessage(String sessionId, Json value) {
    final id = value['attachmentId'], name = value['name'];
    if (sessionId.isEmpty ||
        id is! String ||
        id.isEmpty ||
        name is! String ||
        name.isEmpty) {
      throw const FormatException('文件缺少有效的会话引用。');
    }
    return AttachmentFileReference(
      sessionId: sessionId,
      attachmentId: id,
      name: name,
    );
  }

  final String sessionId, attachmentId, name;
}

class PreparedAttachmentFile {
  const PreparedAttachmentFile(this.id, this.filename, this.size, this.isText);
  final String id, filename;
  final int size;
  final bool isText;

  factory PreparedAttachmentFile.parse(dynamic value, String id, String name) {
    if (value is! Json ||
        value['id'] != id ||
        value['filename'] != name ||
        value['size'] is! int ||
        (value['size'] as int) < 0 ||
        !const ['text', 'binary'].contains(value['previewKind'])) {
      throw const FormatException('附件读取结果不完整，请重新打开。');
    }
    return PreparedAttachmentFile(
      id,
      name,
      value['size'] as int,
      value['previewKind'] == 'text',
    );
  }
}

class AttachmentTextPage {
  const AttachmentTextPage(this.text, this.offset, this.nextOffset, this.eof);
  final String text;
  final int offset, nextOffset;
  final bool eof;

  factory AttachmentTextPage.parse(dynamic value, int offset, int size) {
    if (value is! Json ||
        value['text'] is! String ||
        value['offset'] != offset ||
        value['size'] != size ||
        value['nextOffset'] is! int ||
        value['eof'] is! bool) {
      throw const FormatException('文件分段信息不完整。');
    }
    final next = value['nextOffset'] as int, eof = value['eof'] as bool;
    if (next < offset ||
        next > size ||
        (!eof && next <= offset) ||
        eof != (next == size)) {
      throw const FormatException('文件分段位置无效。');
    }
    return AttachmentTextPage(value['text'] as String, offset, next, eof);
  }
}

class _AttachmentRead {
  _AttachmentRead(this.id, this.connection);
  final String id;
  final int connection;
}

enum AttachmentFileFailure { prepare, read, save, connection }

/// Owns one historical attachment view. Reconnection preserves displayed text
/// but never repeats a read or a system Save As without another user action.
class AttachmentFileController extends ChangeNotifier {
  AttachmentFileController(this.runtime, this.reference)
    : _connection = runtime.connectionGeneration,
      _online = runtime.ready {
    runtime.addListener(_runtimeChanged);
  }

  final RuntimeController runtime;
  final AttachmentFileReference reference;
  int _connection;
  bool _online, _disposed = false;
  _AttachmentRead? _request;
  final _releasing = <String, Future<void>>{};
  final _unreleased = <String>{};
  PreparedAttachmentFile? file;
  AttachmentTextPage? page;
  final _starts = <int>[0];
  int pageIndex = 0;
  int _retryIndex = 0, _retryOffset = 0;
  int _readEpoch = 0;
  bool preparing = false, reading = false, saving = false, cleaning = false;
  bool current = false;
  String? error, message, cleanupError;
  AttachmentFileFailure? failureKind;

  bool get canPrepare =>
      !_disposed &&
      runtime.ready &&
      _request == null &&
      !preparing &&
      !cleaning &&
      _unreleased.isEmpty &&
      _releasing.isEmpty;
  bool get canRead =>
      !_disposed &&
      current &&
      runtime.ready &&
      file?.isText == true &&
      !reading &&
      !saving &&
      !cleaning;
  bool get canSave =>
      !_disposed &&
      current &&
      runtime.ready &&
      file != null &&
      !preparing &&
      !saving &&
      !cleaning;
  bool get canPrevious => canRead && pageIndex > 0;
  bool get canNext => canRead && page != null && !page!.eof;
  bool get hasRequest => _request != null;
  bool get busy => preparing || reading || saving || cleaning;

  bool _owns(_AttachmentRead request) =>
      !_disposed &&
      identical(_request, request) &&
      runtime.ready &&
      request.connection == runtime.connectionGeneration;

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void _runtimeChanged() {
    final generation = runtime.connectionGeneration, online = runtime.ready;
    if (_connection == generation && _online == online) return;
    final invalid = _connection != generation || (_online && !online);
    _connection = generation;
    _online = online;
    if (invalid) {
      final previous = _request;
      _request = null;
      _readEpoch++;
      current = false;
      preparing = false;
      reading = false;
      error = saving
          ? '连接已变化，保存结果尚未确认。请检查所选位置，文件可能不完整。'
          : '连接已变化，已显示的内容尚未核实。请重新读取附件。';
      failureKind = AttachmentFileFailure.connection;
      saving = false;
      if (previous != null) unawaited(_release(previous.id));
    }
    _publish();
  }

  static String _newId() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> prepare() async {
    if (!canPrepare) return;
    final request = _AttachmentRead(_newId(), runtime.connectionGeneration);
    _request = request;
    preparing = true;
    current = false;
    error = null;
    failureKind = null;
    message = null;
    _publish();
    try {
      final result = await runtime.call('session.attachmentFile.prepare', {
        'id': request.id,
        'sessionId': reference.sessionId,
        'attachmentId': reference.attachmentId,
        'name': reference.name,
      });
      if (!_owns(request)) return;
      file = PreparedAttachmentFile.parse(result, request.id, reference.name);
      current = true;
      preparing = false;
      _starts
        ..clear()
        ..add(0);
      pageIndex = 0;
      _retryIndex = 0;
      _retryOffset = 0;
      page = null;
      _publish();
      if (file!.isText) await read(0, 0);
    } catch (failure) {
      if (!_owns(request)) return;
      _request = null;
      current = false;
      preparing = false;
      error = '附件未能打开，原会话和文件未改变。\n$failure';
      failureKind = AttachmentFileFailure.prepare;
      _publish();
      await _release(request.id);
    }
  }

  /// A complete successful page replaces the displayed segment, keeping memory
  /// bounded even when the source file has many pages.
  Future<void> read(int index, int offset) async {
    final request = _request, prepared = file;
    if (!canRead || request == null || prepared == null) return;
    final epoch = ++_readEpoch;
    _retryIndex = index;
    _retryOffset = offset;
    reading = true;
    error = null;
    failureKind = null;
    _publish();
    try {
      final result = await runtime.call('session.attachmentFile.read', {
        'id': request.id,
        'offset': offset,
      });
      if (!_owns(request) || epoch != _readEpoch) return;
      final next = AttachmentTextPage.parse(result, offset, prepared.size);
      page = next;
      pageIndex = index;
      _starts.removeRange(index + 1, _starts.length);
      if (!next.eof) _starts.add(next.nextOffset);
    } catch (failure) {
      if (_owns(request) && epoch == _readEpoch) {
        error = '这段内容未能读取，已显示的内容仍保留。\n$failure';
        failureKind = AttachmentFileFailure.read;
      }
    } finally {
      if (_owns(request) && epoch == _readEpoch) {
        reading = false;
        _publish();
      }
    }
  }

  Future<void> previous() async {
    if (canPrevious) await read(pageIndex - 1, _starts[pageIndex - 1]);
  }

  Future<void> next() async {
    if (canNext) await read(pageIndex + 1, page!.nextOffset);
  }

  Future<void> retryRead() => read(_retryIndex, _retryOffset);

  Future<void> save() async {
    final request = _request, prepared = file;
    if (!canSave || request == null || prepared == null) return;
    saving = true;
    error = null;
    failureKind = null;
    message = null;
    _publish();
    try {
      final raw = await RuntimeController.channel.invokeMethod<String>(
        'attachmentFile.save',
        {'id': request.id, 'filename': prepared.filename},
      );
      if (!_owns(request)) return;
      final result = raw == null ? null : jsonDecode(raw);
      if (result is! Json ||
          !const ['saved', 'cancelled'].contains(result['status'])) {
        throw const FormatException('保存结果尚未确认，请检查目标位置。');
      }
      if (result['status'] == 'saved') {
        if (result['filename'] != prepared.filename ||
            result['bytes'] != prepared.size) {
          throw const FormatException('保存的文件信息不匹配，请检查目标位置。');
        }
        message = '已保存 ${prepared.filename}';
      } else {
        message = result['partialDestination'] == true
            ? '已取消保存，所选位置可能留下不完整的文件。'
            : '已取消保存。';
      }
    } catch (failure) {
      if (_owns(request)) {
        error = '保存未完成，请检查所选位置；可能留下不完整的文件。\n$failure';
        failureKind = AttachmentFileFailure.save;
      }
    } finally {
      if (_owns(request)) {
        saving = false;
        _publish();
      }
    }
  }

  Future<void> cancel() async {
    final request = _request;
    if (request == null || cleaning) return;
    final wasSaving = saving;
    _request = null;
    _readEpoch++;
    current = false;
    preparing = false;
    reading = false;
    saving = false;
    cleaning = true;
    error = null;
    failureKind = null;
    message = wasSaving ? '已取消本次操作。若已选择保存位置，请检查是否留下不完整文件。' : '已取消读取附件。';
    _publish();
    await _release(request.id);
    cleaning = false;
    _publish();
  }

  Future<void> retryCleanup() async {
    if (cleaning) return;
    cleaning = true;
    _publish();
    await Future.wait(_unreleased.toList().map(_release));
    cleaning = false;
    _publish();
  }

  Future<void> _release(String id) {
    return _releasing[id] ??= _releaseOnce(id).whenComplete(() {
      _releasing.remove(id);
      _publish();
    });
  }

  Future<void> _releaseOnce(String id) async {
    _unreleased.add(id);
    try {
      // Stop the system copy before releasing the cache it may still read.
      await RuntimeController.channel.invokeMethod<void>(
        'attachmentFile.cancelSave',
        {'id': id},
      );
      await runtime.call('session.attachmentFile.release', {'id': id});
      _unreleased.remove(id);
      cleanupError = _unreleased.isEmpty ? null : cleanupError;
    } catch (failure) {
      cleanupError = '临时副本清理尚未确认，可重试清理。';
    }
    _publish();
  }

  @override
  void dispose() {
    runtime.removeListener(_runtimeChanged);
    _disposed = true;
    final request = _request;
    _request = null;
    _readEpoch++;
    if (request != null) unawaited(_release(request.id));
    for (final id in _unreleased.toList()) {
      unawaited(_release(id));
    }
    super.dispose();
  }
}
