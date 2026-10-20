import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'runtime.dart';

const subagentRequestTimeout = Duration(seconds: 30);

/// The direct-parent address is part of every read and control operation.
/// A child id alone is not authority to continue or interrupt that child.
class SubagentAddress {
  const SubagentAddress({
    required this.parentSessionId,
    required this.childSessionId,
    required this.mode,
  });

  final String parentSessionId, childSessionId, mode;

  factory SubagentAddress.fromJson(Json value) => SubagentAddress(
    parentSessionId: value['parentSessionId'] as String,
    childSessionId: value['childSessionId'] as String,
    mode: value['mode'] as String,
  );

  Json get json => {
    'parentSessionId': parentSessionId,
    'childSessionId': childSessionId,
    'mode': mode,
  };

  String get key => '$parentSessionId/$childSessionId';
}

String subagentModeLabel(String? mode) => switch (mode) {
  'continuable' => '可继续',
  'one-shot' => '一次性',
  'external' => '外部任务',
  _ => '模式待确认',
};

String subagentReadOnlyExplanation(String? reason) => switch (reason) {
  'one-shot' => '一次性任务不支持后续消息，可在这里查看执行记录。',
  'external' => '此项为外部任务，不能作为本地子会话继续发送消息。',
  'parent-unavailable' => '父会话当前未运行。需要继续时，请先回到父会话。',
  'unknown' => '子会话身份尚未确认，当前仅可查看记录。',
  _ => '子会话状态尚未确认，请刷新后再操作。',
};

String subagentRequestId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// A transport failure leaves the exact submitted draft and identity available
/// for read-only reconciliation. It never creates another request implicitly.
class SubagentSubmission {
  SubagentSubmission({
    required this.requestId,
    required this.text,
    required this.delivery,
  });

  final String requestId, text, delivery;
  String? messageId;
  bool unconfirmed = false;
}

class _RetainedSubmission {
  const _RetainedSubmission(this.submission, this.draft, this.delivery);
  final SubagentSubmission submission;
  final String draft, delivery;
}

// Leaving a page does not turn an uncertain admission into a new submission.
// State belongs to this App connection and is released with its controller.
final _retainedSubmissions = Expando<Map<String, _RetainedSubmission>>(
  'subagent-unconfirmed',
);

String subagentFailureCode(Object failure) =>
    failure is PlatformException ? failure.code : 'unconfirmed';

bool _rejectedBeforeAdmission(Object failure) =>
    failure is PlatformException &&
    const {
      'gateway/bad-request',
      'subagent/invalid-time-zone',
      'subagent/parent-unavailable',
      'subagent/not-resumable',
      'subagent/unauthorized',
      'subagent/attachment-invalid',
      'subagent/delivery-unavailable',
    }.contains(failure.code);

List<Json> _events(dynamic records) => (records as List)
    .cast<Json>()
    .where((record) => record['type'] == 'event')
    .map((record) => record['event'] as Json)
    .toList();

List<Json> _mergeEvents(List<Json> older, List<Json> newer) {
  final values = {for (final event in older) event['seq'] as int: event};
  for (final event in newer) {
    final seq = event['seq'] as int;
    if (!_sameValue(values[seq], event)) values[seq] = event;
  }
  final ordered = values.keys.toList()..sort();
  final merged = ordered.map((seq) => values[seq]!).toList();
  return listEquals(older, merged) ? older : merged;
}

bool _sameValue(dynamic left, dynamic right) {
  if (identical(left, right)) return true;
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every(
          (key) => right.containsKey(key) && _sameValue(left[key], right[key]),
        );
  }
  if (left is List && right is List) {
    return left.length == right.length &&
        Iterable<int>.generate(left.length)
            .every((index) => _sameValue(left[index], right[index]));
  }
  return left == right;
}

/// One page's read-only cache and explicit control requests. The original core
/// owns activation, admission, ordering, cancellation and persisted messages.
class SubagentConversation extends ChangeNotifier {
  SubagentConversation(this.runtime, this.address) {
    _phase = runtime.phase;
    _taskEpoch = runtime.taskState['epoch'];
    final retained = _retainedSubmissions[runtime]?[address.key];
    if (retained != null) {
      submission = retained.submission;
      draft = retained.draft;
      delivery = retained.delivery;
      actionMessage = '上次发送结果未确认，原文与请求标识已恢复。正在只读核对，未自动重发。';
    }
    runtime.addListener(_runtimeChanged);
  }

  final RuntimeController runtime;
  SubagentAddress address;
  Json? inspection;
  List<Json> events = [];
  bool current = false, loading = false, loadingOlder = false;
  bool sending = false, interrupting = false, stopping = false;
  bool hasMore = false, historyReset = false;
  String? error, actionMessage;
  String draft = '', delivery = 'queue';
  SubagentSubmission? submission;
  int? cursor;
  int _generation = 0;
  bool _disposed = false, _refreshAgain = false, _replaceHistory = false;
  late String _phase;
  Object? _taskEpoch;

  Json get capabilities => (inspection?['capabilities'] as Json?) ?? {};
  Json get task => (inspection?['task'] as Json?) ?? {};
  bool get canPrompt =>
      current && runtime.ready && capabilities['canPrompt'] == true;
  bool get canInterrupt =>
      current && runtime.ready && capabilities['canInterrupt'] == true;
  bool get canSend =>
      canPrompt && !sending && submission == null && draft.trim().isNotEmpty;
  bool get uncertain => submission?.unconfirmed == true;

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void _runtimeChanged() {
    final epoch = runtime.taskState['epoch'];
    if (runtime.phase == _phase && epoch == _taskEpoch) return;
    _phase = runtime.phase;
    _taskEpoch = epoch;
    _generation++;
    _replaceHistory = true;
    current = false;
    loading = false;
    loadingOlder = false;
    _refreshAgain = false;
    _publish();
    // Reconnecting only reads. An unresolved request is never replayed.
    if (runtime.ready) unawaited(refresh());
  }

  void edit(String value) {
    draft = value;
    _publish();
  }

  void selectDelivery(String value) {
    if (sending ||
        submission != null ||
        !const ['queue', 'steer'].contains(value)) {
      return;
    }
    delivery = value;
    _publish();
  }

  Future<void> refresh() async {
    if (_disposed || !runtime.ready) return;
    if (loading || loadingOlder) {
      _refreshAgain = true;
      return;
    }
    final generation = _generation;
    loading = true;
    _publish();
    try {
      final value =
          await runtime
                  .call('subagents.inspect', {
                    'address': address.json,
                    'maxMessages': 50,
                    if (submission != null) 'requestId': submission!.requestId,
                  })
                  .timeout(subagentRequestTimeout)
              as Json;
      if (_disposed || generation != _generation || !runtime.ready) return;
      final nextAddress = SubagentAddress.fromJson(value['address'] as Json);
      if (nextAddress.key != address.key) {
        throw const FormatException('Mismatched child address');
      }
      final snapshot = value['snapshot'] as Json;
      final nextCursor = snapshot['cursor'] as int;
      final next = _events(snapshot['records']);
      // A latest window that jumps over the old cut cannot silently manufacture
      // a continuous transcript. Older history remains explicitly pageable.
      final gap =
          cursor != null &&
          next.isNotEmpty &&
          (next.first['seq'] as int) > cursor! + 1;
      final replace =
          _replaceHistory || cursor == null || nextCursor < cursor! || gap;
      if (replace) {
        historyReset = cursor != null;
        events = next;
        hasMore = snapshot['hasMore'] == true;
      } else {
        events = _mergeEvents(events, next);
        // Once the beginning has been read, a shorter tail cannot hide it.
        if (next.isNotEmpty &&
            events.isNotEmpty &&
            next.first['seq'] == events.first['seq']) {
          hasMore = snapshot['hasMore'] == true;
        }
      }
      address = nextAddress;
      inspection = value;
      cursor = nextCursor;
      _replaceHistory = false;
      current = true;
      error = null;
      if (stopping && capabilities['running'] == false) {
        stopping = false;
        actionMessage = '核心已确认当前没有执行中的回合，排队输入保留。';
      }
      final observed = value['submission'] as Json?;
      final pending = submission;
      if (pending != null &&
          observed?['requestId'] == pending.requestId &&
          observed?['state'] == 'observed') {
        _accepted(pending, observed?['messageId'] as String?);
      }
    } catch (failure) {
      if (!_disposed && generation == _generation) {
        current = false;
        error = '子会话状态未确认，请刷新核对。错误：${subagentFailureCode(failure)}';
      }
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        _publish();
        if (_refreshAgain) {
          _refreshAgain = false;
          unawaited(refresh());
        }
      }
    }
  }

  Future<void> loadOlder() async {
    if (_disposed ||
        !current ||
        !runtime.ready ||
        !hasMore ||
        loading ||
        loadingOlder ||
        events.isEmpty ||
        cursor == null) {
      return;
    }
    final generation = _generation;
    final cut = cursor!;
    final before = events.first['seq'] as int;
    loadingOlder = true;
    _publish();
    try {
      final value =
          await runtime
                  .call('subagents.page', {
                    'address': address.json,
                    'throughSeq': cut,
                    'beforeSeq': before,
                    'maxMessages': 50,
                  })
                  .timeout(subagentRequestTimeout)
              as Json;
      if (_disposed || generation != _generation || !runtime.ready) return;
      final older = _events(value['records']);
      if (older.any((event) => (event['seq'] as int) >= before)) {
        throw const FormatException('Invalid older page boundary');
      }
      events = _mergeEvents(older, events);
      hasMore = value['hasMore'] == true;
      historyReset = false;
      error = null;
    } catch (failure) {
      if (!_disposed && generation == _generation) {
        error = '较早记录未能加载，已显示的内容保留。错误：${subagentFailureCode(failure)}';
      }
    } finally {
      if (!_disposed && generation == _generation) {
        loadingOlder = false;
        _publish();
        if (_refreshAgain) {
          _refreshAgain = false;
          unawaited(refresh());
        }
      }
    }
  }

  void _accepted(SubagentSubmission pending, String? messageId) {
    if (!identical(submission, pending)) return;
    pending.messageId = messageId;
    if (draft == pending.text) draft = '';
    submission = null;
    _retainedSubmissions[runtime]?.remove(address.key);
    actionMessage = '消息已被接收；执行结果以会话记录为准。';
  }

  Future<void> send() async {
    if (!canSend || _disposed) return;
    final generation = _generation;
    final pending = SubagentSubmission(
      requestId: subagentRequestId(),
      text: draft,
      delivery: delivery,
    );
    submission = pending;
    sending = true;
    actionMessage = null;
    _publish();
    try {
      final receipt =
          await runtime
                  .call('subagents.send', {
                    'address': address.json,
                    'requestId': pending.requestId,
                    'text': pending.text,
                    'delivery': pending.delivery,
                  })
                  .timeout(subagentRequestTimeout)
              as Json;
      final messageId = receipt['messageId'];
      if (messageId is! String || messageId.isEmpty) {
        throw const FormatException('Missing admission identity');
      }
      if (generation != _generation) {
        throw const FormatException('Receipt belongs to an earlier runtime');
      }
      if (!_disposed) _accepted(pending, messageId);
    } catch (failure) {
      if (!_disposed && identical(submission, pending)) {
        if (_rejectedBeforeAdmission(failure)) {
          submission = null;
          actionMessage = '核心未接受消息，原文已保留。错误：${subagentFailureCode(failure)}';
        } else {
          pending.unconfirmed = true;
          actionMessage = '发送结果未确认，原文与请求标识已保留。请刷新核对，未自动重发。';
        }
      }
    } finally {
      if (!_disposed) {
        sending = false;
        _publish();
        await refresh();
      }
    }
  }

  Future<void> interrupt() async {
    if (_disposed || !canInterrupt || interrupting || stopping) return;
    final generation = _generation;
    interrupting = true;
    actionMessage = null;
    _publish();
    try {
      final receipt =
          await runtime
                  .call('subagents.interrupt', {'address': address.json})
                  .timeout(subagentRequestTimeout)
              as Json;
      if (receipt['accepted'] != true) {
        throw const FormatException('Missing interrupt acknowledgement');
      }
      if (generation != _generation) {
        throw const FormatException('Receipt belongs to an earlier runtime');
      }
      if (!_disposed) {
        stopping = true;
        actionMessage = '停止请求已接收，等待核心确认。排队输入保留。';
      }
    } catch (failure) {
      if (!_disposed) {
        actionMessage = '停止结果未确认，请刷新核对当前状态。未自动重试。';
      }
    } finally {
      if (!_disposed) {
        interrupting = false;
        _publish();
        await refresh();
      }
    }
  }

  @override
  void dispose() {
    final pending = submission;
    if (pending != null) {
      pending.unconfirmed = true;
      (_retainedSubmissions[runtime] ??= {})[address.key] = _RetainedSubmission(
        pending,
        draft,
        delivery,
      );
    }
    _disposed = true;
    _generation++;
    runtime.removeListener(_runtimeChanged);
    super.dispose();
  }
}
