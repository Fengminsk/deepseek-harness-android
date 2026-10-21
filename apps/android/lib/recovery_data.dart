import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'runtime.dart';

String recoveryRequestId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((n) => n.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String recoveryFailure(Object failure) => failure is PlatformException
    ? '${failure.message ?? '原生恢复操作未完成'}（${failure.code}）'
    : failure is TimeoutException
    ? '等待结果超时。操作可能仍在处理，请刷新回执核对，不要重复提交。'
    : '返回结果未能确认，请刷新核对。';

bool _notStarted(Object failure, String requestId) =>
    failure is PlatformException &&
    failure.details is Map &&
    failure.details['outcome'] == 'not-started' &&
    failure.details['requestId'] == requestId;

class RecoveryDocument {
  RecoveryDocument(Json value)
    : id = value['id'] as String,
      base = value['text'] as String,
      draft = value['text'] as String,
      sha256 = value['sha256'] as String,
      existed = value['exists'] == true;
  final String id;
  String base, draft, sha256;
  bool existed, checking = false;
  Json? observed;
  String? requestId, requestGeneration, error;
  Json? receipt;
  bool get dirty => draft != base;
  bool get conflict => observed != null && observed!['sha256'] != sha256;
}

/// This controller uses native IPC even when the Node runtime cannot load.
class RecoveryController extends ChangeNotifier {
  RecoveryController(this.runtime) {
    runtime.addListener(_runtimeChanged);
  }
  final RuntimeController runtime;
  final documents = <String, RecoveryDocument>{};
  Json state = {};
  Json? pendingAction, actionReceipt;
  String? error, readError, notice, _startingGeneration;
  bool loading = false, working = false, awaitingReady = false, current = false;
  bool startupUnconfirmed = false, _disposed = false;
  int _reads = 0;
  Timer? _startupDeadline;
  String? _phase, _generation;

  bool get maintenance =>
      current &&
      state['mode'] == 'maintenance' &&
      state['nodeStarted'] == false &&
      state['mutationAllowed'] == true;
  String? get generation => state['generation'] as String?;
  bool get hasPendingDocument =>
      documents.values.any((document) => document.requestId != null);
  List<Json> get files => (state['files'] as List? ?? []).cast<Json>();
  List<Json> get backups => (state['backups'] as List? ?? []).cast<Json>();
  List<Json> get operations =>
      (state['operations'] as List? ?? []).cast<Json>();
  Json get boot => (state['boot'] as Json?) ?? {};

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void _runtimeChanged() {
    if (_disposed) return;
    if ((awaitingReady || startupUnconfirmed) &&
        runtime.nativeGeneration == _startingGeneration &&
        (runtime.ready || runtime.phase == 'failed')) {
      awaitingReady = false;
      _startupDeadline?.cancel();
      startupUnconfirmed = false;
      if (runtime.ready) {
        notice = '原 DSH 已报告就绪。配置已加载；具体工具仍需按实际操作核对。';
      } else {
        error = '服务仍未恢复：${runtime.error ?? '启动失败'}。可重新进入维护模式修正或恢复备份。';
      }
    }
    if (_phase != runtime.phase || _generation != runtime.nativeGeneration) {
      _phase = runtime.phase;
      _generation = runtime.nativeGeneration;
      _reads++;
      loading = false;
      current = false;
      if (!working) unawaited(load());
    }
    _publish();
  }

  Future<Json> _decode(Future<String?> call) async {
    final raw = await call.timeout(const Duration(seconds: 25));
    if (raw == null) throw const FormatException('Missing native receipt');
    final result = jsonDecode(raw);
    if (result is! Json) throw const FormatException('Invalid native receipt');
    return result;
  }

  Future<Json> call(String method, [Json params = const {}]) => _decode(
    RuntimeController.channel.invokeMethod<String>(
      'recovery.call',
      jsonEncode({'method': method, 'params': params}),
    ),
  );

  Future<void> load() async {
    if (_disposed) return;
    final read = ++_reads;
    loading = true;
    _publish();
    try {
      final snapshot = await call('inspect');
      if (snapshot['mode'] != 'active' && snapshot['mode'] != 'maintenance' ||
          snapshot['generation'] is! String ||
          snapshot['nodeStarted'] is! bool ||
          snapshot['files'] is! List ||
          snapshot['backups'] is! List ||
          snapshot['operations'] is! List) {
        throw const FormatException('Invalid recovery state');
      }
      if (_disposed || read != _reads) return;
      state = snapshot;
      current = true;
      readError = null;
    } catch (failure) {
      if (!_disposed && read == _reads) {
        current = false;
        readError = recoveryFailure(failure);
      }
    } finally {
      if (!_disposed && read == _reads) {
        loading = false;
        _publish();
      }
    }
  }

  Future<void> changeMode({required bool enter}) async {
    if (working) return;
    working = true;
    error = null;
    notice = null;
    _startupDeadline?.cancel();
    startupUnconfirmed = false;
    awaitingReady = false;
    _publish();
    try {
      final receipt = await _decode(
        RuntimeController.channel.invokeMethod<String>(
          enter ? 'recovery.enter' : 'recovery.resume',
          {'requestId': recoveryRequestId()},
        ),
      );
      if (_disposed) return;
      final target = enter ? 'maintenance' : 'active';
      if (receipt['mode'] != target || receipt['generation'] is! String) {
        throw const FormatException('Unconfirmed recovery mode');
      }
      if (enter) {
        notice = '已进入维护模式，旧 Agent 进程已退出。此模式不运行任务或 Web。';
      } else if (runtime.ready &&
          runtime.nativeGeneration == receipt['generation']) {
        awaitingReady = false;
        notice = '原 DSH 已报告就绪。';
      } else if (runtime.phase == 'failed' &&
          runtime.nativeGeneration == receipt['generation']) {
        error = '服务仍未恢复：${runtime.error ?? '启动失败'}。可重新进入维护模式修正或恢复备份。';
      } else {
        _startingGeneration = receipt['generation'] as String;
        awaitingReady = true;
        notice = '已请求使用保存的配置启动，正在等待 DSH 确认。';
        _startupDeadline = Timer(const Duration(seconds: 60), () {
          if (_disposed || !awaitingReady) return;
          awaitingReady = false;
          startupUnconfirmed = true;
          notice = '启动尚未确认。没有推断进程已停止，也不会自动重试。可查看状态或重新进入维护模式。';
          _publish();
        });
      }
    } catch (failure) {
      if (_disposed) return;
      awaitingReady = false;
      error = recoveryFailure(failure);
    } finally {
      if (!_disposed) {
        working = false;
        _publish();
        await load();
      }
    }
  }

  Future<Json> read(String fileId) async {
    final value = await call('read', {'fileId': fileId});
    if (value['id'] != fileId ||
        value['text'] is! String ||
        value['sha256'] is! String) {
      throw const FormatException('Invalid recovery document');
    }
    return value;
  }

  Future<RecoveryDocument> open(String fileId) async {
    final value = await read(fileId);
    final document = documents.putIfAbsent(
      fileId,
      () => RecoveryDocument(value),
    );
    document.observed = value;
    _publish();
    return document;
  }

  void useLatest(RecoveryDocument document) {
    final observed = document.observed;
    if (observed == null || working || document.requestId != null) return;
    document.base = observed['text'] as String;
    document.sha256 = observed['sha256'] as String;
    document.existed = observed['exists'] == true;
    document.error = null;
    _publish();
  }

  Future<Json?> mutate(String method, Json params) async {
    if (!maintenance || generation == null || working) return null;
    working = true;
    error = null;
    notice = null;
    _publish();
    try {
      return await call(method, {...params, 'generation': generation});
    } catch (failure) {
      if (!_disposed) error = recoveryFailure(failure);
      rethrow;
    } finally {
      if (!_disposed) {
        working = false;
        _publish();
        await load();
      }
    }
  }

  Future<void> save(RecoveryDocument document) async {
    if (document.requestId != null || document.conflict || !document.dirty) {
      return;
    }
    if (!maintenance || working || pendingAction != null) return;
    final requestId = recoveryRequestId();
    final submitted = document.draft;
    document.requestId = requestId;
    document.requestGeneration = generation;
    document.receipt = null;
    document.error = null;
    try {
      final receipt = await mutate('write', {
        'fileId': document.id,
        'expectedSha256': document.sha256,
        'text': submitted,
        'requestId': requestId,
      });
      if (receipt == null) {
        document.requestId = null;
        return;
      }
      if (receipt['state'] != 'saved' || receipt['sha256'] is! String) {
        throw const FormatException('Unconfirmed document write');
      }
      document
        ..base = submitted
        ..sha256 = receipt['sha256'] as String
        ..existed = true
        ..observed = null
        ..requestId = null;
      notice = '文件已保存并保留旧版本。尚未验证配置能否启动。';
    } catch (failure) {
      document.error = recoveryFailure(failure);
      // The native journal, not a timeout or configured-state observation,
      // decides whether this exact write completed.
      if (_notStarted(failure, requestId)) {
        try {
          final latest = await read(document.id);
          if (document.requestId == requestId) document.observed = latest;
        } catch (_) {
          // Native rejection is already definitive; a failed read does not
          // make that rejected write uncertain or discard the user's draft.
        }
        if (document.requestId == requestId) document.requestId = null;
      } else {
        await checkReceipt(document);
      }
    }
    _publish();
  }

  Future<void> checkReceipt(RecoveryDocument document) async {
    final requestId = document.requestId;
    if (requestId == null || document.checking || _disposed) return;
    document.checking = true;
    _publish();
    try {
      final receipt = await call('receipt', {'requestId': requestId});
      if (_disposed || document.requestId != requestId) return;
      document.receipt = receipt;
      if (receipt['state'] == 'saved' && receipt['sha256'] is String) {
        final current = await read(document.id);
        if (_disposed || document.requestId != requestId) return;
        document
          ..observed = current
          ..requestId = null;
        if (current['sha256'] == receipt['sha256']) {
          document
            ..base = current['text'] as String
            ..sha256 = current['sha256'] as String
            ..existed = current['exists'] == true;
        }
        document.error = null;
        notice = '已核对原生保存回执。当前文件与草稿可继续比较。';
      } else if (receipt['state'] == 'rejected' ||
          receipt['state'] == 'failed') {
        final current = await read(document.id);
        if (_disposed || document.requestId != requestId) return;
        document.requestId = null;
        document.error = '${receipt['message'] ?? '原生服务报告本次操作未完成'}。草稿保留。';
        document.observed = current;
      } else {
        document.error = '本次保存结果仍未确认；已保留草稿和请求记录，不会重新发送。';
      }
    } catch (_) {
      if (!_disposed && document.requestId == requestId) {
        document.error = '无法读取本次保存回执。已保留草稿与请求记录，不会重新发送。';
      }
    } finally {
      document.checking = false;
      _publish();
    }
  }

  bool canResolveDocument(RecoveryDocument document) =>
      maintenance &&
      !working &&
      document.requestId != null &&
      document.receipt?['state'] == 'unknown' &&
      document.requestGeneration != generation;

  /// Explicitly accepts a fresh baseline after the old writer is known dead.
  /// The original unknown receipt remains in the native journal.
  Future<void> resolveDocument(RecoveryDocument document) async {
    if (!canResolveDocument(document)) return;
    final request = document.requestId;
    try {
      final latest = await read(document.id);
      if (!canResolveDocument(document) || document.requestId != request) {
        return;
      }
      document
        ..observed = latest
        ..base = latest['text'] as String
        ..sha256 = latest['sha256'] as String
        ..existed = latest['exists'] == true
        ..requestId = null
        ..error = null;
      notice = '已采用当前文件作为新的编辑基准，草稿保留。原操作仍记录为未确认，没有重发。';
    } catch (failure) {
      document.error = recoveryFailure(failure);
    }
    _publish();
  }

  /// Retains ownership of restore/repair requests across route changes. A timeout
  /// never turns into permission to resend an operation whose outcome is unknown.
  Future<Json?> trackedMutation(String method, Json params) async {
    if (pendingAction != null || working || !maintenance) return null;
    if (hasPendingDocument) {
      return null;
    }
    final requestId = recoveryRequestId();
    pendingAction = {
      'requestId': requestId,
      'method': method,
      'fileId': params['fileId'],
      'generation': generation,
      'state': 'pending',
    };
    actionReceipt = null;
    try {
      final receipt = await mutate(method, {...params, 'requestId': requestId});
      if (receipt == null) {
        pendingAction = null;
        return null;
      }
      if (receipt['state'] != 'saved' && receipt['state'] != 'quarantined') {
        throw const FormatException('Unconfirmed recovery operation');
      }
      actionReceipt = receipt;
      pendingAction = null;
      notice = method == 'restore'
          ? '备份已恢复。尚未验证配置能否启动，已有编辑草稿保留。'
          : '运行资源已隔离。恢复运行后将从当前安装包重新解包。';
      return receipt;
    } catch (failure) {
      error = recoveryFailure(failure);
      if (_notStarted(failure, requestId)) {
        if (pendingAction?['requestId'] == requestId) pendingAction = null;
      } else {
        await checkAction();
      }
      return actionReceipt;
    } finally {
      _publish();
    }
  }

  Future<void> checkAction() async {
    final pending = pendingAction;
    if (pending == null) return;
    try {
      final receipt = await call('receipt', {
        'requestId': pending['requestId'],
      });
      if (pendingAction?['requestId'] != pending['requestId']) return;
      final status = receipt['state'];
      if (status == 'saved' || status == 'quarantined') {
        actionReceipt = receipt;
        pendingAction = null;
        error = null;
        notice = '已核对原生操作回执。请刷新文件状态；配置是否可运行仍需启动验证。';
      } else if (status == 'failed' || status == 'rejected') {
        pendingAction = null;
        error = '${receipt['message'] ?? '原生操作未完成'}。没有重新提交。';
      } else {
        pendingAction = {...pending, 'state': status ?? 'unconfirmed'};
        error = '本次操作结果尚未确认，保留请求记录且不会重复提交。';
      }
    } catch (_) {
      error = '无法读取本次操作回执；没有重复提交。';
    }
    _publish();
  }

  bool get canAcknowledgeAction =>
      maintenance &&
      !working &&
      pendingAction?['state'] == 'unknown' &&
      pendingAction?['generation'] != generation;

  void acknowledgeAction() {
    if (!canAcknowledgeAction) return;
    pendingAction = null;
    error = null;
    notice = '原操作保留为未确认记录，没有重新提交。请先核对当前文件及运行资源状态。';
    _publish();
  }

  @override
  void dispose() {
    _disposed = true;
    _reads++;
    _startupDeadline?.cancel();
    runtime.removeListener(_runtimeChanged);
    super.dispose();
  }
}
