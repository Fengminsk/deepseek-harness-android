import 'dart:async';

import 'package:flutter/foundation.dart';

import 'runtime.dart';

class AccountState extends ChangeNotifier {
  AccountState(this.runtime, this.client);
  final RuntimeController runtime;
  final Json client;
  StreamSubscription<Json>? _subscription;
  bool _disposed = false;
  int _connection = 0, _details = 0;
  int revision = 0;
  bool connected = false, working = false, loadingDetails = false;
  Json? view, profile, balance, bonuses;
  String? error, detailsError;
  final Set<String> acknowledged = {};
  final Set<String> _acknowledging = {};
  bool get signedIn => view?['status'] == 'credential-stored';
  Json? get attempt => view?['attempt'] as Json?;

  Future<dynamic> api(String method, [Json args = const {}]) => runtime.call(
    'api.call',
    {'namespace': 'account', 'method': method, 'args': args},
  );

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  Future<void> watch() async {
    final connection = ++_connection;
    connected = false;
    error = null;
    _publish();
    await _subscription?.cancel();
    if (_disposed || connection != _connection) return;
    _subscription = runtime
        .watchApi('account', 'watch')
        .listen(
          (frame) {
            if (_disposed || connection != _connection) return;
            if (frame['type'] == 'item') {
              revision++;
              view = frame['value'] as Json;
              connected = true;
              error = null;
              _publish();
              unawaited(refreshDetails());
            } else if (frame['type'] == 'opening' ||
                frame['type'] == 'disconnected') {
              connected = false;
              _details++;
              loadingDetails = false;
              error = frame['type'] == 'disconnected'
                  ? '账号连接已中断，请等待服务恢复或重新连接。'
                  : null;
              _publish();
            }
          },
          onError: (Object failure) {
            if (_disposed || connection != _connection) return;
            connected = false;
            _details++;
            loadingDetails = false;
            error = '无法读取账号状态，请重新连接。';
            _publish();
          },
          onDone: () {
            if (_disposed || connection != _connection) return;
            connected = false;
            _details++;
            loadingDetails = false;
            error ??= '账号连接已结束，请重新连接。';
            _publish();
          },
        );
  }

  Future<void> refreshDetails() async {
    final generation = ++_details;
    profile = null;
    balance = null;
    bonuses = null;
    detailsError = null;
    if (!signedIn || !connected) {
      loadingDetails = false;
      acknowledged.clear();
      _publish();
      return;
    }
    loadingDetails = true;
    _publish();
    Future<void> read(String method, void Function(Json?) accept) async {
      try {
        final value = await api(method, {'client': client});
        if (_disposed || generation != _details || !connected || !signedIn) {
          return;
        }
        accept(value as Json?);
      } catch (failure) {
        if (_disposed || generation != _details) return;
        detailsError = '部分账号信息读取失败，可重新刷新。';
      }
      _publish();
    }

    await Future.wait([
      read('getProfile', (value) => profile = value),
      read('getBalance', (value) => balance = value),
      read('getUnnotifiedBonuses', (value) => bonuses = value),
    ]);
    if (_disposed || generation != _details) return;
    loadingDetails = false;
    _publish();
  }

  Future<bool> command(Future<dynamic> Function() perform) async {
    if (working || !connected || !runtime.ready) return false;
    working = true;
    error = null;
    _publish();
    try {
      await perform();
      return true;
    } catch (failure) {
      error = '账号操作未完成，请检查连接后重试。';
      return false;
    } finally {
      working = false;
      _publish();
    }
  }

  Future<bool> signIn() =>
      command(() => runtime.call('account.signIn', {'client': client}));
  Future<bool> cancel() async {
    final id = attempt?['id'];
    if (id == null) return false;
    return command(() => api('cancelSignIn', {'attemptId': id}));
  }

  Future<bool> signOut() => command(() => api('signOut', {'client': client}));

  /// Only a foreground notice or an explicit dismissal may call this.
  Future<bool> acknowledge(String accountId, String orderId) async {
    final key = '$accountId/$orderId';
    if (acknowledged.contains(key)) return true;
    if (_acknowledging.contains(key) ||
        !connected ||
        !signedIn ||
        bonuses?['accountId'] != accountId) {
      return false;
    }
    _acknowledging.add(key);
    try {
      final accepted = await api('ackBonusNotified', {
        'accountId': accountId,
        'orderId': orderId,
        'client': client,
      }) as bool;
      if (_disposed || !signedIn || bonuses?['accountId'] != accountId) {
        return false;
      }
      if (accepted) acknowledged.add(key);
      return accepted;
    } catch (failure) {
      return false;
    } finally {
      _acknowledging.remove(key);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _connection++;
    _details++;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

String accountAttemptLabel(String phase) => switch (phase) {
  'initializing' => '正在准备授权',
  'waiting-browser' => '等待你完成官方授权',
  'exchanging' => '正在验证授权',
  'committing' => '正在保存登录凭据',
  'succeeded' => '授权完成',
  'cancelled' => '授权已取消',
  'expired' => '授权已过期，请重新登录',
  'failed' => '授权失败，请重新登录',
  _ => phase,
};

String accountAttemptError(String code) => switch (code) {
  'no-response' => '未收到平台响应，请检查网络连接。',
  'network' => '平台请求失败，请检查网络后重试。',
  'protocol' => '平台授权响应无效，请重新发起登录。',
  'expired' => '这次授权已过期，请重新登录。',
  'storage' => '无法保存登录凭据，请检查本地服务状态。',
  _ => '无法完成授权，请重新登录。',
};
