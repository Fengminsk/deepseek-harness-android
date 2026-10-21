import 'dart:async';

import 'package:flutter/foundation.dart';

import 'runtime.dart';

class AccountState extends ChangeNotifier {
  AccountState(this.runtime, this.client)
    : _ready = runtime.ready,
      _runtimeGeneration = runtime.connectionGeneration {
    runtime.addListener(_runtimeChanged);
  }
  final RuntimeController runtime;
  final Json client;
  StreamSubscription<Json>? _subscription;
  Future<void>? _modelInitialization;
  Future<void>? _detailsRefresh;
  Timer? _retry;
  int _retryAttempt = 0;
  bool _watching = false;
  bool _ready;
  int _runtimeGeneration;
  bool _disposed = false;
  int _connection = 0, _details = 0, _modelGeneration = 0;
  int revision = 0;
  bool connected = false, working = false, loadingDetails = false;
  bool profileFresh = false, balanceFresh = false, bonusesFresh = false;
  bool initializingModel = false, _modelRpcAccepted = false;
  Json? view, profile, balance, bonuses;
  String? error,
      detailsError,
      modelInitializationError,
      modelInitializationNotice;
  final Set<String> acknowledged = {};
  final Set<String> _acknowledging = {};
  bool get signedIn => view?['status'] == 'credential-stored';
  Json? get attempt => view?['attempt'] as Json?;

  Future<void> ensureWatching() =>
      _watching || _disposed ? Future.value() : watch();

  void _invalidateDetails() {
    _details++;
    _detailsRefresh = null;
    loadingDetails = false;
    profileFresh = balanceFresh = bonusesFresh = false;
  }

  void _runtimeChanged() {
    final nextReady = runtime.ready;
    final generation = runtime.connectionGeneration;
    if (_ready == nextReady && _runtimeGeneration == generation) return;
    _ready = nextReady;
    _runtimeGeneration = generation;
    connected = false;
    _invalidateDetails();
    _modelGeneration++;
    _modelInitialization = null;
    initializingModel = false;
    _retry?.cancel();
    _retry = null;
    if (nextReady) unawaited(ensureWatching());
    _publish();
  }

  void _retryWatch() {
    if (_disposed || !runtime.ready || _retry != null) return;
    final seconds = 1 << (_retryAttempt > 5 ? 5 : _retryAttempt++);
    _retry = Timer(Duration(seconds: seconds), () {
      _retry = null;
      if (!_disposed && runtime.ready) unawaited(watch());
    });
  }

  Future<dynamic> api(String method, [Json args = const {}]) => runtime.call(
    'api.call',
    {'namespace': 'account', 'method': method, 'args': args},
  );

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  Future<void> watch() async {
    _retry?.cancel();
    _retry = null;
    final connection = ++_connection;
    _watching = true;
    connected = false;
    _invalidateDetails();
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
              final next = frame['value'] as Json;
              final nextAttempt = next['attempt'] as Json?;
              // Match ui-settings-account: the first succeeded snapshot after
              // mounting also qualifies, including an App upgrade after login.
              final initialize =
                  next['status'] == 'credential-stored' &&
                  nextAttempt?['phase'] == 'succeeded' &&
                  attempt?['phase'] != 'succeeded';
              if (next['status'] != view?['status'] ||
                  next['status'] != 'credential-stored' ||
                  nextAttempt?['id'] != attempt?['id']) {
                _invalidateDetails();
                _modelGeneration++;
                _modelInitialization = null;
                initializingModel = false;
                _modelRpcAccepted = false;
                modelInitializationError = null;
                modelInitializationNotice = null;
                profile = balance = bonuses = null;
                acknowledged.clear();
              }
              revision++;
              view = next;
              connected = true;
              _retry?.cancel();
              _retry = null;
              _retryAttempt = 0;
              error = null;
              _publish();
              if (initialize) unawaited(initializeDefaultModel());
              unawaited(refreshDetails());
            } else if (frame['type'] == 'opening' ||
                frame['type'] == 'disconnected') {
              connected = false;
              _invalidateDetails();
              error = frame['type'] == 'disconnected'
                  ? '账号连接已中断，请等待服务恢复或重新连接。'
                  : null;
              _publish();
            }
          },
          onError: (Object failure) {
            if (_disposed || connection != _connection) return;
            connected = false;
            _invalidateDetails();
            error = '无法读取账号状态，请重新连接。';
            _publish();
            // Recoverable errors keep the transport's pending unsubscribe and
            // retry. Only a terminal onDone may create a replacement observer.
          },
          onDone: () {
            if (_disposed || connection != _connection) return;
            connected = false;
            _watching = false;
            _invalidateDetails();
            error ??= '账号连接已结束，请重新连接。';
            _publish();
            _retryWatch();
          },
        );
  }

  /// The core owns the account/API-key decision and default-model selection.
  /// Failure here never changes the already-committed account login state.
  Future<void> initializeDefaultModel() {
    final pending = _modelInitialization;
    if (pending != null) return pending;
    if (_disposed || !connected || !signedIn || !runtime.ready) {
      return Future<void>.value();
    }
    final generation = _modelGeneration;
    initializingModel = true;
    modelInitializationError = null;
    modelInitializationNotice = null;
    _publish();
    late final Future<void> operation;
    operation = _initializeDefaultModel(generation).whenComplete(() {
      if (identical(_modelInitialization, operation)) {
        _modelInitialization = null;
      }
    });
    _modelInitialization = operation;
    return operation;
  }

  Future<void> _initializeDefaultModel(int generation) async {
    bool current() => !_disposed && generation == _modelGeneration && signedIn;
    try {
      if (!_modelRpcAccepted) {
        await runtime.call('api.call', {
          'namespace': 'session',
          'method': 'initializeDefaultModel',
          'args': <String, dynamic>{},
        });
        if (!current()) return;
        _modelRpcAccepted = true;
      }
      // A failed refresh retries only the read, avoiding a second successful
      // initializer after the user may have changed their default elsewhere.
      await runtime.refreshForms();
      if (!current()) return;
      _modelRpcAccepted = false;
      modelInitializationNotice =
          '当前默认模型：${runtime.provider} / ${runtime.model}。已有会话的模型保持不变。';
    } catch (failure) {
      if (!current()) return;
      modelInitializationError = _modelRpcAccepted
          ? '登录已成功，但默认模型配置尚未同步到 App，请重试同步。'
          : '登录已成功，但默认模型初始化未完成，请重试。';
    } finally {
      if (current()) {
        initializingModel = false;
        _publish();
      }
    }
  }

  Future<void> refreshDetails() {
    if (_detailsRefresh != null) return _detailsRefresh!;
    late final Future<void> operation;
    operation = _readDetails().whenComplete(() {
      if (identical(_detailsRefresh, operation)) _detailsRefresh = null;
    });
    return _detailsRefresh = operation;
  }

  Future<void> _readDetails() async {
    final generation = ++_details;
    detailsError = null;
    profileFresh = balanceFresh = bonusesFresh = false;
    if (!signedIn || !connected) {
      loadingDetails = false;
      if (!signedIn) {
        profile = balance = bonuses = null;
        acknowledged.clear();
      }
      _publish();
      return;
    }
    loadingDetails = true;
    _publish();
    Future<void> read(
      String method,
      void Function(Json?) accept, {
      bool requiresReady = false,
    }) async {
      try {
        final value = await api(method, {'client': client});
        if (_disposed || generation != _details || !connected || !signedIn) {
          return;
        }
        if (requiresReady && (value is! Json || value['status'] != 'ready')) {
          // DSH returns {status: failed} for network/protocol failures. Keep a
          // previous ready observation without claiming this read succeeded.
          detailsError = '部分账号信息更新失败，已保留上次读取的信息，可重新刷新。';
        } else {
          accept(value as Json?);
        }
      } catch (failure) {
        if (_disposed || generation != _details) return;
        detailsError = '部分账号信息读取失败，可重新刷新。';
      }
      _publish();
    }

    await Future.wait([
      read('getProfile', (value) {
        profile = value;
        profileFresh = true;
      }, requiresReady: true),
      read('getBalance', (value) {
        balance = value;
        balanceFresh = true;
      }, requiresReady: true),
      read('getUnnotifiedBonuses', (value) {
        bonuses = value;
        bonusesFresh = true;
      }),
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
        !bonusesFresh ||
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
    _modelGeneration++;
    _retry?.cancel();
    runtime.removeListener(_runtimeChanged);
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
