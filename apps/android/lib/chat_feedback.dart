import 'dart:async';

import 'package:flutter/foundation.dart';

import 'runtime.dart';

enum ChatFeedbackRating { positive, negative }

/// The original feedback taxonomy, in the original presentation order.
const chatFeedbackCategories = <String, String>{
  'task-result': '任务结果',
  'instruction-following': '指令理解与遵循',
  'product-interaction': '产品功能与交互',
  'service-stability': '稳定性和速度',
  'resource-cost': '资源使用与费用',
  'security-privacy-permission': '安全隐私与权限',
  'other': '其他',
};

class ChatFeedbackItem {
  const ChatFeedbackItem({
    required this.messageId,
    required this.rating,
    required this.version,
    this.note,
    this.category,
  });
  final String messageId, version;
  final ChatFeedbackRating rating;
  final String? note, category;

  factory ChatFeedbackItem.parse(dynamic raw) {
    if (raw is! Map ||
        raw['messageId'] is! String ||
        (raw['messageId'] as String).isEmpty ||
        raw['version'] is! String ||
        (raw['version'] as String).isEmpty ||
        !['positive', 'negative'].contains(raw['rating']) ||
        (raw['note'] != null && raw['note'] is! String) ||
        (raw['category'] != null &&
            !chatFeedbackCategories.containsKey(raw['category']))) {
      throw const FormatException('反馈记录不完整');
    }
    return ChatFeedbackItem(
      messageId: raw['messageId'],
      rating: ChatFeedbackRating.values.byName(raw['rating']),
      version: raw['version'],
      note: raw['note'],
      category: raw['category'],
    );
  }
}

class ChatFeedbackResult {
  const ChatFeedbackResult.success() : code = null;
  const ChatFeedbackResult.failure(this.code);
  final String? code;
  bool get ok => code == null;
  String get message => switch (code) {
    'version-conflict' => '这条反馈已在别处改动，已显示最新状态。填写内容已保留。',
    'note-too-large' => '描述太长，请缩短后再提交。',
    'note-blank' => '请填写反馈详情，或清空后提交。',
    'session-not-found' => '这段会话已不可用。',
    'target-not-found' => '这条回答尚未保存，无法提交反馈。',
    'connection-changed' => '连接已变化，请核对最新反馈后再提交。填写内容已保留。',
    'unavailable' => '服务尚未就绪，请稍后重试。',
    'disposed' => '这段会话已关闭。',
    _ => '反馈保存失败，填写内容已保留。请重试。',
  };
}

enum ChatFeedbackPhase { cold, loading, ready, error }

/// One Session owns one controller. List/put/delete use the original service,
/// including CAS and durable log ownership; no client mutation is replayed.
class ChatFeedbackController extends ChangeNotifier {
  ChatFeedbackController({required this.runtime, required this.sessionId})
    : _connection = runtime.connectionGeneration,
      _phase = runtime.phase {
    runtime.addListener(_runtimeChanged);
  }

  final RuntimeController runtime;
  final String sessionId;
  ChatFeedbackPhase phase = ChatFeedbackPhase.cold;
  ChatFeedbackResult? failure;
  Map<String, ChatFeedbackItem> _items = const {};
  Map<String, ChatFeedbackItem> get items => _items;
  ChatFeedbackItem? current(String messageId) => _items[messageId];
  bool _disposed = false;
  bool _used = false;
  bool get retired => _disposed;
  int _connection, _epoch = 0;
  String _phase;
  Future<ChatFeedbackResult>? _loading;
  Future<void> _tail = Future.value();
  bool get available => !_disposed && runtime.ready;

  bool _current(int epoch) => !_disposed && epoch == _epoch && runtime.ready;

  Future<dynamic> _api(String method, Json args) => runtime.call('api.call', {
    'namespace': 'messageFeedback',
    'method': method,
    'args': args,
  });

  void _runtimeChanged() {
    if (_connection == runtime.connectionGeneration &&
        _phase == runtime.phase) {
      return;
    }
    final wasUsed = _used;
    _connection = runtime.connectionGeneration;
    _phase = runtime.phase;
    _epoch++;
    _loading = null;
    phase = ChatFeedbackPhase.cold;
    failure = const ChatFeedbackResult.failure('connection-changed');
    notifyListeners();
    if (wasUsed && available) unawaited(resync());
  }

  Future<ChatFeedbackResult> ensure() {
    _used = true;
    if (_disposed) {
      return Future.value(const ChatFeedbackResult.failure('disposed'));
    }
    if (!runtime.ready) {
      return Future.value(const ChatFeedbackResult.failure('unavailable'));
    }
    if (phase == ChatFeedbackPhase.ready) {
      return Future.value(const ChatFeedbackResult.success());
    }
    return _loading ?? _load();
  }

  Future<ChatFeedbackResult> _load() {
    final epoch = _epoch;
    phase = ChatFeedbackPhase.loading;
    failure = null;
    notifyListeners();
    late final Future<ChatFeedbackResult> pending;
    pending = () async {
      try {
        final result = await _api('list', {'sessionId': sessionId});
        if (!_current(epoch)) {
          return const ChatFeedbackResult.failure('connection-changed');
        }
        if (result is! Map || result['ok'] is! bool) {
          throw const FormatException('反馈状态不完整');
        }
        if (result['ok'] != true) return _loadFailure(_businessFailure(result));
        final value = result['value'];
        if (value is! Map || value['items'] is! List) {
          throw const FormatException('反馈列表不完整');
        }
        final items = <String, ChatFeedbackItem>{};
        for (final raw in value['items']) {
          final item = ChatFeedbackItem.parse(raw);
          if (items.containsKey(item.messageId)) {
            throw const FormatException('反馈记录重复');
          }
          items[item.messageId] = item;
        }
        _items = Map.unmodifiable(items);
        phase = ChatFeedbackPhase.ready;
        failure = null;
        notifyListeners();
        return const ChatFeedbackResult.success();
      } catch (_) {
        return _current(epoch)
            ? _loadFailure(const ChatFeedbackResult.failure('load-failed'))
            : const ChatFeedbackResult.failure('connection-changed');
      } finally {
        if (identical(_loading, pending)) _loading = null;
      }
    }();
    return _loading = pending;
  }

  ChatFeedbackResult _loadFailure(ChatFeedbackResult result) {
    phase = ChatFeedbackPhase.error;
    failure = result;
    notifyListeners();
    return result;
  }

  ChatFeedbackResult _businessFailure(Map result, {String? messageId}) {
    final error = result['error'];
    if (error is! Map || error['code'] is! String) {
      throw const FormatException('反馈错误不完整');
    }
    if (error['code'] == 'version-conflict' && messageId != null) {
      final item = error['current'] == null
          ? null
          : ChatFeedbackItem.parse(error['current']);
      if (item != null && item.messageId != messageId) {
        throw const FormatException('反馈返回了不同的消息');
      }
      _commit(messageId, item);
    }
    return ChatFeedbackResult.failure(error['code']);
  }

  void _commit(String messageId, ChatFeedbackItem? item) {
    final next = Map<String, ChatFeedbackItem>.of(_items);
    if (item == null) {
      next.remove(messageId);
    } else {
      next[messageId] = item;
    }
    _items = Map.unmodifiable(next);
    phase = ChatFeedbackPhase.ready;
    failure = null;
    notifyListeners();
  }

  Future<ChatFeedbackResult> _serialize(
    Future<ChatFeedbackResult> Function(int epoch) action,
  ) {
    final epoch = _epoch;
    final result = _tail.then((_) async {
      if (_disposed) return const ChatFeedbackResult.failure('disposed');
      if (!_current(epoch)) {
        return const ChatFeedbackResult.failure('connection-changed');
      }
      try {
        return await action(epoch);
      } catch (_) {
        if (_current(epoch)) {
          // The write may have committed before transport failure. A later
          // explicit action must first read the authoritative state again.
          phase = ChatFeedbackPhase.error;
          failure = const ChatFeedbackResult.failure('transport-failed');
          notifyListeners();
        }
        return ChatFeedbackResult.failure(
          _current(epoch) ? 'transport-failed' : 'connection-changed',
        );
      }
    });
    _tail = result.then<void>((_) {});
    return result;
  }

  /// Reconnection reads queue behind admitted writes, never ahead of them.
  Future<ChatFeedbackResult> resync() => _serialize((epoch) async {
    if (_loading != null) await _loading;
    if (!_current(epoch)) {
      return const ChatFeedbackResult.failure('connection-changed');
    }
    return _load();
  });

  Future<ChatFeedbackResult> rate(
    String messageId,
    ChatFeedbackRating rating, {
    String text = '',
    String? category,
  }) => _serialize((epoch) async {
    final loaded = await ensure();
    if (!loaded.ok) return loaded;
    if (!_current(epoch)) {
      return const ChatFeedbackResult.failure('connection-changed');
    }
    if (category != null && !chatFeedbackCategories.containsKey(category)) {
      return const ChatFeedbackResult.failure('invalid-category');
    }
    final note = text.trim();
    final result = await _api('put', {
      'sessionId': sessionId,
      'messageId': messageId,
      'rating': rating.name,
      if (note.isNotEmpty) 'note': note,
      'category': ?category,
      'ifVersion': current(messageId)?.version,
    });
    if (!_current(epoch)) {
      return const ChatFeedbackResult.failure('connection-changed');
    }
    if (result is! Map || result['ok'] is! bool) {
      throw const FormatException('反馈结果不完整');
    }
    if (result['ok'] != true) {
      return _businessFailure(result, messageId: messageId);
    }
    final item = ChatFeedbackItem.parse(result['value']);
    if (item.messageId != messageId) throw const FormatException('反馈返回了不同的消息');
    _commit(messageId, item);
    return const ChatFeedbackResult.success();
  });

  Future<ChatFeedbackResult> retract(
    String messageId,
    ChatFeedbackRating rating,
  ) => _serialize((epoch) async {
    final loaded = await ensure();
    if (!loaded.ok) return loaded;
    if (!_current(epoch)) {
      return const ChatFeedbackResult.failure('connection-changed');
    }
    final item = current(messageId);
    if (item == null || item.rating != rating) {
      return const ChatFeedbackResult.success();
    }
    final result = await _api('delete', {
      'sessionId': sessionId,
      'messageId': messageId,
      'ifVersion': item.version,
    });
    if (!_current(epoch)) {
      return const ChatFeedbackResult.failure('connection-changed');
    }
    if (result is! Map || result['ok'] is! bool) {
      throw const FormatException('反馈结果不完整');
    }
    if (result['ok'] != true) {
      return _businessFailure(result, messageId: messageId);
    }
    if (result['value'] is! Map || result['value']['absent'] != true) {
      throw const FormatException('反馈撤回状态不完整');
    }
    _commit(messageId, null);
    return const ChatFeedbackResult.success();
  });

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    runtime.removeListener(_runtimeChanged);
    // An open feedback page may outlive its lazy transcript owner.
    scheduleMicrotask(() {
      notifyListeners();
      super.dispose();
    });
  }
}
